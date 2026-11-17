--[[
ZIM file reader. Implements just enough of the ZIM v5/v6 format
(https://wiki.openzim.org/wiki/ZIM_file_format) for offline Wikipedia:

  * Header parse, MIME list parse
  * Directory entry read (article + redirect)
  * Binary search of the URL pointer list (which is sorted by namespace+url)
  * Prefix search by walking forward from the binary-search insertion point
  * Cluster + blob fetch (delegated to cluster.lua for decompression)

Redirects are resolved transparently in :readArticle().
]]

local logger = require("logger")
local Cluster = require("cluster")
local SplitFile = require("splitfile")

local ZIM = {}
ZIM.__index = ZIM

local MAGIC = 0x44D495A

-- little-endian unpackers (1-based offsets, matching string.byte)
local function u16(s, o) return s:byte(o) + s:byte(o+1)*256 end
local function u32(s, o)
    return s:byte(o) + s:byte(o+1)*256 + s:byte(o+2)*65536 + s:byte(o+3)*16777216
end
local function u64(s, o)
    -- ZIM offsets fit comfortably in a Lua double (2^53 = 8 PB)
    return u32(s, o) + u32(s, o+4) * 4294967296
end

-- Read a chunk and return everything up to (and excluding) the next NUL.
-- Reads from current file position, advancing it. Used for url/title strings.
local function read_cstring(f)
    local parts = {}
    while true do
        local chunk = f:read(256)
        if not chunk or #chunk == 0 then break end
        local nul = chunk:find("\0", 1, true)
        if nul then
            parts[#parts+1] = chunk:sub(1, nul - 1)
            -- rewind so the file cursor lands just past the NUL
            local consumed = nul
            f:seek("cur", consumed - #chunk)
            return table.concat(parts)
        end
        parts[#parts+1] = chunk
    end
    return table.concat(parts)
end

-- Open `path` as either:
--   * a regular file (single .zim under 4 GB), or
--   * a virtual concatenation of part files (.zimaa, .zimab, …) when the
--     ZIM had to be split for FAT32 (>4 GB max file size on Kindle storage).
-- Accepts either the base name (".../wiki.zim") or the first part directly.
local function open_zim_handle(path)
    -- 1) If the path looks like a split part (e.g. wiki.zimaa, wiki.zimab),
    --    derive the base name and open ALL parts as one virtual file.
    --    This check must come BEFORE io.open because the part file exists on
    --    disk but is only a slice of the full ZIM — opening it alone would
    --    make every seek beyond the first part return nil.
    local base_from_part = path:match("^(.+%.zim)%l%l$")
    if base_from_part then
        local parts = SplitFile.findParts(base_from_part)
        if #parts > 0 then
            local sf, err = SplitFile.open(parts)
            if not sf then return nil, nil, err end
            return sf, sf.total, "split:" .. #parts
        end
    end
    -- 2) Regular single-file ZIM.
    local f = io.open(path, "rb")
    if f then
        local size = f:seek("end"); f:seek("set", 0)
        return f, size, "single"
    end
    -- 3) User pointed at the (nonexistent) base name and parts sit beside it.
    local parts = SplitFile.findParts(path)
    if #parts > 0 then
        local sf, err = SplitFile.open(parts)
        if not sf then return nil, nil, err end
        return sf, sf.total, "split:" .. #parts
    end
    return nil, nil, "cannot open " .. path
end

function ZIM.open(path)
    local f, file_size, mode_or_err = open_zim_handle(path)
    if not f then return nil, mode_or_err end

    local h = f:read(80)
    if not h or #h < 80 then f:close(); return nil, "ZIM header truncated" end
    if u32(h, 1) ~= MAGIC then
        f:close()
        return nil, "not a ZIM file (bad magic number)"
    end

    local self = setmetatable({
        path             = path,
        file             = f,
        file_size        = file_size,
        open_mode        = mode_or_err,
        major            = u16(h, 5),
        minor            = u16(h, 7),
        article_count    = u32(h, 25),
        cluster_count    = u32(h, 29),
        url_ptr_pos      = u64(h, 33),
        title_ptr_pos    = u64(h, 41),
        cluster_ptr_pos  = u64(h, 49),
        mime_list_pos    = u64(h, 57),
        main_page        = u32(h, 65),
        layout_page      = u32(h, 69),
        checksum_pos     = u64(h, 73),
        cluster_cache    = Cluster.newCache(),
        _sparse_index    = nil,
    }, ZIM)

    -- MIME list: NUL-terminated strings, terminated by an empty string.
    f:seek("set", self.mime_list_pos)
    self.mimes = {}
    while true do
        local s = read_cstring(f)
        if s == "" then break end
        self.mimes[#self.mimes + 1] = s
        if #self.mimes > 1000 then break end -- sanity
    end

    return self
end

function ZIM:close()
    if self.file then self.file:close(); self.file = nil end
    if self.cluster_cache then self.cluster_cache:clear() end
    self._sparse_index = nil
    self._url_index_cache = nil
    self._url_index_cache_keys = nil
end

function ZIM:mimeOf(idx) return self.mimes[idx + 1] end

-- Read 8 bytes from the URL pointer list and return the dirent file offset.
function ZIM:_direntOffset(article_idx)
    local f = self.file
    f:seek("set", self.url_ptr_pos + article_idx * 8)
    local b = f:read(8)
    return u64(b, 1)
end

-- Parse a directory entry at the given file offset. We always need the URL
-- (for binary search) and usually the title.
-- Optimized: single buffered read (512B) parses header, url and title in memory,
-- eliminating multi-seek disk churn on FAT32 flash storage.
function ZIM:_readDirent(off, want_title)
    local f = self.file
    f:seek("set", off)
    local buf = f:read(512)
    if not buf or #buf < 8 then return nil end

    local mime = u16(buf, 1)
    local param_len = buf:byte(3)
    local ns = string.char(buf:byte(4))
    local rev = u32(buf, 5)

    local entry = {
        offset    = off,
        mime      = mime,
        namespace = ns,
        revision  = rev,
        param_len = param_len,
    }
    local strings_buf_start
    local strings_file_off
    if mime == 0xFFFF then
        entry.kind = "redirect"
        if #buf >= 12 then
            entry.redirect_idx = u32(buf, 9)
        end
        strings_buf_start = 13
        strings_file_off  = off + 12
    elseif mime == 0xFFFE or mime == 0xFFFD then
        entry.kind = "deleted"
        strings_buf_start = 9
        strings_file_off  = off + 8
    else
        entry.kind = "article"
        if #buf >= 16 then
            entry.cluster = u32(buf, 9)
            entry.blob    = u32(buf, 13)
        end
        strings_buf_start = 17
        strings_file_off  = off + 16
    end

    local nul1 = buf:find("\0", strings_buf_start, true)
    if nul1 then
        entry.url = buf:sub(strings_buf_start, nul1 - 1)
        if want_title then
            local title_start = nul1 + 1
            local nul2 = buf:find("\0", title_start, true)
            if nul2 then
                entry.title = buf:sub(title_start, nul2 - 1)
                if entry.title == "" then entry.title = entry.url end
            else
                -- Fallback if title exceeded the initial 512-byte buffer
                f:seek("set", strings_file_off + #entry.url + 1)
                entry.title = read_cstring(f)
                if entry.title == "" then entry.title = entry.url end
            end
        end
    else
        -- Fallback if URL exceeded the initial 512-byte buffer
        f:seek("set", strings_file_off)
        entry.url = read_cstring(f)
        if want_title then
            entry.title = read_cstring(f)
            if entry.title == "" then entry.title = entry.url end
        end
    end

    return entry
end

-- Cheap URL-only fetch for the binary search inner loop.
-- Optimized: single buffered read (256B) extracts namespace and URL in memory
-- with 1 seek instead of 3 seeks + 2 reads + backwards seek.
function ZIM:_readUrlAt(off)
    local f = self.file
    f:seek("set", off)
    local buf = f:read(256)
    if not buf or #buf < 8 then return nil, nil end

    local mime = u16(buf, 1)
    local ns = string.char(buf:byte(4))
    local strings_buf_start
    if mime == 0xFFFF then
        strings_buf_start = 13
    elseif mime == 0xFFFE or mime == 0xFFFD then
        strings_buf_start = 9
    else
        strings_buf_start = 17
    end

    local nul = buf:find("\0", strings_buf_start, true)
    if nul then
        return ns, buf:sub(strings_buf_start, nul - 1)
    end

    -- Fallback for rare extra-long URLs
    local strings_file_off = off + strings_buf_start - 1
    f:seek("set", strings_file_off)
    return ns, read_cstring(f)
end

-- Resolve many paths by their directory index.
--
-- The word index stores each article's index into the URL pointer table, so
-- resolving a hit is one seek and one small read — no binary search at all.
-- `indices` is a sorted array of entry indices.
function ZIM:entriesForIndices(indices)
    local out = {}
    if not indices then return out end
    for _, idx in ipairs(indices) do
        if idx >= 0 and idx < self.article_count then
            local entry = self:getEntryByIndex(idx)
            if entry and entry.kind ~= "deleted" then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

function ZIM:getEntryByIndex(idx)
    if idx < 0 or idx >= self.article_count then return nil end
    local off = self:_direntOffset(idx)
    return self:_readDirent(off, true)
end

-- Lazily builds a lightweight in-memory sparse index (256 anchors)
-- to narrow binary search range by ~99% before doing any disk seeks.
function ZIM:_ensureSparseIndex()
    if self._sparse_index ~= nil then return self._sparse_index end
    local count = self.article_count
    if count < 512 then
        self._sparse_index = false
        return false
    end
    local num_anchors = 256
    local step = count / (num_anchors + 1)
    local anchors = {}
    for i = 1, num_anchors do
        local idx = math.floor(i * step)
        local off = self:_direntOffset(idx)
        local ns, url = self:_readUrlAt(off)
        if ns and url then
            anchors[#anchors + 1] = { idx = idx, key = ns .. url }
        end
    end
    self._sparse_index = anchors
    return self._sparse_index
end

-- Binary search returns (idx, exact_match). If not exact, idx is the
-- insertion point — where prefix scanning should start.
-- Optimized: uses in-memory MRU cache (64 entries) and sparse anchor index.
function ZIM:findUrlIndex(namespace, target_url)
    local target_key = namespace .. target_url

    if not self._url_index_cache then
        self._url_index_cache = {}
        self._url_index_cache_keys = {}
    end
    local cached = self._url_index_cache[target_key]
    if cached ~= nil then
        return cached.idx, cached.exact
    end

    local lo, hi = 0, self.article_count - 1

    local anchors = self:_ensureSparseIndex()
    if anchors and #anchors > 0 then
        local a_lo, a_hi = 1, #anchors
        while a_lo <= a_hi do
            local a_mid = math.floor((a_lo + a_hi) / 2)
            local a = anchors[a_mid]
            if a.key <= target_key then
                lo = a.idx
                a_lo = a_mid + 1
            else
                hi = a.idx
                a_hi = a_mid - 1
            end
        end
    end

    local res_idx, res_exact = lo, false
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local off = self:_direntOffset(mid)
        local ns, url = self:_readUrlAt(off)
        if not ns then
            res_idx, res_exact = lo, false
            break
        end
        local key = ns .. url
        if key == target_key then
            res_idx, res_exact = mid, true
            break
        elseif key < target_key then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    if not res_exact then
        res_idx = lo
    end

    if #self._url_index_cache_keys >= 64 then
        local oldest = table.remove(self._url_index_cache_keys, 1)
        self._url_index_cache[oldest] = nil
    end
    self._url_index_cache_keys[#self._url_index_cache_keys + 1] = target_key
    self._url_index_cache[target_key] = { idx = res_idx, exact = res_exact }

    return res_idx, res_exact
end

-- Exact match lookup using binary search. Returns directory entry or nil.
function ZIM:findExact(namespace, target_url)
    local idx, exact = self:findUrlIndex(namespace, target_url)
    if exact then
        local entry = self:getEntryByIndex(idx)
        if entry and entry.kind ~= "deleted" then
            return entry
        end
    end
    return nil
end

-- Walk forward from the insertion point collecting entries whose namespace
-- matches and whose url starts with the prefix. Stops at the first miss.
-- Optimized: batches pointer offsets and uses single-pass _readDirent,
-- avoiding duplicate reads of the exact same dirent offset.
function ZIM:prefixSearch(namespace, prefix, max_results)
    max_results = max_results or 50
    local idx = select(1, self:findUrlIndex(namespace, prefix))
    local results = {}
    local plen = #prefix
    local f = self.file

    while #results < max_results and idx < self.article_count do
        local batch_size = math.min(32, self.article_count - idx)
        f:seek("set", self.url_ptr_pos + idx * 8)
        local ptr_buf = f:read(batch_size * 8)
        if not ptr_buf or #ptr_buf < 8 then break end
        local available = math.floor(#ptr_buf / 8)

        local done = false
        for b = 0, available - 1 do
            local off = u64(ptr_buf, b * 8 + 1)
            local entry = self:_readDirent(off, true)
            if not entry then
                done = true
                break
            end
            if entry.namespace ~= namespace then
                done = true
                break
            end
            if entry.url:sub(1, plen) ~= prefix then
                done = true
                break
            end
            if entry.kind ~= "deleted" then
                results[#results + 1] = entry
                if #results >= max_results then
                    done = true
                    break
                end
            end
            idx = idx + 1
        end

        if done then break end
    end
    return results
end

function ZIM:resolveRedirect(entry, max_hops)
    max_hops = max_hops or 8
    local hops = 0
    while entry and entry.kind == "redirect" and hops < max_hops do
        entry = self:getEntryByIndex(entry.redirect_idx)
        hops = hops + 1
    end
    return entry
end

-- Read the cluster pointer table to determine where a cluster begins/ends,
-- so we know how many bytes to read.
function ZIM:_clusterRange(cluster_num)
    local f = self.file
    f:seek("set", self.cluster_ptr_pos + cluster_num * 8)
    local b = f:read(16)
    local start_off = u64(b, 1)
    local end_off
    if cluster_num + 1 < self.cluster_count then
        end_off = u64(b, 9)
    else
        end_off = self.checksum_pos -- last cluster ends just before the MD5
    end
    return start_off, end_off
end

-- Returns the (uncompressed) blob string for entry.cluster / entry.blob.
function ZIM:readBlob(cluster_num, blob_num)
    local cached = self.cluster_cache:get(cluster_num)
    if not cached then
        local cstart, cend = self:_clusterRange(cluster_num)
        self.file:seek("set", cstart)
        local info = self.file:read(1):byte(1)
        local data = self.file:read(cend - cstart - 1)
        cached = Cluster.parse(info, data)
        self.cluster_cache:put(cluster_num, cached)
    end
    return cached:getBlob(blob_num)
end

-- Sizes of every blob in one cluster, as an array.
-- The word index needs a size for each article; asking per article would
-- re-read and re-inflate the same cluster thousands of times (47k articles
-- live in only ~500 clusters), which is what made indexing run out of memory.
function ZIM:clusterBlobSizes(cluster_num)
    -- Deliberately does NOT go through cluster_cache. The index build walks
    -- every cluster in order, and caching each parsed payload (compressed and
    -- inflated copies alive at once) peaked near 1 GB on a 493-cluster wiki —
    -- more than the device has. Parse, read the sizes, drop the payload.
    local cstart, cend = self:_clusterRange(cluster_num)
    self.file:seek("set", cstart)
    local info = self.file:read(1):byte(1)
    local data = self.file:read(cend - cstart - 1)
    local parsed = Cluster.parse(info, data)
    local sizes = {}
    for i = 0, parsed.num_blobs - 1 do
        sizes[i] = parsed:blobSize(i)
    end
    parsed.payload = nil
    parsed = nil
    data = nil
    return sizes
end

-- Size of one blob, and do not keep the parsed cluster around.
-- The word index asks for tens of thousands of sizes while building; caching
-- every cluster's decompressed payload (493 clusters, ~1 MB each on a
-- 47k-article wiki) exhausted a 485 MB device and the kernel killed the
-- reader mid-build.
function ZIM:clusterBlobSize(cluster_num, blob_num)
    local cached = self.cluster_cache:get(cluster_num)
    if cached then
        return cached:blobSize(blob_num)
    end
    local cstart, cend = self:_clusterRange(cluster_num)
    self.file:seek("set", cstart)
    local info = self.file:read(1):byte(1)
    local data = self.file:read(cend - cstart - 1)
    local parsed = Cluster.parse(info, data)
    local size = parsed:blobSize(blob_num)
    parsed.payload = nil
    return size
end

-- Size of a blob without copying it out of the cluster.
-- Used by the word index to rank big "main" articles above small detail
-- articles; reading the bytes just to call #content would double the cost.
function ZIM:blobSize(cluster_num, blob_num)
    local cached = self.cluster_cache:get(cluster_num)
    if not cached then
        local cstart, cend = self:_clusterRange(cluster_num)
        self.file:seek("set", cstart)
        local info = self.file:read(1):byte(1)
        local data = self.file:read(cend - cstart - 1)
        cached = Cluster.parse(info, data)
        self.cluster_cache:put(cluster_num, cached)
    end
    return cached:blobSize(blob_num)
end

function ZIM:readArticle(entry)
    entry = self:resolveRedirect(entry)
    if not entry or entry.kind ~= "article" then return nil end
    local content = self:readBlob(entry.cluster, entry.blob)
    local mime = self:mimeOf(entry.mime) or "application/octet-stream"
    return content, mime, entry
end

-- The header's main-page index usually points at a synthetic "mainPage"
-- redirect entry (libzim writes one), not at the article itself. Resolve the
-- chain so callers always get a readable article.
function ZIM:getMainPageEntry()
    if self.main_page == 0xFFFFFFFF then return nil end
    local entry = self:getEntryByIndex(self.main_page)
    local hops = 0
    while entry and entry.kind == "redirect" and hops < 8 do
        local target = entry.redirect_idx
        if not target or target >= self.article_count then return nil end
        entry = self:getEntryByIndex(target)
        hops = hops + 1
    end
    if not entry or entry.kind ~= "article" then return nil end
    return entry
end

return ZIM

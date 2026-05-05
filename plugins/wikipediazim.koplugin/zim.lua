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
        cluster_cache    = Cluster.newCache(4),
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
-- (for binary search) and usually the title. Reads only as much as needed.
function ZIM:_readDirent(off, want_title)
    local f = self.file
    f:seek("set", off)
    local head = f:read(16)
    if not head or #head < 8 then return nil end

    local mime = u16(head, 1)
    local param_len = head:byte(3)
    local ns = string.char(head:byte(4))
    local rev = u32(head, 5)

    local entry = {
        offset    = off,
        mime      = mime,
        namespace = ns,
        revision  = rev,
        param_len = param_len,
    }
    local strings_off
    if mime == 0xFFFF then
        entry.kind = "redirect"
        entry.redirect_idx = u32(head, 9)
        strings_off = off + 12
    elseif mime == 0xFFFE or mime == 0xFFFD then
        entry.kind = "deleted"
        strings_off = off + 8
    else
        entry.kind = "article"
        entry.cluster = u32(head, 9)
        entry.blob    = u32(head, 13)
        strings_off = off + 16
    end

    f:seek("set", strings_off)
    entry.url = read_cstring(f)
    if want_title then
        entry.title = read_cstring(f)
        if entry.title == "" then entry.title = entry.url end
    end
    return entry
end

-- Cheap URL-only fetch for the binary search inner loop.
function ZIM:_readUrlAt(off)
    local f = self.file
    f:seek("set", off)
    local head = f:read(4)
    if not head then return nil, nil end
    local mime = u16(head, 1)
    local ns = string.char(head:byte(4))
    local strings_off
    if mime == 0xFFFF then strings_off = off + 12
    elseif mime == 0xFFFE or mime == 0xFFFD then strings_off = off + 8
    else strings_off = off + 16 end
    f:seek("set", strings_off)
    return ns, read_cstring(f)
end

function ZIM:getEntryByIndex(idx)
    if idx < 0 or idx >= self.article_count then return nil end
    local off = self:_direntOffset(idx)
    return self:_readDirent(off, true)
end

-- Binary search returns (idx, exact_match). If not exact, idx is the
-- insertion point — where prefix scanning should start.
function ZIM:findUrlIndex(namespace, target_url)
    local target_key = namespace .. target_url
    local lo, hi = 0, self.article_count - 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local off = self:_direntOffset(mid)
        local ns, url = self:_readUrlAt(off)
        if not ns then return lo, false end
        local key = ns .. url
        if key == target_key then
            return mid, true
        elseif key < target_key then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo, false
end

-- Walk forward from the insertion point collecting entries whose namespace
-- matches and whose url starts with the prefix. Stops at the first miss.
function ZIM:prefixSearch(namespace, prefix, max_results)
    max_results = max_results or 50
    local idx = select(1, self:findUrlIndex(namespace, prefix))
    local results = {}
    local plen = #prefix
    while #results < max_results and idx < self.article_count do
        local off = self:_direntOffset(idx)
        local ns, url = self:_readUrlAt(off)
        if ns ~= namespace then break end
        if url:sub(1, plen) ~= prefix then break end
        local entry = self:_readDirent(off, true)
        if entry and entry.kind ~= "deleted" then
            results[#results + 1] = entry
        end
        idx = idx + 1
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

function ZIM:readArticle(entry)
    entry = self:resolveRedirect(entry)
    if not entry or entry.kind ~= "article" then return nil end
    local content = self:readBlob(entry.cluster, entry.blob)
    local mime = self:mimeOf(entry.mime) or "application/octet-stream"
    return content, mime, entry
end

function ZIM:getMainPageEntry()
    if self.main_page == 0xFFFFFFFF then return nil end
    return self:getEntryByIndex(self.main_page)
end

return ZIM

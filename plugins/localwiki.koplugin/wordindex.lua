--[[
Word index for ZIM archives.

A ZIM's directory is sorted by path, so prefix search can only find articles
whose title *starts* with what you typed. Searching "Snape" in the Harry
Potter archive returns "Snape family" but never "Severus Snape", because the
character's article lives far away in path order.

This module builds a word index once per archive: every word of every title,
lowercased, mapped to the article paths that contain it. Searches then look up
the words directly instead of walking the directory, so a surname finds the
person no matter where the title puts it.

The index is written next to the archive as `<zim>.idx` — delete the ZIM and
the index goes with it. Building costs about a second on a 47k-article wiki
and the file is a few hundred kilobytes.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local WordIndex = {}
WordIndex.__index = WordIndex

-- Bump when the on-disk layout changes; a stale file is then rebuilt instead
-- of being misread.
local FORMAT_VERSION = 3
local MAX_WORD_LEN = 40

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(s, i)
    local lo = u32(s, i)
    local hi = u32(s, i + 4)
    return hi * 4294967296 + lo
end

-- Split a title into searchable words. "Severus_Snape's_Portrait" becomes
-- severus, snape, s, portrait — the possessive tail is dropped because "s"
-- would match half the wiki.
local function title_words(title)
    local out = {}
    local seen = {}
    local t = title:gsub("_", " "):lower()
    for w in t:gmatch("[%w][%w%-%.']*") do
        w = w:gsub("'s$", ""):gsub("'$", ""):gsub("%.$", ""):gsub("%-+$", "")
        w = w:gsub("^%-+", "")
        if #w >= 2 and #w <= MAX_WORD_LEN and not seen[w] then
            seen[w] = true
            out[#out + 1] = w
        end
    end
    return out
end

-- Article count straight from the ZIM header, without opening the archive.
-- The header starts with magic(4) major(2) minor(2) uuid(16) articleCount(4),
-- so the count is at byte 25. Returns nil if the file cannot be read.
function WordIndex.articleCount(zim_path)
    local f = io.open(zim_path, "rb")
    if not f then return nil end
    local head = f:read(64)
    f:close()
    if not head or #head < 28 then return nil end
    local a, b, c, d = head:byte(25, 28)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- True when a usable index already exists for this archive, so startup can
-- skip a build instead of scanning the directory again.
function WordIndex.has_index(zim_path)
    local attr = lfs.attributes(WordIndex.path_for(zim_path))
    return attr ~= nil and (attr.size or 0) > 0
end

-- Path of the index file that belongs to a ZIM.
function WordIndex.path_for(zim_path)
    return zim_path .. ".idx"
end

-- Cheap identity check: size plus mtime. A rebuilt archive has a different
-- size; a replaced one has a different mtime.
local function signature(zim_path)
    local attr = lfs.attributes(zim_path)
    if not attr then return nil end
    return string.format("%d:%d", attr.size or 0, attr.modification or 0)
end

-- Walk the archive once and collect word -> paths.
-- Returns words (sorted array), postings (word -> array of paths).
local function build(zim, zim_path, on_progress)
    local f = zim.file
    local count = zim.article_count
    local url_ptr_pos = zim.url_ptr_pos

    -- One read for the whole pointer table, then one small read per entry.
    -- Reading through ZIM:_direntOffset() would seek twice per article.
    f:seek("set", url_ptr_pos)
    local ptrs = f:read(count * 8) or ""

    local postings = {}
    local words = {}
    local articles = 0

    local progress_step = math.max(1, math.floor(count / 100))
    for i = 0, count - 1 do
        if on_progress and i % progress_step == 0 then
            on_progress(i / count)
        end
        local off = u64(ptrs, i * 8 + 1)
        if off > 0 then
            f:seek("set", off)
            local buf = f:read(512)
            if buf and #buf >= 18 and buf:byte(4) == 67 then -- 'C'
                local mime = buf:byte(1) + buf:byte(2) * 256
                -- Skip redirects: they resolve to an article that is indexed
                -- under its own title.
                if mime ~= 0xFFFF then
                    -- The URL starts at byte 17 and ends at the first NUL. If
                    -- the buffer holds no NUL the title ran past it, so read
                    -- the rest from the file instead of indexing a truncated
                    -- name.
                    local tail = buf:sub(17)
                    local url
                    local nul = tail:find("\0", 1, true)
                    if nul then
                        url = tail:sub(1, nul - 1)
                    else
                        f:seek("set", off + 16)
                        local chunks = {}
                        local total = 0
                        while total < 4096 do
                            local c = f:read(1)
                            if not c or c == "\0" then break end
                            chunks[#chunks + 1] = c
                            total = total + 1
                        end
                        url = table.concat(chunks)
                    end
                    -- Media and internal metadata entries live alongside
                    -- articles; indexing them would pollute results.
                    if url and url ~= "" and url:sub(1, 2) ~= "I/"
                        and url:sub(1, 2) ~= "X/" then
                        articles = articles + 1
                        -- No size: measuring one costs a cluster decompression
                        -- per article, which this device cannot afford. Ranking
                        -- falls back to title shape and length.
                        local size = 0
                        for _, w in ipairs(title_words(url)) do
                            local list = postings[w]
                            if not list then
                                list = {}
                                postings[w] = list
                                words[#words + 1] = w
                            end
                            -- Flat parallel arrays, not a table per hit. A
                            -- {url=,idx=,size=} table costs ~100 bytes plus its
                            -- strings; 155k of them on a 47k-article wiki
                            -- peaked at 1.7 GB and the kernel killed the
                            -- reader. Three arrays share the same strings and
                            -- cost a fraction of that.
                            local n = #list + 1
                            list[n] = url
                            list.idx = list.idx or {}
                            list.size = list.size or {}
                            list.idx[n] = i
                            list.size[n] = size
                        end
                    end
                end
            end
        end
    end

    table.sort(words)
    return words, postings, articles
end

-- On-disk format (all little-endian):
--   "LWIDX\0" | u32 version | u32 word count | u32 article count
--   u32 signature length | signature
--   for each word (sorted): u16 len | bytes | u32 posting count
--                           | for each posting: u16 len | bytes
-- Words are sorted so lookup is a binary search over an offset table that is
-- rebuilt on load; that keeps the file compact and the reader simple.
local function write_file(path, zim_path, words, postings, articles)
    local tmp = path .. ".tmp"
    local fh = io.open(tmp, "wb")
    if not fh then return false end

    local sig = signature(zim_path) or ""
    local parts = {
        "LWIDX\0",
        string.char(FORMAT_VERSION % 256, math.floor(FORMAT_VERSION / 256), 0, 0),
        string.char(#words % 256, math.floor(#words / 256) % 256,
                    math.floor(#words / 65536) % 256, math.floor(#words / 16777216) % 256),
        string.char(articles % 256, math.floor(articles / 256) % 256,
                    math.floor(articles / 65536) % 256, math.floor(articles / 16777216) % 256),
        string.char(#sig % 256, math.floor(#sig / 256) % 256, 0, 0),
        sig,
    }
    fh:write(table.concat(parts))

    for _, w in ipairs(words) do
        local list = postings[w]
        local chunk = {
            string.char(#w % 256, math.floor(#w / 256)),
            w,
            string.char(#list % 256, math.floor(#list / 256) % 256,
                        math.floor(#list / 65536) % 256, math.floor(#list / 16777216) % 256),
        }
        local idxs, sizes = list.idx or {}, list.size or {}
        for pi = 1, #list do
            local url = list[pi]
            local idx = idxs[pi] or 0
            local size = sizes[pi] or 0
            chunk[#chunk + 1] = string.char(
                idx % 256, math.floor(idx / 256) % 256,
                math.floor(idx / 65536) % 256, math.floor(idx / 16777216) % 256)
            chunk[#chunk + 1] = string.char(
                size % 256, math.floor(size / 256) % 256,
                math.floor(size / 65536) % 256, math.floor(size / 16777216) % 256)
            chunk[#chunk + 1] = string.char(#url % 256, math.floor(#url / 256))
            chunk[#chunk + 1] = url
        end
        fh:write(table.concat(chunk))
    end

    fh:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false
    end
    return true
end

-- Load an index file into memory: word -> paths, plus a sorted word array.
local function read_file(path, zim_path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    if not data or #data < 16 or data:sub(1, 6) ~= "LWIDX\0" then return nil end

    local version = u32(data, 7)
    if version ~= FORMAT_VERSION then return nil end

    local word_count = u32(data, 11)
    local articles = u32(data, 15)
    local sig_len = u32(data, 19)
    local pos = 23
    local sig = data:sub(pos, pos + sig_len - 1)
    pos = pos + sig_len

    if sig ~= (signature(zim_path) or "") then return nil end

    local postings = {}
    local words = {}
    for i = 1, word_count do
        if pos + 2 > #data then return nil end
        local wlen = data:byte(pos) + data:byte(pos + 1) * 256
        pos = pos + 2
        local w = data:sub(pos, pos + wlen - 1)
        pos = pos + wlen
        local n = u32(data, pos)
        pos = pos + 4
        local list = { idx = {}, size = {} }
        for j = 1, n do
            local idx = u32(data, pos)
            local size = u32(data, pos + 4)
            pos = pos + 8
            local plen = data:byte(pos) + data:byte(pos + 1) * 256
            pos = pos + 2
            list[j] = data:sub(pos, pos + plen - 1)
            list.idx[j] = idx
            list.size[j] = size
            pos = pos + plen
        end
        postings[w] = list
        words[i] = w
    end

    return { words = words, postings = postings, articles = articles }
end

-- Get the index for a ZIM, building it if missing or stale.
-- `on_build` is called before a build so the caller can show a message;
-- `on_progress` receives a 0..1 fraction while the scan runs.
function WordIndex.open(zim, zim_path, on_build, on_progress)
    if not zim or not zim_path then return nil end
    local path = WordIndex.path_for(zim_path)

    local loaded = read_file(path, zim_path)
    if loaded then
        logger.info(string.format("localwiki: word index for %s — %d words, %d articles",
            zim_path:match("[^/]+$"), #loaded.words, loaded.articles))
        return setmetatable({
            words = loaded.words,
            postings = loaded.postings,
            articles = loaded.articles,
            path = path,
        }, WordIndex)
    end

    if on_build then on_build() end
    local t0 = os.clock()
    local words, postings, articles = build(zim, zim_path, on_progress)
    local ok = write_file(path, zim_path, words, postings, articles)
    logger.info(string.format(
        "localwiki: built word index for %s in %.2f s — %d words, %d articles%s",
        zim_path:match("[^/]+$"), os.clock() - t0, #words, articles,
        ok and "" or " (could not save; will rebuild next time)"))

    return setmetatable({
        words = words,
        postings = postings,
        articles = articles,
        path = path,
    }, WordIndex)
end

-- Every path whose title contains this exact word.
function WordIndex:lookup(word)
    if not word or word == "" then return nil end
    return self.postings[word:lower()]
end

-- Hits whose title contains all of the given words. Each hit is
-- { url = "Severus_Snape", idx = 41522 }.
function WordIndex:lookup_all(words)
    if not words or #words == 0 then return nil end
    local first = self:lookup(words[1])
    if not first then return nil end
    if #words == 1 then
        -- Callers expect {url=,idx=,size=} records; a raw posting list is a
        -- flat array of urls with .idx/.size side tables, so hand back the
        -- same shape for the single-word case instead of the array itself.
        local out = {}
        local idxs, sizes = first.idx or {}, first.size or {}
        for i, url in ipairs(first) do
            out[i] = { url = url, idx = idxs[i] or 0, size = sizes[i] or 0 }
        end
        return out
    end

    local keep = {}
    for _, url in ipairs(first) do keep[url] = true end
    for i = 2, #words do
        local list = self:lookup(words[i])
        if not list then return nil end
        local next_keep = {}
        for _, url in ipairs(list) do
            if keep[url] then next_keep[url] = true end
        end
        keep = next_keep
    end

    local out = {}
    local idxs, sizes = first.idx or {}, first.size or {}
    for i, url in ipairs(first) do
        if keep[url] then
            out[#out + 1] = { url = url, idx = idxs[i] or 0, size = sizes[i] or 0 }
        end
    end
    return out
end

-- Words that start with `prefix`, for suggestions and for matching partial
-- input. Walks the sorted word array, so it stops as soon as the prefix no
-- longer matches.
function WordIndex:complete(prefix, limit)
    if not prefix or prefix == "" then return {} end
    prefix = prefix:lower()
    limit = limit or 20

    local words = self.words
    local lo, hi = 1, #words
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if words[mid] < prefix then lo = mid + 1 else hi = mid - 1 end
    end

    local out = {}
    local i = lo
    while i <= #words and #out < limit do
        if words[i]:sub(1, #prefix) ~= prefix then break end
        out[#out + 1] = words[i]
        i = i + 1
    end
    return out
end

function WordIndex:wordCount()
    return #self.words
end

return WordIndex

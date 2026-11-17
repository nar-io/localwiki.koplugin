--[[
Title index for ZIM archives.

A ZIM stores its entries in path order, so a prefix search can only reach
titles that *start* with the query: "Snape" finds "Snape family" but never
"Severus Snape". The old answer was to scan every article and build a word
index on the device — which needed gigabytes of RAM on a large wiki and got
the reader OOM-killed.

Every ZIM already carries the answer: the `titleOrdered` listing, a 4-byte
entry id per article sorted by title, written by the archive author. Reading
it costs one small sequential read and no decompression, and searching it is
a linear scan over a string array.

This module exposes the same interface the word index did (lookup_all,
articleCount, has_index) so the search path in main.lua does not care which
one is behind it.
]]

local logger = require("logger")

local TitleIndex = {}
TitleIndex.__index = TitleIndex
local CACHE_MAGIC = "LWTI\0"
local CACHE_VERSION = 1

-- The listing lives at this path inside the archive. v1 is the only version
-- libzim has ever written.
local LISTING_PATH = "X/listing/titleOrdered/v1"

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(s, i)
    return u32(s, i) + u32(s, i + 4) * 4294967296
end

local function put_u32(n)
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256)
end

local function put_u64(n)
    local lo = n % 4294967296
    local hi = math.floor(n / 4294967296)
    return put_u32(lo) .. put_u32(hi)
end

-- Lowercase and strip accents so "Émile" is reachable by typing "emile".
local function normalize(s)
    s = s:lower()
    s = s:gsub("[àáâãäå]", "a"):gsub("[èéêë]", "e"):gsub("[ìíîï]", "i")
    s = s:gsub("[òóôõö]", "o"):gsub("[ùúûü]", "u"):gsub("[ç]", "c")
    s = s:gsub("[ñ]", "n"):gsub("[ýÿ]", "y"):gsub("[ğ]", "g")
    s = s:gsub("[ış]", "i"):gsub("[ö]", "o"):gsub("[ü]", "u"):gsub("[ç]", "c")
    s = s:gsub("[ş]", "s"):gsub("[ı]", "i")
    return s
end

-- Read the title-ordered listing straight from the archive.
-- Returns an array of { idx = <directory index>, title = <display title> }
-- or nil when the archive has no listing.
local function cache_signature(zim)
    return put_u32(zim.article_count) .. put_u64(zim.file_size or 0)
end

local function read_cache(path, zim)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data or data:sub(1, #CACHE_MAGIC) ~= CACHE_MAGIC then return nil end
    local pos = #CACHE_MAGIC + 1
    if u32(data, pos) ~= CACHE_VERSION then return nil end
    pos = pos + 4
    local sig = data:sub(pos, pos + 11)
    pos = pos + 12
    if sig ~= cache_signature(zim) then return nil end
    local count = u32(data, pos)
    pos = pos + 4
    local ids, titles, norms = {}, {}, {}
    for i = 1, count do
        if pos + 7 > #data then return nil end
        local idx = u32(data, pos)
        local len = u32(data, pos + 4)
        pos = pos + 8
        if pos + len - 1 > #data then return nil end
        local title = data:sub(pos, pos + len - 1)
        pos = pos + len
        ids[i], titles[i], norms[i] = idx, title, normalize(title)
    end
    return { ids = ids, titles = titles, norms = norms, count = count }
end

local function write_cache(path, zim, loaded)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(CACHE_MAGIC, put_u32(CACHE_VERSION), cache_signature(zim), put_u32(loaded.count))
    for i = 1, loaded.count do
        local title = loaded.titles[i]
        f:write(put_u32(loaded.ids[i]), put_u32(#title), title)
    end
    f:close()
    os.remove(path)
    return os.rename(tmp, path) and true or false
end

function TitleIndex.load(zim, cache_path)
    if not zim or not zim.file then return nil end
    if cache_path then
        local cached = read_cache(cache_path, zim)
        if cached then
            logger.info(string.format("localwiki: loaded title index cache %s (%d entries)",
                cache_path, cached.count))
            return cached
        end
    end
    -- Do not gate on the header's titlePtrPos: LuaJIT numbers cannot hold
    -- 0xFFFFFFFFFFFFFFFF exactly, so the "no title index" sentinel compares
    -- unreliably. The listing entry itself is the real test.

    -- The listing lives in namespace X, so split the path on the first slash.
    local ns, url = LISTING_PATH:match("^([^/]+)/(.+)$")
    local entry = zim:findExact(ns, url)
    if not entry or entry.kind ~= "article" then return nil end

    local data = zim:readBlob(entry.cluster, entry.blob)
    if not data or #data < 4 then return nil end

    local count = math.floor(#data / 4)
    -- Three parallel arrays instead of one table per entry: on a 1.2M-title
    -- Wikipedia the table-of-tables shape alone cost more RAM than the device
    -- has, and the reader was killed mid-search.
    local ids, titles, norms = {}, {}, {}
    local n = 0
    for i = 0, count - 1 do
        local idx = u32(data, i * 4 + 1)
        if idx < zim.article_count then
            local e = zim:getEntryByIndex(idx)
            if e and e.kind ~= "deleted" and e.title and e.title ~= "" then
                n = n + 1
                ids[n] = idx
                titles[n] = e.title
                norms[n] = normalize(e.title)
            end
        end
    end

    if n == 0 then return nil end
    local loaded = { ids = ids, titles = titles, norms = norms, count = n }
    if cache_path and not write_cache(cache_path, zim, loaded) then
        logger.warn("localwiki: could not write title index cache: " .. cache_path)
    end
    return loaded
end

-- Rank a title against the query. Lower is better; nil means no match.
--   0  the query is the whole title
--   1  the last title word is the query ("Severus Snape")
--   2  the title starts with the query ("Snape family")
--   3  a word of the title starts with the query
--   4  the query appears anywhere in the title
local function rank_of(norm_title, q)
    if norm_title == q then return 0 end
    local last_word = norm_title:match("([^ _%-() :,]+)$")
    if last_word == q then return 1 end
    if norm_title:sub(1, #q) == q then return 2 end
    -- Word-start match: look for the query after a space or separator.
    local init = 1
    while true do
        local s = norm_title:find(q, init, true)
        if not s then break end
        if s == 1 then return 2 end
        local prev = norm_title:sub(s - 1, s - 1)
        if prev == " " or prev == "_" or prev == "-" or prev == "(" or prev == ":" then
            return 3
        end
        init = s + 1
    end
    if norm_title:find(q, 1, true) then return 4 end
    return nil
end

local function rank_words(norm_title, words)
    local total = 0
    for _, word in ipairs(words) do
        local rank = rank_of(norm_title, word)
        if not rank then return nil end
        total = total + rank
    end
    return total
end

local function result_before(a, b)
    if a.matched ~= b.matched then return a.matched > b.matched end
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.len ~= b.len then return a.len < b.len end
    return a.title < b.title
end

local function keep_best(scored, hit, limit)
    local pos = 1
    while pos <= #scored and not result_before(hit, scored[pos]) do
        pos = pos + 1
    end
    table.insert(scored, pos, hit)
    if #scored > limit then scored[#scored] = nil end
end

-- Incremental scanner for large archives. Each step does bounded work so the
-- caller can yield to KOReader between batches instead of freezing the UI.
function TitleIndex.newScanner(zim, words, limit, batch_size)
    if not zim or not zim.file or not words or #words == 0 then return nil end
    local normed = {}
    for _, word in ipairs(words) do
        local n = normalize(word)
        if #n >= 2 then normed[#normed + 1] = n end
    end
    if #normed == 0 then return nil end
    return setmetatable({
        zim = zim,
        words = normed,
        limit = limit or 50,
        batch_size = batch_size or 256,
        next_index = 0,
        scored = {},
    }, { __index = TitleIndex })
end

function TitleIndex:step()
    if self.next_index >= self.zim.article_count then
        return true, self.scored
    end

    local start = self.next_index
    local count = math.min(self.batch_size, self.zim.article_count - start)
    local f = self.zim.file
    f:seek("set", self.zim.url_ptr_pos + start * 8)
    local pointer_data = f:read(count * 8) or ""
    count = math.floor(#pointer_data / 8)
    if count == 0 then
        self.next_index = self.zim.article_count
        return true, self.scored
    end

    for i = 0, count - 1 do
        local off = u64(pointer_data, i * 8 + 1)
        local entry = self.zim:_readDirent(off, true)
        if entry and entry.namespace == "C" and entry.kind == "article" then
            local title = entry.title or entry.url or ""
            local rank = rank_words(normalize(title), self.words)
            if rank then
                keep_best(self.scored, {
                    rank = rank,
                    matched = #self.words,
                    len = #title,
                    idx = start + i,
                    title = title,
                }, self.limit)
            end
        end
    end

    self.next_index = start + count
    return self.next_index >= self.zim.article_count, self.scored
end

function TitleIndex.new(loaded)
    return setmetatable(loaded, TitleIndex)
end

-- Look up one query. Returns an array of hits carrying `idx` (directory
-- index) and `title`, best first, capped at `limit`.
function TitleIndex:lookup(query, limit)
    limit = limit or 50
    if not query or query == "" then return {} end
    local q = normalize(query)
    if q == "" then return {} end

    local scored = {}
    local norms, titles, ids = self.norms, self.titles, self.ids
    for i = 1, self.count do
        local rank = rank_of(norms[i], q)
        if rank then
            scored[#scored + 1] = { rank = rank, len = #titles[i], idx = ids[i], title = titles[i] }
        end
    end

    table.sort(scored, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.len ~= b.len then return a.len < b.len end
        return a.title < b.title
    end)

    local out = {}
    for i = 1, math.min(limit, #scored) do out[i] = scored[i] end
    return out
end

-- All query words must match somewhere in the title; results are ordered by
-- how many words matched exactly, then by title shape. Mirrors the word
-- index's contract so main.lua can swap between them.
function TitleIndex:lookup_all(words, limit)
    limit = limit or 50
    if not words or #words == 0 then return {} end

    local normed = {}
    for _, w in ipairs(words) do
        local n = normalize(w)
        if #n >= 2 then normed[#normed + 1] = n end
    end
    if #normed == 0 then return {} end

    local scored = {}
    local norms, titles, ids = self.norms, self.titles, self.ids
    for i = 1, self.count do
        local nt = norms[i]
        local total_rank, matched = 0, 0
        local ok = true
        for _, w in ipairs(normed) do
            local r = rank_of(nt, w)
            if not r then ok = false; break end
            total_rank = total_rank + r
            matched = matched + 1
        end
        if ok then
            scored[#scored + 1] = {
                rank = total_rank,
                matched = matched,
                len = #titles[i],
                idx = ids[i],
                title = titles[i],
            }
        end
    end

    table.sort(scored, function(a, b)
        if a.matched ~= b.matched then return a.matched > b.matched end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.len ~= b.len then return a.len < b.len end
        return a.title < b.title
    end)

    local out = {}
    for i = 1, math.min(limit, #scored) do out[i] = scored[i] end
    return out
end

function TitleIndex:entryCount()
    return self.count
end

return TitleIndex

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

-- The listing lives at this path inside the archive. v1 is the only version
-- libzim has ever written.
local LISTING_PATH = "X/listing/titleOrdered/v1"

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return 0 end
    return a + b * 256 + c * 65536 + d * 16777216
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
function TitleIndex.load(zim)
    if not zim or not zim.file then return nil end
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
    return { ids = ids, titles = titles, norms = norms, count = n }
end

-- Rank a title against the query. Lower is better; nil means no match.
--   0  the query is the whole title
--   1  the title starts with the query
--   2  a word of the title starts with the query
--   3  the query appears anywhere in the title
local function rank_of(norm_title, q)
    if norm_title == q then return 0 end
    if norm_title:sub(1, #q) == q then return 1 end
    -- Word-start match: look for the query after a space or separator.
    local init = 1
    while true do
        local s = norm_title:find(q, init, true)
        if not s then break end
        if s == 1 then return 1 end
        local prev = norm_title:sub(s - 1, s - 1)
        if prev == " " or prev == "_" or prev == "-" or prev == "(" or prev == ":" then
            return 2
        end
        init = s + 1
    end
    if norm_title:find(q, 1, true) then return 3 end
    return nil
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

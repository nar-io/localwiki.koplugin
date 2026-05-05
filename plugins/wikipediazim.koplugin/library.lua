--[[
ZIM library: auto-discovers ZIM files (and split-set parts) in a folder,
groups parts by base name into virtual ZIMs, and opens each lazily on first
use. The rest of the plugin sees a flat list of "logical" ZIMs and never
worries about whether a ZIM is on disk as one file or many parts.

A "logical ZIM" is identified by its base name — e.g.
  wikipedia_en_all_mini_2026-03.zim
which on disk might be either:
  wikipedia_en_all_mini_2026-03.zim                  (single file < 4 GiB)
or:
  wikipedia_en_all_mini_2026-03.zimaa                (split for FAT32)
  wikipedia_en_all_mini_2026-03.zimab
  …
ZIM.open() handles both layouts transparently.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ZIM = require("zim")

local Library = {}
Library.__index = Library

function Library.new()
    return setmetatable({
        folder = nil,
        zims = {},        -- array of { base, paths={…}, zim=nil_until_opened }
        by_base = {},     -- base_name -> entry (same table as in zims[])
    }, Library)
end

local function dir_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "directory"
end

-- Scan `folder` for *.zim and *.zim?? files. Group split parts by base name.
-- Returns true if at least one logical ZIM was found.
function Library:scan(folder)
    self.folder = folder
    self.zims = {}
    self.by_base = {}
    if not folder or not dir_exists(folder) then return false end

    local groups = {}   -- base_name -> array of full paths
    for entry in lfs.dir(folder) do
        if entry ~= "." and entry ~= ".." then
            local lower = entry:lower()
            local base = entry:match("^(.+%.zim)%a%a$")
            local is_single = (not base) and lower:match("%.zim$")
            if base then
                groups[base] = groups[base] or {}
                table.insert(groups[base], folder .. "/" .. entry)
            elseif is_single then
                groups[entry] = groups[entry] or {}
                table.insert(groups[entry], folder .. "/" .. entry)
            end
        end
    end

    -- Sort and pick a stable display order
    local base_names = {}
    for b in pairs(groups) do base_names[#base_names + 1] = b end
    table.sort(base_names)

    for _, base in ipairs(base_names) do
        local paths = groups[base]
        table.sort(paths)
        local entry = {
            base = base,
            paths = paths,
            single = (#paths == 1) and not paths[1]:lower():match("%.zim%a%a$"),
            zim = nil,
        }
        self.zims[#self.zims + 1] = entry
        self.by_base[base] = entry
    end

    logger.info(string.format("wikipediazim: scanned %s — %d logical ZIM(s)",
        folder, #self.zims))
    for _, e in ipairs(self.zims) do
        logger.info(string.format("  %s — %d %s",
            e.base, #e.paths, e.single and "file" or "parts"))
    end
    return #self.zims > 0
end

-- Open a logical ZIM (cached after first call). Returns the ZIM object
-- or nil + error string.
function Library:open(base)
    local entry = self.by_base[base]
    if not entry then return nil, "unknown ZIM: " .. tostring(base) end
    if entry.zim then return entry.zim end
    -- ZIM.open auto-detects split sets: pass either the single file or
    -- the first part path.
    local first_path = entry.paths[1]
    local z, err = ZIM.open(first_path)
    if not z then return nil, err end
    entry.zim = z
    logger.info(string.format(
        "wikipediazim: opened %s (%s) — %d articles, %d clusters",
        base, z.open_mode or "single", z.article_count, z.cluster_count))
    return z
end

-- Close all opened ZIMs (e.g. on suspend / plugin unload).
function Library:closeAll()
    for _, e in ipairs(self.zims) do
        if e.zim then
            pcall(function() e.zim:close() end)
            e.zim = nil
        end
    end
end

-- Run a prefix search across every logical ZIM. Each result gets a `_base`
-- field tagging which ZIM it came from. Returns alpha-sorted by url, capped.
function Library:prefixSearch(namespace, prefix, max_results)
    max_results = max_results or 60
    local out = {}
    for _, e in ipairs(self.zims) do
        local z, err = self:open(e.base)
        if z then
            local hits = z:prefixSearch(namespace, prefix, max_results)
            for _, h in ipairs(hits) do
                h._base = e.base
                out[#out + 1] = h
            end
        else
            logger.warn("wikipediazim: skipping " .. e.base .. ": " .. tostring(err))
        end
    end
    table.sort(out, function(a, b) return a.url < b.url end)
    if #out > max_results then
        for i = max_results + 1, #out do out[i] = nil end
    end
    return out
end

-- Number of *opened* (i.e. file-handle-active) ZIMs — for diagnostics.
function Library:openedCount()
    local n = 0
    for _, e in ipairs(self.zims) do if e.zim then n = n + 1 end end
    return n
end

function Library:isMultiZim()
    return #self.zims > 1
end

return Library

--[[
Virtual-concatenation file: presents a list of part files
(e.g. wiki.zimaa, wiki.zimab, wiki.zimac, …) as one logical io handle so
zim.lua doesn't have to care that FAT32 forced us to split the file.

Exposes the same surface zim.lua uses on a real Lua file:
    :seek("set"|"cur"|"end", offset)
    :read(n)
    :close()

Lookup of the active part on each read is linear over the parts table —
fine for the 4-ish parts a 12 GB ZIM produces; not worth a binary search.
]]

local SplitFile = {}
SplitFile.__index = SplitFile

local function exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

-- Build the list of part paths starting from base + "aa", "ab", …
-- Stops at the first missing part. Two-letter suffix is the `split` /
-- `zimsplit` convention (a..z × a..z = up to 676 parts, plenty).
function SplitFile.findParts(base_path)
    local parts = {}
    for i = 0, 26 * 26 - 1 do
        local s = string.char(97 + math.floor(i / 26), 97 + (i % 26))  -- 'aa'..'zz'
        local p = base_path .. s
        if exists(p) then
            parts[#parts + 1] = p
        else
            break
        end
    end
    return parts
end

function SplitFile.open(parts)
    if #parts == 0 then return nil, "no parts given" end
    local self = setmetatable({
        parts = {},
        total = 0,
        cur = 0,
    }, SplitFile)
    for _, path in ipairs(parts) do
        local f, err = io.open(path, "rb")
        if not f then
            for _, p in ipairs(self.parts) do p.handle:close() end
            return nil, err or ("cannot open " .. path)
        end
        local size = f:seek("end")
        f:seek("set", 0)
        self.parts[#self.parts + 1] = { path = path, size = size, handle = f }
        self.total = self.total + size
    end
    return self
end

function SplitFile:close()
    for _, p in ipairs(self.parts) do
        if p.handle then p.handle:close(); p.handle = nil end
    end
end

-- Map a virtual offset into (part_index, offset_within_part).
function SplitFile:_locate(off)
    if off < 0 or off >= self.total then return nil end
    local rel = off
    for i, p in ipairs(self.parts) do
        if rel < p.size then return i, rel end
        rel = rel - p.size
    end
    return nil
end

function SplitFile:seek(whence, offset)
    offset = offset or 0
    if whence == "set" then
        self.cur = offset
    elseif whence == "cur" then
        self.cur = self.cur + offset
    elseif whence == "end" then
        self.cur = self.total + offset
    else
        return nil, "bad whence"
    end
    return self.cur
end

function SplitFile:read(n)
    if not n or n <= 0 then return "" end
    local chunks = {}
    local remaining = n
    while remaining > 0 do
        local idx, rel = self:_locate(self.cur)
        if not idx then break end
        local p = self.parts[idx]
        local can_read = math.min(remaining, p.size - rel)
        p.handle:seek("set", rel)
        local chunk = p.handle:read(can_read)
        if not chunk or #chunk == 0 then break end
        chunks[#chunks + 1] = chunk
        self.cur = self.cur + #chunk
        remaining = remaining - #chunk
        if #chunk < can_read then break end
    end
    if #chunks == 0 then return nil end
    return table.concat(chunks)
end

return SplitFile

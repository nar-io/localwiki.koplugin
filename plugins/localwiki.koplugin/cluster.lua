--[[
ZIM cluster handling: parsing the offsets table, slicing blobs, and decompressing
zstd / lzma2 cluster payloads via LuaJIT FFI.

A "cluster" in ZIM is just a packed array of blobs (HTML pages, images, css,
etc.) with a small offsets-table prefix. Articles in the same cluster usually
link heavily to each other, so we keep a tiny LRU of the last few decompressed
clusters — that turns a hot reading session into pure memcpy after the first hit.
]]

local ffi = require("ffi")
local logger = require("logger")

pcall(ffi.cdef, [[
/* libzstd — one-shot decompression API, plenty for our cluster sizes */
size_t ZSTD_decompress(void* dst, size_t dstCap, const void* src, size_t srcSize);
uint64_t ZSTD_getFrameContentSize(const void* src, size_t srcSize);
unsigned ZSTD_isError(size_t code);
const char* ZSTD_getErrorName(size_t code);

typedef struct ZSTD_DStream_s ZSTD_DStream;
ZSTD_DStream* ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream* zds);
size_t ZSTD_initDStream(ZSTD_DStream* zds);
typedef struct { const void* src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void* dst; size_t size; size_t pos; } ZSTD_outBuffer;
size_t ZSTD_decompressStream(ZSTD_DStream* zds, ZSTD_outBuffer* output, ZSTD_inBuffer* input);

/* liblzma — single-call buffer decoder for raw .xz streams (LZMA2 in ZIM) */
typedef enum { LZMA_OK = 0 } lzma_ret;
lzma_ret lzma_stream_buffer_decode(
    uint64_t *memlimit, uint32_t flags, void *allocator,
    const uint8_t *in, size_t *in_pos, size_t in_size,
    uint8_t *out, size_t *out_pos, size_t out_size);
]])

-- Resolve a native library the way KOReader itself does.
--
-- Android is the awkward one: its libraries are unversioned (libzstd.so, not
-- libzstd.so.1) and live in the APK's nativeLibraryDir, and on builds with the
-- monolibtic bundle zstd is not a separate .so at all — it is a set of symbols
-- inside libkoreader-monolibtic.so. Plain ffi.load("zstd") fails there, which
-- is why the plugin said "libzstd not available" on Android.
--
-- ffi.findlib (installed by koreader-base/ffi/loadlib.lua at startup) already
-- knows all of this: it redirects bundled names to the monolibtic path and
-- searches nativeLibraryDir. Use it first, then fall back to ffi.load.
local function try_load(names)
    if ffi.findlib then
        for _, n in ipairs(names) do
            local ok, found = pcall(ffi.findlib, n, "1")
            if ok and found and found ~= "" then
                local load_ok, lib = pcall(ffi.load, found)
                if load_ok and lib then return lib, found end
            end
        end
        -- Android builds are unversioned.
        for _, n in ipairs(names) do
            local ok, found = pcall(ffi.findlib, n)
            if ok and found and found ~= "" then
                local load_ok, lib = pcall(ffi.load, found)
                if load_ok and lib then return lib, found end
            end
        end
    end

    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then return lib, n end
    end
    return nil
end

local zstd, zstd_path = try_load{
    "zstd",
    "libs/libkoreader-monolibtic",
    "libkoreader-monolibtic",
    "libzstd.so.1",
    "libzstd.so",
    "libzstd.1.dylib",
}
-- liblzma is not part of KOReader's monolibtic bundle on every platform
-- (it is redirected on desktop builds but loaded separately on Android), so
-- try the plain names first and fall back to the bundle path.
local lzma, lzma_path = try_load{
    "lzma",
    "libs/libkoreader-monolibtic",
    "libkoreader-monolibtic",
    "libs/liblzma.so.5",
    "liblzma.so.5",
    "liblzma.so",
    "liblzma.5.dylib",
}

-- Log the outcome once, at load time: on Android a failed symbol lookup shows
-- up later as a SIGSEGV inside the FFI call (fault addr 0x0), which is far
-- harder to diagnose than one line here.
if zstd then
    logger.info(string.format("localwiki: zstd loaded from %s", tostring(zstd_path)))
    local ok_sym, sym = pcall(function() return zstd.ZSTD_decompress end)
    logger.info(string.format("localwiki: ZSTD_decompress symbol = %s (%s)",
        tostring(ok_sym and sym ~= nil), tostring(sym)))
else
    logger.warn("localwiki: zstd NOT available")
end
if lzma then
    logger.info(string.format("localwiki: lzma loaded from %s", tostring(lzma_path)))
else
    logger.info("localwiki: lzma NOT available")
end

local Cluster = {}
local M = {}

-- ---------- LRU cache ----------
--
-- Bounded by bytes, not by entry count: a cluster holds the whole decompressed
-- payload, and cluster sizes differ wildly between ZIMs (a Turkish Wikipedia
-- cluster is ~200 KB, a book ZIM built with few clusters can be 1.2 MB). With
-- a fixed entry count the cache silently grew to tens of megabytes once
-- several ZIMs were open, which is what pushed the device into the OOM killer.
local LRU = {}
LRU.__index = LRU
local DEFAULT_CACHE_BYTES = 4 * 1024 * 1024

function M.newCache(max_bytes)
    return setmetatable({
        cap = max_bytes or DEFAULT_CACHE_BYTES,
        bytes = 0,
        items = {},
        order = {},
    }, LRU)
end
function LRU:get(key)
    local v = self.items[key]
    if v then
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i); break end
        end
        self.order[#self.order + 1] = key
    end
    return v
end
function LRU:put(key, value)
    local old = self.items[key]
    if old then
        self.bytes = self.bytes - (old._bytes or 0)
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i); break end
        end
    end
    self.items[key] = value
    self.order[#self.order + 1] = key
    self.bytes = self.bytes + (value._bytes or 0)
    -- Evict oldest until the budget is met, but always keep the newest entry:
    -- a single cluster larger than the whole budget still has to be usable.
    while self.bytes > self.cap and #self.order > 1 do
        local oldest = table.remove(self.order, 1)
        local v = self.items[oldest]
        if v then self.bytes = self.bytes - (v._bytes or 0) end
        self.items[oldest] = nil
    end
end
function LRU:clear()
    self.items = {}; self.order = {}; self.bytes = 0
end

-- ---------- decompression ----------

local UNKNOWN_SIZE = 0xFFFFFFFFFFFFFFFFULL  -- ZSTD_CONTENTSIZE_UNKNOWN
local ERROR_SIZE   = 0xFFFFFFFFFFFFFFFEULL  -- ZSTD_CONTENTSIZE_ERROR

-- Reusable static buffer to prevent repetitive 1-2 MB allocations on the LuaJIT GC heap.
local cached_decomp_buf = nil
local cached_decomp_cap = 0
local function get_decomp_buf(size)
    if not cached_decomp_buf or cached_decomp_cap < size then
        cached_decomp_cap = math.max(size, 2 * 1024 * 1024)
        cached_decomp_buf = ffi.new("uint8_t[?]", cached_decomp_cap)
    end
    return cached_decomp_buf
end

local function decompress_zstd(data)
    if not zstd then
        error("libzstd not available — cannot read compressed clusters. "
            .. "This KOReader build ships zstd inside libkoreader-monolibtic.so; "
            .. "report the device and KOReader version.")
    end
    -- Keep a strong reference to `data` for the whole call: ffi.cast gives C a
    -- raw pointer into the Lua string's memory, and if the string is collected
    -- mid-call (LuaJIT only tracks it through this local) the pointer dangles.
    -- That shows up as SIGSEGV / SEGV_MAPERR at fault addr 0x0.
    local src_buf = data
    local src = ffi.cast("const char*", src_buf)
    local src_size = #src_buf
    local frame_size = zstd.ZSTD_getFrameContentSize(src, src_size)

    -- Fast path: known content size, single call into reusable C buffer.
    if frame_size ~= UNKNOWN_SIZE and frame_size ~= ERROR_SIZE then
        local size = tonumber(frame_size)
        -- A corrupt or truncated cluster can advertise a nonsense size; refuse
        -- it here rather than handing it to the allocator.
        if not size or size <= 0 or size > 64 * 1024 * 1024 then
            error("zstd: implausible frame size " .. tostring(size))
        end
        local dst = get_decomp_buf(size)
        local r = zstd.ZSTD_decompress(dst, size, src, src_size)
        if zstd.ZSTD_isError(r) ~= 0 then
            error("zstd decompress: " .. ffi.string(zstd.ZSTD_getErrorName(r)))
        end
        return ffi.string(dst, tonumber(r))
    end

    -- Frames without a content-size header (ZIM clusters built with streaming
    -- compressors) report ZSTD_CONTENTSIZE_UNKNOWN. The streaming API used to
    -- handle those, but it crashes on Android: KOReader's monolibtic zstd is
    -- built without a usable ZSTD_DStream layout, so the very first
    -- ZSTD_createDStream/ZSTD_decompressStream call faults at address 0x0.
    -- Probe the decompressed size with a bounded retry loop instead — ZSTD
    -- writes nothing past dstCapacity, so growing the buffer is safe.
    do
        local cap = math.max(src_size * 8, 2 * 1024 * 1024)
        local limit = 64 * 1024 * 1024
        while cap <= limit do
            local dst = get_decomp_buf(cap)
            local rr = zstd.ZSTD_decompress(dst, cap, src, src_size)
            if zstd.ZSTD_isError(rr) == 0 then
                return ffi.string(dst, tonumber(rr))
            end
            local name = ffi.string(zstd.ZSTD_getErrorName(rr))
            -- dstSize_tooSmall is the only error that growth can fix.
            if not name:find("Destination buffer is too small") then
                error("zstd: " .. name)
            end
            cap = cap * 2
        end
        error("zstd: cluster larger than 64 MiB")
    end

    -- Streaming fallback for frames without a content-size header.
    local zds = zstd.ZSTD_createDStream()
    if zds == nil then error("zstd: createDStream failed") end
    ffi.gc(zds, zstd.ZSTD_freeDStream)
    local init_r = zstd.ZSTD_initDStream(zds)
    if zstd.ZSTD_isError(init_r) ~= 0 then
        error("zstd: initDStream " .. ffi.string(zstd.ZSTD_getErrorName(init_r)))
    end
    local in_buf  = ffi.new("ZSTD_inBuffer",  src, src_size, 0)
    local out_cap = 256 * 1024
    local out     = ffi.new("uint8_t[?]", out_cap)
    local chunks  = {}
    while true do
        local out_buf = ffi.new("ZSTD_outBuffer", out, out_cap, 0)
        local r = zstd.ZSTD_decompressStream(zds, out_buf, in_buf)
        if zstd.ZSTD_isError(r) ~= 0 then
            error("zstd stream: " .. ffi.string(zstd.ZSTD_getErrorName(r)))
        end
        if out_buf.pos > 0 then
            chunks[#chunks + 1] = ffi.string(out, tonumber(out_buf.pos))
        end
        if r == 0 or in_buf.pos >= in_buf.size then break end
    end
    return table.concat(chunks)
end

local function decompress_lzma(data)
    if not lzma then error("liblzma not available — cluster needs LZMA2 decompression") end
    -- We don't know the uncompressed size up-front. Try doubling buffer sizes
    -- until the call no longer reports "buffer too small". LZMA-clusters are
    -- a legacy format; in practice they max out ~few MB.
    local out_size = math.max(1024 * 1024, #data * 6)
    while out_size <= 64 * 1024 * 1024 do
        local memlimit = ffi.new("uint64_t[1]", 0xFFFFFFFFFFFFFFFFULL)
        local in_pos   = ffi.new("size_t[1]", 0)
        local out_pos  = ffi.new("size_t[1]", 0)
        local out      = ffi.new("uint8_t[?]", out_size)
        -- Same GC hazard as zstd: hold the input string across the FFI call.
        local src_hold = data
        local r = lzma.lzma_stream_buffer_decode(
            memlimit, 0, nil,
            ffi.cast("const uint8_t*", src_hold), in_pos, #src_hold,
            out, out_pos, out_size)
        if r == 0 then
            return ffi.string(out, tonumber(out_pos[0]))
        end
        -- LZMA_BUF_ERROR (5) means output too small — grow and retry.
        if r ~= 5 then error("liblzma error code " .. tonumber(r)) end
        out_size = out_size * 2
    end
    error("lzma cluster larger than 64 MiB — bailing")
end

-- ---------- cluster parsing ----------

Cluster.__index = Cluster

local function u32(s, o)
    return s:byte(o) + s:byte(o+1)*256 + s:byte(o+2)*65536 + s:byte(o+3)*16777216
end
local function u64(s, o)
    return u32(s, o) + u32(s, o+4) * 4294967296
end

-- Parse a cluster given its info byte and (still possibly compressed) body.
-- Returns a Cluster object exposing :getBlob(idx).
function M.parse(info_byte, body)
    local bit = require("bit")
    local comp = bit.band(info_byte, 0x0F)
    local extended = bit.band(info_byte, 0x10) ~= 0

    local payload
    if comp == 1 or comp == 2 or comp == 3 then
        payload = body                    -- uncompressed (or legacy markers)
    elseif comp == 4 then
        payload = decompress_lzma(body)
    elseif comp == 5 then
        payload = decompress_zstd(body)
    else
        error("unknown cluster compression: " .. tostring(comp))
    end

    local off_size = extended and 8 or 4
    local read_off = extended and u64 or u32
    local first = read_off(payload, 1)
    local num_blobs = math.floor(first / off_size) - 1
    return setmetatable({
        payload  = payload,
        off_size = off_size,
        read_off = read_off,
        num_blobs = num_blobs,
        -- Used by the cache to enforce its byte budget.
        _bytes   = #payload,
    }, Cluster)
end

-- Byte length of one blob, without slicing the payload.
function Cluster:blobSize(idx)
    if idx < 0 or idx >= self.num_blobs then return 0 end
    local lo = self.read_off(self.payload, idx * self.off_size + 1)
    local hi = self.read_off(self.payload, (idx + 1) * self.off_size + 1)
    return hi - lo
end

function Cluster:getBlob(idx)
    if idx < 0 or idx >= self.num_blobs then return nil end
    -- offsets table is at the start of payload; offset[i] is at byte i*off_size+1
    local lo = self.read_off(self.payload, idx * self.off_size + 1)
    local hi = self.read_off(self.payload, (idx + 1) * self.off_size + 1)
    -- offsets are relative to start of the offsets table itself (i.e. start of payload)
    return self.payload:sub(lo + 1, hi)
end

return M

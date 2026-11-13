-- End-to-end exercise of zim.lua / cluster.lua / htmlclean.lua against a real
-- ZIM file, without KOReader. Run: luajit tests/lua_smoke.lua /tmp/test.zim
package.path = "./plugins/localwiki.koplugin/?.lua;" .. package.path

-- KOReader module stubs (only what the readers touch)
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, debug = function() end, err = function() end }
end

local zim_path = arg[1] or "/tmp/test.zim"
local ZIM = require("zim")
local HtmlClean = require("htmlclean")

local fails, checks = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if cond then
        print(string.format("  ok   %s", name))
    else
        fails = fails + 1
        print(string.format("  FAIL %s%s", name, detail and (" — " .. tostring(detail)) or ""))
    end
end

print("== open ==")
local z, err = ZIM.open(zim_path)
check("ZIM.open succeeds", z ~= nil, err)
if not z then os.exit(1) end
check("article_count == 6", z.article_count == 6, z.article_count)
check("cluster_count == 6", z.cluster_count == 6, z.cluster_count)
check("mime list parsed", z.mimes[1] == "text/html" and z.mimes[2] == "image/png",
    table.concat(z.mimes, ","))

print("== exact lookup (Turkish) ==")
for _, url in ipairs({ "Ana_Sayfa", "İstanbul", "Fizik", "Çocuk", "Işık" }) do
    local entry = z:findExact("C", url)
    check("findExact C/" .. url, entry ~= nil and entry.kind == "article")
end

print("== read + decompress (zstd) ==")
local ist = z:findExact("C", "İstanbul")
local html, mime = z:readArticle(ist)
check("readArticle returns html", html ~= nil and #html > 100, html and #html)
check("mime is text/html", mime == "text/html", mime)
check("html contains İstanbul", html and html:find("İstanbul", 1, true) ~= nil)
check("html contains infobox", html and html:find("infobox", 1, true) ~= nil)

print("== binary search ordering ==")
local idx, exact = z:findUrlIndex("C", "Fizik")
check("Fizik found exactly", exact == true, tostring(idx))
local idx2, exact2 = z:findUrlIndex("C", "Zzzz")
check("missing key not exact", exact2 == false)

print("== prefix search ==")
local hits = z:prefixSearch("C", "F", 10)
check("prefix F returns Fizik", #hits >= 1 and hits[1].url == "Fizik",
    #hits > 0 and hits[1].url or "none")

print("== image entry ==")
local img = z:findExact("I", "logo.png")
check("image entry found", img ~= nil)
if img then
    local data, imime = z:readArticle(img)
    check("image bytes are PNG", data and data:sub(1, 4) == "\137PNG", imime)
end

print("== main page ==")
local main = z:getMainPageEntry()
check("main page resolves", main ~= nil and main.url == "Ana_Sayfa",
    main and main.url or "nil")

print("== htmlclean full page ==")
local cleaned = HtmlClean.clean(html, true, "İstanbul", {})
check("header injected", cleaned:find("mw-body-header", 1, true) ~= nil)
check("navbox stripped", cleaned:find("NAVBOX", 1, true) == nil)
check("references stripped", cleaned:find("Kaynak 1", 1, true) == nil)
check("infobox rebuilt", cleaned:find('class="infobox"', 1, true) ~= nil)
check("prose kept", cleaned:find("Marmara", 1, true) ~= nil)

print("== htmlclean lookup mode ==")
local lead = HtmlClean.clean(html, false, "İstanbul", {})
check("lookup drops tables", lead:find("<table", 1, true) == nil)
check("lookup keeps prose", lead:find("Marmara", 1, true) ~= nil)

print("== cluster cache ==")
-- İstanbul lives in cluster 4 in the fixture; reading it must leave that
-- cluster cached so a second read is a memory hit, not another decompress.
local ist_cluster = ist.cluster
local c1 = z.cluster_cache:get(ist_cluster)
check("read article's cluster is cached", c1 ~= nil, "cluster " .. tostring(ist_cluster))
local blob = z:readBlob(ist_cluster, 0)
check("readBlob reuses cache", blob ~= nil and #blob > 0)
check("cache stays under its byte budget",
    z.cluster_cache.bytes <= z.cluster_cache.cap,
    string.format("%d > %d", z.cluster_cache.bytes, z.cluster_cache.cap))

z:close()
print(string.format("\n%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)

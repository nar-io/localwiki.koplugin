-- Verify the cluster module on the Kindle: zstd must resolve, and a real
-- article must decompress through the new probe path.
package.path = '/mnt/us/koreader/?.lua;/mnt/us/koreader/frontend/?.lua;/mnt/us/koreader/plugins/?.lua;/mnt/us/koreader/plugins/localwiki.koplugin/?.lua;' .. package.path
package.cpath = '/mnt/us/koreader/libs/?.so;' .. package.cpath
require("setupkoenv")

local ok_c, Cluster = pcall(require, "cluster")
print("cluster require: " .. tostring(ok_c) .. " " .. (ok_c and "" or tostring(Cluster)))

local ok_z, ZIM = pcall(require, "zim")
if not ok_z then print("zim require failed: " .. tostring(ZIM)) return end

local path = "/mnt/us/Wikipedia/dune_full.zim"
local z, err = ZIM.open(path)
if not z then print("ZIM.open failed: " .. tostring(err)) return end
print(string.format("opened: %d articles, %d clusters", z.article_count, z.cluster_count))

local entry = z:findExact("C", "Paul_Atreides")
if not entry then
    entry = z:findExact("A", "Paul_Atreides")
end
if not entry then print("Paul_Atreides not found") return end

local t0 = os.clock()
local ok_r, html = pcall(function() return z:readArticle(entry) end)
if not ok_r then print("readArticle FAILED: " .. tostring(html)) return end
print(string.format("readArticle: %d bytes in %.3f s", html and #html or 0, os.clock() - t0))
print(html and #html > 1000 and "RESULT OK" or "RESULT EMPTY")

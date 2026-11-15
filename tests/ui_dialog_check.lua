-- Drive the real UI code paths that crashed on the device. ButtonDialog is
-- stubbed to record what it was handed, so a malformed `buttons` table shows
-- up here instead of as a crash on the Kindle.
package.path = "./?.lua;./frontend/?.lua;./plugins/?.lua;" .. package.path
package.cpath = "./libs/?.so;" .. package.cpath
require("setupkoenv")
package.path = "/home/opc/koreader_wikipedia/plugins/localwiki.koplugin/?.lua;" .. package.path

local shown = {}
package.preload["ui/widget/buttondialog"] = function()
    local BD = {}
    function BD:new(o)
        o = o or {}
        table.insert(shown, o)
        return setmetatable(o, { __index = BD })
    end
    function BD:init() end
    function BD:handleEvent() return true end
    return BD
end
package.preload["fontlist"] = function() return { getFontList = function() return {} end, fontnames = {} } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
-- The host's glibc is older than KOReader's MuPDF build expects; stub the
-- widget stack that drags it in. The plugin's own code still runs for real.
package.preload["viewer"] = function()
    local V = {}
    function V:new(o) return setmetatable(o or {}, { __index = V }) end
    function V:openImageViewer() end
    return V
end
package.preload["ui/widget/infomessage"] = function()
    local M = {}
    function M:new(o) o = o or {}; table.insert(shown, o); return setmetatable(o, {__index = M}) end
    function M:init() end
    function M:handleEvent() return true end
    return M
end
for _, m in ipairs{ "ui/widget/dictquicklookup", "ui/renderimage", "ui/widget/imageviewer",
                    "ui/widget/pathchooser", "ui/widget/menu", "ui/widget/inputdialog" } do
    package.preload[m] = function()
        return setmetatable({}, { __index = function() return function() end end })
    end
end

G_reader_settings = require("luasettings"):open("/tmp/lw_settings.lua", true)
G_defaults = require("luasettings"):open("./defaults.lua", true)

local LocalWiki = require("main")
local Library = require("library")

local fails, checks = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if cond then print("  ok   " .. name)
    else fails = fails + 1
        print("  FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
    end
end

-- Build a plugin instance with a fake multi-archive library.
local s = setmetatable({}, { __index = LocalWiki })
s.library = Library.new()
s.library.zims = {
    { base = "asimov_full.zim", paths = { "/x/a.zim" }, single = true },
    { base = "dune_full.zim",    paths = { "/x/d.zim" }, single = true },
    { base = "lotr_full.zim",    paths = { "/x/l.zim" }, single = true },
}
for _, e in ipairs(s.library.zims) do s.library.by_base[e.base] = e end
s._scanned = true
s._folder = function() return "/mnt/us/Wikipedia" end
s.history = {}

-- 1. showLoadedZims must not blow up on the `_` gettext shadowing bug.
shown = {}
local ok, err = pcall(function() s:showLoadedZims() end)
check("showLoadedZims runs", ok, err)
local dlg = shown[#shown]
check("a dialog was shown", dlg ~= nil)
if dlg then
    check("dialog has a title", type(dlg.title) == "string", dlg.title)
    local rows = dlg.buttons or {}
    check("one row per archive + controls", #rows == 4, #rows)
    local shaped = true
    for i, row in ipairs(rows) do
        if type(row) ~= "table" or type(row[1]) ~= "table" or type(row[1].text) ~= "string" then
            shaped = false
            print("    row " .. i .. " is not a button row")
        end
    end
    check("every row is a button row", shaped)
    check("first row is an archive", rows[1] and rows[1][1].text:find("asimov_full.zim", 1, true) ~= nil,
        rows[1] and rows[1][1].text)
end

-- 2. Toggling a row must disable that archive and redraw.
if dlg and dlg.buttons[1] then
    local before = s.library:activeCount()
    local ok2, err2 = pcall(dlg.buttons[1][1].callback)
    check("archive row callback runs", ok2, err2)
    check("archive got disabled", s.library:activeCount() == before - 1)
end

-- 3. openMainPage with several archives must show a picker with one row each.
shown = {}
ok, err = pcall(function() s:openMainPage() end)
check("openMainPage runs", ok, err)
local picker = shown[#shown]
check("picker was shown", picker ~= nil)
if picker then
    local rows = picker.buttons or {}
    check("picker has one row per enabled archive", #rows == 2, #rows)
    local shaped = true
    for i, row in ipairs(rows) do
        if type(row) ~= "table" or type(row[1]) ~= "table" or type(row[1].text) ~= "string" then
            shaped = false
            print("    picker row " .. i .. " is not a button row")
        end
    end
    check("picker rows are button rows", shaped)
end

-- 4. With a single enabled archive the picker is skipped entirely.
s.library:setDisabled("dune_full.zim", true)
shown = {}
pcall(function() s:openMainPage() end)
local skipped = true
for _, d in ipairs(shown) do
    if d.title == "Open main page of…" then skipped = false end
end
check("single archive opens directly", skipped)

print(string.format("\n%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)

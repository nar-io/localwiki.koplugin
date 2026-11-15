-- Run on the Kindle: exercise the two menu paths that crashed, against the
-- real archives in /mnt/us/Wikipedia. UI widgets are stubbed so this can run
-- headless; the plugin's own code is the real thing.
package.path = './?.lua;./frontend/?.lua;./plugins/?.lua;' .. package.path
package.cpath = './libs/?.so;' .. package.cpath
require('setupkoenv')
package.path = '/mnt/us/koreader/plugins/localwiki.koplugin/?.lua;' .. package.path

G_reader_settings = require('luasettings'):open('/mnt/us/koreader/settings/reader.lua', true)
G_defaults = require('luasettings'):open('./defaults.lua', true)

package.preload['fontlist'] = function()
    return { getFontList = function() return {} end, fontnames = {} }
end
package.preload['ui/font'] = function()
    return { getFace = function() return {} end }
end
package.preload['viewer'] = function()
    local V = {}
    function V:new(o) return setmetatable(o or {}, { __index = V }) end
    function V:openImageViewer() end
    return V
end
for _, m in ipairs{ 'ui/widget/pathchooser', 'ui/widget/menu', 'ui/widget/inputdialog',
                    'ui/widget/dictquicklookup', 'ui/renderimage', 'ui/widget/imageviewer' } do
    package.preload[m] = function()
        local M = {}
        function M:new(o) return setmetatable(o or {}, { __index = M }) end
        function M:init() end
        function M:handleEvent() return true end
        return M
    end
end

local shown = {}
package.preload['ui/widget/buttondialog'] = function()
    local BD = {}
    function BD:new(o) o = o or {}; table.insert(shown, o); return setmetatable(o, { __index = BD }) end
    function BD:init() end
    function BD:handleEvent() return true end
    return BD
end
package.preload['ui/widget/infomessage'] = function()
    local M = {}
    function M:new(o) o = o or {}; table.insert(shown, o); return setmetatable(o, { __index = M }) end
    function M:init() end
    function M:handleEvent() return true end
    return M
end

local LocalWiki = require('main')
local Library = require('library')

local fails, checks = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if cond then print('  ok   ' .. name)
    else fails = fails + 1; print('  FAIL ' .. name .. (detail and (' — ' .. tostring(detail)) or '')) end
end

local s = setmetatable({}, { __index = LocalWiki })
s.library = Library.new()
s.library:scan('/mnt/us/Wikipedia')
s._scanned = true
s._folder = function() return '/mnt/us/Wikipedia' end
s.history = {}

local n = #s.library.zims
print(string.format('archives found: %d', n))

-- 1. Loaded ZIMs dialog (crashed with "attempt to call local '_'").
shown = {}
local ok, err = pcall(function() s:showLoadedZims() end)
check('showLoadedZims runs', ok, err)
local dlg = shown[#shown]
check('dialog shown', dlg ~= nil)
if dlg then
    local rows = dlg.buttons or {}
    check('one row per archive + controls', #rows == n + 1, #rows)
    local shaped = true
    for i, row in ipairs(rows) do
        if type(row) ~= 'table' or type(row[1]) ~= 'table' or type(row[1].text) ~= 'string' then
            shaped = false; print('    row ' .. i .. ' is not a button row')
        end
    end
    check('every row is a button row', shaped)
end

-- 2. Main-page picker (opened an empty dialog on the device).
shown = {}
ok, err = pcall(function() s:openMainPage() end)
check('openMainPage runs', ok, err)
local picker = shown[#shown]
check('picker shown', picker ~= nil)
if picker then
    local rows = picker.buttons or {}
    check('one row per enabled archive', #rows == s.library:activeCount(), #rows)
    local shaped = true
    for i, row in ipairs(rows) do
        if type(row) ~= 'table' or type(row[1]) ~= 'table' or type(row[1].text) ~= 'string' then
            shaped = false; print('    picker row ' .. i .. ' is not a button row')
        end
    end
    check('picker rows are button rows', shaped)
end

-- 3. Every archive's main page must open a real article.
for _i, e in ipairs(s.library.zims) do
    local z = s.library:open(e.base)
    local entry = z and z:getMainPageEntry()
    local html = entry and z:readArticle(entry)
    check(string.format('main page of %s', e.base),
        html ~= nil and #html > 500,
        entry and (entry.namespace .. '/' .. entry.url) or 'no entry')
end

-- 4. Disabling an archive takes it out of the picker.
local first = s.library.zims[1].base
s.library:setDisabled(first, true)
shown = {}
pcall(function() s:openMainPage() end)
local p2 = shown[#shown]
check('disabled archive leaves the picker', p2 and #(p2.buttons or {}) == n - 1,
    p2 and #(p2.buttons or {}))
s.library:setDisabled(first, false)

print(string.format('\n%d checks, %d failed', checks, fails))
os.exit(fails == 0 and 0 or 1)

--[[
Wikipedia ZIM plugin — main entry.

Auto-discovers ZIMs (and split-set parts) in the configured folder
(default /mnt/us/wikipedia/) and exposes a "Wikipedia (offline)" submenu:
  * Search articles      (prefix search across all ZIMs in the folder)
  * Open main page       (of the first/only ZIM)
  * Loaded ZIMs…         (status — what was discovered + open state)
  * Set Wikipedia folder…  (rarely needed)

Each logical ZIM is opened lazily on first search/article and kept open
for the rest of the session (one set of file handles per ZIM, regardless
of how many .zim?? part files it consists of on disk).
]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")

local Library = require("library")
local Viewer = require("viewer")
local HtmlClean = require("htmlclean")

local SETTING_FOLDER      = "wikipediazim_folder"
local SETTING_FONT        = "wikipediazim_font_size"
local SETTING_FACE        = "wikipediazim_font_face"
local SETTING_SPACING     = "wikipediazim_line_spacing"
local SETTING_MARGIN      = "wikipediazim_margin_em"
local LEGACY_PATH_SETTING = "wikipediazim_path"   -- old single-file setting

local DEFAULT_FOLDER = "/mnt/us/wikipedia"

-- Seed font size from KOReader's global reading setting on first launch.
local function _defaultFontSize()
    local kr = G_reader_settings:readSetting("copt_font_size")
    if type(kr) == "number" and kr > 0 then return kr end
    return 26
end

local function _defaultFontFace()
    return G_reader_settings:readSetting("copt_fontface")  -- may be nil
end

local WikipediaZim = WidgetContainer:extend{
    name = "wikipediazim",
    is_doc_only = false,
}

-- ---------- init ----------

function WikipediaZim:init()
    self.library     = Library.new()
    self.history     = {}
    self.last_search = nil
    self.current_html  = nil
    self.current_entry = nil
    self.current_title = nil
    self.font_size    = G_reader_settings:readSetting(SETTING_FONT)    or _defaultFontSize()
    self.font_face    = G_reader_settings:readSetting(SETTING_FACE)    or _defaultFontFace()
    self.line_spacing = G_reader_settings:readSetting(SETTING_SPACING) or 1.2
    -- margin_em is the "compact view" knob (no UI to set it yet) — always
    -- start from the in-code default rather than a stale saved value.
    self.margin_em    = 0

    -- One-shot migration from the old single-file setting:
    --   <folder>/<file>.zim  -->  folder = <folder>
    if not G_reader_settings:readSetting(SETTING_FOLDER) then
        local legacy = G_reader_settings:readSetting(LEGACY_PATH_SETTING)
        if legacy and legacy ~= "" then
            local dir = legacy:match("^(.+)[/\\][^/\\]+$")
            if dir then
                G_reader_settings:saveSetting(SETTING_FOLDER, dir)
                logger.info("wikipediazim: migrated folder from legacy path -> " .. dir)
            end
        end
    end

    self.ui.menu:registerToMainMenu(self)
end

function WikipediaZim:_folder()
    return G_reader_settings:readSetting(SETTING_FOLDER) or DEFAULT_FOLDER
end

-- Lazy: only scans the folder the first time the user actually does anything.
-- Returns true if at least one logical ZIM was found.
function WikipediaZim:_ensureScanned()
    if self._scanned then return #self.library.zims > 0 end
    self._scanned = true
    self.library:scan(self:_folder())
    return #self.library.zims > 0
end

function WikipediaZim:_rescan()
    self.library:closeAll()
    self.library = Library.new()
    self._scanned = false
    return self:_ensureScanned()
end

function WikipediaZim:onCloseDocument() self:_releaseAll() end
function WikipediaZim:onSuspend()       self:_releaseAll() end

function WikipediaZim:_releaseAll()
    self.library:closeAll()
    self.history = {}
    self.current_entry = nil
    self.current_html  = nil
end

-- ---------- menu ----------

function WikipediaZim:addToMainMenu(menu_items)
    menu_items.wikipediazim = {
        text = _("Wikipedia (offline)"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:_buildSubMenu() end,
    }
end

function WikipediaZim:_buildSubMenu()
    self:_ensureScanned()
    local items = {
        {
            text = _("Search articles"),
            enabled_func = function() return #self.library.zims > 0 end,
            callback = function() self:openSearchDialog() end,
        },
        {
            text = _("Open main page"),
            enabled_func = function() return #self.library.zims > 0 end,
            callback = function() self:openMainPage() end,
        },
        {
            text_func = function()
                local n = #self.library.zims
                if n == 0 then
                    return _("No ZIM files found in folder")
                end
                local opened = self.library:openedCount()
                return string.format(_("Loaded ZIMs: %d (%d open)"), n, opened)
            end,
            keep_menu_open = true,
            callback = function() self:showLoadedZims() end,
        },
        {
            text = _("Set Wikipedia folder…"),
            keep_menu_open = true,
            callback = function() self:chooseFolder() end,
        },
        {
            text_func = function() return _("Folder: ") .. self:_folder() end,
            enabled_func = function() return false end,
        },
    }
    return items
end

function WikipediaZim:showLoadedZims()
    self:_ensureScanned()
    if #self.library.zims == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No .zim or .zim?? files in:\n%s\n\nDrop your ZIM (or its split parts) into that folder, then re-open this menu."),
                self:_folder()),
        })
        return
    end
    local lines = {}
    for _, e in ipairs(self.library.zims) do
        local state = e.zim and "● open" or "○ closed"
        local layout
        if e.single then
            layout = "single file"
        else
            layout = string.format("%d parts", #e.paths)
        end
        local meta = ""
        if e.zim then
            meta = string.format("  (%d articles)", e.zim.article_count)
        end
        lines[#lines + 1] = string.format("%s  %s\n   %s%s",
            state, e.base, layout, meta)
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n\n") })
end

function WikipediaZim:chooseFolder()
    local picker
    picker = PathChooser:new{
        title = _("Folder containing your ZIM file(s)"),
        select_directory = true,
        select_file = false,
        path = self:_folder(),
        onConfirm = function(folder)
            G_reader_settings:saveSetting(SETTING_FOLDER, folder)
            self:_rescan()
            UIManager:show(InfoMessage:new{
                text = string.format(_("Folder set: %s\nFound %d ZIM(s)."),
                    folder, #self.library.zims),
                timeout = 2,
            })
        end,
    }
    UIManager:show(picker)
end

-- ---------- search ----------

local function query_to_url(q)
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    q = q:gsub(" ", "_")
    if #q > 0 then q = q:sub(1, 1):upper() .. q:sub(2) end
    return q
end

local function url_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function WikipediaZim:openSearchDialog()
    if not self:_ensureScanned() then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No ZIM files in:\n%s"), self:_folder()),
        })
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search Wikipedia"),
        input = self.last_search or "",
        input_hint = _("Article title prefix"),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true,
              callback = function()
                  local q = dialog:getInputText()
                  UIManager:close(dialog)
                  self.last_search = q
                  self:runSearch(q)
              end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WikipediaZim:runSearch(query)
    if not self:_ensureScanned() then return end
    local url = query_to_url(query)
    if url == "" then return end
    local results = self.library:prefixSearch("C", url, 60)
    if #results == 0 then
        UIManager:show(InfoMessage:new{ text = _("No matches for: ") .. query })
        return
    end
    self:showResultsMenu(results, query)
end

function WikipediaZim:showResultsMenu(results, query)
    local multi = self.library:isMultiZim()
    local menu_items = {}
    for _i, entry in ipairs(results) do
        local title = entry.title ~= "" and entry.title or entry.url
        if entry.kind == "redirect" then title = title .. " ⇒" end
        if multi then
            -- Show short ZIM tag when results span multiple ZIMs
            local short = (entry._base or ""):match("^([^_%.]+)") or entry._base or ""
            title = "[" .. short:sub(1, 10) .. "] " .. title
        end
        menu_items[#menu_items + 1] = {
            text = title,
            callback = function() self:openEntry(entry, true) end,
        }
    end
    local menu = Menu:new{
        title = string.format(_("Results for “%s” (%d)"), query, #results),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
    }
    UIManager:show(menu)
end

-- ---------- article opening + navigation ----------

function WikipediaZim:openMainPage()
    if not self:_ensureScanned() then return end
    local first = self.library.zims[1]
    if not first then return end
    local z, err = self.library:open(first.base)
    if not z then
        UIManager:show(InfoMessage:new{ text = tostring(err) })
        return
    end
    local entry = z:getMainPageEntry()
    if not entry then
        UIManager:show(InfoMessage:new{ text = _("This ZIM has no main page.") })
        return
    end
    entry._base = first.base
    self.history = {}
    self:openEntry(entry, false)
end

function WikipediaZim:openEntry(entry, push_history)
    local base = entry._base
    if not base then
        -- Shouldn't happen, but fall back to first ZIM
        base = self.library.zims[1] and self.library.zims[1].base
    end
    local z, err = self.library:open(base)
    if not z then
        UIManager:show(InfoMessage:new{ text = tostring(err) })
        return
    end
    local resolved = z:resolveRedirect(entry)
    if not resolved or resolved.kind ~= "article" then
        UIManager:show(InfoMessage:new{ text = _("Article not found.") })
        return
    end
    local ok, html_or_err, mime = pcall(function() return z:readArticle(resolved) end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(html_or_err) })
        return
    end
    local html = html_or_err
    if not html or not mime or not mime:match("^text/html") then
        UIManager:show(InfoMessage:new{ text = _("Article is not HTML.") })
        return
    end
    resolved._base = base

    if push_history and self.current_entry then
        self.history[#self.history + 1] = self.current_entry
    end
    self.current_entry = resolved
    self.current_title = resolved.title ~= "" and resolved.title or resolved.url
    self.current_html  = HtmlClean.clean(html)

    self:_showViewer()
end

function WikipediaZim:_applySettings(sz, face, spc, margin)
    self.font_size    = sz     or self.font_size
    self.font_face    = face   -- nil is valid (default serif)
    self.line_spacing = spc    or self.line_spacing
    self.margin_em    = margin or self.margin_em
    G_reader_settings:saveSetting(SETTING_FONT,    self.font_size)
    G_reader_settings:saveSetting(SETTING_FACE,    self.font_face)
    G_reader_settings:saveSetting(SETTING_SPACING, self.line_spacing)
    G_reader_settings:saveSetting(SETTING_MARGIN,  self.margin_em)
    self:_showViewer()
end

function WikipediaZim:_showViewer()
    if not self.current_html then return end
    if self.current_viewer then
        UIManager:close(self.current_viewer)
        self.current_viewer = nil
    end
    self.current_viewer = Viewer:new{
        title        = self.current_title or "",
        html         = self.current_html,
        font_size    = self.font_size,
        font_face    = self.font_face,
        line_spacing = self.line_spacing,
        margin_em    = self.margin_em,
        can_go_back  = #self.history > 0,
        on_link     = function(href)                    self:_followLink(href) end,
        on_back     = function()                        self:_goBack() end,
        on_home     = function()                        self:openMainPage() end,
        on_search   = function()                        self:openSearchDialog() end,
        on_settings = function(sz, face, spc, margin)   self:_applySettings(sz, face, spc, margin) end,
    }
    UIManager:show(self.current_viewer)
end

function WikipediaZim:_goBack()
    local prev = table.remove(self.history)
    if not prev then return end
    self.current_entry = nil  -- so openEntry won't push prev back onto history
    self:openEntry(prev, false)
end

function WikipediaZim:_followLink(href)
    if not href or href == "" then return end
    local hash = href:find("#", 1, true)
    if hash then href = href:sub(1, hash - 1) end
    if href == "" then return end
    href = href:gsub("^%./", "")
    if href:match("^https?://") or href:match("^mailto:") then
        UIManager:show(InfoMessage:new{
            text = _("External link (offline):\n") .. href, timeout = 2,
        })
        return
    end
    local target = url_decode(href)
    -- Look up in the same ZIM as the current article first; if not found,
    -- fall back to scanning the others (rare with one Wikipedia ZIM).
    local base = self.current_entry and self.current_entry._base
    local tried = {}
    if base then
        local z = self.library:open(base)
        if z then
            local idx, exact = z:findUrlIndex("C", target)
            if exact then
                local entry = z:getEntryByIndex(idx)
                entry._base = base
                self:openEntry(entry, true)
                return
            end
            tried[base] = true
        end
    end
    for _, e in ipairs(self.library.zims) do
        if not tried[e.base] then
            local z = self.library:open(e.base)
            if z then
                local idx, exact = z:findUrlIndex("C", target)
                if exact then
                    local entry = z:getEntryByIndex(idx)
                    entry._base = e.base
                    self:openEntry(entry, true)
                    return
                end
            end
        end
    end
    UIManager:show(InfoMessage:new{
        text = _("Linked article not found:\n") .. target, timeout = 3,
    })
end

return WikipediaZim

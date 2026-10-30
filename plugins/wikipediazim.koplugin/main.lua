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
local ok_dict, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")

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
    self:registerSelectionHooks()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            self:registerSelectionHooks()
        end)
    end
end

function WikipediaZim:onReaderReady()
    self:registerSelectionHooks()
end

function WikipediaZim:registerSelectionHooks()
    self:addToHighlightDialog()
    self:registerDictButtons()
    self:hookWikipediaModule()
end

function WikipediaZim:addToHighlightDialog()
    if not self.ui or not self.ui.highlight then return end
    self.ui.highlight:addToHighlightDialog("05_wikipedia_offline", function(this)
        return {
            id = "wikipedia_offline",
            text = _("Offline Wikipedia"),
            show_in_highlight_dialog_func = function()
                return true
            end,
            callback = function()
                if this.hold_pos and not this.selected_text then
                    this:highlightFromHoldPos()
                end
                local raw_text = this.selected_text and this.selected_text.text
                local boxes = this.selected_text and (this.selected_text.sboxes or this.selected_text.pboxes)
                local ok_util, util = pcall(require, "util")
                if ok_util and util and util.cleanupSelectedText and raw_text then
                    raw_text = util.cleanupSelectedText(raw_text)
                end
                this:onClose()
                if raw_text and raw_text ~= "" then
                    self:searchFromSelection(raw_text, boxes)
                end
            end,
        }
    end)
end

function WikipediaZim:registerDictButtons()
    if not self.ui or not self.ui.dictionary then return end
    self.ui.dictionary:addToDictButtons({
        id = "wikipedia_offline",
        menu_text = _("Offline Wikipedia"),
        text = _("Offline Wikipedia"),
        can_shrink = true,
        pairs_with = "wikipedia",
        conditional = true,
        show_func = function(dict_popup)
            return not dict_popup.is_offline_wiki
        end,
        callback = function(dict_popup)
            local word = dict_popup.lookupword or dict_popup.word
            if (not word or word == "") and dict_popup.highlight and dict_popup.highlight.selected_text then
                word = dict_popup.highlight.selected_text.text
            end
            local boxes = dict_popup.word_boxes
            dict_popup:onClose(true)
            if word and word ~= "" then
                self:searchFromSelection(word, boxes)
            end
        end,
    })
end

function WikipediaZim:hookWikipediaModule()
    if not self.ui or not self.ui.wikipedia then return end
    if self._wikipedia_hooked then return end
    self._wikipedia_hooked = true
    local orig_onLookupWikipedia = self.ui.wikipedia.onLookupWikipedia
    self.ui.wikipedia.onLookupWikipedia = function(wiki_self, word, is_sane, boxes, page, lang, dict_close_callback)
        if (G_reader_settings:isTrue("wikipediazim_prefer_offline") or page) and self:_ensureScanned() then
            if page then
                local cands = self:_getSearchCandidates(word)
                for _, cand in ipairs(cands) do
                    local hits = self.library:findExact("C", cand)
                    if #hits > 0 then
                        self:openEntry(hits[1], true)
                        return true
                    end
                end
                local prefix_hits = self.library:prefixSearch("C", query_to_url(word), 1)
                if #prefix_hits > 0 then
                    self:openEntry(prefix_hits[1], true)
                    return true
                end
            end
            if dict_close_callback then dict_close_callback() end
            self:searchFromSelection(word, boxes, dict_close_callback)
            return true
        end
        return orig_onLookupWikipedia(wiki_self, word, is_sane, boxes, page, lang, dict_close_callback)
    end
end

function WikipediaZim:onDispatcherRegisterActions()
    local ok_disp, Dispatcher = pcall(require, "dispatcher")
    if ok_disp and Dispatcher and Dispatcher.registerAction then
        Dispatcher:registerAction("wikipediazim_search", {
            category = "none",
            event = "SearchOfflineWikipedia",
            title = _("Search Offline Wikipedia"),
            general = true,
        })
    end
end

function WikipediaZim:onSearchOfflineWikipedia(text)
    self:searchFromSelection(text)
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
    if self.lookup_window then
        UIManager:close(self.lookup_window)
        self.lookup_window = nil
    end
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
            text = _("Use for default 'Wikipedia' button"),
            checked_func = function()
                return G_reader_settings:isTrue("wikipediazim_prefer_offline")
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse("wikipediazim_prefer_offline")
            end,
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

-- UTF-8 safe first character extraction (returns first UTF-8 char and remainder)
local function utf8_first_char(s)
    if not s or #s == 0 then return "", "" end
    local b1 = s:byte(1)
    local len = 1
    if b1 >= 0xC0 and b1 <= 0xDF then len = 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then len = 3
    elseif b1 >= 0xF0 and b1 <= 0xF7 then len = 4
    end
    if #s < len then len = #s end
    return s:sub(1, len), s:sub(len + 1)
end

-- UTF-8 safe string truncation (avoids cutting in the middle of multi-byte code points)
local function utf8_truncate(s, max_len)
    if not s or #s <= max_len then return s end
    local cut = max_len
    while cut > 0 and (s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0) do
        cut = cut - 1
    end
    if cut > 0 then
        local b = s:byte(cut)
        local char_len = 1
        if b >= 0xC0 and b <= 0xDF then char_len = 2
        elseif b >= 0xE0 and b <= 0xEF then char_len = 3
        elseif b >= 0xF0 and b <= 0xF7 then char_len = 4
        end
        if cut + char_len - 1 > max_len then
            cut = cut - 1
        end
    end
    return s:sub(1, cut):gsub("%s+$", "")
end

-- Generate search candidate URLs supporting Unicode, Turkish characters,
-- multiword phrases, and title-cased variants.
function WikipediaZim:_getSearchCandidates(query)
    local candidates = {}
    local seen = {}
    local function add(c)
        if c and c ~= "" and not seen[c] then
            seen[c] = true
            candidates[#candidates + 1] = c
        end
    end

    local q = query:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if q == "" then return candidates end

    local raw_url = q:gsub(" ", "_")
    local first_char, rest = utf8_first_char(raw_url)

    -- Determine uppercase variants for first character
    local uppers = {}
    if first_char == "i" then
        -- Turkish: 'i' -> 'İ' (U+0130, \196\176); English/standard: 'i' -> 'I'
        uppers[#uppers + 1] = "\196\176"
        uppers[#uppers + 1] = "I"
    elseif first_char == "\196\177" then -- Turkish dotless 'ı' -> 'I'
        uppers[#uppers + 1] = "I"
    elseif first_char == "\196\176" then -- 'İ'
        uppers[#uppers + 1] = "\196\176"
        uppers[#uppers + 1] = "I"
    elseif first_char == "I" then
        uppers[#uppers + 1] = "I"
        uppers[#uppers + 1] = "\196\176"
    elseif first_char == "\195\167" then -- ç -> Ç
        uppers[#uppers + 1] = "\195\135"
    elseif first_char == "\196\159" then -- ğ -> Ğ
        uppers[#uppers + 1] = "\196\158"
    elseif first_char == "\195\182" then -- ö -> Ö
        uppers[#uppers + 1] = "\195\150"
    elseif first_char == "\197\159" then -- ş -> Ş
        uppers[#uppers + 1] = "\197\158"
    elseif first_char == "\195\188" then -- ü -> Ü
        uppers[#uppers + 1] = "\195\156"
    elseif #first_char == 1 and first_char >= "a" and first_char <= "z" then
        uppers[#uppers + 1] = first_char:upper()
    else
        uppers[#uppers + 1] = first_char
    end

    -- 1. Sentence-capitalized candidates (first character uppercase)
    for _, u in ipairs(uppers) do
        add(u .. rest)
    end

    -- 2. Title-cased candidate (if multiple words)
    if raw_url:find("_", 1, true) then
        local words = {}
        for word in raw_url:gmatch("[^_]+") do
            local w_first, w_rest = utf8_first_char(word)
            local w_up = w_first
            if w_first == "i" then w_up = "I"
            elseif w_first == "\196\177" then w_up = "I"
            elseif w_first == "\195\167" then w_up = "\195\135"
            elseif w_first == "\196\159" then w_up = "\196\158"
            elseif w_first == "\195\182" then w_up = "\195\150"
            elseif w_first == "\197\159" then w_up = "\197\158"
            elseif w_first == "\195\188" then w_up = "\195\156"
            elseif #w_first == 1 and w_first >= "a" and w_first <= "z" then
                w_up = w_first:upper()
            end
            words[#words + 1] = w_up .. w_rest
        end
        add(table.concat(words, "_"))

        -- Turkish title-cased candidate if any word starts with i or ı
        local tr_words = {}
        local has_tr = false
        for word in raw_url:gmatch("[^_]+") do
            local w_first, w_rest = utf8_first_char(word)
            local w_up = w_first
            if w_first == "i" then
                w_up = "\196\176" -- 'İ'
                has_tr = true
            elseif w_first == "\196\177" then
                w_up = "I"
                has_tr = true
            elseif w_first == "\195\167" then w_up = "\195\135"
            elseif w_first == "\196\159" then w_up = "\196\158"
            elseif w_first == "\195\182" then w_up = "\195\150"
            elseif w_first == "\197\159" then w_up = "\197\158"
            elseif w_first == "\195\188" then w_up = "\195\156"
            elseif #w_first == 1 and w_first >= "a" and w_first <= "z" then
                w_up = w_first:upper()
            end
            tr_words[#tr_words + 1] = w_up .. w_rest
        end
        if has_tr then
            add(table.concat(tr_words, "_"))
        end
    end

    -- 3. Raw URL as typed/selected (e.g. for "iPhone", "eBay")
    add(raw_url)

    return candidates
end

local function query_to_url(q)
    local cands = WikipediaZim._getSearchCandidates(nil, q)
    return cands[1] or ""
end

local function url_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function WikipediaZim:openSearchDialog(initial_query, custom_title)
    if not self:_ensureScanned() then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No ZIM files in:\n%s"), self:_folder()),
        })
        return
    end
    local q_init = initial_query or self.last_search or ""
    local title = custom_title or _("Search Wikipedia")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = q_init,
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

function WikipediaZim:searchFromSelection(text, boxes, dict_close_callback)
    if type(text) ~= "string" then return end
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.cleanupSelectedText then
        local ok, clean = pcall(util.cleanupSelectedText, text)
        if ok and clean then text = clean end
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end

    -- Safe truncation for excessively long selections (max 256 bytes)
    text = utf8_truncate(text, 256)
    if text == "" then return end

    self.last_search = text
    self:runSearch(text, boxes, dict_close_callback)
end

function WikipediaZim:runSearch(query, boxes, dict_close_callback)
    if not self:_ensureScanned() then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No ZIM files in:\n%s"), self:_folder()),
        })
        return
    end

    if type(query) ~= "string" then return end
    query = query:gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return end
    query = utf8_truncate(query, 256)
    if query == "" then return end

    self.last_search = query

    local candidates = self:_getSearchCandidates(query)
    local results = {}
    local seen_keys = {}

    -- 1. Prefer exact title matches across all ZIMs (best match first)
    for _, cand in ipairs(candidates) do
        local exact_hits = self.library:findExact("C", cand)
        for _, hit in ipairs(exact_hits) do
            local key = (hit._base or "") .. ":" .. (hit.url or "")
            if not seen_keys[key] then
                seen_keys[key] = true
                results[#results + 1] = hit
            end
        end
    end

    -- 2. Fall back to title-prefix search if no exact match or to supplement results
    local max_results = 60
    for _, cand in ipairs(candidates) do
        if #results >= max_results then break end
        local prefix_hits = self.library:prefixSearch("C", cand, max_results - #results)
        for _, hit in ipairs(prefix_hits) do
            local key = (hit._base or "") .. ":" .. (hit.url or "")
            if not seen_keys[key] then
                seen_keys[key] = true
                results[#results + 1] = hit
                if #results >= max_results then break end
            end
        end
    end

    -- 3. If no results found, show empty result in lookup window
    if #results == 0 then
        local dummy_results = {
            {
                dict = _("Wikipedia (offline)"),
                word = query,
                definition = string.format(_("No offline Wikipedia articles found for “%s”."), query),
                is_html = false,
                is_wiki = true,
            }
        }
        self:showInLookupWindow(dummy_results, query, boxes, dict_close_callback)
        return
    end

    self:showInLookupWindow(results, query, boxes, dict_close_callback)
end

function WikipediaZim:_loadArticleHtml(entry)
    local base = entry._base or (self.library.zims[1] and self.library.zims[1].base)
    if not base then
        return "<p><i>" .. _("Article not found.") .. "</i></p>"
    end
    local z, err = self.library:open(base)
    if not z then
        return "<p><i>" .. tostring(err or _("Failed to open ZIM.")) .. "</i></p>"
    end
    local resolved = z:resolveRedirect(entry)
    if not resolved or resolved.kind ~= "article" then
        return "<p><i>" .. _("Article not found.") .. "</i></p>"
    end
    local ok, html_or_err, mime = pcall(function() return z:readArticle(resolved) end)
    if not ok or not html_or_err then
        return "<p><i>" .. tostring(html_or_err or _("Failed to read article.")) .. "</i></p>"
    end
    if not mime or not mime:match("^text/html") then
        return "<p><i>" .. _("Article is not HTML.") .. "</i></p>"
    end
    resolved._base = base
    local cleaned = HtmlClean.clean(html_or_err)
    if not cleaned or cleaned == "" then
        cleaned = html_or_err
    end
    return cleaned
end

function WikipediaZim:showInLookupWindow(results, query, boxes, dict_close_callback)
    if not ok_dict or not DictQuickLookup then
        self:showResultsMenu(results, query)
        return
    end

    local multi = self.library:isMultiZim()
    local dict_results = {}
    local seen_targets = {}

    for _i, entry in ipairs(results) do
        local base = entry._base or (self.library.zims[1] and self.library.zims[1].base)
        local target_key = (base or "") .. ":" .. (entry.url or "")
        if not seen_targets[target_key] then
            seen_targets[target_key] = true

            local title = (entry.title and entry.title ~= "") and entry.title or (entry.url and entry.url:gsub("_", " ")) or query
            title = title:gsub("_", " ")

            local dict_name = _("Wikipedia (offline)")
            if multi then
                local short = (base or ""):match("^([^_%.]+)") or base or ""
                dict_name = string.format(_("Wikipedia (%s)"), short:sub(1, 10))
            end

            local item = {
                dict = dict_name,
                word = title,
                is_html = (entry.is_html ~= false),
                is_wiki = true,
                is_wiki_fullpage = false,
                zim_entry = entry,
            }

            if entry.definition then
                item.definition = entry.definition
            elseif #dict_results == 0 then
                -- Preload definition for the first (best match) result immediately
                item.definition = self:_loadArticleHtml(entry)
            else
                -- Lazy load definition for other matching articles on demand
                setmetatable(item, {
                    __index = function(t, k)
                        if k == "definition" then
                            local def = self:_loadArticleHtml(entry)
                            rawset(t, "definition", def)
                            return def
                        end
                        return nil
                    end,
                })
            end

            table.insert(dict_results, item)
        end
    end

    if #dict_results == 0 then
        table.insert(dict_results, {
            dict = _("Wikipedia (offline)"),
            word = query,
            definition = string.format(_("No offline Wikipedia articles found for “%s”."), query),
            is_html = false,
            is_wiki = true,
        })
    end

    local ui = self.ui
    if not ui then
        ui = {}
    end
    if not ui.wikipedia then
        ui.wikipedia = {
            getWikiLanguages = function()
                return { "en" }, "en"
            end,
            setLastSelectedLanguage = function() end,
        }
    end
    if not ui.dictionary then
        ui.dictionary = {
            default_layout = {
                { "prev_dict", "highlight", "next_dict" },
                { "wikipedia", "search", "close" },
            },
            _dict_buttons = {},
            addToDictButtons = function() end,
        }
    end

    local lookup_window
    lookup_window = DictQuickLookup:new{
        ui = ui,
        highlight = self.ui and self.ui.highlight,
        word = query,
        results = dict_results,
        word_boxes = boxes,
        is_wiki = true,
        is_wiki_fullpage = false,
        is_offline_wiki = true,
        refresh_callback = function()
            if self.ui and self.ui.view and self.ui.view.footer then
                self.ui.view.footer:onUpdateFooter()
            end
        end,
        html_dictionary_link_tapped_callback = function(dictionary, link)
            self:onHtmlDictionaryLinkTapped(dictionary, link)
        end,
        dict_close_callback = dict_close_callback,
    }
    self.lookup_window = lookup_window
    UIManager:show(lookup_window)
end

function WikipediaZim:onHtmlDictionaryLinkTapped(dictionary, link)
    local href = type(link) == "table" and (link.uri or link.url) or link
    if not href or href == "" then return end
    local hash = href:find("#", 1, true)
    if hash then href = href:sub(1, hash - 1) end
    if href == "" then return end
    href = href:gsub("^%./", ""):gsub("^/A/", ""):gsub("^A/", "")
    href = href:gsub("%.html?$", "")
    if href:match("^https?://") or href:match("^mailto:") then
        UIManager:show(InfoMessage:new{
            text = _("External link (offline):\n") .. href, timeout = 2,
        })
        return
    end
    local target = url_decode(href)
    local link_boxes
    if type(link) == "table" and link.x0 and link.y0 then
        local ok_geom, Geom = pcall(require, "ui/geometry")
        if ok_geom and Geom then
            link_boxes = {
                Geom:new{
                    x = link.x0,
                    y = link.y0,
                    w = math.abs((link.x1 or link.x0) - link.x0),
                    h = math.abs((link.y1 or link.y0) - link.y0),
                }
            }
        end
    end
    self:searchFromSelection(target, link_boxes)
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
    local menu
    menu = Menu:new{
        title = string.format(_("Results for “%s” (%d)"), query, #results),
        item_table = menu_items,
        is_borderless = true,
        is_popout = false,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        title_bar_left_icon = "search",
        onLeftButtonTap = function()
            UIManager:close(menu)
            self:openSearchDialog(query)
        end,
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

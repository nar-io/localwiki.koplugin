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

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Font = require("ui/font")
local Archiver = require("ffi/archiver")
local ffiUtil = require("ffi/util")
local InputDialog = require("ui/widget/inputdialog")
local lfs = require("libs/libkoreader-lfs")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")
local ok_dict, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")

local Library = require("library")
local TitleIndex = require("titleindex")
local WordIndex = require("wordindex")
local Viewer = require("viewer")
local HtmlClean = require("htmlclean")

local SETTING_FOLDER      = "localwiki_folder"
local LEGACY_FOLDER_SETTING = "wikipediazim_folder"
local SETTING_FONT        = "localwiki_font_size"
local SETTING_FACE        = "localwiki_font_face"
local SETTING_SPACING     = "localwiki_line_spacing"
local SETTING_MARGIN      = "localwiki_margin_em"
local SETTING_DISABLED_ZIMS = "localwiki_disabled_zims"
local SETTING_IMAGE_LIMIT = "localwiki_image_limit"
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

local function sanitizeDictButtonConfig()
    local config = G_reader_settings:readSetting("dict_button_config")
    if config and config.layout then
        local modified = false
        for i = #config.layout, 1, -1 do
            local row = config.layout[i]
            if type(row) == "table" then
                for j = #row, 1, -1 do
                    if row[j] == "wikipedia_offline" then
                        table.remove(row, j)
                        modified = true
                    end
                end
                if #row == 0 then
                    table.remove(config.layout, i)
                    modified = true
                end
            end
        end
        if config.order then
            for j = #config.order, 1, -1 do
                if config.order[j] == "wikipedia_offline" then
                    table.remove(config.order, j)
                    modified = true
                end
            end
        end
        if modified then
            G_reader_settings:saveSetting("dict_button_config", config)
        end
    end
end

local function sanitizeDictLayout(dict_module)
    if not dict_module or not dict_module.default_layout then return end
    local layout = dict_module.default_layout
    for i = #layout, 1, -1 do
        local row = layout[i]
        if type(row) == "table" then
            for j = #row, 1, -1 do
                if row[j] == "wikipedia_offline" then
                    table.remove(row, j)
                end
            end
            if #row == 0 then
                table.remove(layout, i)
            end
        end
    end
end

local LocalWiki = WidgetContainer:extend{
    name = "localwiki",
    is_doc_only = false,
}

-- ---------- init ----------

function LocalWiki:init()
    self.library     = Library.new()
    self.history     = {}
    self.last_search = nil
    self.current_html  = nil
    self.current_entry = nil
    self.current_title = nil
    self.font_size    = G_reader_settings:readSetting(SETTING_FONT)    or _defaultFontSize()
    self.font_face    = G_reader_settings:readSetting(SETTING_FACE)    or _defaultFontFace()
    self.line_spacing = G_reader_settings:readSetting(SETTING_SPACING) or 1.2
    -- margin_em is the text inset (em units). It is persisted by
    -- _applySettings(), so read it back instead of forcing the default on
    -- every launch — otherwise a margin the reader picked is silently lost.
    local saved_margin = G_reader_settings:readSetting(SETTING_MARGIN)
    self.margin_em = (type(saved_margin) == "number" and saved_margin >= 0) and saved_margin or 0

    -- One-shot migration from the old single-file setting:
    --   <folder>/<file>.zim  -->  folder = <folder>
    if not G_reader_settings:readSetting(SETTING_FOLDER) then
        local legacy_f = G_reader_settings:readSetting(LEGACY_FOLDER_SETTING)
        if legacy_f and legacy_f ~= "" then
            G_reader_settings:saveSetting(SETTING_FOLDER, legacy_f)
        end
        local legacy = G_reader_settings:readSetting(LEGACY_PATH_SETTING)
        if legacy and legacy ~= "" then
            local dir = legacy:match("^(.+)[/\\][^/\\]+$")
            if dir then
                G_reader_settings:saveSetting(SETTING_FOLDER, dir)
                logger.info("localwiki: migrated folder from legacy path -> " .. dir)
            end
        end
    end

    self.ui.menu:registerToMainMenu(self)
    self:registerSelectionHooks()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            self:registerSelectionHooks()
            -- Index at startup, not on first document: the reader may sit in
            -- the file browser for a long time before opening anything, and
            -- a missing index would then surprise them mid-search.
            self:_indexOnStartup()
        end)
    end
end

function LocalWiki:onReaderReady()
    self:registerSelectionHooks()
end


function LocalWiki:registerSelectionHooks()
    self:addToHighlightDialog()
    self:registerDictButtons()
    self:hookWikipediaModule()
    self:patchDictQuickLookup()
end

function LocalWiki:patchDictQuickLookup()
    if not ok_dict or not DictQuickLookup or DictQuickLookup._localwiki_patched then
        return
    end
    DictQuickLookup._localwiki_patched = true

    -- Safeguard TextBoxWidget: if KOReader adjusts image.width/height for line layout,
    -- ensure image.bb is properly scaled so it never overflows past the right border or overlaps text.
    local ok_tbw, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
    if ok_tbw and TextBoxWidget and not TextBoxWidget._localwiki_patched then
        TextBoxWidget._localwiki_patched = true
        local orig_renderImage = TextBoxWidget._renderImage
        TextBoxWidget._renderImage = function(tb_self, start_row_idx)
            if tb_self.line_num_to_image and tb_self.line_num_to_image[start_row_idx] then
                local img = tb_self.line_num_to_image[start_row_idx]
                if img and img.bb and img.width and img.height then
                    local bw = img.bb:getWidth()
                    local bh = img.bb:getHeight()
                    if bw > img.width or bh > img.height then
                        local ok_ri, RenderImage = pcall(require, "ui/renderimage")
                        if ok_ri and RenderImage then
                            if RenderImage.renderImageData and img._raw_data then
                                local scaled = RenderImage:renderImageData(img._raw_data, #img._raw_data, false, img.width, img.height)
                                if scaled then
                                    img.bb:free()
                                    img.bb = scaled
                                end
                            elseif RenderImage.scaleBlitBuffer then
                                local scaled = RenderImage:scaleBlitBuffer(img.bb, img.width, img.height, true)
                                if scaled then
                                    img.bb:free()
                                    img.bb = scaled
                                end
                            end
                        end
                    end
                end
            end
            return orig_renderImage(tb_self, start_row_idx)
        end
    end

    local orig_buildButtonLayout = DictQuickLookup.buildButtonLayout
    DictQuickLookup.buildButtonLayout = function(dql_self)
        if dql_self.ui and dql_self.ui.dictionary then
            sanitizeDictLayout(dql_self.ui.dictionary)
        end
        sanitizeDictButtonConfig()

        local dict_mod = dql_self.ui and dql_self.ui.dictionary
        local orig_default_layout = dict_mod and dict_mod.default_layout
        local temp_layout = nil
        if dql_self.is_wiki and orig_default_layout then
            local ok_u, u = pcall(require, "util")
            if ok_u and u and u.tableDeepCopy then
                temp_layout = u.tableDeepCopy(orig_default_layout)
                dict_mod.default_layout = temp_layout
            end
        end

        local buttons = orig_buildButtonLayout(dql_self)

        if temp_layout and orig_default_layout then
            dict_mod.default_layout = orig_default_layout
        end

        -- Deduplicate and enforce prefer_offline hiding
        if buttons and type(buttons) == "table" then
            local seen_offline = false
            for i = #buttons, 1, -1 do
                local row = buttons[i]
                if type(row) == "table" then
                    for j = #row, 1, -1 do
                        local btn = row[j]
                        if btn and btn.id == "wikipedia_offline" then
                            if seen_offline or G_reader_settings:isTrue("localwiki_prefer_offline") then
                                table.remove(row, j)
                            else
                                seen_offline = true
                            end
                        end
                    end
                    if #row == 0 then
                        table.remove(buttons, i)
                    end
                end
            end
        end

        return buttons
    end
end

function LocalWiki:addToHighlightDialog()
    if not self.ui or not self.ui.highlight then return end
    self.ui.highlight:addToHighlightDialog("05_wikipedia_offline", function(this)
        return {
            id = "wikipedia_offline",
            text = _("Offline Wikipedia"),
            show_in_highlight_dialog_func = function()
                return not G_reader_settings:isTrue("localwiki_prefer_offline")
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

function LocalWiki:registerDictButtons()
    if not self.ui or not self.ui.dictionary then return end
    sanitizeDictLayout(self.ui.dictionary)
    sanitizeDictButtonConfig()
    self.ui.dictionary:addToDictButtons({
        id = "wikipedia_offline",
        menu_text = _("Offline Wikipedia"),
        text = _("Offline Wikipedia"),
        can_shrink = true,
        pairs_with = "wikipedia",
        conditional = true,
        show_func = function(dict_popup)
            if dict_popup.is_offline_wiki or dict_popup.is_wiki then
                return false
            end
            if G_reader_settings:isTrue("localwiki_prefer_offline") then
                return false
            end
            return true
        end,
        callback = function(dict_popup)
            local word = dict_popup.word
            if (not word or word == "") and dict_popup.highlight and dict_popup.highlight.selected_text then
                word = dict_popup.highlight.selected_text.text
            end
            if not word or word == "" then
                word = dict_popup.lookupword
            end
            local boxes = dict_popup.word_boxes
            dict_popup:onClose(true)
            if word and word ~= "" then
                self:searchFromSelection(word, boxes)
            end
        end,
    })
end

function LocalWiki:hookWikipediaModule()
    if not self.ui or not self.ui.wikipedia then return end
    if self._wikipedia_hooked then return end
    self._wikipedia_hooked = true
    local orig_onLookupWikipedia = self.ui.wikipedia.onLookupWikipedia
    self.ui.wikipedia.onLookupWikipedia = function(wiki_self, word, is_sane, boxes, page, lang, dict_close_callback)
        if (G_reader_settings:isTrue("localwiki_prefer_offline") or page) and self:_ensureScanned() then
            if page then
                local cands = self:_getSearchCandidates(word)
                for _, cand in ipairs(cands) do
                    local hits = self.library:findExact("C", cand)
                    if #hits > 0 then
                        self:openEntry(hits[1], true)
                        return true
                    end
                end
                -- Use the first candidate directly: query_to_url() is declared
                -- further down the file, so a `local function` reference here
                -- would still be nil when this closure is built.
                local prefix_seed = cands[1]
                if prefix_seed then
                    local prefix_hits = self.library:prefixSearch("C", prefix_seed, 1)
                    if #prefix_hits > 0 then
                        self:openEntry(prefix_hits[1], true)
                        return true
                    end
                end
            end
            self:searchFromSelection(word, boxes, dict_close_callback)
            return true
        end
        return orig_onLookupWikipedia(wiki_self, word, is_sane, boxes, page, lang, dict_close_callback)
    end
end

function LocalWiki:onDispatcherRegisterActions()
    local ok_disp, Dispatcher = pcall(require, "dispatcher")
    if ok_disp and Dispatcher and Dispatcher.registerAction then
        Dispatcher:registerAction("localwiki_search", {
            category = "none",
            event = "SearchOfflineWikipedia",
            title = _("Search Offline Wikipedia"),
            general = true,
        })
    end
end

function LocalWiki:onSearchOfflineWikipedia(text)
    self:searchFromSelection(text)
end

function LocalWiki:_folder()
    return G_reader_settings:readSetting(SETTING_FOLDER) or DEFAULT_FOLDER
end

function LocalWiki:_imageLimit()
    local limit = G_reader_settings:readSetting(SETTING_IMAGE_LIMIT)
    if type(limit) == "number" and (limit == -1 or limit >= 0) then return limit end
    -- Preserve the old toggle for users upgrading from the boolean setting.
    if G_reader_settings:readSetting("localwiki_show_images") == false then
        return 0
    end
    return 4
end

local IMAGE_LIMITS = { 0, 1, 2, 3, 4, 5, 6, 10, -1 }

local function imageLimitLabel(limit)
    if limit == 0 then return _("No images") end
    if limit < 0 then return _("All") end
    return tostring(limit)
end

function LocalWiki:_imageLimitMenu()
    local items = {}
    for _, limit in ipairs(IMAGE_LIMITS) do
        items[#items + 1] = {
            text = imageLimitLabel(limit),
            checked_func = function() return self:_imageLimit() == limit end,
            callback = function()
                G_reader_settings:saveSetting(SETTING_IMAGE_LIMIT, limit)
                self._article_lru = nil
                self._article_lru_keys = nil
            end,
        }
    end
    return items
end

function LocalWiki:_saveDisabledZims()
    local disabled = {}
    for base, is_disabled in pairs(self.library.disabled or {}) do
        if is_disabled then disabled[base] = true end
    end
    G_reader_settings:saveSetting(SETTING_DISABLED_ZIMS, disabled)
end

function LocalWiki:_restoreDisabledZims()
    local saved = G_reader_settings:readSetting(SETTING_DISABLED_ZIMS)
    if type(saved) ~= "table" then return end
    for base, is_disabled in pairs(saved) do
        if is_disabled and self.library.by_base[base] then
            self.library:setDisabled(base, true)
        end
    end
end

-- Title index for one logical ZIM, read once from the archive's own
-- titleOrdered listing and cached for the session. This replaces the old
-- word index: no scan, no per-word tables, no OOM on large wikis.
-- Archives above this size keep their titles out of RAM: 1.2M lowercased
-- strings is more than the 474 MB device has, and the reader was killed the
-- moment the index was built. Their prefix search is good enough, and their
-- titles are far more predictable than a fandom wiki's.
local TITLE_INDEX_MAX_ARTICLES = 200000
local WORD_INDEX_MAX_ARTICLES = 100000
-- libzim's Python Item API stores custom items in the C namespace, so keep
-- the internal marker in the URL and look it up as a normal C entry.
local POPULARITY_PATH = "X/localwiki/popularity/v1"

local function read_u32_le(data, pos)
    local a, b, c, d = data:byte(pos, pos + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

function LocalWiki:_titleIndex(base)
    if not self._title_indexes then self._title_indexes = {} end
    if self._title_indexes[base] ~= nil then
        return self._title_indexes[base] or nil
    end
    local z = self.library:open(base)
    if not z then
        self._title_indexes[base] = false
        return nil
    end
    if z.article_count > TITLE_INDEX_MAX_ARTICLES then
        logger.info(string.format("localwiki: skipping title index for %s (%d articles)", base, z.article_count))
        self._title_indexes[base] = false
        return nil
    end
    local cache_path = self.library:pathOf(base)
    if cache_path then cache_path = cache_path .. ".titleidx" end
    local entries = TitleIndex.load(z, cache_path)
    if not entries then
        self._title_indexes[base] = false
        return nil
    end
    local idx = TitleIndex.new(entries)
    logger.info(string.format("localwiki: title index for %s has %d entries", base, idx:entryCount()))
    self._title_indexes[base] = idx
    return idx
end

function LocalWiki:_wordIndex(base)
    if not self._word_indexes then self._word_indexes = {} end
    if self._word_indexes[base] ~= nil then
        return self._word_indexes[base] or nil
    end
    local z = self.library:open(base)
    local path = self.library:pathOf(base)
    if not z or not path or z.article_count > WORD_INDEX_MAX_ARTICLES then
        self._word_indexes[base] = false
        return nil
    end
    local idx = WordIndex.open(z, path)
    self._word_indexes[base] = idx or false
    return idx
end

function LocalWiki:_popularity(base, z)
    if not self._popularity_indexes then self._popularity_indexes = {} end
    if self._popularity_indexes[base] ~= nil then
        return self._popularity_indexes[base] or nil
    end
    local entry = z:findExact("C", POPULARITY_PATH)
    if not entry or entry.kind ~= "article" then
        self._popularity_indexes[base] = false
        return nil
    end
    local data = z:readBlob(entry.cluster, entry.blob)
    if not data or data:sub(1, 5) ~= "LWPS\0" then
        self._popularity_indexes[base] = false
        return nil
    end
    local version = read_u32_le(data, 6)
    local count = read_u32_le(data, 10)
    if version ~= 1 or not count then
        self._popularity_indexes[base] = false
        return nil
    end
    local scores = {}
    local pos = 14
    for _ = 1, count do
        local len_lo, len_hi = data:byte(pos, pos + 1)
        if not len_hi then
            scores = nil
            break
        end
        local len = len_lo + len_hi * 256
        pos = pos + 2
        if pos + len + 3 > #data then
            scores = nil
            break
        end
        local title = data:sub(pos, pos + len - 1)
        pos = pos + len
        local score = read_u32_le(data, pos)
        pos = pos + 4
        if not score then
            scores = nil
            break
        end
        scores[title] = score
    end
    self._popularity_indexes[base] = scores or false
    return scores
end

-- Nothing to prebuild any more. The title listing is read straight from each
-- archive on first use (a few milliseconds for a fandom wiki), so startup no
-- longer scans articles, writes .idx files or holds every archive open.
function LocalWiki:_indexOnStartup()
    return
end

function LocalWiki:_ensureScanned()
    if self._scanned then return #self.library.zims > 0 end
    self._scanned = true
    self.library:scan(self:_folder())
    self:_restoreDisabledZims()
    return #self.library.zims > 0
end

function LocalWiki:_rescan()
    self.library:closeAll()
    self.library = Library.new()
    self._scanned = false
    return self:_ensureScanned()
end

local function getTempImageDir()
    local base
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage and DataStorage.getDataDir then
        base = DataStorage:getDataDir() .. "/cache"
    else
        base = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    end
    local img_dir = base .. "/localwiki_img"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        ok_lfs, lfs = pcall(require, "lfs")
    end
    if ok_lfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, base)
        pcall(lfs.mkdir, img_dir)
    end
    return img_dir
end

local function cleanTempImageDir(max_files)
    max_files = max_files or 300
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then return end
    local dir = getTempImageDir()
    if not lfs.attributes(dir, "mode") then return end
    local entries = {}
    for file in lfs.dir(dir) do
        if file ~= "." and file ~= ".." then
            local p = dir .. "/" .. file
            local mtime = lfs.attributes(p, "modification") or 0
            entries[#entries + 1] = { path = p, mtime = mtime }
        end
    end
    if #entries > max_files then
        table.sort(entries, function(a, b) return a.mtime < b.mtime end)
        for i = 1, #entries - 150 do
            pcall(os.remove, entries[i].path)
        end
    end
end

local function safe_image_filename(src, mime)
    local ext = ".jpg"
    if mime == "image/png" then ext = ".png"
    elseif mime == "image/gif" then ext = ".gif"
    elseif mime == "image/bmp" then ext = ".bmp"
    elseif mime == "image/webp" then ext = ".webp"
    elseif mime == "image/svg+xml" then ext = ".svg"
    else
        local e = src and src:match("%.([%a%d]+)$")
        if e then ext = "." .. e:lower() end
    end

    local base = src:match("([^/]+)$") or src
    base = base:gsub("%.%w+$", ""):gsub("[^%w_%-]", "_")
    if #base > 32 then base = base:sub(1, 32) end
    if #base == 0 then base = "img" end

    local h = 5381
    for i = 1, #src do
        h = ((h * 33) + src:byte(i)) % 4294967296
    end
    return string.format("%s_%08x%s", base, h, ext)
end

function LocalWiki:onCloseDocument() self:_releaseAll() end
function LocalWiki:onSuspend()       self:_releaseAll() end

-- KOReader calls this when the reader closes the viewer. Drop the document and
-- the cleaned HTML right away instead of waiting for the next article: the
-- MuPDF document plus its layout cache is the single biggest allocation the
-- plugin holds.
function LocalWiki:onCloseWidget()
    -- Do not call UIManager:close() here: KOReader is already tearing the
    -- widget down and re-entering the manager corrupts its stack. Just drop
    -- the references so the GC can reclaim the document and the HTML.
    self.current_viewer = nil
    self.current_html = nil
end

function LocalWiki:_releaseAll()
    self.library:closeAll()
    self.history = {}
    self.current_entry = nil
    self.current_html  = nil
    self._article_lru = nil
    self._article_lru_keys = nil
    self._extracted_img_files = nil
    if self.lookup_window then
        UIManager:close(self.lookup_window)
        self.lookup_window = nil
    end
    if cleanTempImageDir then
        cleanTempImageDir()
    end
end

-- ---------- menu ----------

function LocalWiki:addToMainMenu(menu_items)
    menu_items.localwiki = {
        text = _("Wikipedia (offline)"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:_buildSubMenu() end,
    }
end

function LocalWiki:_buildSubMenu()
    self:_ensureScanned()
    local items = {
        {
            text = _("Search articles"),
            enabled_func = function() return self.library:activeCount() > 0 end,
            callback = function() self:openSearchDialog() end,
        },
        {
            text = _("Recent searches"),
            enabled_func = function()
                local h = self:getSearchHistory()
                return #h > 0
            end,
            callback = function() self:showSearchHistoryMenu() end,
        },
        {
            text = _("Open main page"),
            enabled_func = function() return self.library:activeCount() > 0 end,
            callback = function() self:openMainPage() end,
        },
        {
            text_func = function()
                local n = #self.library.zims
                if n == 0 then
                    return _("No ZIM files found in folder")
                end
                local opened = self.library:openedCount()
                local active = self.library:activeCount()
                if active < n then
                    return string.format(_("Loaded ZIMs: %d of %d enabled (%d open)"), active, n, opened)
                end
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
                return G_reader_settings:isTrue("localwiki_prefer_offline")
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse("localwiki_prefer_offline")
                if self.ui and self.ui.dictionary then
                    sanitizeDictLayout(self.ui.dictionary)
                end
                sanitizeDictButtonConfig()
            end,
        },
        {
            text = _("Show references (slower)"),
            checked_func = function()
                return G_reader_settings:isTrue("localwiki_show_references")
            end,
            callback = function()
                G_reader_settings:flipNilOrFalse("localwiki_show_references")
                -- Cached HTML was cleaned with the previous setting.
                self._article_lru = nil
                self._article_lru_keys = nil
            end,
        },
        {
            text_func = function()
                return _("Images: ") .. imageLimitLabel(self:_imageLimit())
            end,
            sub_item_table_func = function() return self:_imageLimitMenu() end,
        },
        {
            text = _("About LocalWiki"),
            keep_menu_open = true,
            callback = function() self:showAbout() end,
        },
        {
            text = _("Check for updates"),
            keep_menu_open = true,
            callback = function() self:checkForUpdates() end,
        },
        {
            text_func = function() return _("Folder: ") .. self:_folder() end,
            enabled_func = function() return false end,
        },
    }
    return items
end

-- ---------- about / update ----------

local PLUGIN_REPO = "nar-io/localwiki.koplugin"
local PLUGIN_VERSION = "0.6.3"
local PLUGIN_ARCHIVE = "localwiki.koplugin.zip"

function LocalWiki:showAbout()
    local lines = {
        _("LocalWiki — offline ZIM reader for KOReader"),
        "",
        string.format(_("Version: %s"), PLUGIN_VERSION),
        string.format(_("Repository: github.com/%s"), PLUGIN_REPO),
        "",
        _("Reads Kiwix ZIM archives (Wikipedia, Wiktionary, Fandom and any other MediaWiki export) straight from the device — no conversion, no companion server."),
        "",
        _("Based on c5e3/koreader_wikipedia; the ZIM engine and the original KOReader integration are the upstream author's work."),
        "",
        _("License: CC BY-NC 4.0"),
        "",
        string.format(_("ZIM folder: %s"), self:_folder()),
        string.format(_("Archives found: %d (%d enabled)"),
            #self.library.zims, self.library:activeCount()),
    }
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

-- Compare the installed version with the latest GitHub release. Runs only
-- when the reader asks for it, so the plugin never phones home on its own.
function LocalWiki:checkForUpdates()
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    local ok_json, rapidjson = pcall(require, "rapidjson")
    if not (ok_http and ok_ltn and ok_json) then
        UIManager:show(InfoMessage:new{
            text = _("Update check needs the network stack; it is not available on this build."),
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates…"), timeout = 1,
    })

    local url = string.format("https://api.github.com/repos/%s/releases/latest", PLUGIN_REPO)
    local chunks = {}
    local ok, code = http.request{
        url = url,
        headers = { ["User-Agent"] = "localwiki-koplugin/" .. PLUGIN_VERSION },
        sink = ltn12.sink.table(chunks),
    }
    if not ok or code ~= 200 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not reach GitHub (HTTP %s).\nCheck your Wi-Fi connection."),
                tostring(code or ok)),
        })
        return
    end

    local body = table.concat(chunks)
    local parsed_ok, data = pcall(rapidjson.decode, body)
    if not parsed_ok or type(data) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Unexpected reply from GitHub.") })
        return
    end

    local latest = tostring(data.tag_name or data.name or ""):gsub("^v", "")
    if latest == "" then
        UIManager:show(InfoMessage:new{ text = _("No releases published yet.") })
        return
    end

    local function parts(v)
        local out = {}
        for n in tostring(v):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local a, b = parts(PLUGIN_VERSION), parts(latest)
    local newer = false
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if y > x then
            newer = true
            break
        elseif y < x then
            newer = false
            break
        end
    end

    if not newer then
        UIManager:show(InfoMessage:new{
            text = string.format(_("You are on the latest version (%s)."), PLUGIN_VERSION),
        })
        return
    end

    -- ButtonDialog expects buttons[row][col].
    UIManager:show(ButtonDialog:new{
        title = string.format(_("Version %s is available (you have %s)."), latest, PLUGIN_VERSION),
        buttons = {
            {{
                text = _("Update now"),
                callback = function()
                    self:_installUpdate(latest, data)
                end,
            }},
            {{
                text = _("Open release page"),
                callback = function()
                    if self.ui and self.ui.openLinkDialog then
                        self.ui:openLinkDialog(string.format(
                            "https://github.com/%s/releases/latest", PLUGIN_REPO))
                    end
                end,
            }},
            {{ text = _("Close"), callback = function() end }},
        },
    })
end

local function pluginDirectory()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return source:match("^(.*)/[^/]+$")
end

function LocalWiki:_installUpdate(version, release)
    local plugin_dir = pluginDirectory()
    local plugins_dir = plugin_dir and plugin_dir:match("^(.*)/[^/]+$")
    if not plugin_dir or not plugins_dir then
        UIManager:show(InfoMessage:new{ text = _("Could not locate the LocalWiki plugin folder.") })
        return
    end

    local asset_url
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == PLUGIN_ARCHIVE then
            asset_url = asset.browser_download_url or asset.url
            break
        end
    end
    if not asset_url then
        UIManager:show(InfoMessage:new{ text = _("The selected release has no plugin archive.") })
        return
    end

    local stamp = tostring(os.time())
    local archive_path = plugins_dir .. "/." .. PLUGIN_ARCHIVE .. "." .. stamp
    local temp_dir = plugins_dir .. "/.localwiki-update-" .. stamp
    local archive_file = io.open(archive_path, "wb")
    if not archive_file then
        UIManager:show(InfoMessage:new{ text = _("Could not create the update download file.") })
        return
    end

    UIManager:show(InfoMessage:new{ text = _("Downloading update…") })
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, socket.http.request{
        url = asset_url,
        headers = { ["User-Agent"] = "localwiki-koplugin/" .. PLUGIN_VERSION },
        sink = socketutil.file_sink(archive_file),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        archive_file:close()
        os.remove(archive_path)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Update download failed (HTTP %s)."), tostring(status or code)),
        })
        return
    end

    local made, make_err = util.makePath(temp_dir)
    if not made then
        os.remove(archive_path)
        UIManager:show(InfoMessage:new{ text = tostring(make_err or _("Could not create an update folder.")) })
        return
    end

    local arc = Archiver.Reader:new()
    local opened = arc:open(archive_path)
    local extracted = opened
    if opened then
        for entry in arc:iterate() do
            local path = entry.path or ""
            if path:sub(1, 1) == "/" or path == ".." or
                path:sub(1, 3) == "../" or path:find("/../", 1, true) or
                path:sub(-3) == "/.." then
                extracted = false
                break
            end
            if not arc:extractToPath(path, temp_dir .. "/" .. path) then
                extracted = false
                break
            end
        end
        extracted = extracted and not arc.err
    end
    arc:close()
    os.remove(archive_path)

    local new_plugin_dir = temp_dir .. "/localwiki.koplugin"
    if not extracted or not lfs.attributes(new_plugin_dir, "mode") then
        ffiUtil.purgeDir(temp_dir)
        UIManager:show(InfoMessage:new{ text = _("Could not unpack the update archive.") })
        return
    end

    self.library:closeAll()
    local backup_dir = plugin_dir .. ".bak-" .. stamp
    if not os.rename(plugin_dir, backup_dir) then
        ffiUtil.purgeDir(temp_dir)
        UIManager:show(InfoMessage:new{ text = _("Could not replace the current plugin folder.") })
        return
    end
    local installed = os.rename(new_plugin_dir, plugin_dir)
    ffiUtil.purgeDir(temp_dir)
    if not installed then
        os.rename(backup_dir, plugin_dir)
        UIManager:show(InfoMessage:new{ text = _("Could not install the downloaded update.") })
        return
    end

    UIManager:askForRestart(string.format(_("LocalWiki %s was installed. Restart KOReader to finish the update."), version))
end

-- List every discovered ZIM with a switch. Disabled archives are skipped by
-- search, lookup and the main page, and their file handles are released.
function LocalWiki:showLoadedZims()
    self:_ensureScanned()
    if #self.library.zims == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No .zim or .zim?? files in:\n%s\n\nDrop your ZIM (or its split parts) into that folder, then re-open this menu."),
                self:_folder()),
        })
        return
    end

    local buttons = {}
    for _idx, e in ipairs(self.library.zims) do
        local on = not self.library:isDisabled(e.base)
        local layout = e.single and _("single file") or string.format(_("%d parts"), #e.paths)
        local meta = ""
        if e.zim then
            meta = string.format(_(" · %d articles, open"), e.zim.article_count)
        end
        local label = string.format("%s %s\n%s%s",
            on and "☑" or "☐", e.base, layout, meta)
        buttons[#buttons + 1] = {{
            text = label,
            callback = function()
                self.library:setDisabled(e.base, on)
                self:_saveDisabledZims()
                UIManager:close(self._zim_dialog)
                self._zim_dialog = nil
                self:showLoadedZims()
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Enable all"),
        enabled = self.library:activeCount() < #self.library.zims,
        callback = function()
            for _i, e in ipairs(self.library.zims) do
                self.library:setDisabled(e.base, false)
            end
            self:_saveDisabledZims()
            UIManager:close(self._zim_dialog)
            self._zim_dialog = nil
            self:showLoadedZims()
        end,
    }, {
        text = _("Close"),
        callback = function()
            UIManager:close(self._zim_dialog)
            self._zim_dialog = nil
        end,
    }}

    self._zim_dialog = ButtonDialog:new{
        title = string.format(_("Loaded ZIMs: %d of %d enabled"),
            self.library:activeCount(), #self.library.zims),
        buttons = buttons,
    }
    UIManager:show(self._zim_dialog)
end

function LocalWiki:chooseFolder()
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

-- Decode HTML entity codes commonly found in article texts, titles, and ZIM extracts
local function decode_html_entities(s)
    if not s or s == "" then return s or "" end
    return s:gsub("&nbsp;", " ")
            :gsub("&#160;", " ")
            :gsub("&quot;", '"')
            :gsub("&apos;", "'")
            :gsub("&#39;", "'")
            :gsub("&#x27;", "'")
            :gsub("&#039;", "'")
            :gsub("&lsquo;", "'")
            :gsub("&rsquo;", "'")
            :gsub("&#8216;", "'")
            :gsub("&#8217;", "'")
            :gsub("&#x2018;", "'")
            :gsub("&#x2019;", "'")
            :gsub("&amp;", "&")
            :gsub("&lt;", "<")
            :gsub("&gt;", ">")
            :gsub("&ndash;", "–")
            :gsub("&mdash;", "—")
            :gsub("&#x2013;", "–")
            :gsub("&#x2014;", "—")
            :gsub("&#x(%x+);", function(h)
                local n = tonumber(h, 16)
                if n == 39 then return "'" end
                if n == 34 then return '"' end
                if n == 38 then return '&' end
                if n and n >= 32 and n <= 126 then return string.char(n) end
            end)
            :gsub("&#(%d+);", function(d)
                local n = tonumber(d)
                if n == 39 then return "'" end
                if n == 34 then return '"' end
                if n == 38 then return '&' end
                if n and n >= 32 and n <= 126 then return string.char(n) end
            end)
end

-- Diacritics folding: converts accented / Turkish / circumflex characters to plain ASCII.
-- Note: \195\162 is UTF-8 lowercase circumflex a, and \195\130 is uppercase circumflex A.
-- Literal circumflex characters are strictly avoided in Lua source code.
local function fold_to_ascii(s)
    if not s or s == "" then return "" end
    return s:gsub("\195\162", "a")
            :gsub("\195\130", "A")
            :gsub("\195\167", "c") -- ç
            :gsub("\195\135", "C") -- Ç
            :gsub("\196\159", "g") -- ğ
            :gsub("\196\158", "G") -- Ğ
            :gsub("\196\177", "i") -- ı
            :gsub("\196\176", "I") -- İ
            :gsub("\195\182", "o") -- ö
            :gsub("\195\150", "O") -- Ö
            :gsub("\197\159", "s") -- ş
            :gsub("\197\158", "S") -- Ş
            :gsub("\195\188", "u") -- ü
            :gsub("\195\156", "U") -- Ü
end

-- Maps standard ASCII letters to common Turkish diacritic equivalents
local function to_turkish_diacritics(s)
    if not s or s == "" then return "" end
    return s:gsub("c", "\195\167")
            :gsub("C", "\195\135")
            :gsub("g", "\196\159")
            :gsub("G", "\196\158")
            :gsub("o", "\195\182")
            :gsub("O", "\195\150")
            :gsub("s", "\197\159")
            :gsub("S", "\197\158")
            :gsub("u", "\195\188")
            :gsub("U", "\195\156")
end

-- Generates circumflex variants for words containing 'a' or 'A' using byte escapes
local function add_circumflex_variants(word, add_fn)
    local indices = {}
    local p = 1
    while true do
        local i = word:find("[aA]", p)
        if not i then break end
        indices[#indices + 1] = i
        p = i + 1
        if #indices >= 3 then break end
    end
    for _, idx in ipairs(indices) do
        local is_upper = word:sub(idx, idx) == "A"
        local rep = is_upper and "\195\130" or "\195\162"
        local v = word:sub(1, idx - 1) .. rep .. word:sub(idx + 1)
        add_fn(v)
    end
    if #indices > 1 then
        local v = word:gsub("a", "\195\162"):gsub("A", "\195\130")
        add_fn(v)
    end
end

-- Generate search candidate URLs supporting Unicode, Turkish characters,
-- circumflex variants (\195\162 / \195\130), multiword phrases, and title-cased variants.
function LocalWiki:_getSearchCandidates(query)
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
        uppers[#uppers + 1] = "\196\176"
    elseif first_char == "\196\176" then -- 'İ'
        uppers[#uppers + 1] = "\196\176"
        uppers[#uppers + 1] = "I"
    elseif first_char == "I" then
        uppers[#uppers + 1] = "I"
        uppers[#uppers + 1] = "\196\176"
    elseif first_char == "\195\167" then -- ç -> Ç
        uppers[#uppers + 1] = "\195\135"
        uppers[#uppers + 1] = "C"
    elseif first_char == "c" or first_char == "C" then
        uppers[#uppers + 1] = "C"
        uppers[#uppers + 1] = "\195\135"
    elseif first_char == "\196\159" then -- ğ -> Ğ
        uppers[#uppers + 1] = "\196\158"
        uppers[#uppers + 1] = "G"
    elseif first_char == "g" or first_char == "G" then
        uppers[#uppers + 1] = "G"
        uppers[#uppers + 1] = "\196\158"
    elseif first_char == "\195\182" then -- ö -> Ö
        uppers[#uppers + 1] = "\195\150"
        uppers[#uppers + 1] = "O"
    elseif first_char == "o" or first_char == "O" then
        uppers[#uppers + 1] = "O"
        uppers[#uppers + 1] = "\195\150"
    elseif first_char == "\197\159" then -- ş -> Ş
        uppers[#uppers + 1] = "\197\158"
        uppers[#uppers + 1] = "S"
    elseif first_char == "s" or first_char == "S" then
        uppers[#uppers + 1] = "S"
        uppers[#uppers + 1] = "\197\158"
    elseif first_char == "\195\188" then -- ü -> Ü
        uppers[#uppers + 1] = "\195\156"
        uppers[#uppers + 1] = "U"
    elseif first_char == "u" or first_char == "U" then
        uppers[#uppers + 1] = "U"
        uppers[#uppers + 1] = "\195\156"
    elseif first_char == "\195\162" then -- circumflex a -> A
        uppers[#uppers + 1] = "\195\130"
        uppers[#uppers + 1] = "A"
    elseif first_char == "\195\130" then -- circumflex A -> A
        uppers[#uppers + 1] = "\195\130"
        uppers[#uppers + 1] = "A"
    elseif first_char == "a" or first_char == "A" then
        uppers[#uppers + 1] = "A"
        uppers[#uppers + 1] = "\195\130"
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
            elseif w_first == "\195\162" or w_first == "\195\130" then w_up = "\195\130"
            elseif #w_first == 1 and w_first >= "a" and w_first <= "z" then
                w_up = w_first:upper()
            end
            words[#words + 1] = w_up .. w_rest
        end
        add(table.concat(words, "_"))

        -- Turkish title-cased candidate if any word starts with special char
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
            elseif w_first == "\195\167" or w_first == "c" then
                w_up = "\195\135"
                has_tr = true
            elseif w_first == "\196\159" or w_first == "g" then
                w_up = "\196\158"
                has_tr = true
            elseif w_first == "\195\182" or w_first == "o" then
                w_up = "\195\150"
                has_tr = true
            elseif w_first == "\197\159" or w_first == "s" then
                w_up = "\197\158"
                has_tr = true
            elseif w_first == "\195\188" or w_first == "u" then
                w_up = "\195\156"
                has_tr = true
            elseif w_first == "\195\162" or w_first == "\195\130" or w_first == "a" then
                w_up = "\195\130"
                has_tr = true
            elseif #w_first == 1 and w_first >= "a" and w_first <= "z" then
                w_up = w_first:upper()
            end
            tr_words[#tr_words + 1] = w_up .. w_rest
        end
        if has_tr then
            add(table.concat(tr_words, "_"))
        end
    end

    -- 3. Diacritics folding: fold any accented/circumflex/Turkish characters to plain ASCII
    local folded = fold_to_ascii(raw_url)
    if folded ~= raw_url then
        local f_first, f_rest = utf8_first_char(folded)
        add(f_first:upper() .. f_rest)
        add(folded)
    end

    -- 4. Diacritics unfolding: generate Turkish diacritics variants
    local tr_converted = to_turkish_diacritics(raw_url)
    if tr_converted ~= raw_url then
        local t_first, t_rest = utf8_first_char(tr_converted)
        local t_up = t_first
        if t_first == "\195\167" then t_up = "\195\135"
        elseif t_first == "\196\159" then t_up = "\196\158"
        elseif t_first == "\195\182" then t_up = "\195\150"
        elseif t_first == "\197\159" then t_up = "\197\158"
        elseif t_first == "\195\188" then t_up = "\195\156"
        elseif #t_first == 1 and t_first >= "a" and t_first <= "z" then t_up = t_first:upper() end
        add(t_up .. t_rest)
    end

    -- 5. Circumflex a (\195\162) variants for words with 'a' or 'A'
    if raw_url:find("[aA]") then
        add_circumflex_variants(raw_url, function(v)
            local v_first, v_rest = utf8_first_char(v)
            local v_up = v_first
            if v_first == "a" or v_first == "A" or v_first == "\195\162" or v_first == "\195\130" then
                v_up = (v_first == "\195\162" or v_first == "\195\130") and "\195\130" or "A"
            elseif #v_first == 1 and v_first >= "a" and v_first <= "z" then
                v_up = v_first:upper()
            end
            add(v_up .. v_rest)
        end)
    end

    -- 6. Raw URL as typed/selected (e.g. for "iPhone", "eBay")
    add(raw_url)

    return candidates
end

local function url_decode(s)
    if not s then return s end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function url_encode(s)
    if not s then return "" end
    return (s:gsub("([^%w_%-%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function LocalWiki:recordSearchHistory(q)
    if not q or q == "" then return end
    q = q:gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return end
    local history = G_reader_settings:readSetting("localwiki_search_history") or {}
    for i = #history, 1, -1 do
        if history[i] == q then
            table.remove(history, i)
        end
    end
    table.insert(history, 1, q)
    while #history > 15 do
        table.remove(history)
    end
    G_reader_settings:saveSetting("localwiki_search_history", history)
end

function LocalWiki:getSearchHistory()
    return G_reader_settings:readSetting("localwiki_search_history") or {}
end

function LocalWiki:showSearchHistoryMenu(parent_dialog)
    local history = self:getSearchHistory()
    if #history == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No recent searches."),
        })
        return
    end

    local items = {}
    for _, q in ipairs(history) do
        local query_text = q
        items[#items + 1] = {
            text = query_text,
            callback = function()
                if parent_dialog then
                    UIManager:close(parent_dialog)
                end
                self.last_search = query_text
                self:runSearch(query_text)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Clear history"),
        separator = true,
        callback = function()
            G_reader_settings:saveSetting("localwiki_search_history", {})
            UIManager:show(InfoMessage:new{
                text = _("Search history cleared."),
            })
        end,
    }

    local menu = Menu:new{
        title = _("Recent searches"),
        item_table = items,
        is_popout = false,
        width = math.min(Device.screen:getWidth() - 40, Device.screen:scaleBySize(450)),
    }
    UIManager:show(menu)
end

function LocalWiki:openSearchDialog(initial_query, custom_title)
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
            { text = _("Recent"),
              callback = function()
                  self:showSearchHistoryMenu(dialog)
              end },
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

function LocalWiki:searchFromSelection(text, boxes, dict_close_callback)
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

function LocalWiki:runSearch(query, boxes, dict_close_callback)
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
    self:recordSearchHistory(query)

    local candidates = self:_getSearchCandidates(query)
    local results = {}
    local seen_keys = {}
    local function attachPopularity(hit)
        if not hit._base then return end
        local z = self.library:open(hit._base)
        local popularity = z and self:_popularity(hit._base, z)
        hit._popularity = popularity and popularity[hit.url] or 0
    end

    -- 1. Prefer exact title matches across all ZIMs (best match first)
    for _, cand in ipairs(candidates) do
        local exact_hits = self.library:findExact("C", cand)
        for _, hit in ipairs(exact_hits) do
            local key = (hit._base or "") .. ":" .. (hit.url or "")
            if not seen_keys[key] then
                seen_keys[key] = true
                attachPopularity(hit)
                results[#results + 1] = hit
            end
        end
    end

    -- 2. Fall back to title-prefix search if no exact match or to supplement results
    local max_results = 60
    local prefix_seen = {}
    for _, cand in ipairs(candidates) do
        if #results >= max_results then break end
        -- In ZIM namespace C, all standard MediaWiki article titles start uppercase.
        -- If an uppercase candidate was already scanned, skip redundant lowercased scan.
        local first_char = utf8_first_char(cand)
        local is_lower = (#first_char == 1 and first_char >= "a" and first_char <= "z")
        local norm_cand = is_lower and (first_char:upper() .. cand:sub(#first_char + 1)) or cand
        if not prefix_seen[norm_cand] then
            prefix_seen[norm_cand] = true
            local prefix_hits = self.library:prefixSearch("C", cand, max_results - #results)
            for _, hit in ipairs(prefix_hits) do
                local key = (hit._base or "") .. ":" .. (hit.url or "")
                if not seen_keys[key] then
                    seen_keys[key] = true
                    attachPopularity(hit)
                    results[#results + 1] = hit
                    if #results >= max_results then break end
                end
            end
        end
    end

    -- 3. Word-index pass: find articles whose title contains the query as a
    -- word anywhere, not just at the start. This is what makes "Snape" reach
    -- "Severus Snape" and "Snape's Portrait". Runs after the prefix pass so
    -- prefix hits keep their place, and only when the query is a single word
    -- (multi-word queries are handled by the prefix pass plus ranking).
    local query_words = {}
    for w in query:lower():gsub("[^%w%s%-']", " "):gmatch("%S+") do
        w = w:gsub("'s$", ""):gsub("'$", "")
        if #w >= 2 then query_words[#query_words + 1] = w end
    end
    local pending_scans = {}
    local scan_zims = {}
    local finishSearch

    local function addTitleHits(base, z, hits)
        local popularity = self:_popularity(base, z)
        local indices = {}
        for _, h in ipairs(hits or {}) do
            if h.idx then indices[#indices + 1] = h.idx end
        end
        for _, found in ipairs(z:entriesForIndices(indices)) do
            local key = base .. ":" .. (found.url or "")
            if not seen_keys[key] then
                seen_keys[key] = true
                found._base = base
                found._popularity = popularity and popularity[found.url] or 0
                results[#results + 1] = found
            end
        end
    end

    if #query_words > 0 then
        for _, e in ipairs(self.library:activeZims()) do
            local z = self.library:open(e.base)
            local word_idx
            if z then
                word_idx = self:_wordIndex(e.base)
            end
            if word_idx and z then
                local hits = word_idx:lookup_all(query_words)
                addTitleHits(e.base, z, hits)
            elseif z and z.article_count <= TITLE_INDEX_MAX_ARTICLES then
                local title_idx = self:_titleIndex(e.base)
                if title_idx then
                    addTitleHits(e.base, z, title_idx:lookup_all(query_words, 60))
                end
            elseif z then
                logger.info(string.format(
                    "localwiki: skipping title search for large archive %s (%d articles)",
                    e.base, z.article_count))
            end
        end
    end

    -- 4. Rank the results. prefixSearch walks the archive in path order, and
    -- in a path an apostrophe (39) sorts before an underscore (95), so
    -- "Frodo's_Song" always came before "Frodo_Baggins" — searching a
    -- character name buried the character under event articles. Order by how
    -- likely a title is to be the thing the reader meant:
    --   0. the query itself as a title
    --   1. a single bare word (character / item / place articles)
    --   2. a short title (two or three words)
    --   3. everything else, shortest first
    -- Ties fall back to alphabetical so the list is stable between searches.
    finishSearch = function()
    local query_key = query:gsub(" ", "_")
    local q_lower = query:lower():gsub(" ", "_")
    -- A prefix hit whose title *is* the query is the same article the exact
    -- pass already put in tier 0; without this it reappeared in tier 1 and
    -- pushed the real character article down ("Charizard" 372 KB landed
    -- below "Ash's_Charizard" 408 KB).
    local function is_exact_title(url)
        return url == query_key or url:lower() == q_lower
    end
    local function rank(entry)
        local url = entry.url or ""
        local lower = url:lower()
        local words = 0
        for _ in url:gmatch("[^_]+") do words = words + 1 end

        -- Does the query match the *last* word of the title? "Snape" ->
        -- "Severus_Snape" is almost certainly the person the reader meant,
        -- while "Snape's_Bias" is a detail article about them.
        local last_word = lower:match("([^_]+)$") or ""
        local suffix_hit = (last_word == q_lower)

        -- Tiers, most relevant first:
        --   0  the title *is* the query
        --   1  a short title (<= 3 words) that contains the query
        --   2  a single-word title
        --   3  everything else
        -- A short title is one tier whether the query sits at the end
        -- ("Severus_Snape") or the start ("Snape_with_Thorp"): both are
        -- about the query, and size decides between them. Splitting them
        -- put a 95 KB article below a 7 KB one purely on word order.
        local tier
        if is_exact_title(url) then
            tier = 0
        elseif words <= 3 then
            tier = 1
        elseif words == 1 then
            tier = 2
        else
            tier = 3
        end

        -- Within a tier: a title that *ends* with the query first (the
        -- person, not the event), then the shorter title. Article size would
        -- be the better key, but measuring it costs a cluster decompression
        -- per result — the reader was OOM-killed doing exactly that on this
        -- device, so title shape carries the ranking instead.
        return tier, (suffix_hit and 0 or 1), -(entry._popularity or 0), #url, url
    end
    table.sort(results, function(a, b)
        local at, as, ap, al, au = rank(a)
        local bt, bs, bp, bl, bu = rank(b)
        if at ~= bt then return at < bt end
        if as ~= bs then return as < bs end
        if ap ~= bp then return ap < bp end
        if al ~= bl then return al < bl end
        return au < bu
    end)

    -- The word-index pass can push the list past the cap; trim after ranking
    -- so the best matches survive rather than whichever were found first.
    for i = #results, max_results + 1, -1 do
        results[i] = nil
    end

    -- 4. If no results found, show empty result in lookup window
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

    if #pending_scans > 0 then
        self:_scanTitleMatchesAsync(pending_scans, function(hits)
            for _, hit in ipairs(hits) do
                local z = scan_zims[hit._base]
                if z then addTitleHits(hit._base, z, { hit }) end
            end
            finishSearch()
        end)
        return
    end

    finishSearch()
end

local function base64_encode(data)
    if not data or data == "" then return "" end
    local ok_sha2, sha2 = pcall(require, "ffi/sha2")
    if ok_sha2 and sha2 and sha2.bin_to_base64 then
        local ok, res = pcall(sha2.bin_to_base64, data)
        if ok and res then return res end
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    local ok_bit, bit = pcall(require, "bit")
    if ok_ffi and ffi and ok_bit and bit then
        local len = #data
        local out_len = math.floor((len + 2) / 3) * 4
        local out = ffi.new("uint8_t[?]", out_len)
        local src = ffi.cast("const uint8_t*", data)
        local b64_table = ffi.new("const uint8_t[65]", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

        local si, di = 0, 0
        local full_chunks = math.floor(len / 3)
        for _ = 1, full_chunks do
            local b0 = src[si]
            local b1 = src[si + 1]
            local b2 = src[si + 2]
            out[di]     = b64_table[bit.rshift(b0, 2)]
            out[di + 1] = b64_table[bit.bor(bit.band(bit.lshift(b0, 4), 0x30), bit.rshift(b1, 4))]
            out[di + 2] = b64_table[bit.bor(bit.band(bit.lshift(b1, 2), 0x3C), bit.rshift(b2, 6))]
            out[di + 3] = b64_table[bit.band(b2, 0x3F)]
            si = si + 3
            di = di + 4
        end

        local remain = len % 3
        if remain == 1 then
            local b0 = src[si]
            out[di]     = b64_table[bit.rshift(b0, 2)]
            out[di + 1] = b64_table[bit.band(bit.lshift(b0, 4), 0x30)]
            out[di + 2] = 61
            out[di + 3] = 61
        elseif remain == 2 then
            local b0 = src[si]
            local b1 = src[si + 1]
            out[di]     = b64_table[bit.rshift(b0, 2)]
            out[di + 1] = b64_table[bit.bor(bit.band(bit.lshift(b0, 4), 0x30), bit.rshift(b1, 4))]
            out[di + 2] = b64_table[bit.band(bit.lshift(b1, 2), 0x3C)]
            out[di + 3] = 61
        end

        return ffi.string(out, out_len)
    end

    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b64chars:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

local function convert_to_png(raw_data)
    if not raw_data or #raw_data == 0 then return nil end
    local max_w = 1264
    local max_h = 1680

    -- Strategy 1: KOReader's RenderImage
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    local bb = nil
    if ok_ri and RenderImage and RenderImage.renderImageData then
        bb = RenderImage:renderImageData(raw_data, #raw_data)
        if bb then
            local bw = bb:getWidth()
            local bh = bb:getHeight()
            if bw > max_w or bh > max_h then
                local scale = math.min(max_w / bw, max_h / bh)
                local target_w = math.max(1, math.floor(bw * scale))
                local target_h = math.max(1, math.floor(bh * scale))
                local scaled_bb = RenderImage:renderImageData(raw_data, #raw_data, false, target_w, target_h)
                if scaled_bb then
                    bb:free()
                    bb = scaled_bb
                end
            end
        end
    end

    -- Strategy 2: Direct ffi/webp if RenderImage didn't handle it
    if not bb and #raw_data >= 12 and raw_data:sub(1, 4) == "RIFF" and raw_data:sub(9, 12) == "WEBP" then
        local ok_webp, WebP = pcall(require, "ffi/webp")
        if ok_webp and WebP and WebP.fromData then
            local ok_open, webp = pcall(WebP.fromData, raw_data, #raw_data)
            if ok_open and webp then
                local ok_frame, webp_bb = pcall(webp.getFrameImage, webp, 1)
                pcall(webp.close, webp)
                if ok_frame and webp_bb then
                    bb = webp_bb
                end
            end
        end
    end

    -- Strategy 3: Direct libwebp FFI binding if available
    if not bb and #raw_data >= 12 and raw_data:sub(1, 4) == "RIFF" and raw_data:sub(9, 12) == "WEBP" then
        local ok_ffi, ffi = pcall(require, "ffi")
        if ok_ffi and ffi then
            pcall(ffi.cdef, [[
                uint8_t* WebPDecodeRGBA(const uint8_t* data, size_t data_size, int* width, int* height);
                void WebPFree(void* ptr);
            ]])
            local ok_lib, libwebp = pcall(ffi.load, "webp")
            if not ok_lib or not libwebp then
                ok_lib, libwebp = pcall(ffi.load, "libwebp")
            end
            if ok_lib and libwebp and libwebp.WebPDecodeRGBA then
                local w = ffi.new("int[1]")
                local h = ffi.new("int[1]")
                local rgba = libwebp.WebPDecodeRGBA(raw_data, #raw_data, w, h)
                if rgba ~= nil then
                    local ok_bb_mod, Blitbuffer = pcall(require, "ffi/blitbuffer")
                    if ok_bb_mod and Blitbuffer then
                        bb = Blitbuffer.new(w[0], h[0], Blitbuffer.TYPE_BBRGB32, rgba)
                    end
                    libwebp.WebPFree(rgba)
                end
            end
        end
    end

    -- Write BlitBuffer to temporary PNG and read back encoded PNG bytes
    if bb then
        local bw = bb:getWidth()
        local bh = bb:getHeight()
        if bw > max_w or bh > max_h then
            local scale = math.min(max_w / bw, max_h / bh)
            local target_w = math.max(1, math.floor(bw * scale))
            local target_h = math.max(1, math.floor(bh * scale))
            local ok_ri2, RenderImage2 = pcall(require, "ui/renderimage")
            if ok_ri2 and RenderImage2 and RenderImage2.scaleBlitBuffer then
                bb = RenderImage2:scaleBlitBuffer(bb, target_w, target_h, true)
            elseif bb.scale then
                local scaled_bb = bb:scale(target_w, target_h)
                if scaled_bb then
                    bb:free()
                    bb = scaled_bb
                end
            end
        end

        local tmp_dir = "/tmp"
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage and DataStorage.getDataDir then
            tmp_dir = DataStorage:getDataDir() .. "/cache"
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if not ok_lfs or not lfs then
                ok_lfs, lfs = pcall(require, "lfs")
            end
            if ok_lfs and lfs and lfs.mkdir then
                pcall(lfs.mkdir, tmp_dir)
            end
        else
            tmp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp" or "."
        end

        local tmp_path = string.format("%s/wzim_%d_%d.png", tmp_dir, os.time(), math.random(1000, 9999))
        local ok_write = pcall(bb.writePNG, bb, tmp_path)
        pcall(bb.free, bb)

        if ok_write then
            local f = io.open(tmp_path, "rb")
            if f then
                local png_bytes = f:read("*all")
                f:close()
                pcall(os.remove, tmp_path)
                if png_bytes and #png_bytes > 0 then
                    return png_bytes
                end
            end
        end
    end

    return nil
end

function LocalWiki:_resolveImageBlob(z, src)
    if not z or not src or src == "" then return nil end
    if src:match("^https?://") or src:match("^data:") then return nil end

    if not z._img_cache then
        z._img_cache = {}
        z._img_cache_keys = {}
    end
    if z._img_cache[src] ~= nil then
        if not z._img_cache[src] then return nil end
        return z._img_cache[src].data, z._img_cache[src].mime
    end

    src = src:gsub("#.*$", ""):gsub("%?.*$", "")
    local clean = src:gsub("^%./", ""):gsub("^%.%./", ""):gsub("^/", "")

    -- Image paths in the ZIM are URL-encoded twice: a file called "+44.jpg"
    -- is stored as "%252B44.jpg". Try the path as written, once decoded and
    -- twice decoded; without the second decode covers and pictures whose name
    -- starts with a punctuation mark never resolve.
    local variants = { clean }
    local once = url_decode(clean)
    if once ~= clean then variants[#variants + 1] = once end
    local twice = url_decode(once)
    if twice ~= once then variants[#variants + 1] = twice end

    local candidates = {}
    local function add(ns, url)
        candidates[#candidates + 1] = { ns = ns, url = url }
    end
    for _, v in ipairs(variants) do
        add("C", v)
        add("-", v)
        add("I", v)
    end

    if clean:match("^I/") then
        local sub = clean:sub(3)
        add("I", sub)
        add("I", url_decode(sub))
    end
    if clean:match("^%-/") then
        local sub = clean:sub(3)
        add("-", sub)
        add("-", url_decode(sub))
    end

    local seen = {}
    for _, c in ipairs(candidates) do
        local key = c.ns .. ":" .. c.url
        if not seen[key] then
            seen[key] = true
            if z._img_cache[key] ~= nil then
                if z._img_cache[key] then
                    z._img_cache[src] = z._img_cache[key]
                    return z._img_cache[key].data, z._img_cache[key].mime
                end
            else
                local entry = z:findExact(c.ns, c.url)
                if entry and entry.kind == "redirect" then
                    entry = z:resolveRedirect(entry)
                end
                if entry and entry.kind == "article" then
                    local data, mime = z:readArticle(entry)
                    if data and #data > 0 then
                        -- MuPDF's HTML engine cannot decode WebP: it aborts the
                        -- whole page render ("failed decoding webp image") and
                        -- KOReader crashes, so WebP is converted to PNG below.
                        local is_native = false
                        if #data >= 12 and data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
                            mime = "image/webp"
                            is_native = false
                        elseif #data >= 4 then
                            local b1, b2, b3, b4 = data:byte(1, 4)
                            if b1 == 0xFF and b2 == 0xD8 then
                                mime = "image/jpeg"
                                is_native = true
                            elseif b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
                                mime = "image/png"
                                is_native = true
                            elseif b1 == 0x47 and b2 == 0x49 and b3 == 0x46 and b4 == 0x38 then
                                mime = "image/gif"
                                is_native = true
                            elseif b1 == 0x42 and b2 == 0x4D then
                                mime = "image/bmp"
                                is_native = true
                            end
                        end

                        -- If format is not natively decoded by MuPDF HTML engine (e.g. SVG, WebP or
                        -- uncompressed BMP), convert it to PNG. Native images (JPEG, PNG, GIF) are
                        -- passed directly to MuPDF.
                        if not is_native then
                            local converted = convert_to_png(data)
                            if converted and #converted > 0 then
                                data = converted
                                mime = "image/png"
                            else
                                if not mime or mime == "application/octet-stream" then
                                    local ext = c.url:match("%.([%a%d]+)$")
                                    if ext then
                                        ext = ext:lower()
                                        if ext == "jpg" or ext == "jpeg" then mime = "image/jpeg"
                                        elseif ext == "png" then mime = "image/png"
                                        elseif ext == "webp" then mime = "image/webp"
                                        elseif ext == "gif" then mime = "image/gif"
                                        elseif ext == "svg" then mime = "image/svg+xml"
                                        end
                                    end
                                end
                            end
                        end

                        local res = { data = data, mime = mime or "image/jpeg" }
                        -- Small cache: the bytes are only needed until the
                        -- picture has been written out as a file, and the
                        -- lookup popup re-reads them from the ZIM if needed.
                        if #z._img_cache_keys >= 4 then
                            local oldest = table.remove(z._img_cache_keys, 1)
                            z._img_cache[oldest] = nil
                        end
                        z._img_cache_keys[#z._img_cache_keys + 1] = key
                        z._img_cache[key] = res
                        z._img_cache[src] = res
                        return res.data, res.mime
                    end
                end
            end
        end
    end
    z._img_cache[src] = false
    return nil
end

function LocalWiki:_getLeadImageForArticle(z, article_url)
    if not z or not article_url or article_url == "" then return nil end
    if not z._lead_images then
        z._lead_images = {}
        local main_entry = z:getMainPageEntry()
        if main_entry then
            local main_html = z:readArticle(main_entry)
            if main_html then
                for href, src, cap in main_html:gmatch('<a%s+class="item"%s+href="([^"]+)">%s*<figure><img[^>]+src="([^"]+)">%s*<figcaption>([^<]*)</figcaption>') do
                    local clean_href = url_decode(href)
                    z._lead_images[href] = { src = src, caption = cap }
                    z._lead_images[clean_href] = { src = src, caption = cap }
                end
            end
        end
    end
    local item = z._lead_images[article_url] or z._lead_images[url_decode(article_url)]
    if item then
        return item.src, item.caption
    end
    return nil
end

function LocalWiki:_resolveImageFile(z, src)
    if not z or not src or src == "" then return nil end
    if src:match("^https?://") or src:match("^data:") then return nil end

    if not z._img_file_cache then z._img_file_cache = {} end
    if z._img_file_cache[src] ~= nil then
        return z._img_file_cache[src] or nil
    end

    local data, mime = self:_resolveImageBlob(z, src)
    if not data or #data == 0 then
        z._img_file_cache[src] = false
        return nil
    end

    local filename = safe_image_filename(src, mime)
    local img_dir = getTempImageDir()
    local filepath = img_dir .. "/" .. filename

    if not self._extracted_img_files then self._extracted_img_files = {} end
    if not self._extracted_img_files[filename] then
        local exists_file = io.open(filepath, "rb")
        if exists_file then
            exists_file:close()
        else
            local f = io.open(filepath, "wb")
            if f then
                f:write(data)
                f:close()
            end
        end
        self._extracted_img_files[filename] = true
    end

    z._img_file_cache[src] = filename
    return filename
end

local function is_decorative_icon(src)
    if not src then return true end
    -- Only the file name is inspected: the directory part ("_assets_/<hash>/")
    -- is random hex and would otherwise match by accident.
    local s = (src:match("([^/]+)$") or src):lower()
    return s:find("flag") or s:find("icon") or s:find("pog") or s:find("arrow")
        or s:find("symbol") or s:find("lock") or s:find("increase") or s:find("decrease")
        or s:find("bullet") or s:find("portal") or s:find("edit") or s:find("magnify")
end

-- Removes every <div …>…</div> block whose opening tag matches
-- `open_pattern`, counting nested <div>s so the matching closing tag is the
-- one that gets cut.
local function strip_div_blocks(html, open_pattern)
    local out = {}
    local pos = 1
    while true do
        local s, e = html:find(open_pattern, pos)
        if not s then break end
        out[#out + 1] = html:sub(pos, s - 1)
        local depth, i = 1, e + 1
        while depth > 0 do
            local ns = html:find("<div", i, true)
            local ne = html:find("</div>", i, true)
            if not ne then i = #html + 1; break end
            if ns and ns < ne then
                depth, i = depth + 1, ns + 4
            else
                depth, i = depth - 1, ne + 6
            end
        end
        pos = i
    end
    out[#out + 1] = html:sub(pos)
    return table.concat(out)
end

function LocalWiki:_embedImagesInHtml(z, html, article_url)
    if not html or html == "" then return html end

    local BLANK_GIF = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    local max_images = self:_imageLimit()
    if max_images == 0 then
        -- Images off: drop the pictures *and* the text that describes them.
        -- Blanking only the source leaves the <img> width/height attributes in
        -- place (a hole in the text) and keeps the caption (a stray sentence),
        -- so the whole block goes: figure, legacy thumb, and the image row
        -- normalize_infobox() builds for the infobox.
        if not html:find("<img", 1, true) and not html:find("<figure", 1, true) then
            return html
        end
        local r = html
        r = r:gsub("<figure[^>]*>.-</figure>", "")
        r = strip_div_blocks(r, '<div[^>]-class="[^"]-thumb[^"]-"')
        r = r:gsub('<tr><td colspan="2" class="wz%-ib%-images">.-</td></tr>', "")
        r = r:gsub("<img[^>]*>", "")
        return r
    end

    -- Cap the pictures embedded into one article. Each decoded bitmap is a
    -- full-size RGB buffer and a Fandom page can carry a thousand <img> tags,
    -- so an explicit cap avoids pushing a 512 MB Kindle into the OOM killer.
    -- A negative limit means unlimited images.
    local count = 0

    local replaced_html = html
    local has_img = html:find("<img", 1, true)

    if has_img then
        local dq = string.char(34)
        local sq = string.char(39)

        local function replace_and_wrap(tag_start, src, tag_end)
            if is_decorative_icon(src) or (max_images > 0 and count >= max_images) then
                return tag_start .. BLANK_GIF .. tag_end
            end
            local filename = self:_resolveImageFile(z, src)
            if filename then
                count = count + 1
                local img_tag = tag_start .. filename .. tag_end
                return '<a href="zim-img-zoom:' .. filename .. '" class="zim-img-zoom">' .. img_tag .. '</a>'
            end
            return tag_start .. BLANK_GIF .. tag_end
        end

        replaced_html = replaced_html:gsub("(<img%s+[^>]-src=" .. dq .. ")([^" .. dq .. "]+)(" .. dq .. "[^>]*>)", replace_and_wrap)
        replaced_html = replaced_html:gsub("(<img%s+[^>]-src=" .. sq .. ")([^" .. sq .. "]+)(" .. sq .. "[^>]*>)", replace_and_wrap)
    end

    if count == 0 and article_url and z then
        local lead_src, caption = self:_getLeadImageForArticle(z, article_url)
        if lead_src then
            local filename = self:_resolveImageFile(z, lead_src)
            if filename then
                local enc_cap = (caption and caption ~= "") and ("|" .. url_encode(caption)) or ""
                local fig = string.format(
                    '<figure class="mw-halign-center"><a href="zim-img-zoom:%s%s" class="zim-img-zoom"><img src="%s"></a><figcaption>%s</figcaption></figure>',
                    filename, enc_cap, filename, caption or ""
                )
                local p_start = replaced_html:find("<p[%s>]")
                if p_start then
                    replaced_html = replaced_html:sub(1, p_start - 1) .. fig .. replaced_html:sub(p_start)
                else
                    replaced_html = fig .. replaced_html
                end
                count = count + 1
            end
        end
    end

    -- Extract caption for figures and thumbs so ImageViewer can display it as subtitle
    if count > 0 then
        if replaced_html:find("<figcaption", 1, true) then
            replaced_html = replaced_html:gsub("(<figure[^>]*>)(.-)(</figure>)", function(p1, content, p2)
                local cap = content:match("<figcaption[^>]*>(.-)</figcaption>")
                if cap then
                    local clean_cap = cap:gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if clean_cap ~= "" then
                        local enc_cap = url_encode(clean_cap)
                        content = content:gsub('(href="zim%-img%-zoom:[^"|]+)', function(m) return m .. "|" .. enc_cap end)
                    end
                end
                return p1 .. content .. p2
            end)
        end
        if replaced_html:find("thumbcaption", 1, true) then
            replaced_html = replaced_html:gsub('(<div[^>]-class="[^"]-thumb[^"]-"[^>]*>)(.-)(</div>)', function(p1, content, p2)
                local cap = content:match('<div[^>]-class="[^"]-thumbcaption[^"]-"[^>]*>(.-)</div>')
                if cap then
                    local clean_cap = cap:gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
                    if clean_cap ~= "" then
                        local enc_cap = url_encode(clean_cap)
                        content = content:gsub('(href="zim%-img%-zoom:[^"|]+)', function(m) return m .. "|" .. enc_cap end)
                    end
                end
                return p1 .. content .. p2
            end)
        end
    end

    return replaced_html
end

function LocalWiki:_findLeadImageSrc(html, article_url, z)
    if not html or html == "" then return nil end

    -- (1) Check infobox table
    local infobox = html:match('<table[^>]-class="[^"]-infobox[^"]-"[^>]*>(.-)</table>')
    if infobox then
        local src = infobox:match('<img%s+[^>]-src="([^"]+)"') or infobox:match("<img%s+[^>]-src='([^']+)'")
        if src then
            local cap = infobox:match('<[^>]-class="[^"]-infobox%-caption[^"]-"[^>]*>(.-)</[^>]+>')
            if cap then
                cap = cap:gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            end
            return src, cap
        end
    end

    -- (2) Check lead section before first heading
    local lead = html
    local h2 = lead:find("<h2[%s>]")
    if not h2 then h2 = lead:find('<div%s+[^>]*class="[^"]*mw%-heading2') end
    if not h2 then h2 = lead:find('<section%s+[^>]*data%-mw%-section%-id="[1-9]') end
    if h2 then lead = lead:sub(1, h2) end

    -- Check figure before h2
    local fig_src, fig_cap = lead:match('<figure[^>]*>.-<img%s+[^>]-src="([^"]+)".-<figcaption[^>]*>(.-)</figcaption>.-</figure>')
    if not fig_src then
        fig_src, fig_cap = lead:match("<figure[^>]*>.-<img%s+[^>]-src='([^']+)'.-<figcaption[^>]*>(.-)</figcaption>.-</figure>")
    end
    if fig_src then
        if fig_cap then
            fig_cap = fig_cap:gsub("<[^>]+>", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
        return fig_src, fig_cap
    end

    -- Check simple img in figure
    local fig_simple = lead:match('<figure[^>]*>.-<img%s+[^>]-src="([^"]+)"') or lead:match("<figure[^>]*>.-<img%s+[^>]-src='([^']+)'")
    if fig_simple then
        return fig_simple, nil
    end

    -- Check any img tag in lead
    local lead_img = lead:match('<img%s+[^>]-src="([^"]+)"') or lead:match("<img%s+[^>]-src='([^']+)'")
    if lead_img then
        return lead_img, nil
    end

    -- (3) Check main page lead images index
    if z and article_url then
        local lead_src, cap = self:_getLeadImageForArticle(z, article_url)
        if lead_src then
            return lead_src, cap
        end
    end

    return nil
end

function LocalWiki:_getLeadImageBlitBuffer(z, raw_html, cleaned_html, article_url)
    if not z then return nil end
    -- Deliberately not tied to the article image limit: the lookup popup is a
    -- single small picture that helps identify the article, and it stays either way.

    local src, caption = self:_findLeadImageSrc(raw_html, article_url, z)
    if not src and cleaned_html then
        src, caption = self:_findLeadImageSrc(cleaned_html, article_url, z)
    end
    if not src then return nil end

    local data, mime = self:_resolveImageBlob(z, src)
    if not data or #data == 0 then return nil end

    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage or not RenderImage.renderImageData then
        return nil
    end

    -- Target dimensions for the dictionary popup lead image:
    -- On Kindle/e-ink, definition_height in DictQuickLookup is ~0.35 * screen height (~560px on PW5).
    -- TextBoxWidget strictly caps image height to math.floor(self.height / 2) (~280px on PW5).
    -- If image height exceeds this, TextBoxWidget modifies image.height without resizing image.bb,
    -- which causes text to overlap the unscaled bottom of image.bb and right clipping.
    -- Therefore, max_h must be safely below 0.16 * screen height (scaleBySize(135) ≈ 242px).
    -- Similarly, max_w is bounded to scaleBySize(130) ≈ 233px.
    local max_w = 150
    local max_h = 150
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.screen and Device.screen.scaleBySize then
        max_w = Device.screen:scaleBySize(130)
        max_h = Device.screen:scaleBySize(135)
    end

    -- Render at the image's own aspect ratio, scaled down to fit the box.
    -- Passing both max_w and max_h to the renderer asks MuPDF to fill that
    -- exact box, which stretches the picture. Ask for the native size first
    -- and only scale down (never up) if it does not fit.
    local bb = RenderImage:renderImageData(data, #data, false)
    if not bb then return nil end

    local bw = bb:getWidth()
    local bh = bb:getHeight()
    if bw > max_w or bh > max_h then
        local scale = math.min(max_w / bw, max_h / bh)
        local target_w = math.max(1, math.floor(bw * scale))
        local target_h = math.max(1, math.floor(bh * scale))
        local scaled = (RenderImage.scaleBlitBuffer and RenderImage:scaleBlitBuffer(bb, target_w, target_h, true))
            or RenderImage:renderImageData(data, #data, false, target_w, target_h)
        if scaled then
            if scaled ~= bb then bb:free() end
            bb = scaled
            bw = bb:getWidth()
            bh = bb:getHeight()
        end
    end

    local image_item = {
        width = bw,
        height = bh,
        caption = caption,
        bb = bb,
        _raw_data = data,
    }

    -- TextBoxWidget keeps the aspect ratio when it shrinks the image to fit
    -- the text column, but it blits the full BlitBuffer into a box of
    -- image.width x image.height. If the buffer is larger than the reported
    -- size the picture is drawn stretched/cropped, so the buffer must match
    -- the reported dimensions exactly.
    image_item.load_bb_func = function(highres)
        if highres then
            if not image_item.hi_bb then
                image_item.hi_bb = RenderImage:renderImageData(data, #data, true)
            end
            return image_item.hi_bb
        end
        return image_item.bb
    end

    return { image_item }
end

-- End of the article lead: the first real section heading.
--
-- Portable infoboxes (Fandom) put their own <h2 class="pi-title"> inside the
-- <aside class="portable-infobox">. Cutting the document at the first <h2>
-- therefore cut it inside the box, and the popup showed nothing but the
-- article title. Skip the box first, then look for the heading.
local function find_lead_end(html)
    local box_start = html:find("<aside[^>]-portable%-infobox")
    if box_start then
        local box_end = html:find("</aside>", box_start, true)
        if box_end then
            local h2 = html:find("<h2[%s>]", box_end + 8)
            if h2 then return h2 end
            local heading = html:find('<div%s+[^>]*class="[^"]*mw%-heading2', box_end + 8)
            if heading then return heading end
            return html:find('<section%s+[^>]*data%-mw%-section%-id="[1-9]', box_end + 8)
        end
    end
    return html:find("<h2[%s>]")
        or html:find('<div%s+[^>]*class="[^"]*mw%-heading2')
        or html:find('<section%s+[^>]*data%-mw%-section%-id="[1-9]')
end

function LocalWiki:_extractIntroText(cleaned_html, raw_html, stop_at_heading, max_chars, max_paras)
    local html = cleaned_html or raw_html or ""
    if html == "" then return "" end
    max_chars = max_chars or 1800
    max_paras = max_paras or 4

    -- Find boundary of intro before first major section heading
    local lead = html
    if stop_at_heading ~= false then
        local h2 = lead:find("<h2[%s>]")
        if not h2 then
            h2 = lead:find('<div%s+[^>]*class="[^"]*mw%-heading2')
        end
        if not h2 then
            h2 = lead:find('<section%s+[^>]*data%-mw%-section%-id="[1-9]')
        end
        if h2 then
            lead = lead:sub(1, h2 - 1)
        end
    end

    -- Strip tables and figures from lead
    lead = lead:gsub("<table.-</table>", "")
    lead = lead:gsub("<figure.-</figure>", "")
    lead = lead:gsub('<div%s+[^>]-class="[^"]-infobox[^"]-"[^>]*>.-</div>', "")
    lead = lead:gsub('<div%s+[^>]-class="[^"]-thumb[^"]-"[^>]*>.-</div>', "")

    local paras = {}
    local used = 0
    for p in lead:gmatch("<p[^>]*>(.-)</p>") do
        local text = p:gsub("<[^>]+>", "")
        -- Strip any residual opening tag attributes or unclosed brackets
        text = text:gsub("^[^<]*>", "")
        -- Decode entities
        text = decode_html_entities(text)
        -- Remove citations/footnotes [1], [2], [citation needed]
        text = text:gsub("%[%s*%d+%s*%]", "")
        text = text:gsub("%[%s*%a%s*%]", "")
        text = text:gsub("%[%s*citation needed%s*%]", "")
        -- Normalize spaces
        text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #text > 20 then
            paras[#paras + 1] = text
            used = used + #text
            -- A popup is a preview, not the article: stop after a few
            -- paragraphs instead of dumping every section we walked through.
            if used >= max_chars or #paras >= max_paras then break end
        end
    end

    if #paras == 0 then
        local plain = lead:gsub("<[^>]+>", " ")
        plain = decode_html_entities(plain)
        plain = plain:gsub("%s+", " ")
                     :gsub("^%s+", "")
                     :gsub("%s+$", "")
        if #plain > 0 then
            paras[#paras + 1] = plain:sub(1, 1500)
        end
    end

    local intro = table.concat(paras, "\n\n")
    intro = decode_html_entities(intro)
    if intro == "" then
        intro = _("No introduction.")
    end

    local full_len = raw_html and #raw_html or (cleaned_html and #cleaned_html or 0)
    if full_len > 0 then
        local size_kb = math.ceil(full_len / 1024)
        intro = intro .. "\n\n" .. string.format(_("(full article : %d kB)"), size_kb)
    end

    return intro
end

function LocalWiki:_loadArticleIntro(entry)
    local base = entry._base or (self.library:activeZims()[1] or {}).base
    if not base then
        return _("Article not found."), nil
    end
    local z, err = self.library:open(base)
    if not z then
        return tostring(err or _("Failed to open ZIM.")), nil
    end
    local resolved = z:resolveRedirect(entry)
    if not resolved or resolved.kind ~= "article" then
        return _("Article not found."), nil
    end
    local ok, html_or_err, mime = pcall(function() return z:readArticle(resolved) end)
    if not ok or not html_or_err then
        return tostring(html_or_err or _("Failed to read article.")), nil
    end
    if not mime or not mime:match("^text/html") then
        return _("Article is not HTML."), nil
    end
    resolved._base = base
    if self.library then
        self.library.active_base = base
    end
    local raw_html = html_or_err

    -- Optimize dictionary popup intro extraction:
    -- Find the lead boundary before first real section heading and clean ONLY
    -- the lead section rather than parsing and regexing the whole article.
    -- find_lead_end() skips the <h2> rows of a portable infobox, which would
    -- otherwise cut the document inside the box.
    local lead_end = find_lead_end(raw_html)
    local lead_raw = lead_end and raw_html:sub(1, lead_end - 1) or raw_html:sub(1, 100000)

    local cleaned_lead = HtmlClean.clean(lead_raw)
    if not cleaned_lead or cleaned_lead == "" then
        cleaned_lead = lead_raw
    end

    local intro = decode_html_entities(self:_extractIntroText(cleaned_lead, raw_html))

    -- Wiki pages built from infobox templates (Fandom) often have a one-line
    -- lead before the first heading, so the popup showed nothing but the
    -- title. Walk past the headings and take the next paragraphs too, up to
    -- the same budget, instead of leaving the description empty.
    if #intro < 400 and #raw_html > #lead_raw then
        local wider = raw_html:sub(1, math.min(#raw_html, 150 * 1024))
        local cleaned_wide = HtmlClean.clean(wider)
        local wider_intro = decode_html_entities(
            self:_extractIntroText(cleaned_wide, raw_html, false))
        if #wider_intro > #intro then
            intro = wider_intro
        end
    end

    local images = self:_getLeadImageBlitBuffer(z, raw_html, cleaned_lead, resolved.url or entry.url)

    return intro, images, resolved
end

local DEFAULT_WIKI_CSS = [[
    header.mw-body-header, .vector-page-titlebar { margin: 0.2em 0 0.6em; }
    h1.firstHeading, .mw-first-heading {
        font-size: 1.45em; font-weight: normal; margin: 0.2em 0 0.15em;
        padding-bottom: 0.2em; border-bottom: 1px solid #a2a9b1; color: #000;
    }
    .siteSub { font-size: 0.8em; color: #54595d; margin: 0 0 0.5em; font-style: italic; }
    table.infobox {
        border: 1px solid #a2a9b1 !important; border-spacing: 0 !important; border-collapse: collapse !important;
        background-color: #f8f9fa !important; color: #202122 !important; margin: 0.8em auto 1.0em auto !important;
        float: none !important; clear: both !important; width: 96% !important; max-width: 96% !important; font-size: 88%; line-height: 1.35;
        box-sizing: border-box !important; border-radius: 4px;
    }
    table.infobox th, table.infobox td {
        vertical-align: top; padding: 0.3em 0.4em; border: 1px solid #eaecf0; word-break: break-word;
    }
    table.infobox th { background-color: #f0f2f5; font-weight: bold; width: 35%; }
    table.infobox td { width: 65%; }
    table.infobox caption { font-weight: bold; font-size: 105%; padding: 0.3em; text-align: center; }
    table.wikitable {
        background-color: #f8f9fa; color: #202122; margin: 0.8em auto !important;
        border: 1px solid #a2a9b1; border-collapse: collapse; font-size: 88%;
        width: 98% !important; max-width: 100% !important; float: none !important; clear: both !important; word-break: break-word;
    }
    table.wikitable > tr > th, table.wikitable > * > tr > th {
        background-color: #eaecf0; font-weight: bold; border: 1px solid #a2a9b1; padding: 0.3em 0.4em;
    }
    table.wikitable > tr > td, table.wikitable > * > tr > td {
        border: 1px solid #a2a9b1; padding: 0.3em 0.4em; background-color: #ffffff;
    }
    table.sidebar { float: none !important; clear: both !important; margin: 0.8em auto !important; background: #f8f9fa; border: 1px solid #a2a9b1; padding: 0.3em; width: 96% !important; max-width: 96% !important; border-radius: 4px; }
    .hatnote { font-style: italic; padding: 0.25em 0.5em; margin: 0.3em 0 0.6em; background-color: #fdfdfd; border-left: 3px solid #c8ccd1; font-size: 92%; }
    ol.references { font-size: 85%; margin-left: 1.5em; }

    figure, .thumb, .thumbinner, .pi-image {
        margin: 0.8em auto !important;
        padding: 0 !important;
        border: none !important;
        background: transparent !important;
        max-width: 100% !important;
        width: auto !important;
        text-align: center !important;
        display: block !important;
        float: none !important;
        clear: both !important;
        box-sizing: border-box;
    }
    figure.mw-halign-left, .tleft,
    figure.mw-halign-right, .tright,
    figure.mw-halign-center, .tcenter, .tnone {
        float: none !important;
        clear: both !important;
        margin: 0.8em auto !important;
        text-align: center !important;
    }
    img {
        max-width: 100% !important;
        height: auto !important;
        display: inline-block !important;
        vertical-align: middle !important;
        margin: 0.4em auto !important;
        border: none !important;
    }
    figure img, .thumb img, .thumbinner img, .pi-image img, figure > a > img, a.zim-img-zoom img {
        max-width: 100% !important;
        height: auto !important;
        display: inline-block !important;
        vertical-align: middle !important;
        margin: 0 auto !important;
        border: none !important;
    }
    a.zim-img-zoom {
        text-decoration: none !important;
        border: none !important;
        display: inline-block !important;
        vertical-align: middle !important;
        margin: 0 auto !important;
        padding: 0 !important;
        background: transparent !important;
    }
    a.zim-img-zoom:link, a.zim-img-zoom:visited {
        text-decoration: none !important;
        border: none !important;
        color: inherit !important;
    }
    figure a.zim-img-zoom, .thumb a.zim-img-zoom, .pi-image a.zim-img-zoom {
        display: inline-block !important;
        margin: 0 auto !important;
        text-align: center !important;
    }
    figcaption, .thumbcaption {
        font-size: 0.85em;
        line-height: 1.3;
        padding: 6px 8px 2px;
        text-align: center;
        color: #444;
        display: block;
        margin: 0 auto;
    }

    /* Fandom portable-infobox */
    aside.portable-infobox {
        display: block !important;
        margin: 0.8em auto !important;
        padding: 0.5em 0.8em !important;
        border: 1px solid #c8ccd1 !important;
        background-color: #f8f9fa !important;
        max-width: 95% !important;
        box-sizing: border-box;
        border-radius: 4px;
        float: none !important;
        clear: both !important;
    }
    aside.portable-infobox figure,
    aside.portable-infobox .pi-image {
        margin: 0.4em auto !important;
        text-align: center !important;
        display: block !important;
        border: none !important;
        background: transparent !important;
    }
    aside.portable-infobox figure a.zim-img-zoom,
    aside.portable-infobox .pi-image a.zim-img-zoom {
        margin: 0 auto !important;
        text-align: center !important;
        display: inline-block !important;
        border: none !important;
        background: transparent !important;
    }
    aside.portable-infobox figure img,
    aside.portable-infobox .pi-image img,
    aside.portable-infobox figure a.zim-img-zoom img,
    aside.portable-infobox .pi-image a.zim-img-zoom img {
        display: inline-block !important;
        vertical-align: middle !important;
        margin: 0 auto !important;
        max-width: 100% !important;
        height: auto !important;
    }
    aside.portable-infobox .pi-title {
        font-size: 1.15em !important;
        font-weight: bold !important;
        text-align: center !important;
        margin: 0.2em 0 0.4em !important;
        border-bottom: 1px solid #ccc !important;
        padding-bottom: 0.2em !important;
        display: block !important;
    }
    aside.portable-infobox .pi-header {
        font-size: 1.0em !important;
        font-weight: bold !important;
        text-align: left !important;
        background-color: #e2e5e8 !important;
        padding: 0.25em 0.5em !important;
        margin: 0.6em 0 0.3em !important;
        border-radius: 2px;
        display: block !important;
    }
    aside.portable-infobox .pi-data {
        margin: 0.3em 0 !important;
        text-align: left !important;
        font-size: 0.92em !important;
        line-height: 1.35 !important;
        display: block !important;
    }
    aside.portable-infobox .pi-data-label {
        font-weight: bold !important;
        font-size: 0.95em !important;
        display: inline !important;
        text-align: left !important;
        margin: 0 !important;
        padding: 0 !important;
    }
    aside.portable-infobox .pi-data-label::after {
        content: ": ";
    }
    aside.portable-infobox .pi-data-value {
        display: inline !important;
        margin-left: 0.2em !important;
        text-align: left !important;
    }
    aside.portable-infobox section.pi-group {
        display: block !important;
        margin: 0.4em 0 !important;
        padding: 0 !important;
        border: none !important;
        text-align: left !important;
    }
    .mwe-math-fallback-image-inline {
        display: inline-block;
        vertical-align: middle;
        margin: 0 0.1em;
    }
    figure:empty {
        display: none !important;
    }
]]

function LocalWiki:showInLookupWindow(results, query, boxes, dict_close_callback)
    if not ok_dict or not DictQuickLookup then
        self:showResultsMenu(results, query)
        return
    end

    local multi = self.library:isMultiZim()
    local dict_results = {}
    local seen_targets = {}

    for _i, entry in ipairs(results) do
        local base = entry._base or (self.library:activeZims()[1] or {}).base
        local target_key = (base or "") .. ":" .. (entry.url or "")
        if not seen_targets[target_key] then
            seen_targets[target_key] = true

            local title = (entry.title and entry.title ~= "") and entry.title or (entry.url and entry.url:gsub("_", " ")) or query
            title = decode_html_entities(title:gsub("_", " "))

            local dict_name = _("Wikipedia (offline)")
            if multi then
                local short = (base or ""):match("^([^_%.]+)") or base or ""
                dict_name = string.format(_("Wikipedia (%s)"), short:sub(1, 10))
            end

            local item = {
                dict = dict_name,
                word = title,
                is_html = false,
                is_wiki = true,
                is_wiki_fullpage = false,
                zim_entry = entry,
                css = DEFAULT_WIKI_CSS,
            }

            if entry.definition then
                item.definition = decode_html_entities(entry.definition)
                item.images = entry.images
            elseif #dict_results == 0 then
                -- Preload intro extract and lead image for first (best match) result immediately
                local intro, images, resolved = self:_loadArticleIntro(entry)
                item.definition = intro
                item.images = images
                if resolved then item.zim_entry = resolved end
            else
                -- Lazy load intro extract and lead image for other matching articles on demand
                setmetatable(item, {
                    __index = function(t, k)
                        if k == "definition" then
                            local intro, images, resolved = self:_loadArticleIntro(entry)
                            rawset(t, "definition", intro or "")
                            rawset(t, "images", images)
                            if resolved then rawset(t, "zim_entry", resolved) end
                            return rawget(t, "definition")
                        elseif k == "images" then
                            -- Only return already-loaded images; do NOT trigger heavy article loading during image cleanup on window close
                            return rawget(t, "images")
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
            is_wiki_fullpage = false,
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

    -- Tapping the "Full article" button opens the complete article in Viewer
    lookup_window.lookupWikipedia = function(lookup_self, get_fullpage, word, is_sane, lang, close_cb)
        local cur_item = lookup_self.results and lookup_self.results[lookup_self.dict_index]
        local entry = cur_item and cur_item.zim_entry
        if entry then
            lookup_self:onClose(true)
            self:openEntry(entry, true)
            return
        end
        if word and word ~= "" then
            lookup_self:onClose(true)
            self:searchFromSelection(word, lookup_self.word_boxes)
        end
    end

    self.lookup_window = lookup_window
    UIManager:show(lookup_window)
end

function LocalWiki:onHtmlDictionaryLinkTapped(dictionary, link)
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

function LocalWiki:showResultsMenu(results, query)
    local multi = self.library:isMultiZim()
    local menu_items = {}
    for _i, entry in ipairs(results) do
        local title = entry.title ~= "" and entry.title or entry.url
        title = decode_html_entities(title:gsub("_", " "))
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

-- Open the main page of one ZIM. With several archives enabled there is no
-- single "the" home page, so the reader picks which one; with exactly one
-- enabled archive this goes straight there.
function LocalWiki:openMainPage(base)
    if not self:_ensureScanned() then return end
    local active = self.library:activeZims()
    if #active == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Every ZIM is switched off. Enable one under \"Loaded ZIMs\"."),
        })
        return
    end
    if not base then
        if #active == 1 then
            base = active[1].base
        else
            -- ButtonDialog wants one row per entry: {{ {text=…}, {text=…} }}
            -- (it lays out up to two buttons per row). Passing a flat list of
            -- single-button tables leaves it with nothing to draw.
            local buttons = {}
            for _i, e in ipairs(active) do
                local label = e.base
                if self.library.active_base == e.base then
                    label = "● " .. label
                end
                buttons[#buttons + 1] = {
                    { text = label, callback = function() self:openMainPage(e.base) end },
                }
            end
            UIManager:show(ButtonDialog:new{
                title = _("Open main page of…"),
                buttons = buttons,
            })
            return
        end
    end
    local z, err = self.library:open(base)
    if not z then
        UIManager:show(InfoMessage:new{ text = tostring(err) })
        return
    end
    local entry = z:getMainPageEntry()
    if not entry then
        UIManager:show(InfoMessage:new{
            text = string.format(_("%s has no main page."), base),
        })
        return
    end
    entry._base = base
    self.history = {}
    self:openEntry(entry, false)
end

function LocalWiki:openEntry(entry, push_history)
    -- The article leaving the screen frees its images before the next one
    -- extracts its own; doing it later would wipe the new article's pictures.
    self:_dropArticleImages()
    local base = entry._base
    if not base then
        -- Shouldn't happen, but fall back to first ZIM
        base = (self.library:activeZims()[1] or {}).base
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
    resolved._base = base
    if self.library then
        self.library.active_base = base
    end

    if push_history and self.current_entry then
        self.history[#self.history + 1] = self.current_entry
    end
    self.current_entry = resolved
    self.current_title = resolved.title ~= "" and resolved.title or resolved.url
    self.current_title = decode_html_entities(self.current_title:gsub("_", " "))

    local cache_key = (base or "") .. ":" .. (resolved.url or entry.url or "")
    if not self._article_lru then
        self._article_lru = {}
        self._article_lru_keys = {}
    end
    local cached = self._article_lru[cache_key]
    if cached then
        self.current_html = cached.html
        self.current_title = cached.title or self.current_title
        self:_showViewer()
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

    local t0 = os.clock()
    local cleaned = HtmlClean.clean(html, true, self.current_title, {
        keep_references = G_reader_settings:isTrue("localwiki_show_references"),
    })
    if not cleaned or cleaned == "" then
        cleaned = html
    end
    self.current_html = self:_embedImagesInHtml(z, cleaned, resolved.url or entry.url)
    logger.info(string.format("localwiki: cleaned %s in %.2f s (%d -> %d bytes)",
        self.current_title, os.clock() - t0, #html, #self.current_html))

    -- Keep only the article currently on screen. Each entry is a full cleaned
    -- HTML document (up to ~350 KB for a long article) and on a 512 MB device
    -- that competes with the MuPDF layout of the article actually on screen.
    -- Back re-reads from the ZIM instead, which costs a few milliseconds.
    for i = 1, #self._article_lru_keys do
        self._article_lru[self._article_lru_keys[i]] = nil
    end
    self._article_lru_keys = {}
    self._article_lru_keys[#self._article_lru_keys + 1] = cache_key
    self._article_lru[cache_key] = {
        html = self.current_html,
        title = self.current_title,
    }

    self:_showViewer()
end

function LocalWiki:_applySettings(sz, face, spc, margin)
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

-- Free the decoded image blobs and the extracted files of the article that is
-- leaving the screen. A Fandom page carries hundreds of <img> tags and their
-- decoded bitmaps are the heaviest thing the plugin keeps in memory.
function LocalWiki:_dropArticleImages()
    if self._extracted_img_files then
        local dir = getTempImageDir()
        for filename in pairs(self._extracted_img_files) do
            pcall(os.remove, dir .. "/" .. filename)
        end
        self._extracted_img_files = nil
    end
    -- The viewer still holds the previous document; drop the decoded blobs so
    -- the GC can take them back before the next article allocates its own.
    if self.library then
        for _i, e in ipairs(self.library.zims) do
            if e.zim then
                e.zim._img_cache = nil
                e.zim._img_cache_keys = nil
                e.zim._img_file_cache = nil
            end
        end
    end
end

function LocalWiki:_showViewer()
    if not self.current_html then return end
    local t0 = os.clock()
    if self.current_viewer then
        -- Drop the old viewer outright. Keeping a reference to it (or to the
        -- article it rendered) holds a whole MuPDF document plus its layout
        -- cache alive; on a 512 MB Kindle, browsing a few articles that way
        -- ends with the OOM killer taking KOReader down.
        UIManager:close(self.current_viewer)
        self.current_viewer = nil
        -- The closed viewer's MuPDF document is only reclaimed once the GC
        -- runs. On the Kindle that happens too late: the next article
        -- allocates while the old one is still resident, and the OOM killer
        -- steps in. Collect now, while nothing new has been built yet.
        collectgarbage("collect")
    end
    -- The previous article's HTML is no longer on screen; the LRU keeps a
    -- small copy for Back, this field does not need to.
    local html = self.current_html
    self.current_html = nil
    self.current_viewer = Viewer:new{
        title        = self.current_title or "",
        html         = html,
        html_resource_directory = getTempImageDir(),
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
    logger.info(string.format("localwiki: viewer shown in %.2f s (%s)",
        os.clock() - t0, self.current_title or "?"))
end

function LocalWiki:_goBack()
    local prev = table.remove(self.history)
    if not prev then return end
    self.current_entry = nil  -- so openEntry won't push prev back onto history
    self:openEntry(prev, false)
end

function LocalWiki:_followLink(href)
    if not href or href == "" then return end
    if href:match("^zim%-img%-zoom:") or href:match("^zim%-image:") then
        local filename = href:match("^zim%-img%-zoom:(.+)") or href:match("^zim%-image:(.+)")
        if self.current_viewer and self.current_viewer.openImageViewer then
            self.current_viewer:openImageViewer(filename)
            return
        end
    end

    local hash = href:find("#", 1, true)
    if hash then href = href:sub(1, hash - 1) end
    if href == "" then return end
    href = href:gsub("^%./", "")

    -- Check if link points directly to an image file
    local img_ext = href:match("%.([%a%d]+)$")
    if img_ext then
        local ext_l = img_ext:lower()
        if ext_l == "jpg" or ext_l == "jpeg" or ext_l == "png" or ext_l == "webp" or ext_l == "gif" or ext_l == "svg" then
            local base = self.current_entry and self.current_entry._base
            if base then
                local z = self.library:open(base)
                if z then
                    local filename = self:_resolveImageFile(z, href) or self:_resolveImageFile(z, url_decode(href))
                    if filename and self.current_viewer and self.current_viewer.openImageViewer then
                        self.current_viewer:openImageViewer(filename)
                        return
                    end
                end
            end
        end
    end

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
    for _, e in ipairs(self.library:activeZims()) do
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

return LocalWiki

--[[
Article viewer.

Toolbar row 1:  [Back]  [Home]  [Search]   (Back only when history exists)
Toolbar row 2:  [A-]  [A+]  [Aa Font: …]  [Spc: …]  [Margin: …]
Top right 'X' closes the reader.
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local ok_fontlist, FontList = pcall(require, "fontlist")
if not ok_fontlist then
    ok_fontlist, FontList = pcall(require, "ui/fontlist")
end
if not ok_fontlist then FontList = nil end
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local Menu            = require("ui/widget/menu")
local Screen          = require("device").screen
local ScrollHtmlWidget= require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _               = require("gettext")

-- Available CSS generic families KOReader's MuPDF HTML engine recognizes
local CSS_GENERIC = {
    ["serif"]      = true,
    ["sans-serif"] = true,
    ["monospace"]  = true,
    ["cursive"]    = true,
    ["fantasy"]    = true,
}

local FONT_SIZES = { 14,16,18,20,22,24,26,28,30,32,36,40,46,52,60,72,84,96 }

local Viewer = InputContainer:extend{
    title        = "",
    html         = "",
    html_resource_directory = nil,
    font_size    = 26,
    font_face    = nil,    -- nil = CSS "sans-serif"
    line_spacing = 1.2,
    margin_em    = 0,
    can_go_back  = false,
    on_link      = nil,
    on_back      = nil,
    on_home      = nil,
    on_search    = nil,
    on_settings  = nil,
}

-- ── CSS builder ───────────────────────────────────────────────────────────────

local function makeCss(face, spacing, margin_em)
    -- Build a valid CSS font-family value.
    -- Generic keywords must NOT be quoted; named fonts should be.
    local family
    if not face or face == "" then
        family = "sans-serif"
    elseif CSS_GENERIC[face] then
        family = face                              -- e.g.  sans-serif
    else
        family = string.format('"%s", sans-serif', face) -- e.g.  "Verdana", sans-serif
    end
    -- margin_em drives how much whitespace surrounds the text ("screen filling")
    local m = margin_em or 0
    return string.format([[
        body {
            margin: %.2fem;
            font-family: %s;
            line-height: %.2f;
            color: #202122;
            background-color: #ffffff;
        }
        header.mw-body-header, .vector-page-titlebar {
            margin: 0.2em 0 0.8em;
            padding-bottom: 0.2em;
        }
        h1.firstHeading, .mw-first-heading, h1 {
            font-size: 1.65em;
            font-weight: normal;
            margin: 0.2em 0 0.15em;
            padding-bottom: 0.2em;
            border-bottom: 1px solid #a2a9b1;
            color: #000000;
            line-height: 1.25;
        }
        .siteSub {
            font-size: 0.8em;
            color: #54595d;
            margin: 0 0 0.6em;
            font-style: italic;
        }
        h2 {
            font-size: 1.35em;
            font-weight: normal;
            margin: 1.0em 0 0.3em;
            border-bottom: 1px solid #a2a9b1;
            padding-bottom: 0.15em;
            color: #000000;
        }
        h3 {
            font-size: 1.15em;
            font-weight: bold;
            margin: 0.8em 0 0.25em;
            color: #000000;
        }
        h4, h5, h6 {
            font-size: 1.0em;
            font-weight: bold;
            margin: 0.6em 0 0.2em;
        }
        p {
            margin: 0.4em 0 0.6em;
        }
        a {
            text-decoration: none;
            color: #0645ad;
        }
        a:visited {
            color: #0b0080;
        }
        ul, ol {
            margin: 0.4em 0 0.6em 1.4em;
            padding: 0;
        }
        li {
            margin-bottom: 0.2em;
        }
        sup, sub {
            font-size: 75%%;
            line-height: 1;
            vertical-align: super;
        }
        sub {
            vertical-align: sub;
        }
        sup.reference {
            padding-left: 1px;
            font-weight: normal;
        }
        .mw-editsection, .noprint {
            display: none;
        }

        /* Mobile Wikipedia Infobox Card */
        table.infobox {
            border: 1px solid #a2a9b1 !important;
            border-spacing: 0 !important;
            border-collapse: collapse !important;
            background-color: #f8f9fa !important;
            color: #202122 !important;
            margin: 0.6em auto 1.0em auto !important;
            padding: 0.2em !important;
            float: none !important;
            clear: both !important;
            width: 98%% !important;
            max-width: 100%% !important;
            font-size: 85%%;
            line-height: 1.35 !important;
            box-sizing: border-box !important;
            border-radius: 4px;
        }
        table.infobox * {
            box-sizing: border-box;
            line-height: 1.35 !important;
        }
        table.infobox th, table.infobox td {
            vertical-align: top;
            text-align: left;
            padding: 0.25em 0.4em;
            border: 1px solid #eaecf0;
            word-break: break-word;
            line-height: 1.35 !important;
        }
        table.infobox td.infobox-full-data {
            text-align: center;
            padding: 0.35em 0.5em;
        }
        table.infobox th {
            text-align: left;
            background-color: #f0f2f5;
            font-weight: bold;
            width: 35%%;
        }
        table.infobox td {
            width: 65%%;
        }
        table.infobox caption {
            font-weight: bold;
            font-size: 110%%;
            padding: 0.3em;
            text-align: center;
        }
        table.infobox .infobox-title, table.infobox .infobox-above {
            font-size: 115%%;
            font-weight: bold;
            text-align: center;
            background-color: #eaecf0;
            padding: 0.3em 0.4em;
        }
        table.infobox .infobox-image {
            text-align: center !important;
            padding: 0.3em;
            width: 100%% !important;
        }
        table.infobox .infobox-image img {
            max-width: 90%% !important;
            height: auto !important;
            margin: 0 auto !important;
            display: inline-block !important;
        }
        table.infobox .infobox-caption {
            font-size: 85%%;
            line-height: 1.25 !important;
            text-align: center;
            color: #54595d;
        }

        /* Mobile Wikipedia Wikitable */
        table.wikitable {
            background-color: #f8f9fa;
            color: #202122;
            margin: 0.8em auto 1.0em auto !important;
            border: 1px solid #a2a9b1;
            border-collapse: collapse;
            font-size: 88%%;
            line-height: 1.3;
            width: 98%% !important;
            max-width: 100%% !important;
            box-sizing: border-box;
            float: none !important;
            clear: both !important;
            word-break: break-word;
        }
        table.wikitable > tr > th, table.wikitable > * > tr > th {
            background-color: #eaecf0;
            text-align: center;
            font-weight: bold;
            border: 1px solid #a2a9b1;
            padding: 0.3em 0.4em;
        }
        table.wikitable > tr > td, table.wikitable > * > tr > td {
            border: 1px solid #a2a9b1;
            padding: 0.3em 0.4em;
            background-color: #ffffff;
        }
        table.wikitable tr:nth-child(even) td {
            background-color: #f8f9fa;
        }

        /* Sidebar table (also centered card) */
        table.sidebar {
            float: none !important;
            clear: both !important;
            margin: 0.8em auto !important;
            background: #f8f9fa;
            border: 1px solid #a2a9b1;
            padding: 0.3em;
            font-size: 88%%;
            width: 96%% !important;
            max-width: 96%% !important;
            box-sizing: border-box;
            border-radius: 4px;
        }

        /* Disambiguation and hatnotes */
        .hatnote {
            font-style: italic;
            padding: 0.3em 0.5em;
            margin: 0.4em 0 0.7em 0;
            color: #444444;
            background-color: #fdfdfd;
            border-left: 3px solid #c8ccd1;
            font-size: 92%%;
        }

        /* References section */
        ol.references {
            font-size: 85%%;
            line-height: 1.3;
            margin-left: 1.6em;
            padding-left: 0;
            color: #444444;
        }
        ol.references li {
            margin-bottom: 0.35em;
        }

        /* Blockquotes and code */
        blockquote {
            margin: 0.8em 1.2em;
            padding: 0.4em 0.8em;
            border-left: 3px solid #eaecf0;
            color: #333333;
            background-color: #fdfdfd;
            font-style: italic;
        }
        code, pre {
            font-family: monospace;
            background-color: #f8f9fa;
            border: 1px solid #eaecf0;
            padding: 1px 4px;
            font-size: 88%%;
        }

        /* Figures and illustrations */
        figure, .thumb, .thumbinner, .pi-image {
            margin: 0.8em auto !important;
            padding: 0 !important;
            border: none !important;
            background: transparent !important;
            max-width: 100%% !important;
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
            max-width: 100%% !important;
            height: auto !important;
            display: inline-block !important;
            vertical-align: middle !important;
            margin: 0.4em auto !important;
            border: none !important;
        }
        figure img, .thumb img, .thumbinner img, .pi-image img, figure > a > img, a.zim-img-zoom img {
            max-width: 100%% !important;
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
            max-width: 95%% !important;
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
            max-width: 100%% !important;
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
    ]], m, family, spacing)
end

-- ── Font size helpers ─────────────────────────────────────────────────────────

local function prevFontSize(sz)
    for i = #FONT_SIZES, 1, -1 do
        if FONT_SIZES[i] < sz then return FONT_SIZES[i] end
    end
    return FONT_SIZES[1]
end

local function nextFontSize(sz)
    for i = 1, #FONT_SIZES do
        if FONT_SIZES[i] > sz then return FONT_SIZES[i] end
    end
    return FONT_SIZES[#FONT_SIZES]
end

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

-- ── Slim title bar ────────────────────────────────────────────────────────────

local function makeSlimBar(title_text, width, close_cb)
    local bar_h = Screen:scaleBySize(34)
    local face = Font:getFace("cfont", 15)
    local page_face = Font:getFace("cfont", 13)
    local page_w = Screen:scaleBySize(76)
    local close_w = Screen:scaleBySize(36)
    local title_w = width - page_w - close_w - Screen:scaleBySize(16)

    local tw = TextWidget:new{
        text      = title_text,
        face      = face,
        max_width = title_w,
    }
    local page_widget = TextWidget:new{
        text = "",
        face = page_face,
    }
    local close_btn = Button:new{
        text       = "X",
        radius     = 0,
        bordersize = 0,
        padding    = Screen:scaleBySize(4),
        width      = close_w,
        height     = bar_h,
        callback   = close_cb,
    }
    local bar = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = title_w, h = bar_h },
                tw,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = page_w, h = bar_h },
                page_widget,
            },
            close_btn,
        },
    }
    local divider = LineWidget:new{
        dimen      = Geom:new{ w = width, h = Size.line.thick },
        background = Blitbuffer.COLOR_DARK_GRAY,
    }
    local title_group = VerticalGroup:new{ bar, divider }
    return title_group, title_group:getSize().h, page_widget
end

-- ── init ──────────────────────────────────────────────────────────────────────

function Viewer:init()
    local W = Screen:getWidth()
    local H = Screen:getHeight()
    self.dimen = Geom:new{ w = W, h = H }

    local title_bar, title_h, page_widget = makeSlimBar(
        (self.title and self.title ~= "") and decode_html_entities(self.title) or _("Wikipedia"),
        W,
        function() self:onClose() end
    )

    local btn_pad = Screen:scaleBySize(4)

    -- Row 1: [Back]  [Home]  [Search]   (Back only when history exists)
    local row1 = {}
    if self.can_go_back then
        row1[#row1 + 1] = Button:new{
            text     = _("Back"),
            padding  = btn_pad,
            callback = function()
                if self.on_back then self.on_back() end
            end,
        }
    end
    row1[#row1 + 1] = Button:new{
        text     = _("Home"),
        padding  = btn_pad,
        callback = function()
            if self.on_home then self.on_home() end
        end,
    }
    row1[#row1 + 1] = Button:new{
        text     = _("Search"),
        padding  = btn_pad,
        callback = function()
            if self.on_search then self.on_search() end
        end,
    }

    -- Toolbar: all buttons on a single row at the bottom.
    local function notify(sz, face, spc, margin)
        if self.on_settings then self.on_settings(sz, face, spc, margin) end
    end

    local row2 = {
        Button:new{
            text     = "A-",
            padding  = btn_pad,
            callback = function()
                notify(prevFontSize(self.font_size), self.font_face, self.line_spacing, self.margin_em)
            end,
        },
        Button:new{
            text     = "A+",
            padding  = btn_pad,
            callback = function()
                notify(nextFontSize(self.font_size), self.font_face, self.line_spacing, self.margin_em)
            end,
        },
        Button:new{
            text     = string.format("Aa %s", self.font_face or _("Default")),
            padding  = btn_pad,
            callback = function()
                self:_showFontMenu(function(chosen_face)
                    notify(self.font_size, chosen_face, self.line_spacing, self.margin_em)
                end)
            end,
        },
        Button:new{
            text     = string.format("%.1f", self.line_spacing or 1.2),
            padding  = btn_pad,
            callback = function()
                self:_showSpacingMenu(function(chosen_spc)
                    notify(self.font_size, self.font_face, chosen_spc, self.margin_em)
                end)
            end,
        },
        Button:new{
            text     = self.margin_em == 0 and _("Compact") or _("Normal"),
            padding  = btn_pad,
            callback = function()
                local next_m = (self.margin_em == 0) and 0.8 or 0
                notify(self.font_size, self.font_face, self.line_spacing, next_m)
            end,
        },
    }

    local row_h = Screen:scaleBySize(34)
    local all_buttons = {}
    for _, b in ipairs(row1) do all_buttons[#all_buttons + 1] = b end
    for _, b in ipairs(row2) do all_buttons[#all_buttons + 1] = b end

    -- Keep every button on one row: shrink the horizontal padding until the
    -- row fits the screen width.
    local function row_width(pad)
        local total = 0
        for i, b in ipairs(all_buttons) do
            b.padding_h = pad
            total = total + b:getSize().w
            if i > 1 then total = total + pad end -- HorizontalGroup spacing
        end
        return total
    end
    local pad = Screen:scaleBySize(4)
    while pad > 0 and row_width(pad) > W - Screen:scaleBySize(8) do
        pad = pad - 1
    end
    row_width(pad)

    local toolbar_items = {
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = row_h },
            HorizontalGroup:new{ align = "center", padding = pad, table.unpack(all_buttons) },
        },
    }

    local toolbar_divider = LineWidget:new{
        dimen      = Geom:new{ w = W, h = Size.line.thick },
        background = Blitbuffer.COLOR_DARK_GRAY,
    }
    local toolbar_block = VerticalGroup:new{
        toolbar_divider,
        table.unpack(toolbar_items),
    }
    local toolbar_h = toolbar_block:getSize().h
    local V_PAD = Screen:scaleBySize(4)
    local H_PAD = Screen:scaleBySize(8)
    local content_h = H - title_h - toolbar_h
    local html_h = math.max(100, content_h - 2 * V_PAD)

    -- Layout metrics, used by main.lua to pre-layout the article in the
    -- background before the viewer is shown.
    self.layout_metrics = {
        width = W - 2 * H_PAD,
        height = html_h,
        font_size = self.font_size,
    }

    local css = makeCss(self.font_face, self.line_spacing, self.margin_em)

    local html_widget = ScrollHtmlWidget:new{
        html_body         = self.html,
        html_resource_directory = self.html_resource_directory,
        css               = css,
        default_font_size = self.font_size,
        width             = W - 2 * H_PAD,
        height            = html_h,
        dialog            = self,
        html_link_tapped_callback = function(link)
            if not link then return end

            local w = self.html_widget
            -- In-page anchor jumping (e.g. Table of Contents sections)
            if link.page and link.page >= 0 then
                local page_num = link.page + 1
                if w and w.htmlbox_widget then
                    if page_num > w.htmlbox_widget.page_count then
                        page_num = w.htmlbox_widget.page_count
                    end
                    if page_num ~= w.htmlbox_widget.page_number then
                        w.htmlbox_widget:setPageNumber(page_num)
                        w:_updateScrollBar()
                        w.htmlbox_widget:freeBb()
                        w.htmlbox_widget:_render()
                        UIManager:setDirty(self, function()
                            return "partial", self.dimen
                        end)
                    end
                    return
                end
            end

            local href = link.uri or link.url
            if not href then return end
            if href:match("^zim%-img%-zoom:") or href:match("^zim%-image:") then
                local filename = href:match("^zim%-img%-zoom:(.+)") or href:match("^zim%-image:(.+)")
                self:openImageViewer(filename)
                return
            end
            if href:sub(1, 1) == "#" then
                local anchor = href:sub(2):gsub("_", " ")
                if w and w.htmlbox_widget and anchor ~= "" then
                    pcall(function() w.htmlbox_widget:findText(anchor) end)
                end
                return
            end
            if self.on_link then self.on_link(href) end
        end,
    }

    local update_page_indicator = function()
        if page_widget and html_widget.htmlbox_widget then
            local cur = html_widget.htmlbox_widget.page_number or 1
            local total = html_widget.htmlbox_widget.page_count or 1
            page_widget:setText(string.format("%d / %d", cur, total))
            UIManager:setDirty(title_bar, function()
                return "partial", title_bar.dimen
            end)
        end
    end
    html_widget.scroll_callback = function()
        update_page_indicator()
    end
    UIManager:nextTick(update_page_indicator)

    self.html_widget = html_widget

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        VerticalGroup:new{
            align = "left",
            title_bar,
            FrameContainer:new{
                bordersize     = 0,
                padding_left   = H_PAD,
                padding_right  = H_PAD,
                padding_top    = V_PAD,
                padding_bottom = V_PAD,
                html_widget,
            },
            toolbar_block,
        },
    }

    local screen_range = Geom:new{ w = W, h = H }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = screen_range,
                },
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = screen_range,
                },
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close    = { { Device.input.group.Back } },
            PageDown = { { Device.input.group.PgFwd } },
            PageUp   = { { Device.input.group.PgBack } },
        }
    end
end

function Viewer:onSwipe(arg, ges)
    if not self.html_widget or not ges or not ges.direction then return false end
    local dir = ges.direction
    if dir == "west" or dir == "north" then
        self.html_widget:scrollText(1)
        return true
    elseif dir == "east" or dir == "south" then
        self.html_widget:scrollText(-1)
        return true
    end
    return false
end

function Viewer:onTap(arg, ges)
    if not self.html_widget or not self.html_widget.htmlbox_widget then return false end
    -- Guard against malformed/synthetic touch events: some devices deliver a
    -- tap without a position, which used to crash in gesturedetector.lua.
    if not ges or not ges.pos then return false end
    local box = self.html_widget.htmlbox_widget

    -- First, check if a link or image was tapped
    local pos = box:getPosFromAbsPos(ges.pos)
    if pos then
        local link = box:getLinkByPosition(pos)
        if link and self.html_widget.html_link_tapped_callback then
            self.html_widget.html_link_tapped_callback(link)
            return true
        end
    end

    -- If not a link, handle instant page navigation
    local W = Screen:getWidth()
    local x = ges.pos.x
    if x > W * 0.60 then
        self.html_widget:scrollText(1)
        return true
    elseif x < W * 0.40 then
        self.html_widget:scrollText(-1)
        return true
    end
    return false
end

function Viewer:onPageDown()
    if self.html_widget then
        self.html_widget:scrollText(1)
        return true
    end
end

function Viewer:onPageUp()
    if self.html_widget then
        self.html_widget:scrollText(-1)
        return true
    end
end

function Viewer:openImageViewer(filename, caption)
    if not filename or filename == "" then return end
    local bar = filename:find("|", 1, true)
    if bar then
        local enc_caption = filename:sub(bar + 1)
        filename = filename:sub(1, bar - 1)
        if not caption and enc_caption ~= "" then
            caption = enc_caption:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
        end
    end
    local img_dir = self.html_resource_directory
    local filepath = (img_dir and (img_dir .. "/") or "") .. filename
    local f = io.open(filepath, "rb")
    if not f then return end
    f:close()

    local ImageViewer = require("ui/widget/imageviewer")
    local imgviewer = ImageViewer:new{
        file = filepath,
        fullscreen = true,
        with_title_bar = true,
        title_text = (self.title and self.title ~= "") and decode_html_entities(self.title) or _("Image"),
        caption = caption,
    }
    UIManager:show(imgviewer)
end

-- ── lifecycle ─────────────────────────────────────────────────────────────────

function Viewer:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function Viewer:onCloseWidget()
    UIManager:setDirty(nil, function() return "partial", self.dimen end)
end

function Viewer:onClose()
    UIManager:close(self)
    return true
end

-- ── menus ─────────────────────────────────────────────────────────────────────

function Viewer:_showFontMenu(callback)
    -- KOReader v2026.07+ no longer exposes Font:getFaces(); the font list lives
    -- in ui/fontlist. Keep a pcall fallback so older/newer versions both work.
    local faces = {}
    if FontList and FontList.getFontList then
        local ok, list = pcall(FontList.getFontList, FontList)
        if ok and type(list) == "table" then
            -- getFontList() returns font file paths. CSS font-family needs
            -- family names, which FontList keeps in its fontnames map.
            if FontList.fontnames then
                local names = {}
                for name in pairs(FontList.fontnames) do
                    if type(name) == "string" and name ~= "" then
                        names[#names + 1] = name
                    end
                end
                table.sort(names)
                faces = names
            end
            if #faces == 0 then
                local seen = {}
                for _, path in ipairs(list) do
                    local base = tostring(path):match("([^/\\]+)$") or tostring(path)
                    base = base:gsub("%.[^.]+$", "")
                    if base ~= "" and not seen[base] then
                        seen[base] = true
                        faces[#faces + 1] = base
                    end
                end
            end
        end
    end
    local item_table = {
        {
            text      = _("Default (sans-serif)"),
            checked   = (self.font_face == nil),
            radio     = true,
            callback  = function() callback(nil) end,
        },
    }
    for _, f in ipairs(faces) do
        -- getFontList() normally returns strings; tolerate table entries too.
        local name = type(f) == "table" and (f.name or f.face or f.font) or f
        if type(name) == "string" and name ~= "" then
            item_table[#item_table + 1] = {
                text      = name,
                checked   = (self.font_face == name),
                radio     = true,
                callback  = function() callback(name) end,
            }
        end
    end
    local m
    m = Menu:new{
        title       = _("Font"),
        item_table  = item_table,
        onMenuClose = function() UIManager:close(m) end,
    }
    UIManager:show(m)
end

function Viewer:_showSpacingMenu(callback)
    local options = { 1.0, 1.1, 1.2, 1.3, 1.4, 1.6, 1.8 }
    local item_table = {}
    for _, spc in ipairs(options) do
        item_table[#item_table + 1] = {
            text      = string.format("%.1f", spc),
            checked   = (math.abs((self.line_spacing or 1.2) - spc) < 0.05),
            radio     = true,
            callback  = function() callback(spc) end,
        }
    end
    local m
    m = Menu:new{
        title       = _("Line spacing"),
        item_table  = item_table,
        onMenuClose = function() UIManager:close(m) end,
    }
    UIManager:show(m)
end

return Viewer

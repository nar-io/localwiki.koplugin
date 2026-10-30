--[[
Article viewer.

Toolbar row 1:  [Back]  [Home]  [Search]   (Back only when history exists)
Toolbar row 2:  [A-]  [A+]                 (persist font size across sessions)

CSS font bug fixed: CSS generic keywords (serif, sans-serif, monospace)
must NOT be quoted in font-family.  Quoting them treats them as a font
*name* that does not exist and MuPDF silently falls back to serif,
making every face choice look identical.
]]

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _ = require("gettext")

-- ── Constants ─────────────────────────────────────────────────────────────────

local TITLE_H        = Screen:scaleBySize(28)
local H_PAD          = Screen:scaleBySize(2)   -- fixed pixel side padding
local V_PAD          = Screen:scaleBySize(2)
local TOOLBAR_BOTTOM = Screen:scaleBySize(8)   -- breathing room under A-/A+

-- Generic CSS keyword families (must NOT be quoted in CSS).
local CSS_GENERIC = { serif=true, ["sans-serif"]=true, monospace=true,
                      cursive=true, fantasy=true }

-- Ordered font sizes used for A-/A+ stepping.
local FONT_SIZES = { 14,16,18,20,22,24,26,28,30,32,36,40,46,52,60,72,84,96 }

-- ── Viewer widget ─────────────────────────────────────────────────────────────

local Viewer = InputContainer:extend{
    title        = "",
    html         = "",
    font_size    = 26,
    font_face    = nil,    -- nil = CSS "serif"
    line_spacing = 1.2,
    margin_em    = 0,      -- compact: no body margin around text
    can_go_back  = false,
    on_link      = nil,
    on_back      = nil,
    on_home      = nil,
    on_search    = nil,
    -- function(new_size, new_face, new_spc, new_margin)
    on_settings  = nil,
}

-- ── CSS ───────────────────────────────────────────────────────────────────────

local function makeCss(face, spacing, margin_em)
    -- Build a valid CSS font-family value.
    -- Generic keywords must NOT be quoted; named fonts should be.
    local family
    if not face or face == "" then
        family = "serif"
    elseif CSS_GENERIC[face] then
        family = face                              -- e.g.  sans-serif
    else
        family = string.format('"%s", serif', face) -- e.g.  "Verdana", serif
    end
    -- margin_em drives how much whitespace surrounds the text ("screen filling")
    local m = margin_em or 0
    return string.format([[
        body { margin:%.2fem; font-family:%s; line-height:%.2f; }
        h1   { font-size:1.35em; margin:0.5em 0 0.25em; }
        h2   { font-size:1.2em;  margin:0.7em 0 0.25em;
               border-bottom:1px solid #aaa; padding-bottom:0.1em; }
        h3   { font-size:1.05em; margin:0.5em 0 0.2em; }
        p    { margin:0 0 0.45em; }
        a    { text-decoration:underline; color:#000; }
        ul,ol{ margin:0.25em 0 0.45em 1em; padding:0; }
        sup,sub{ font-size:75%%; }
        .reference,.mw-editsection,.noprint{ display:none; }
        figure, .thumb, .thumbinner {
            float: right;
            clear: right;
            margin: 0.4em 0 0.6em 0.8em;
            padding: 3px;
            border: 1px solid #c8ccd1;
            background-color: #f8f9fa;
            max-width: 48%%;
            box-sizing: border-box;
            display: block;
        }
        figure.mw-halign-left, .tleft {
            float: left;
            clear: left;
            margin: 0.4em 0.8em 0.6em 0;
        }
        figure.mw-halign-center, .tcenter, .tnone {
            float: none;
            clear: both;
            margin: 0.5em auto;
            display: block;
            text-align: center;
        }
        img {
            max-width: 100%%;
            height: auto;
            display: block;
            margin: 0 auto;
        }
        figcaption, .thumbcaption {
            font-size: 0.82em;
            line-height: 1.25;
            padding: 4px 2px 2px;
            text-align: left;
            color: #333;
            display: block;
        }
        .mwe-math-fallback-image-inline {
            display: inline-block;
            vertical-align: middle;
            margin: 0 0.1em;
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

-- ── Slim title bar ────────────────────────────────────────────────────────────

local function makeSlimBar(title_text, width, close_cb)
    local face = Font:getFace("cfont", 15)
    local tw = TextWidget:new{
        text      = title_text,
        face      = face,
        max_width = width - Screen:scaleBySize(48),
    }
    local close_btn = Button:new{
        text       = "X",
        radius     = 0,
        bordersize = 0,
        padding    = Screen:scaleBySize(4),
        width      = Screen:scaleBySize(36),
        callback   = close_cb,
    }
    local bar = FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{ w = width - Screen:scaleBySize(40), h = TITLE_H },
                tw,
            },
            close_btn,
        },
    }
    local divider = LineWidget:new{
        dimen      = Geom:new{ w = width, h = Size.line.thick },
        background = Blitbuffer.COLOR_DARK_GRAY,
    }
    return VerticalGroup:new{ bar, divider }, TITLE_H + Size.line.thick
end

-- ── init ──────────────────────────────────────────────────────────────────────

function Viewer:init()
    local W = Screen:getWidth()
    local H = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }

    local title_bar, title_bar_h = makeSlimBar(
        self.title, W, function() self:onClose() end)

    -- Row 1: [Back]  [Home]  [Search]   (Back only when history exists)
    local row1 = {}
    if self.can_go_back then
        row1[#row1+1] = {
            text     = _("Back"),
            callback = function() if self.on_back then self.on_back() end end,
        }
    end
    row1[#row1+1] = {
        text     = _("Home"),
        callback = function() if self.on_home then self.on_home() end end,
    }
    row1[#row1+1] = {
        text     = _("Search"),
        callback = function() if self.on_search then self.on_search() end end,
    }

    -- Row 2: [A-]  [A+]
    local row2 = {
        {
            text     = "A-",
            callback = function()
                if self.on_settings then
                    self.on_settings(prevFontSize(self.font_size), self.font_face,
                                     self.line_spacing, self.margin_em)
                end
            end,
        },
        {
            text     = "A+",
            callback = function()
                if self.on_settings then
                    self.on_settings(nextFontSize(self.font_size), self.font_face,
                                     self.line_spacing, self.margin_em)
                end
            end,
        },
    }

    local toolbar = ButtonTable:new{
        buttons     = { row1, row2 },
        zero_sep    = true,
        show_parent = self,
    }
    local toolbar_h = toolbar:getSize().h

    -- Center the toolbar across the screen and add bottom breathing room
    -- so A-/A+ glyphs don't kiss the bottom edge.
    local toolbar_centered = CenterContainer:new{
        dimen = Geom:new{ w = W, h = toolbar_h },
        toolbar,
    }
    local toolbar_block = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_bottom = TOOLBAR_BOTTOM,
        background     = Blitbuffer.COLOR_WHITE,
        toolbar_centered,
    }

    local content_h = H - title_bar_h - toolbar_h - TOOLBAR_BOTTOM
    local css = makeCss(self.font_face, self.line_spacing, self.margin_em)

    local html_widget = ScrollHtmlWidget:new{
        html_body         = self.html,
        css               = css,
        default_font_size = self.font_size,
        width             = W - 2 * H_PAD,
        height            = content_h - V_PAD,
        dialog            = self,
        html_link_tapped_callback = function(link)
            local href = link and (link.uri or link.url)
            if href and self.on_link then self.on_link(href) end
        end,
    }

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
                padding_bottom = 0,
                html_widget,
            },
            toolbar_block,
        },
    }

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
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

return Viewer

--[[
HTML cleaner for Wikipedia ZIM articles.

Wikipedia HTML carries a heavy preamble (Vector skin chrome, embedded CSS,
hatnotes, infoboxes, navboxes) before the actual article. MuPDF on a Kindle
parses every byte of that, so cutting it down is the single biggest perf
win we can do.

What this function does:
  1. Crops to the first <div class="mw-parser-output"> — the actual article
     body. Header chrome, page titlebars, footers all get dropped.
  2. Removes elements that don't nest in real HTML via regex:
        <style>, <script>, <noscript>, <svg>, <img>, <picture>, <figure>,
        <audio>, <video>, <link>, <meta>
  3. Removes elements that DO nest via balanced tag matching:
        <table> (infoboxes, navboxes — drop ALL tables; on a 6" screen
                 they always render as walls of text)
        <div class="hatnote …"> (the "For the cat family, see Felidae"
                                 disambig blurbs)
  4. Removes empty <p class="mw-empty-elt"> placeholders.

Returns the cleaned HTML body (you wrap it with whatever <html>/<body>
shell your renderer wants).
]]

local M = {}

-- Strip every <openTag …>…</closeTag> block including nested ones.
-- `start_pat` is the Lua-pattern that anchors the *opening* tag (so we
-- can target by attribute), but nesting is tracked using the literal
-- `nest_open` prefix (e.g. "<table") so any nested same-tag children
-- bump the depth counter.
local function strip_balanced(html, start_pat, nest_open, close_str)
    local out, pos = {}, 1
    local close_len = #close_str
    local nest_len = #nest_open
    while true do
        local s, e = html:find(start_pat, pos)
        if not s then
            out[#out + 1] = html:sub(pos)
            return table.concat(out)
        end
        out[#out + 1] = html:sub(pos, s - 1)
        local depth, i = 1, e + 1
        while depth > 0 do
            local oo = html:find(nest_open, i, true)
            local cc = html:find(close_str, i, true)
            if not cc then
                -- Malformed input — bail out and keep what we already have.
                out[#out + 1] = html:sub(s)
                return table.concat(out)
            end
            if oo and oo < cc then
                depth = depth + 1
                i = oo + nest_len
            else
                depth = depth - 1
                i = cc + close_len
            end
        end
        pos = i
    end
end

function M.clean(html)
    if not html or html == "" then return html end

    -- (1) Crop to the article-body div if present.
    local body_start = html:find('<div%s+class="[^"]-mw[%-_]parser[%-_]output')
    if body_start then
        html = html:sub(body_start)
    else
        -- Fall back to <body>… so we at least drop <head>.
        local b = html:find("<body[^>]*>")
        if b then
            local _, e = html:find("<body[^>]*>", b)
            if e then html = html:sub(e + 1) end
        end
    end

    -- (2) Non-nesting noise — single-pass gsub each.
    html = html:gsub("<script[^>]*>.-</script>", "")
    html = html:gsub("<style[^>]*>.-</style>", "")
    html = html:gsub("<noscript[^>]*>.-</noscript>", "")
    html = html:gsub("<svg[^>]*>.-</svg>", "")
    html = html:gsub("<picture[^>]*>.-</picture>", "")
    html = html:gsub("<figure[^>]*>.-</figure>", "")
    html = html:gsub("<audio[^>]*>.-</audio>", "")
    html = html:gsub("<video[^>]*>.-</video>", "")
    html = html:gsub("<img[^>]*>", "")
    html = html:gsub("<link[^>]*>", "")
    html = html:gsub("<meta[^>]*>", "")

    -- (3) Nesting blocks — balanced removal.
    html = strip_balanced(html, "<table[%s>]", "<table", "</table>")
    html = strip_balanced(html,
        '<div%s+[^>]-class="[^"]-hatnote[^"]-"',
        "<div", "</div>")
    -- Editor notices & ambox-style banners.
    html = strip_balanced(html,
        '<div%s+[^>]-class="[^"]-ambox[^"]-"',
        "<div", "</div>")
    -- MediaWiki template/parser warnings baked into ZIM HTML.
    -- These appear as <div class="preview-warning"> or mw-message-box variants.
    html = strip_balanced(html,
        '<div%s+[^>]-class="[^"]-preview%-warning[^"]-"',
        "<div", "</div>")
    html = strip_balanced(html,
        '<div%s+[^>]-class="[^"]-mw%-message%-box[^"]-"',
        "<div", "</div>")
    -- "References" / footer crud often inside <ol class="references">
    html = strip_balanced(html,
        '<ol%s+[^>]-class="[^"]-references[^"]-"',
        "<ol", "</ol>")

    -- (4) Empty placeholders.
    html = html:gsub('<p[^>]-class="[^"]-mw%-empty[^"]-"[^>]*>.-</p>', "")
    -- Compress runs of blank lines (cheap; helps MuPDF's whitespace handling).
    html = html:gsub("\n%s*\n", "\n")

    return html
end

return M

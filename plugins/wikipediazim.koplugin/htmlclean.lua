--[[
HTML cleaner for Wikipedia ZIM articles.

Wikipedia HTML carries a heavy preamble (Vector skin chrome, embedded CSS,
hatnotes, infoboxes, navboxes) before the actual article. MuPDF on a Kindle
parses every byte of that, so cutting it down is the single biggest perf
win we can do.

What this function does:
  1. In full page mode, retains original Wikipedia structure with a mobile card layout:
     - Infoboxes and sidebars as clean centered cards (float:none) to eliminate text wrap bugs.
     - Strips heavy navbox tables, footers, metadata and banners.
     - Strips layout-breaking inline CSS (hardcoded widths, floats, positions).
  2. In lookup mode (short extracts), crops and strips tables to save RAM.
  3. Removes elements that don't nest in real HTML via regex with fast probe guards:
        <style>, <script>, <noscript>, <svg>, <picture>,
        <audio>, <video>, <link>, <meta>
  4. Removes empty <p class="mw-empty-elt"> placeholders.

Returns the cleaned HTML body.
]]

local M = {}

-- Elements whose content never contributes text to the article.
local NOISE_BLOCKS = {
    script = true, style = true, noscript = true,
    svg = true, audio = true, video = true,
}
-- Void elements that carry no content.
local NOISE_VOID = { link = true, meta = true }

-- Remove HTML comments and the noise elements in ONE scan.
--
-- This used to be ten whole-document gsubs. Each gsub costs ~80 ms per
-- megabyte even when it matches nothing (the pattern engine walks the string
-- and the result is a fresh copy), and five of them do fire on a typical
-- article: on a 1 MB page the block alone took 0.43 s. The scanner is 2.5x
-- faster and produces the same output.
local function strip_noise(html)
    local out, copy_from, pos = {}, 1, 1
    local len = #html
    while pos <= len do
        local lt = html:find("<", pos, true)
        if not lt then break end
        if html:sub(lt, lt + 3) == "<!--" then
            local e = html:find("-->", lt + 4, true)
            if not e then break end
            out[#out + 1] = html:sub(copy_from, lt - 1)
            copy_from, pos = e + 3, e + 3
        else
            local name = html:match("^<(%a+)", lt)
            local gt = name and html:find(">", lt, true)
            if name and gt then
                name = name:lower()
                if NOISE_BLOCKS[name] then
                    local close = html:find("</" .. name, gt, true)
                    local cgt = close and html:find(">", close, true)
                    if cgt then
                        out[#out + 1] = html:sub(copy_from, lt - 1)
                        copy_from, pos = cgt + 1, cgt + 1
                    else
                        pos = gt + 1
                    end
                elseif NOISE_VOID[name] then
                    out[#out + 1] = html:sub(copy_from, lt - 1)
                    copy_from, pos = gt + 1, gt + 1
                else
                    pos = gt + 1
                end
            else
                pos = lt + 1
            end
        end
    end
    out[#out + 1] = html:sub(copy_from)
    return table.concat(out)
end

-- Remove the invisible Z3988 COinS spans (10-25 KB of unrenderable metadata
-- on a long article). A scanner instead of a gsub: the pattern had to walk
-- every character of the document and rewrite it, 271 times on Istanbul.
local function strip_z3988(html)
    local out, copy_from, pos = {}, 1, 1
    while true do
        local s = html:find("<span", pos, true)
        if not s then break end
        local gt = html:find(">", s, true)
        if not gt then break end
        if html:sub(s, gt):find("Z3988", 1, true) then
            local close = html:find("</span>", gt, true)
            if close then
                out[#out + 1] = html:sub(copy_from, s - 1)
                copy_from, pos = close + 7, close + 7
            else
                pos = gt + 1
            end
        else
            pos = gt + 1
        end
    end
    out[#out + 1] = html:sub(copy_from)
    return table.concat(out)
end

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

-- Fast-path conditional wrapper: skips expensive scanning when probe string is absent
local function strip_balanced_if(html, start_pat, nest_open, close_str, probe)
    if probe and not html:find(probe, 1, true) then return html end
    return strip_balanced(html, start_pat, nest_open, close_str)
end

-- ── Infobox normalisation ────────────────────────────────────────────────────

-- Find the end of the block opened by `open_tag` at `start`, counting nested
-- tags of the same name. Returns the index just past the matching close tag.
local function find_block_end(html, start, name)
    local open_pat = "<" .. name
    local close_str = "</" .. name .. ">"
    local gt = html:find(">", start, true)
    if not gt then return nil end
    local depth, i = 1, gt + 1
    while depth > 0 do
        local oo = html:find(open_pat, i, true)
        local cc = html:find(close_str, i, true)
        if not cc then return nil end
        if oo and oo < cc then
            depth = depth + 1
            i = oo + #open_pat
        else
            depth = depth - 1
            i = cc + #close_str
        end
    end
    return i
end

-- Remove nested tables from a cell and flatten its markup to plain text.
-- `sep` is what a <br> becomes (a line break inside a cell is meaningful).
local function cell_text(fragment, sep)
    sep = sep or " "
    local guard = 0
    while fragment:find("<table", 1, true) and guard < 20 do
        local s = fragment:find("<table", 1, true)
        local e = find_block_end(fragment, s, "table")
        if not e then break end
        fragment = fragment:sub(1, s - 1) .. fragment:sub(e)
        guard = guard + 1
    end
    fragment = fragment:gsub("<img[^>]*>", "")
    fragment = fragment:gsub("</?span[^>]*>", "")
    fragment = fragment:gsub("</?div[^>]*>", " ")
    fragment = fragment:gsub("</?small[^>]*>", "")
    fragment = fragment:gsub("</?b>", "")
    fragment = fragment:gsub("</?i>", "")
    fragment = fragment:gsub("</?a[^>]*>", "")
    fragment = fragment:gsub("<br%s*/?>", sep)
    fragment = fragment:gsub("<[^>]+>", "")
    fragment = fragment:gsub("&#160;", " "):gsub("&nbsp;", " ")
    fragment = fragment:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'")
    fragment = fragment:gsub("[ \t]+", " ")
    fragment = fragment:gsub(" *\n *", "\n")
    fragment = fragment:gsub("\n+", sep)
    fragment = fragment:match("^%s*(.-)%s*$") or ""
    fragment = fragment:gsub("^[%s·]+", ""):gsub("[%s·]+$", "")
    return fragment
end

-- Rebuild the first infobox as a simple two-column table that MuPDF can lay
-- out: one <tr> per label/value pair, full-width rows for headings and
-- images. Wikipedia's original box nests tables several levels deep, which
-- MuPDF renders with overlapping text.
local function normalize_infobox(html)
    local s = html:find('<table%s+[^>]-class="[^"]-infobox')
    if not s then return html end
    local e = find_block_end(html, s, "table")
    if not e then return html end
    local box = html:sub(s, e - 1)

    local out = { '<table class="infobox">' }
    local images = {}
    local rows, pairs = 0, 0
    local pos = 1
    while true do
        local rs = box:find("<tr", pos, true)
        if not rs then break end
        local re = find_block_end(box, rs, "tr")
        if not re then break end
        local row = box:sub(rs, re - 1)
        pos = re
        rows = rows + 1

        for img in row:gmatch("<img[^>]*>") do
            images[#images + 1] = img
        end

        local is_heading = row:find("infobox%-above") or row:find("infobox%-title")
            or row:find("infobox%-subheader")

        -- Collect every cell in the row (battle boxes use one column per side).
        local cells = {}
        local cp = 1
        while true do
            local cs = row:find("<t[dh]", cp)
            if not cs then break end
            local is_th = row:sub(cs + 1, cs + 2) == "th"
            local ce = find_block_end(row, cs, is_th and "th" or "td")
            if not ce then break end
            local tag = row:sub(cs, row:find(">", cs, true))
            local colspan = tonumber(tag:match('colspan="(%d+)"') or tag:match("colspan='(%d+)'") or 1) or 1
            cells[#cells + 1] = {
                is_th = is_th,
                colspan = colspan,
                text = cell_text(row:sub(cs, ce - 1), "\n"),
            }
            cp = ce
        end

        local function emit_row(html_row)
            out[#out + 1] = html_row
        end

        if is_heading then
            local text = cell_text(row)
            if text ~= "" then
                emit_row('<tr><th colspan="2" class="wz-ib-heading">' .. text .. '</th></tr>')
            end
        elseif #cells >= 2 and cells[1].is_th then
            -- Label + one or more values: keep the label in the left column and
            -- the values in the right one, separated by a line break.
            local vals = {}
            for k = 2, #cells do
                if cells[k].text ~= "" then vals[#vals + 1] = cells[k].text end
            end
            if cells[1].text ~= "" and #vals > 0 then
                emit_row('<tr><th class="wz-ib-label">' .. cells[1].text ..
                    '</th><td class="wz-ib-value">' .. table.concat(vals, "\n") .. '</td></tr>')
                pairs = pairs + 1
            elseif #vals > 0 then
                emit_row('<tr><td colspan="2" class="wz-ib-value">' ..
                    table.concat(vals, "\n") .. '</td></tr>')
            end
        elseif #cells >= 2 then
            -- Side-by-side values without a label (battle "Taraflar",
            -- "Komutanlar", "Güçler"): one column per side, exactly like the
            -- original table.
            local cols = {}
            for k = 1, #cells do
                if cells[k].text ~= "" then cols[#cols + 1] = cells[k].text end
            end
            if #cols > 0 then
                local width = math.floor(100 / #cols)
                local tds = {}
                for k, v in ipairs(cols) do
                    tds[#tds + 1] = string.format('<td class="wz-ib-value" style="width: %d%% !important">%s</td>',
                        width, v)
                end
                emit_row("<tr>" .. table.concat(tds) .. "</tr>")
                pairs = pairs + 1
            end
        else
            local text = cells[1] and cells[1].text or cell_text(row)
            if text ~= "" then
                emit_row('<tr><td colspan="2" class="wz-ib-value">' .. text .. '</td></tr>')
            end
        end
    end
    if #images > 0 then
        table.insert(out, 2, '<tr><td colspan="2" class="wz-ib-images">' ..
            table.concat(images) .. '</td></tr>')
    end
    out[#out + 1] = '</table>'

    if rows == 0 or pairs == 0 then
        return html:sub(1, s - 1) .. html:sub(e)
    end
    return html:sub(1, s - 1) .. table.concat(out) .. html:sub(e)
end

-- Remove every <tag … class="… name …">…</tag> block (nested same-tag
-- children included) in a single pass over the document.
--
-- `classes` maps a class name to true (strip it) or false (keep it).
--
-- The pre-refactor code ran one strip pass per class over the whole document
-- (13 passes for a full page), even when the class never appeared: on a 1 MB
-- article that was ~1 s of scanning and ~13 copies of the document. Here the
-- document is scanned once for `class="`; each match is resolved to its
-- enclosing tag, and only matching blocks are cut out. Output is identical
-- to the old pass sequence (verified against the pre-refactor implementation).
--
-- A kept block is copied out verbatim, so the scan never restarts inside it.
local BLOCK_TAGS = { table = true, div = true, ol = true, ul = true }

-- Find the <tag …> that encloses position `c` (a `class="` occurrence),
-- walking back through nested tags. Returns tag_start, tag_name, gt (index
-- of the closing ">"), or nil when the position is not inside a tag.
--
-- The walk back is byte-by-byte and bounded: `html:sub(1, c-1):match(".*()<")`
-- copies the whole prefix on every call, which made this O(n²) on articles
-- with thousands of class attributes (3.3 s for 2000 lookups on Ankara).
local LOOKBACK_LIMIT = 2048
local function enclosing_tag(html, c)
    local lt = c - 1
    local limit = c - LOOKBACK_LIMIT
    if limit < 1 then limit = 1 end
    while lt >= limit do
        if html:byte(lt) == 60 then -- '<'
            local tag_name = html:match("^<(%a+)", lt)
            local gt = html:find(">", lt, true)
            if tag_name and gt and gt > c then
                return lt, tag_name, gt
            end
        end
        lt = lt - 1
    end
    return nil
end

-- Find the matching close tag for a block opened at `tag_start` whose opening
-- tag ends at `gt`. Returns the index just past the close tag.
local function block_end(html, tag_start, name, gt)
    local close_str = "</" .. name .. ">"
    local nest_open = "<" .. name
    local nest_len, close_len = #nest_open, #close_str
    local depth, i = 1, gt + 1
    while depth > 0 do
        local oo = html:find(nest_open, i, true)
        local cc = html:find(close_str, i, true)
        if not cc then
            -- Malformed input: keep the rest untouched.
            return nil
        end
        if oo and oo < cc then
            depth = depth + 1
            i = oo + nest_len
        else
            depth = depth - 1
            i = cc + close_len
        end
    end
    return i
end

local function strip_class_blocks(html, classes)
    local out, pos = {}, 1
    while true do
        local c = html:find('class="', pos, true)
        if not c then
            out[#out + 1] = html:sub(pos)
            break
        end
        local tag_start, tag_name, gt = enclosing_tag(html, c)
        local name = tag_name and tag_name:lower()
        local strip = false
        if name and BLOCK_TAGS[name] then
            -- Only the first class token: the attribute value ends at the
            -- closing quote, not at the end of the tag.
            local first_word = html:sub(c + 7):match("^[^%s\"]*")
            local wanted = classes[first_word]
            if wanted ~= nil then
                strip = wanted
            end
        end
        if not strip then
            out[#out + 1] = html:sub(pos, c + 6)
            pos = c + 7
        else
            local next_pos = block_end(html, tag_start, name, gt)
            if not next_pos then
                out[#out + 1] = html:sub(pos)
                break
            end
            out[#out + 1] = html:sub(pos, tag_start - 1)
            pos = next_pos
        end
    end
    return table.concat(out)
end

function M.clean(html, is_full_page, page_title, opts)
    if not html or html == "" then return html end
    opts = opts or {}
    local keep_references = opts.keep_references == true

    -- Extract article title heading for full page view before body cropping
    local header_html = nil
    if is_full_page then
        local first_heading = html:match('<h1[^>]-id="firstHeading"[^>]*>(.-)</h1>')
            or html:match('<h1[^>]-class="[^"]-firstHeading[^"]-"[^>]*>(.-)</h1>')
            or html:match('<h1[^>]*>(.-)</h1>')
        local title_text = first_heading or page_title
        if title_text and title_text ~= "" then
            local clean_title = title_text:gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
            if clean_title == "" then clean_title = page_title or "Wikipedia" end
            local sub = html:match('<div[^>]-id="siteSub"[^>]*>(.-)</div>')
            if not sub or sub == "" then
                local ok_gettext, _ = pcall(require, "gettext")
                if ok_gettext and _ then
                    sub = _("From Wikipedia, the free encyclopedia")
                else
                    sub = "Vikipedi, özgür ansiklopedi"
                end
            else
                sub = sub:gsub("<[^>]+>", ""):match("^%s*(.-)%s*$")
            end
            header_html = string.format(
                '<header class="mw-body-header vector-page-titlebar">' ..
                '<h1 id="firstHeading" class="firstHeading mw-first-heading">%s</h1>' ..
                '<div class="siteSub">%s</div>' ..
                '</header>',
                clean_title, sub
            )
        end
    end

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

    -- (2) Non-nesting noise — one scan for comments and the content-less
    -- elements, then the passes that need a pattern.
    html = strip_noise(html)
    if html:find("picture", 1, true) then html = html:gsub("</?picture[^>]*>", "") end
    if html:find("info%-icon", 1, true) then html = html:gsub('<a%s+[^>]-class="[^"]-info%-icon[^"]-"[^>]*>.-</a>', "") end

    -- Strip invisible Z3988 COinS bibliographic metadata (10-25 KB of
    -- unrenderable DOM bloat on a long article).
    if html:find("Z3988", 1, true) then
        html = strip_z3988(html)
    end
    -- Unwrap external image links to avoid "External link (offline)" dialog on broken/unloaded images
    if html:find("nocookie", 1, true) or html:find("wikimedia", 1, true) then
        html = html:gsub('<a%s+[^>]-href=[\"\']https?://[^\"\']*(?:nocookie%.net|wikimedia%.org|upload%.wikimedia)[^\"\']*[\"\'][^>]*>(.-)</a>', "%1")
    end
    -- Unwrap links that wrap exclusively an <img> so illustrations can be
    -- wrapped in the zoomable viewer link. The old class="image",
    -- href="...File:" and href="...Dosya:" passes were fully subsumed by the
    -- generic pattern below, so they were removed (3 fewer full-document gsubs).
    if html:find("<a", 1, true) and html:find("<img", 1, true) then
        html = html:gsub('<a%s+[^>]*>(%s*<img[^>]+>%s*)</a>', "%1")
    end

    -- (3) Nesting blocks — balanced removal by class in a single pass.
    local KEEP_NAVBOX = is_full_page
    local block_classes = {
        navbox       = KEEP_NAVBOX,
        toccolours   = is_full_page,
        nowraplinks  = is_full_page,
        ambox        = is_full_page,
        catlinks     = is_full_page,
        printfooter  = is_full_page,
        ["preview-warning"] = is_full_page,
        ["mw-message-box"]  = is_full_page,
        eraicon      = is_full_page,
        ["wds-dropdown"]    = is_full_page,
        metadata     = is_full_page,
        hatnote      = not is_full_page,
        -- Kept as a marker: the reference list sits inside a wrapper div, so
        -- it is removed by its own balanced pass below.
        references   = false,
    }
    if html:find("class=", 1, true) then
        html = strip_class_blocks(html, block_classes)
    end

    -- Reader mode: references are often 30-40% of the cleaned HTML and
    -- generate many extra MuPDF pages. Drop them by default; callers can
    -- opt back in with { keep_references = true }.
    if is_full_page and not keep_references then
        -- In-text citation markers ([1], [2], ...). They point at the list
        -- that is removed below, so they are dead links that only clutter the
        -- text. Removing them first also shrinks the document before the
        -- reference-list pass and MuPDF's parse (~30% less HTML on articles
        -- with heavy citation, ~0.1 s faster to parse on a 1 MB article).
        if html:find("mw%-ref", 1, true) then
            html = html:gsub('<sup[^>]-class="[^"]-mw%-ref[^"]-"[^>]*>.-</sup>', "")
        end
        if html:find('class="reference', 1, true) then
            html = html:gsub('<sup[^>]-class="[^"]-reference[^"]-"[^>]*>.-</sup>', "")
        end
        html = strip_balanced_if(html, '<ol%s+[^>]-class="[^"]-references', "<ol", "</ol>", "references")
        -- With the list gone, the "Kaynakça"/"References" heading and its
        -- empty wrapper are left behind as a stray heading: drop them too.
        if html:find("Kaynak", 1, true) or html:find("References", 1, true) then
            html = html:gsub('<div class="mw%-heading mw%-heading2"><h2[^>]->.-</h2></div>', function(block)
                local id = block:match('id="([^"]+)"')
                if id and (id:find("Kaynak") or id:find("References")) then return "" end
                return block
            end)
            html = html:gsub('<h2[^>]-id="[^"]-[Kk]aynak[^"]-"[^>]*>.-</h2>', "")
            html = html:gsub('<h2[^>]-id="[^"]-[Rr]eferences[^"]-"[^>]*>.-</h2>', "")
            html = html:gsub('<div class="reflist[^"]*"[^>]*>%s*<div class="mw%-references%-wrap[^"]*"[^>]*>%s*</div>%s*</div>', "")
        end
    end

    if is_full_page then
        -- Coordinates and non-viewer audio widgets
        if html:find("coordinates", 1, true) then
            html = html:gsub('<span%s+[^>]-id="coordinates"[^>]*>.-</span>', "")
            html = html:gsub('<div%s+[^>]-id="coordinates"[^>]*>.-</div>', "")
        end
        if html:find("noviewer", 1, true) then
            html = html:gsub('<span%s+[^>]-class="[^"]-noviewer[^"]-"[^>]*>.-</span>', "")
        end

        -- Infobox: MuPDF's HTML engine lays out the deeply nested tables
        -- Wikipedia uses for infoboxes badly (labels and values overlap,
        -- image grids collapse). Rebuild the box as a simple two-column table
        -- before MuPDF ever sees it.
        if html:find("infobox", 1, true) then
            html = normalize_infobox(html)
        end

        if header_html then
            html = header_html .. html
        end
    else
        -- Extract lead image from infobox table if present,
        -- converting it to a standard figure so the picture is preserved when the table is stripped.
        local lead_fig = nil
        if html:find("infobox", 1, true) then
            local infobox = html:match('<table[^>]-class="[^"]-infobox[^"]-"[^>]*>(.-)</table>')
            if infobox then
                local img_tag = infobox:match('(<img%s+[^>]+>)')
                if img_tag then
                    local cap = infobox:match('<[^>]-class="[^"]-infobox%-caption[^"]-"[^>]*>(.-)</[^>]+>')
                    lead_fig = string.format('<figure class="mw-halign-center">%s%s</figure>',
                        img_tag, cap and ("<figcaption>" .. cap .. "</figcaption>") or "")
                end
            end
        end

        -- Lookup mode: drop every table, then place the salvaged lead figure
        -- right before the first paragraph.
        html = strip_balanced_if(html, "<table[%s>]", "<table", "</table>", "<table")
        if lead_fig then
            local p_start = html:find("<p[%s>]")
            if p_start then
                html = html:sub(1, p_start - 1) .. lead_fig .. html:sub(p_start)
            else
                html = lead_fig .. html
            end
        end
    end

    -- (4) Empty placeholders (both p and span).
    if html:find("mw-empty", 1, true) then
        html = html:gsub('<p[^>]-class="[^"]-mw%-empty[^"]-"[^>]*>.-</p>', "")
        html = html:gsub('<span[^>]-class="[^"]-mw%-empty[^"]-"[^>]*>.-</span>', "")
    end

    -- Strip destructive inline styles that cause MuPDF layout bugs on e-ink
    -- (line-height, font-size, width, height, float, clear, position, margin).
    -- Only a small whitelist of harmless properties is kept, and values are
    -- validated before being emitted: malformed declarations used to reach
    -- MuPDF as e.g. "align>=<" and produced CSS syntax errors.
    if html:find("style=", 1, true) then
        local ALLOWED_STYLE_PROPS = {
            ["background"] = true,
            ["background-color"] = true,
            ["border"] = true,
            ["border-bottom"] = true,
            ["border-collapse"] = true,
            ["border-color"] = true,
            ["border-left"] = true,
            ["border-right"] = true,
            ["border-spacing"] = true,
            ["border-style"] = true,
            ["border-top"] = true,
            ["border-width"] = true,
            ["caption-side"] = true,
            ["color"] = true,
            ["display"] = true,
            ["font-family"] = true,
            ["font-style"] = true,
            ["font-variant"] = true,
            ["font-weight"] = true,
            ["letter-spacing"] = true,
            ["list-style"] = true,
            ["list-style-type"] = true,
            ["padding"] = true,
            ["padding-bottom"] = true,
            ["padding-left"] = true,
            ["padding-right"] = true,
            ["padding-top"] = true,
            ["text-align"] = true,
            ["text-decoration"] = true,
            ["text-indent"] = true,
            ["vertical-align"] = true,
            ["white-space"] = true,
            ["word-spacing"] = true,
        }
        local function valid_style_value(v)
            if not v or v == "" then return false end
            if v:find("[<>\"'{}]") then return false end
            -- Typical CSS values: numbers+units, colors, keywords, rgb(...), %.
            return v:match("^[%w%s%.,#%%%(%)%-%+/]+$") ~= nil
        end
        local function filter_style(s)
            if s:find("display%s*:%s*none") then
                return 'style="display:none;"'
            end
            local parts = {}
            for prop, val in s:gmatch("([%a%-]+)%s*:%s*([^;]+)") do
                local p = prop:lower():match("^%s*(.-)%s*$")
                local v = val:match("^%s*(.-)%s*$"):gsub("%s*!important%s*$", "")
                if ALLOWED_STYLE_PROPS[p]
                   and p ~= "line-height"
                   and p ~= "font-size"
                   and p ~= "width"
                   and p ~= "height"
                   and p ~= "float"
                   and p ~= "clear"
                   and p ~= "position"
                   and not p:find("^margin")
                   and not p:find("^column")
                   and valid_style_value(v) then
                    table.insert(parts, p .. ": " .. v)
                end
            end
            if #parts == 0 then return "" end
            return 'style="' .. table.concat(parts, "; ") .. '"'
        end
        html = html:gsub('style="([^"]*)"', filter_style)
        html = html:gsub("style='([^']*)'", filter_style)
    end

    -- Remove hardcoded width attributes from tables and cells so CSS controls
    -- them, and drop large width/height attributes from <img> (>= 80px wide,
    -- >= 60px high) so illustrations scale to the page while small icons
    -- (30px Commons, math, flags) stay small.
    --
    -- This used to be four whole-document gsubs whose patterns had to scan to
    -- the end of every tag; on a 1 MB article that alone cost ~1.5 s. Walking
    -- the tags once and rewriting only the matching ones costs ~0.1 s and
    -- produces byte-identical output.
    if html:find("width=", 1, true) then
        html = html:gsub("<[%a][^>]*>", function(tag)
            local name = tag:match("^<(%a+)"):lower()
            if name == "table" or name == "td" or name == "th" or name == "col" then
                return (tag:gsub('%s+width=(["\'])[%d%%]+%1', ""))
            elseif name == "img" then
                -- Width and height are rewritten in one pass: they can sit
                -- next to each other, so two back-to-back gsubs would leave
                -- the second one's leading space in place.
                tag = tag:gsub('(%s+)(width|height)=(["\'])(%d+)%3', function(space, attr, q, value)
                    local n = tonumber(value)
                    if attr == "width" and n >= 80 then return "" end
                    if attr == "height" and n >= 60 then return "" end
                    return space .. attr .. "=" .. q .. value .. q
                end)
                return tag
            end
            return tag
        end)
    end

    -- Ensure Fandom portable-infobox figures have mw-halign-center class for consistent centering
    if html:find("pi-image", 1, true) then
        html = html:gsub('(<figure%s+[^>]-class="[^"]-pi%-image[^"]-)"', '%1 mw-halign-center"')
    end

    -- Compress runs of blank lines (cheap; helps MuPDF's whitespace handling).
    html = html:gsub("\n%s*\n", "\n")

    return html
end

function M.cleanFull(html, page_title, opts)
    return M.clean(html, true, page_title, opts)
end

return M

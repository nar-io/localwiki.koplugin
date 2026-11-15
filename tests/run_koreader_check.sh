#!/usr/bin/env bash
# Load the plugin inside a real KOReader runtime and exercise it end to end.
#
#   tests/run_koreader_check.sh [path-to-koreader]
#
# What this proves that the pure-Lua smoke test cannot:
#   * the plugin's _meta.lua is a valid KOReader plugin descriptor
#   * main.lua loads under KOReader's own luajit + frontend modules
#   * every method KOReader calls (addToMainMenu, runSearch, ...) exists
#   * a ZIM found by library.lua is opened and searched through KOReader's
#     runtime, not a bare LuaJIT
#
# KOReader's bundled native libraries need glibc >= 2.35. On an older host the
# font/MuPDF stack is stubbed (see the preload block in the generated script);
# everything the plugin itself does still runs for real.
set -euo pipefail

KO="${1:-${KOREADER_DIR:-/tmp/koreader}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/../plugins/localwiki.koplugin"

if [ ! -x "$KO/lib/koreader/luajit" ]; then
    echo "KOReader not found at $KO (pass the path as the first argument)" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Plugin sources on a flat path so `require("main")` resolves to the plugin.
mkdir -p "$WORK/plugin"
cp "$PLUGIN"/*.lua "$WORK/plugin/"

# Fixture ZIM. Needs Python with zstandard; fall back to a prebuilt one.
ZIM="$WORK/test.zim"
PY=""
for cand in python3 /usr/bin/python3; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import zstandard' 2>/dev/null; then
        PY="$cand"; break
    fi
done
if [ -n "$PY" ]; then
    "$PY" "$HERE/make_test_zim.py" "$ZIM" >/dev/null
elif [ -f "$HERE/fixtures/test.zim" ]; then
    cp "$HERE/fixtures/test.zim" "$ZIM"
else
    echo "no python with zstandard and no tests/fixtures/test.zim — cannot build a fixture" >&2
    exit 2
fi
mkdir -p "$WORK/wiki" && cp "$ZIM" "$WORK/wiki/"

cat > "$WORK/check.lua" <<LUA
package.path = "./?.lua;./frontend/?.lua;./plugins/?.lua;" .. package.path
package.cpath = "./libs/?.so;" .. package.cpath
require("setupkoenv")
package.path = "$WORK/plugin/?.lua;" .. package.path

-- Stubs for modules that reach KOReader's native libs (MuPDF/harfbuzz/freetype).
package.preload["ui/font"] = function()
    return { getFace = function() return { orig_font = "cfont", size = 15 } end }
end
package.preload["fontlist"] = function()
    return { getFontList = function() return {} end, fontnames = {} }
end
package.preload["viewer"] = function()
    local V = {}
    function V:new(o) return setmetatable(o or {}, {__index = V}) end
    function V:openImageViewer() end
    return V
end
for _, m in ipairs{"ui/widget/dictquicklookup", "ui/renderimage", "ui/widget/imageviewer",
                   "ui/widget/pathchooser", "ui/widget/menu", "ui/widget/inputdialog"} do
    package.preload[m] = function()
        return setmetatable({}, {__index = function() return function() end end})
    end
end

local fails, checks = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if cond then print("  ok   " .. name)
    else fails = fails + 1; print("  FAIL " .. name .. (detail and (" — " .. tostring(detail)) or "")) end
end

G_reader_settings = require("luasettings"):open("$WORK/settings.reader.lua", true)
G_defaults = require("luasettings"):open("./defaults.lua", true)

local meta = require("_meta")
check("_meta is a plugin descriptor", meta.name == "localwiki" and type(meta.version) == "string",
      tostring(meta.name) .. " " .. tostring(meta.version))

local LocalWiki = require("main")
check("main.lua returns a table", type(LocalWiki) == "table")
for _, fn in ipairs{"init","addToMainMenu","runSearch","searchFromSelection",
                    "_getSearchCandidates","openEntry","_embedImagesInHtml",
                    "showInLookupWindow","registerSelectionHooks","_followLink",
                    "_goBack","openMainPage","_ensureScanned","showLoadedZims"} do
    check("method " .. fn, type(LocalWiki[fn]) == "function")
end

local Library = require("library")
local lib = Library.new()
check("library finds the fixture ZIM", lib:scan("$WORK/wiki") and #lib.zims == 1)
local z = lib:open(lib.zims[1].base)
check("ZIM opens under KOReader", z ~= nil)
if z then
    check("article count", z.article_count == 6, z.article_count)
    local e = z:findExact("C", "İstanbul")
    check("Turkish exact lookup", e ~= nil)
    local html = z:readArticle(e)
    check("article decompresses", html ~= nil and #html > 100, html and #html)
end

-- Search candidates must survive the Turkish dotted/dotless i rules.
local cases = {
    { "istanbul", "İstanbul" },
    { "çocuk",    "Çocuk"    },
    { "ışık",     "Işık"     },
    { "Fizik",    "Fizik"    },
}
for _, c in ipairs(cases) do
    local got = LocalWiki._getSearchCandidates(nil, c[1])
    local hit = false
    for _, v in ipairs(got) do if v == c[2] then hit = true end end
    check(string.format("candidate '%s' -> '%s'", c[1], c[2]), hit, table.concat(got, "|"))
end

-- Per-archive enable/disable and the main-page picker (0.5.0).
local lib2 = Library.new()
lib2.zims = {
    { base = "a.zim", paths = { "/x/a.zim" }, single = true },
    { base = "b.zim", paths = { "/x/b.zim" }, single = true },
    { base = "c.zim", paths = { "/x/c.zim" }, single = true },
}
for _, e in ipairs(lib2.zims) do lib2.by_base[e.base] = e end
check("all ZIMs enabled by default", lib2:activeCount() == 3)
lib2:setDisabled("b.zim", true)
check("disabled ZIM leaves the active set", lib2:activeCount() == 2)
check("disabled ZIM is still listed", #lib2.zims == 3)
check("activeZims skips the disabled one", lib2:activeZims()[2].base == "c.zim")
lib2:setDisabled("b.zim", false)
check("re-enabling restores it", lib2:activeCount() == 3)
lib2:setDisabled("a.zim", true)
lib2:setDisabled("b.zim", true)
lib2:setDisabled("c.zim", true)
check("every ZIM can be switched off", lib2:activeCount() == 0)
check("unknown ZIM is rejected", lib2:setDisabled("nope.zim", true) == false)

check("openMainPage takes a base argument", debug.getinfo(LocalWiki.openMainPage).nparams >= 2)
check("showAbout exists", type(LocalWiki.showAbout) == "function")
check("checkForUpdates exists", type(LocalWiki.checkForUpdates) == "function")

print(string.format("\n%d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
LUA

cd "$KO/lib/koreader"
SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" ./luajit "$WORK/check.lua"

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.10] — 2026-11-17

### Fixed
- "Check for Updates" no longer fails with "File exists" when creating its
  working folder. The folder is created directly and an existing one is
  treated as success instead of an error.
- Backup folders from previous updates are cleaned up after a successful
  install instead of piling up next to the plugin.

## [0.6.9] — 2026-11-17

### Fixed
- Reading a ZIM on Android no longer crashes KOReader with SIGSEGV as soon as
  an article opens. ZIM clusters carry no content-size header, so the plugin
  fell through to zstd's streaming API — which the Android build's bundled
  zstd does not expose, faulting at address 0x0. Frames without a known size
  are now decoded with a growing destination buffer instead, which lands on
  the first attempt for typical compression ratios.
- zstd/lzma are now resolved the way KOReader itself resolves them
  (`ffi.findlib`), so Android finds them inside `libkoreader-monolibtic.so`
  and the Kindle keeps using its own `libzstd.so.1`.
- FFI calls keep a strong reference to their input string. The raw pointer
  handed to C could outlive the Lua string behind it once the GC ran.

### Changed
- The "Offline Wikipedia" button now actually shows up in the dictionary
  window. KOReader has no `show_func` field in its dictionary button spec —
  the old one was silently ignored — and conditional buttons only render when
  a `default_layout` exists, which is usually not the case once a
  `dict_button_config` has been saved.
- The button is no longer stripped out of a saved dictionary layout on every
  lookup and every start.
- The lookup window preloads the article intro on Android too. The old
  platform carve-out showed "Tap to open article." because eager cluster work
  used to crash there; the crash was the decompression path, not the window.

## [0.6.8] — 2026-11-17

### Fixed
- Android KOReader's monolibtic build can now provide zstd/lzma decompression
  instead of reporting that libzstd is unavailable.

## [0.6.7] — 2026-11-17

### Fixed
- Android KOReader builds without `dictionary:addToDictButtons` can now load
  the plugin instead of aborting initialization.
- Highlight-menu registration now checks for the API before use.

## [0.6.6] — 2026-11-17

### Fixed
- Android title searches no longer build or use the legacy word index.
- Android lookup results avoid eager ZIM article and bitmap decoding.
- Prefix searches normalize uppercase ZIM title candidates.
- Title-index and entry-resolution failures are guarded instead of reaching the UI.

## [0.6.5] — 2026-11-17

### Changed
- Moved the LocalWiki entry into **Search > Settings**.

## [0.6.4] — 2026-11-17

### Changed
- Moved the LocalWiki entry from **More tools** to the main **Search** menu, next to Wikipedia.

## [0.6.3] — 2026-11-17

### Added
- Update LocalWiki directly from the **Check for updates** menu.

## [0.6.2] — 2026-11-17

### Added
- Improved article search and ranking for titles that contain the query.
- Popularity metadata support for scored ZIM archives.
- Persistent archive enable/disable settings.
- Image limits from no images to all images in full articles.
- LocalWiki plugin icon and simplified user documentation.

## [0.5.1] — Unreleased

### Fixed
- **Crash while browsing a long article** (`Killed` in `crash.log`, OOM killer
  taking `reader.lua` at ~240 MB RSS). Four things held memory that no longer
  had a use: the previous viewer was closed but kept referenced, the cleaned
  HTML of the last two articles stayed in an LRU, every decoded image blob and
  extracted image file survived the article that needed it, and up to six
  pictures were embedded per page. Each article now releases the previous one's
  document, HTML and images before loading its own, the article cache holds one
  entry, and the per-article image cap is four.
- **`showLoadedZims` crashed** with `attempt to call local '_' (a number
  value)`: the loop variable `_` shadowed the gettext function. Renamed.

### Added
- Per-archive switches, About, and Check for updates (see 0.5.0 below).

## [0.5.0] — Unreleased

### Added
- **Per-archive switches.** "Loaded ZIMs" now lists every archive with a
  checkbox, so a reader with Wikipedia, Wiktionary and a Fandom wiki in the
  same folder can keep only the ones they want. A disabled archive is skipped
  by search, lookup and the main page, and its file handles are closed.
- **About LocalWiki** menu entry: version, repository, licence, upstream
  credit, and how many archives were found and enabled.
- **Check for updates**: asks GitHub for the latest release and offers the
  release page when a newer version exists. Runs only when tapped.

### Fixed
- **Main page with several archives.** "Open main page" always opened the
  first ZIM in the folder, so with more than one archive there was no way to
  reach the others' home pages. It now asks which archive to open — or goes
  straight there when only one is enabled.
- **Main page could resolve to a redirect entry.** The ZIM header's main-page
  index points at a synthetic `mainPage` redirect, and the plugin returned
  that entry as-is, so opening the main page read a redirect record instead of
  an article. The redirect chain is now followed to the real article.

## [0.4.0] — Unreleased

The plugin was renamed from `wikipediazim` to `localwiki`. Existing settings
are migrated on first launch, so an upgrade keeps your folder, font and
history.

### Added
- Font face, line spacing and text margin are now selectable from the reader
  toolbar (previously only `A-` / `A+` existed, and the margin was not
  persisted).
- `tests/lua_smoke.lua` — exercises the ZIM reader, zstd decompression,
  Turkish search and the HTML cleaner against a generated archive, no
  KOReader required.
- `tests/make_test_zim.py` — builds a small valid ZIM v6 fixture (no
  third-party ZIM writer needed).
- `tests/run_koreader_check.sh` — loads the plugin inside a real KOReader
  runtime and verifies the plugin descriptor, every method KOReader calls,
  and end-to-end article reads.
- This changelog.

### Fixed
- `hookWikipediaModule` called `query_to_url()` before it was declared, so
  the prefix-search fallback inside the dictionary hook always failed. The
  hook now uses the first search candidate directly, and the now-unused
  helper is gone.
- The text margin reset to `0` on every launch even after the reader changed
  it; the saved value is now read back.
- `split_zim.py`'s docstring claimed 3 GiB default chunks while the code used
  1 GiB, and `parse_size()` mis-parsed values such as `3500MB`.
- `library.lua` contained mojibake (`â€"` instead of `—`) in comments and log
  strings.
- The test suite referenced the pre-rename class name `WikipediaZim` and had
  mojibake-encoded Turkish fixtures, which made 11 of 38 tests fail.

### Removed
- `LocalWiki:_loadArticleHtml()` — dead code, never called; `openEntry()`
  inlines the same work.
- `viewer.lua`'s unused `layout_metrics` table.

## [0.3.5]

- Rebrand the plugin to `localwiki.koplugin`; README credits the upstream
  project.

## [0.3.4]

- The lookup popup shows a few paragraphs again.

## [0.3.3]

- 19% faster cleaning, and HTML comments are actually removed.

## [0.3.2]

- Stop the OOM killer from taking KOReader down (byte-bounded cluster cache).

## [0.3.1]

- Images off leaves no holes; lookup keeps its picture.

## [0.3.0]

- Back to the 0.2.9 article layout, images behind one switch.

## [0.2.9]

- Keep the in-page lookup image at its own aspect ratio.

## [0.2.8]

- Two-row toolbar built with `ButtonTable`.

## [0.2.7]

- Faster image blanking when images are disabled.

## [0.2.5]

- Rebuild the infobox as a two-column table.

## [0.2.0]

- Initial public release: ZIM reading, search, link navigation, split-file
  support for FAT32.

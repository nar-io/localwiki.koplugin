# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

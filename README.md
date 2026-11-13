# LocalWiki for KOReader (`localwiki.koplugin`)

An offline Wikipedia and ZIM reader plugin for [KOReader](https://koreader.rocks/).

Browse and search offline [Kiwix ZIM files](https://library.kiwix.org/) directly on your e-reader (Kindle, Kobo, Android, PocketBook, etc.) — no conversion, no companion server, and no internet connection required.

---

## Features

- **Direct ZIM Reading:** Reads uncompressed and compressed ZIM clusters (`zstd` and `lzma`) on-the-fly using KOReader's bundled libraries.
- **Multi-Archive Discovery:** Automatically detects and searches across all ZIM archives located in your library folder.
- **FAT32 Large File Support:** Reads split ZIM files (`.zimaa`, `.zimab`, ...) seamlessly, overcoming the 4 GB FAT32 file size limit on Kindles and other devices.
- **Optimized for E-ink:** Sanitizes heavy Wikipedia Vector skin HTML, navigation templates, and unrenderable CSS for fast, responsive rendering via MuPDF.
- **Lookup & Dictionary Integration:** Integrates into KOReader's dictionary quick lookup and text selection menu.
- **Offline Link Navigation:** Tap internal article links to jump between articles, complete with full back/forward history navigation.
- **Customizable Reading:** Adjustable font sizes, font faces, line spacing, and optional image display.

---

## Repository Structure

```
plugins/localwiki.koplugin/
  _meta.lua         Plugin metadata
  main.lua          Menu, search dialog, history, selection hooks, and settings
  library.lua       Auto-discovery and multi-ZIM management
  zim.lua           ZIM file format reader (headers, dirents, URLs, redirects)
  cluster.lua       Decompression (libzstd / liblzma via FFI) + cluster cache
  splitfile.lua     Virtual reader for FAT32 split ZIM archives
  htmlclean.lua     Fast HTML sanitization and mobile card formatting for E-ink
  viewer.lua        Full-screen article viewer with touch navigation
split_zim.py        Desktop helper to split >4 GB ZIM files for FAT32 storage
```

---

## Quick Start Guide

### 1. Download a ZIM Archive
Download any `.zim` file from the [Kiwix Library](https://library.kiwix.org/):
- **Wikipedia English (Mini):** `wikipedia_en_all_mini` (~12 GB, text only)
- **Wikipedia Simple English:** `wikipedia_en_simple_all` (~300 MB, recommended for testing)
- **Other wikis:** Wiktionary, Wikiquote, Stack Overflow, Project Gutenberg, etc.

### 2. (Optional) Split for FAT32 Storage (Kindle devices)
FAT32 storage cannot store individual files larger than 4 GB. If your `.zim` file exceeds 4 GB, split it on your desktop computer:

```bash
python split_zim.py /path/to/wikipedia.zim --out /path/to/output_dir
```

This creates chunk files (`wikipedia.zimaa`, `wikipedia.zimab`, etc.) that the plugin automatically detects and handles as a single virtual archive.

### 3. Installation
1. Connect your e-reader to your computer via USB.
2. Download `localwiki.koplugin.zip` from [Releases](https://github.com/nar-io/localwiki.koplugin/releases) and extract `localwiki.koplugin` into your device's KOReader plugins directory:
   - `<koreader_folder>/plugins/localwiki.koplugin`
3. Create a `wikipedia` folder on your device storage (e.g. `/mnt/us/wikipedia/`) and place your `.zim` or split `.zim*` files inside.
4. Safely eject your device and launch KOReader.

---

## Usage

1. In KOReader, open the top menu.
2. Navigate to **Search / Tools** → **Wikipedia (offline)** (or **LocalWiki**).
3. Tap **Search articles** to look up any topic, or browse from your search history.
4. While reading a book, select any word or phrase and tap the Wikipedia action to view the article summary or read the full article offline.

---

## Credits & Acknowledgements

This project is based on and extends [c5e3/koreader_wikipedia](https://github.com/c5e3/koreader_wikipedia). Special thanks and full credit to the original author for creating the initial architecture, ZIM reader engine, and KOReader integration.

Additional credits:
- **[Kiwix](https://kiwix.org/)** — for creating and hosting the offline ZIM archives.
- **[KOReader](https://koreader.rocks/)** — for the outstanding e-reader platform and bundled libraries (libzstd, liblzma, MuPDF).
- **Wikipedia / Wikimedia contributors** — for the open knowledge and articles.

---

## License

This project is released under the **Creative Commons Attribution-NonCommercial 4.0 International** license (CC BY-NC 4.0). See [LICENSE](LICENSE) for details.

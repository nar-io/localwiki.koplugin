## What's fixed

**KOReader no longer crashes when you open a ZIM on Android.** Any article used to close the app the moment it loaded. That's fixed.

**The "Offline Wikipedia" button now shows up in the dictionary popup.** It was registered before but never drawn. Tap a word and it's there.

**The lookup popup shows the article text on Android too.** It used to say "Tap to open article." instead; now it shows the lead paragraph and its image straight away.

**"Check for Updates" works.** It failed on Android with a "File exists" error every time. One tap now updates the plugin in place.

## Notes

- Menu path: **Search → Search settings → Wikipedia (offline)**
- Backup folders from earlier updates are cleaned up after an update instead of piling up.

## Requirements

The dictionary-popup button needs KOReader **v2026.07.1** or newer — older builds don't have that button API. Everything else works on older versions too.

## Install

1. Download `localwiki.koplugin.zip` below and extract `localwiki.koplugin` into `koreader/plugins/`
2. Restart KOReader
3. **Search → Search settings → Wikipedia (offline)** → Search articles

## Verified on

- Nothing Phone 3 (Android 17, KOReader v2026.07.1)
- Kindle (KOReader v2026.07.1)

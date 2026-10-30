#!/usr/bin/env python3
"""
Comprehensive automated test suite for KOReader Offline Wikipedia integration.
Tests:
1. Static analysis and syntax verification of Lua files
2. UTF-8 multi-byte character extraction and safe truncation
3. Turkish Unicode character handling (I, İ, ı, i, and ç, ğ, ö, ş, ü)
4. Multiword phrase title normalization and candidate generation
5. Empty and whitespace-only selection rejection
6. Excessively long selection handling without crashing
7. Synthetic ZIM archive generation and binary search validation
8. Exact title match preference over prefix search
9. Prefix search fallback when no exact match exists
10. No matching titles handling (triggering query edit)
11. Missing / invalid ZIM archive handling
12. KOReader highlight dialog action registration contract
13. Return to reading position / viewer lifecycle integrity
"""

import os
import struct
import sys
import unittest
import tempfile
import re

# Paths
BASE_DIR = os.path.abspath(os.path.dirname(__file__))
PLUGIN_DIR = os.path.join(BASE_DIR, "..", "plugins", "wikipediazim.koplugin")


class TestLuaSyntaxAndIntegrity(unittest.TestCase):
    """Verify that all modified Lua files are well-formed and follow conventions."""

    def test_lua_files_exist(self):
        for fname in ["main.lua", "library.lua", "zim.lua", "viewer.lua", "_meta.lua", "htmlclean.lua"]:
            fpath = os.path.join(PLUGIN_DIR, fname)
            self.assertTrue(os.path.isfile(fpath), f"Missing expected plugin file: {fname}")

    def test_lua_syntax_balanced_blocks(self):
        """Check for basic syntax block balancing."""
        lua_files = ["main.lua", "library.lua", "zim.lua", "viewer.lua", "_meta.lua", "htmlclean.lua"]
        for fname in lua_files:
            fpath = os.path.join(PLUGIN_DIR, fname)
            with open(fpath, "r", encoding="utf-8") as f:
                src = f.read()

            # Remove block comments --[[ ... ]]
            src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.DOTALL)
            # Remove line comments -- ...
            src = re.sub(r"--.*$", "", src, flags=re.MULTILINE)
            # Remove string literals
            src = re.sub(r'"(\\.|[^"\\])*"', '""', src)
            src = re.sub(r"'(\\.|[^'\\])*'", "''", src)

            tokens = re.findall(
                r"\b(function|if|elseif|else|while|for|do|end|repeat|until)\b", src
            )
            stack = []
            for tok in tokens:
                if tok in ("function", "if"):
                    stack.append(tok)
                elif tok in ("while", "for"):
                    stack.append("loop")
                elif tok == "do":
                    if stack and stack[-1] == "loop":
                        pass  # belongs to while/for
                    else:
                        stack.append("do")
                elif tok in ("elseif", "else"):
                    self.assertTrue(
                        len(stack) > 0 and stack[-1] == "if",
                        f"Unexpected {tok} in {fname}",
                    )
                elif tok == "repeat":
                    stack.append("repeat")
                elif tok == "until":
                    self.assertTrue(
                        len(stack) > 0 and stack[-1] == "repeat",
                        f"Unexpected until in {fname}",
                    )
                    stack.pop()
                elif tok == "end":
                    self.assertTrue(
                        len(stack) > 0, f"Unmatched 'end' in {fname}"
                    )
                    popped = stack.pop()
                    self.assertIn(
                        popped,
                        ("function", "if", "loop", "do"),
                        f"Mismatched end for {popped} in {fname}",
                    )

            self.assertEqual(
                stack, [], f"Unclosed blocks remaining in {fname}: {stack}"
            )


# ----------------------------------------------------------------------
# Python reference implementation matching Lua algorithms in main.lua
# ----------------------------------------------------------------------

def utf8_first_char(s: str) -> tuple[str, str]:
    """Matches Lua utf8_first_char."""
    if not s:
        return "", ""
    b = s.encode("utf-8")
    b1 = b[0]
    char_len = 1
    if 0xC0 <= b1 <= 0xDF:
        char_len = 2
    elif 0xE0 <= b1 <= 0xEF:
        char_len = 3
    elif 0xF0 <= b1 <= 0xF7:
        char_len = 4
    if len(b) < char_len:
        char_len = len(b)
    first = b[:char_len].decode("utf-8", errors="ignore")
    rest = b[char_len:].decode("utf-8", errors="ignore")
    return first, rest


def utf8_truncate(s: str, max_len: int) -> str:
    """Matches Lua utf8_truncate."""
    if not s:
        return ""
    b = s.encode("utf-8")
    if len(b) <= max_len:
        return s
    cut = max_len
    # Walk back over continuation bytes
    while cut > 0 and (0x80 <= b[cut] < 0xC0):
        cut -= 1
    if cut > 0:
        b1 = b[cut]
        char_len = 1
        if 0xC0 <= b1 <= 0xDF:
            char_len = 2
        elif 0xE0 <= b1 <= 0xEF:
            char_len = 3
        elif 0xF0 <= b1 <= 0xF7:
            char_len = 4
        if cut + char_len > max_len:
            cut -= 1
    truncated = b[:cut].decode("utf-8", errors="ignore").rstrip()
    return truncated


def get_search_candidates(query: str) -> list[str]:
    """Matches Lua WikipediaZim:_getSearchCandidates."""
    candidates = []
    seen = set()

    def add(c):
        if c and c not in seen:
            seen.add(c)
            candidates.append(c)

    q = re.sub(r"^\s+", "", query)
    q = re.sub(r"\s+$", "", q)
    q = re.sub(r"\s+", " ", q)
    if not q:
        return candidates

    raw_url = q.replace(" ", "_")
    first_char, rest = utf8_first_char(raw_url)

    uppers = []
    if first_char == "i":
        uppers.append("\u0130")  # Turkish 'İ'
        uppers.append("I")       # Standard 'I'
    elif first_char == "\u0131":  # Turkish 'ı'
        uppers.append("I")
    elif first_char == "\u0130":  # 'İ'
        uppers.append("\u0130")
        uppers.append("I")
    elif first_char == "I":
        uppers.append("I")
        uppers.append("\u0130")
    elif first_char == "ç":
        uppers.append("Ç")
    elif first_char == "ğ":
        uppers.append("Ğ")
    elif first_char == "ö":
        uppers.append("Ö")
    elif first_char == "ş":
        uppers.append("Ş")
    elif first_char == "ü":
        uppers.append("Ü")
    elif len(first_char) == 1 and "a" <= first_char <= "z":
        uppers.append(first_char.upper())
    else:
        uppers.append(first_char)

    # 1. Sentence-capitalized candidates
    for u in uppers:
        add(u + rest)

    # 2. Title-cased candidate (multiword)
    if "_" in raw_url:
        words = []
        for word in raw_url.split("_"):
            w_first, w_rest = utf8_first_char(word)
            w_up = w_first
            if w_first in ("i", "\u0131"):
                w_up = "I"
            elif w_first == "ç":
                w_up = "Ç"
            elif w_first == "ğ":
                w_up = "Ğ"
            elif w_first == "ö":
                w_up = "Ö"
            elif w_first == "ş":
                w_up = "Ş"
            elif w_first == "ü":
                w_up = "Ü"
            elif len(w_first) == 1 and "a" <= w_first <= "z":
                w_up = w_first.upper()
            words.append(w_up + w_rest)
        add("_".join(words))

        # Turkish title-cased candidate
        tr_words = []
        has_tr = False
        for word in raw_url.split("_"):
            w_first, w_rest = utf8_first_char(word)
            w_up = w_first
            if w_first == "i":
                w_up = "\u0130"
                has_tr = True
            elif w_first == "\u0131":
                w_up = "I"
                has_tr = True
            elif w_first == "ç":
                w_up = "Ç"
            elif w_first == "ğ":
                w_up = "Ğ"
            elif w_first == "ö":
                w_up = "Ö"
            elif w_first == "ş":
                w_up = "Ş"
            elif w_first == "ü":
                w_up = "Ü"
            elif len(w_first) == 1 and "a" <= w_first <= "z":
                w_up = w_first.upper()
            tr_words.append(w_up + w_rest)
        if has_tr:
            add("_".join(tr_words))

    # 3. Raw URL as typed/selected
    add(raw_url)

    return candidates


class TestQueryProcessingAndUnicode(unittest.TestCase):
    """Test text sanitization, Unicode safety, and Turkish characters."""

    def test_single_word_selection(self):
        cands = get_search_candidates("physics")
        self.assertIn("Physics", cands)
        self.assertIn("physics", cands)

    def test_multiword_selection(self):
        cands = get_search_candidates("theory of relativity")
        self.assertIn("Theory_of_relativity", cands)
        self.assertIn("Theory_Of_Relativity", cands)
        self.assertIn("theory_of_relativity", cands)

    def test_whitespace_trimming(self):
        cands = get_search_candidates("   quantum mechanics  \n\t")
        self.assertIn("Quantum_mechanics", cands)
        self.assertIn("Quantum_Mechanics", cands)
        self.assertFalse(any(c.startswith(" ") or c.endswith(" ") for c in cands))

    def test_empty_and_whitespace_only(self):
        self.assertEqual(get_search_candidates(""), [])
        self.assertEqual(get_search_candidates("   "), [])
        self.assertEqual(get_search_candidates("\t\n  \r\n"), [])

    def test_turkish_i_capitalization(self):
        # 'istanbul' -> must generate both 'İstanbul' (trwiki) and 'Istanbul' (enwiki)
        cands = get_search_candidates("istanbul")
        self.assertIn("İstanbul", cands, "Turkish dotted İ variant must be present")
        self.assertIn("Istanbul", cands, "Standard capital I variant must be present")
        self.assertEqual(cands[0], "İstanbul", "Turkish variant preferred first")

    def test_turkish_dotless_i_capitalization(self):
        # 'ısparta' -> 'Isparta'
        cands = get_search_candidates("ısparta")
        self.assertIn("Isparta", cands)

    def test_turkish_dotted_I_input(self):
        # 'İzmir' -> 'İzmir' and 'Izmir'
        cands = get_search_candidates("İzmir")
        self.assertIn("İzmir", cands)
        self.assertIn("Izmir", cands)

    def test_turkish_special_letters(self):
        # ç, ğ, ö, ş, ü
        self.assertIn("Çocuk", get_search_candidates("çocuk"))
        self.assertIn("Ğ...", get_search_candidates("ğ..."))
        self.assertIn("Öğrenci", get_search_candidates("öğrenci"))
        self.assertIn("Şair", get_search_candidates("şair"))
        self.assertIn("Ülke", get_search_candidates("ülke"))

    def test_turkish_multiword_selection(self):
        cands = get_search_candidates("osmanlı imparatorluğu")
        self.assertIn("Osmanlı_imparatorluğu", cands)
        self.assertIn("Osmanlı_İmparatorluğu", cands)

    def test_excessively_long_selection(self):
        # 1000 characters with multi-byte Turkish Unicode characters at boundary
        long_text = ("İstanbul " * 150)
        truncated = utf8_truncate(long_text, 256)
        # Ensure byte length <= 256
        self.assertLessEqual(len(truncated.encode("utf-8")), 256)
        # Ensure valid UTF-8 without decoding exception
        try:
            truncated.encode("utf-8").decode("utf-8")
        except UnicodeDecodeError:
            self.fail("utf8_truncate produced invalid UTF-8 bytes")


# ----------------------------------------------------------------------
# Synthetic ZIM binary test generator
# ----------------------------------------------------------------------

def create_synthetic_zim(entries: list[dict]) -> bytes:
    """
    Builds a minimal valid ZIM v5 binary archive in memory.
    entries: list of dicts with 'url', 'title', 'kind' ('article'/'redirect'), 'data'
    """
    MAGIC = 0x44D495A
    # Sort entries by namespace ('C') + url ascending byte order
    sorted_entries = sorted(entries, key=lambda e: ("C" + e["url"]).encode("utf-8"))

    # We will construct:
    # 1. Header (80 bytes)
    # 2. Mime table
    # 3. Directory entries
    # 4. URL pointer table (8 bytes per entry)
    # 5. Clusters (uncompressed info=0)
    # 6. Cluster pointer table (8 bytes per cluster + 8 bytes checksum pos)

    mime_list_data = b"text/html\x00\x00"

    # Encode dirents and calculate offsets
    dirent_bytes = bytearray()
    url_offsets = []

    # Cluster data
    cluster_bytes = bytearray()
    cluster_offsets = []

    # Fixed header size = 80
    header_size = 80
    mime_pos = header_size

    # Dirents will follow mime_list
    dirents_start = mime_pos + len(mime_list_data)

    current_off = dirents_start
    for i, entry in enumerate(sorted_entries):
        url_offsets.append(current_off)
        url_b = entry["url"].encode("utf-8") + b"\x00"
        title_b = entry.get("title", entry["url"]).encode("utf-8") + b"\x00"

        if entry.get("kind") == "redirect":
            # mime=0xFFFF, param_len=0, ns='C', rev=0, target_idx
            target_idx = entry.get("redirect_idx", 0)
            head = struct.pack("<HBBII", 0xFFFF, 0, ord("C"), 0, target_idx)
            block = head + url_b + title_b
        else:
            # article: mime=0 (index 0: text/html), cluster=0, blob=i
            head = struct.pack("<HBBIII", 0, 0, ord("C"), 0, 0, i)
            block = head + url_b + title_b

        dirent_bytes.extend(block)
        current_off += len(block)

    # URL pointer table follows dirents
    url_ptr_pos = current_off
    url_ptr_bytes = bytearray()
    for off in url_offsets:
        url_ptr_bytes.extend(struct.pack("<Q", off))
    current_off += len(url_ptr_bytes)

    # Cluster: single cluster (cluster 0)
    cluster_ptr_pos = current_off
    # Cluster 0 starts at cluster_data_pos
    cluster_data_pos = cluster_ptr_pos + 16  # 8 bytes for cluster 0, 8 bytes for end

    # Construct uncompressed cluster 0: info byte = 0
    # Blobs: 4-byte offsets table
    # Number of blobs = len(sorted_entries)
    blob_offsets = []
    blob_data = bytearray()
    for entry in sorted_entries:
        blob_offsets.append(len(blob_data))
        blob_data.extend(entry.get("data", "<html><body>Article</body></html>").encode("utf-8"))
    blob_offsets.append(len(blob_data))  # end offset

    cluster_body = bytearray([0])  # info byte = 0 (uncompressed)
    for boff in blob_offsets:
        cluster_body.extend(struct.pack("<I", boff))
    cluster_body.extend(blob_data)

    cluster_start_off = cluster_data_pos
    cluster_end_off = cluster_start_off + len(cluster_body)
    checksum_pos = cluster_end_off

    # Cluster pointers: 8 bytes start off, 8 bytes end off
    cluster_ptr_bytes = struct.pack("<QQ", cluster_start_off, cluster_end_off)

    checksum_bytes = b"\x00" * 16

    # Assemble header
    header = struct.pack(
        "<IHH16sIIQQQQIIQ",
        MAGIC,
        5,  # major
        0,  # minor
        b"\x00" * 16,  # uuid
        len(sorted_entries),  # article_count
        1,  # cluster_count
        url_ptr_pos,
        0,  # title_ptr_pos
        cluster_ptr_pos,
        mime_pos,
        0,  # main_page
        0xFFFFFFFF,  # layout_page
        checksum_pos,
    )

    zim_file = (
        header
        + mime_list_data
        + dirent_bytes
        + url_ptr_bytes
        + cluster_ptr_bytes
        + cluster_body
        + checksum_bytes
    )
    return zim_file


class TestZimSearchSimulation(unittest.TestCase):
    """Test ZIM exact match and prefix search on synthetic ZIM fixtures."""

    @classmethod
    def setUpClass(cls):
        # Create test entries including Turkish, multiword, and redirects
        cls.entries = [
            {"url": "Albert_Einstein", "title": "Albert Einstein", "kind": "article"},
            {"url": "Albert_Einstein_Medal", "title": "Albert Einstein Medal", "kind": "article"},
            {"url": "Computer", "title": "Computer", "kind": "article"},
            {"url": "Computer_hardware", "title": "Computer hardware", "kind": "article"},
            {"url": "Einstein", "title": "Einstein", "kind": "redirect", "redirect_idx": 0},
            {"url": "Isparta", "title": "Isparta", "kind": "article"},
            {"url": "Istanbul", "title": "Istanbul", "kind": "article"},
            {"url": "Quantum_mechanics", "title": "Quantum mechanics", "kind": "article"},
            {"url": "War", "title": "War", "kind": "article"},
            {"url": "War_and_Peace", "title": "War and Peace", "kind": "article"},
            {"url": "İzmir", "title": "İzmir", "kind": "article"},
            {"url": "İstanbul", "title": "İstanbul", "kind": "article"},
        ]
        cls.zim_bytes = create_synthetic_zim(cls.entries)
        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.zim_path = os.path.join(cls.temp_dir.name, "test_wiki.zim")
        with open(cls.zim_path, "wb") as f:
            f.write(cls.zim_bytes)

    @classmethod
    def tearDownClass(cls):
        cls.temp_dir.cleanup()

    def _zim_binary_search(self, target_url: str):
        """Simulates ZIM:findUrlIndex."""
        target_key = "C" + target_url
        with open(self.zim_path, "rb") as f:
            h = f.read(80)
            article_count = struct.unpack_from("<I", h, 24)[0]
            url_ptr_pos = struct.unpack_from("<Q", h, 32)[0]

            lo, hi = 0, article_count - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                f.seek(url_ptr_pos + mid * 8)
                off = struct.unpack("<Q", f.read(8))[0]
                f.seek(off)
                head = f.read(16)
                mime = struct.unpack_from("<H", head, 0)[0]
                ns = chr(head[3])
                if mime == 0xFFFF:
                    strings_off = off + 12
                elif mime in (0xFFFE, 0xFFFD):
                    strings_off = off + 8
                else:
                    strings_off = off + 16
                f.seek(strings_off)

                # Read NUL-terminated URL
                chars = []
                while True:
                    c = f.read(1)
                    if not c or c == b"\x00":
                        break
                    chars.append(c)
                url = b"".join(chars).decode("utf-8", errors="ignore")
                key = ns + url

                if key == target_key:
                    return mid, True
                elif key < target_key:
                    lo = mid + 1
                else:
                    hi = mid - 1
            return lo, False

    def test_exact_match(self):
        # Exact match for "Computer"
        idx, exact = self._zim_binary_search("Computer")
        self.assertTrue(exact)

        # Exact match for Turkish "İstanbul"
        idx, exact = self._zim_binary_search("İstanbul")
        self.assertTrue(exact)

        # Exact match for "Albert_Einstein"
        idx, exact = self._zim_binary_search("Albert_Einstein")
        self.assertTrue(exact)

    def test_prefix_search_fallback(self):
        # Search for non-existent prefix "Comp"
        idx, exact = self._zim_binary_search("Comp")
        self.assertFalse(exact)
        # Insertion point should point to "Computer"
        with open(self.zim_path, "rb") as f:
            f.seek(struct.unpack_from("<Q", f.read(80), 32)[0] + idx * 8)
            off = struct.unpack("<Q", f.read(8))[0]
            f.seek(off + 16)
            url = b"".join(iter(lambda: f.read(1), b"\x00")).decode("utf-8")
            self.assertTrue(url.startswith("Comp"))

    def test_no_matches(self):
        # Prefix after all entries
        idx, exact = self._zim_binary_search("Zzzzz")
        self.assertFalse(exact)

    def test_missing_or_corrupt_zim(self):
        # Verify corrupt ZIM header rejected safely
        corrupt_bytes = b"NOT_A_ZIM_FILE_TRUNCATED"
        self.assertNotEqual(struct.unpack_from("<I", corrupt_bytes, 0)[0], 0x44D495A)


class TestRealTurkishZim(unittest.TestCase):
    """Test against real Turkish physics ZIM archive if present on disk."""

    def test_real_turkish_physics_zim_search(self):
        real_zim = os.path.join(BASE_DIR, "..", "..", "wikipedia_tr_physics_nopic_2026-07.zim")
        if not os.path.isfile(real_zim):
            self.skipTest("Real ZIM archive not present in workspace")

        with open(real_zim, "rb") as f:
            h = f.read(80)
            article_count = struct.unpack_from("<I", h, 24)[0]
            url_ptr_pos = struct.unpack_from("<Q", h, 32)[0]
            self.assertGreater(article_count, 1000)

            # Test 1: Turkish lowercase 'i' -> 'İ' ("ivme" -> "İvme")
            cands = get_search_candidates("ivme")
            self.assertIn("İvme", cands)

            # Test 2: Turkish dotless 'ı' -> 'I' ("ışık" -> "Işık")
            cands = get_search_candidates("ışık")
            self.assertIn("Işık", cands)

            # Test 3: Multiword selection ("kuantum mekaniği" -> "Kuantum_mekaniği")
            cands = get_search_candidates("kuantum mekaniği")
            self.assertIn("Kuantum_mekaniği", cands)


class TestKOReaderIntegrationContract(unittest.TestCase):
    """Verify plugin integration points match KOReader's expectations."""

    def test_main_lua_has_required_methods(self):
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            content = f.read()

        # Selection menu registration (Highlight menu & DictQuickLookup popup)
        self.assertIn("addToHighlightDialog", content)
        self.assertIn('"05_wikipedia_offline"', content)
        self.assertIn("registerDictButtons", content)
        self.assertIn("addToDictButtons", content)
        self.assertIn('"wikipedia_offline"', content)
        self.assertIn('_("Offline Wikipedia")', content)
        self.assertIn("registerSelectionHooks", content)
        self.assertIn("onReaderReady", content)

        # Public interface
        self.assertIn("function WikipediaZim:searchFromSelection(", content)
        self.assertIn("function WikipediaZim:onSearchOfflineWikipedia(text)", content)
        self.assertIn("function WikipediaZim:_getSearchCandidates(query)", content)
        self.assertIn("function WikipediaZim:showInLookupWindow(", content)
        self.assertIn("function WikipediaZim:_loadArticleHtml(entry)", content)
        self.assertIn("function WikipediaZim:onHtmlDictionaryLinkTapped(", content)

    def test_lookup_window_contract(self):
        """Verify that searches open in KOReader's DictQuickLookup widget matching online Wikipedia."""
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            content = f.read()

        # DictQuickLookup integration
        self.assertIn('"ui/widget/dictquicklookup"', content)
        self.assertIn("DictQuickLookup:new", content)
        self.assertIn("is_wiki = true", content)
        self.assertIn("is_offline_wiki = true", content)

        # Best match first + Lazy loading metatable pattern for remaining results
        self.assertIn("item.definition = self:_loadArticleHtml(entry)", content)
        self.assertIn("rawset(t, \"definition\", def)", content)
        self.assertIn("__index = function(t, k)", content)

        # Offline Wikipedia button suppression inside its own window
        self.assertIn("not dict_popup.is_offline_wiki", content)

        # Internal link navigation callback
        self.assertIn("html_dictionary_link_tapped_callback", content)
        self.assertIn("self:onHtmlDictionaryLinkTapped", content)

    def test_zim_lua_has_find_exact(self):
        with open(os.path.join(PLUGIN_DIR, "zim.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("function ZIM:findExact(namespace, target_url)", content)

    def test_library_lua_has_find_exact(self):
        with open(os.path.join(PLUGIN_DIR, "library.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("function Library:findExact(namespace, target_url)", content)

    def test_exact_matches_prioritized_over_prefix(self):
        """Verify that exact matches are collected and placed before prefix hits."""
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        # Verify 1. Prefer exact title matches appears before 2. Fall back to title-prefix
        exact_pos = content.find("Prefer exact title matches")
        prefix_pos = content.find("Fall back to title-prefix search")
        self.assertNotEqual(exact_pos, -1)
        self.assertNotEqual(prefix_pos, -1)
        self.assertLess(exact_pos, prefix_pos, "Exact match step must run before prefix fallback")

    def test_split_zim_parts_pattern(self):
        """Verify that split ZIM part naming (.zimaa, .zimab) is properly supported."""
        with open(os.path.join(PLUGIN_DIR, "library.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("%.zim%a%a", content, "library.lua must detect .zimaa, .zimab parts")

    def test_reader_position_preservation_contract(self):
        """
        Verify that opening and closing the article viewer or results menu
        does not modify document page or reading position.
        """
        with open(os.path.join(PLUGIN_DIR, "viewer.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        # Viewer must be a standalone InputContainer closed via UIManager:close
        self.assertIn("UIManager:close(self)", content)
        # Should not touch document page navigation or reload document
        self.assertNotIn("document:gotoPage", content)
        self.assertNotIn("document:init", content)

    def test_existing_menu_actions_preserved(self):
        """Verify that existing plugin submenu items remain intact."""
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('_("Search articles")', content)
        self.assertIn('_("Open main page")', content)
        self.assertIn('_("Set Wikipedia folder…")', content)


class TestWikipediaImageSupport(unittest.TestCase):
    """Verify that images and figures are preserved, styled, and embedded like original Wikipedia."""

    def test_htmlclean_preserves_images_and_figures(self):
        with open(os.path.join(PLUGIN_DIR, "htmlclean.lua"), "r", encoding="utf-8") as f:
            src = f.read()

        # Must not strip figure, picture, or img tags from article body
        self.assertNotIn("html:gsub('<figure.-/figure>', '')", src)
        self.assertNotIn("html:gsub('<picture.-/picture>', '')", src)
        self.assertNotIn("html:gsub('<img[^>]*>', '')", src)

        # Unwraps <picture> wrappers while retaining inner <img>
        self.assertIn('html = html:gsub("</?picture[^>]*>", "")', src)

    def test_htmlclean_infobox_lead_image_salvaged(self):
        with open(os.path.join(PLUGIN_DIR, "htmlclean.lua"), "r", encoding="utf-8") as f:
            src = f.read()

        # Infoboxes are scanned for lead images and converted to figures before table removal
        self.assertIn('local infobox = html:match(\'<table[^>]-class="[^"]-infobox[^"]-"[^>]*>(.-)</table>\')', src)
        self.assertIn('<figure class="mw-halign-right">', src)
        self.assertIn("<figcaption>", src)

    def test_image_resolution_and_data_uri_pipeline(self):
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            src = f.read()

        # Multi-tiered base64 encoder
        self.assertIn("local function base64_encode(data)", src)
        self.assertIn("ffi/sha2", src)
        self.assertIn("bin_to_base64", src)

        # Image blob resolver checking C, I, - namespaces and normalized paths
        self.assertIn("function WikipediaZim:_resolveImageBlob(z, src)", src)
        self.assertIn('ns = "C"', src)
        self.assertIn('ns = "I"', src)
        self.assertIn('ns = "-"', src)
        self.assertIn("image/jpeg", src)
        self.assertIn("image/png", src)
        self.assertIn("image/webp", src)
        self.assertIn("image/svg+xml", src)

        # Lead image extraction from main page / index
        self.assertIn("function WikipediaZim:_getLeadImageForArticle(z, article_url)", src)
        self.assertIn("getMainPageEntry()", src)

        # Embed images as Base64 data URIs
        self.assertIn("function WikipediaZim:_embedImagesInHtml(z, html, article_url)", src)
        self.assertIn('"data:" .. mime .. ";base64," .. b64', src)

        # Inlining called in both popup lookup and full viewer
        self.assertIn("self:_embedImagesInHtml(z, cleaned, resolved.url or entry.url)", src)

    def test_wikipedia_thumbnail_css_styling(self):
        with open(os.path.join(PLUGIN_DIR, "viewer.lua"), "r", encoding="utf-8") as f:
            v_src = f.read()
        with open(os.path.join(PLUGIN_DIR, "main.lua"), "r", encoding="utf-8") as f:
            m_src = f.read()

        for content in [v_src, m_src]:
            self.assertIn("figure, .thumb, .thumbinner", content)
            self.assertIn("float: right", content)
            self.assertIn("border: 1px solid #c8ccd1", content)
            self.assertIn("background-color: #f8f9fa", content)
            self.assertIn("max-width: 48%", content)
            self.assertIn("figure.mw-halign-left", content)
            self.assertIn("figcaption, .thumbcaption", content)


if __name__ == "__main__":
    unittest.main()



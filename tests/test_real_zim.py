#!/usr/bin/env python3
"""
Test against real Turkish ZIM archive: wikipedia_tr_physics_nopic_2026-07.zim
"""

import os
import struct
import sys
sys.path.insert(0, os.path.dirname(__file__))
from test_offline_wikipedia import get_search_candidates

ZIM_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "wikipedia_tr_physics_nopic_2026-07.zim")


def read_cstring(f):
    chars = []
    while True:
        c = f.read(1)
        if not c or c == b"\x00":
            break
        chars.append(c)
    return b"".join(chars).decode("utf-8", errors="ignore")


def dirent_offset(f, url_ptr_pos, idx):
    f.seek(url_ptr_pos + idx * 8)
    return struct.unpack("<Q", f.read(8))[0]


def read_url_at(f, off):
    f.seek(off)
    head = f.read(4)
    mime = struct.unpack_from("<H", head, 0)[0]
    ns = chr(head[3])
    if mime == 0xFFFF:
        strings_off = off + 12
    elif mime in (0xFFFE, 0xFFFD):
        strings_off = off + 8
    else:
        strings_off = off + 16
    f.seek(strings_off)
    return ns, read_cstring(f)


def read_dirent(f, off):
    f.seek(off)
    head = f.read(16)
    mime = struct.unpack_from("<H", head, 0)[0]
    ns = chr(head[3])
    entry = {"mime": mime, "namespace": ns}
    if mime == 0xFFFF:
        entry["kind"] = "redirect"
        strings_off = off + 12
    elif mime in (0xFFFE, 0xFFFD):
        entry["kind"] = "deleted"
        strings_off = off + 8
    else:
        entry["kind"] = "article"
        strings_off = off + 16
    f.seek(strings_off)
    entry["url"] = read_cstring(f)
    entry["title"] = read_cstring(f)
    if not entry["title"]:
        entry["title"] = entry["url"]
    return entry


def find_url_index(f, url_ptr_pos, article_count, namespace, target_url):
    target_key = namespace + target_url
    lo, hi = 0, article_count - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        off = dirent_offset(f, url_ptr_pos, mid)
        ns, url = read_url_at(f, off)
        key = ns + url
        if key == target_key:
            return mid, True
        elif key < target_key:
            lo = mid + 1
        else:
            hi = mid - 1
    return lo, False


def main():
    if not os.path.exists(ZIM_PATH):
        print(f"Archive not found: {ZIM_PATH}")
        return

    with open(ZIM_PATH, "rb") as f:
        h = f.read(80)
        article_count = struct.unpack_from("<I", h, 24)[0]
        url_ptr_pos = struct.unpack_from("<Q", h, 32)[0]
        print(f"Loaded {os.path.basename(ZIM_PATH)}: {article_count} articles")

        test_queries = [
            "fizik",
            "ısı",
            "ışık",
            "ivme",
            "kuantum mekaniği",
            "albert einstein",
            "görelilik",
        ]
        for q in test_queries:
            cands = get_search_candidates(q)
            print(f"\nQuery: '{q}' -> Candidates: {cands}")

            # Exact match check
            exact_hits = []
            for c in cands:
                idx, exact = find_url_index(f, url_ptr_pos, article_count, "C", c)
                if exact:
                    entry = read_dirent(f, dirent_offset(f, url_ptr_pos, idx))
                    exact_hits.append(entry)
            exact_titles = [e["title"] for e in exact_hits]
            print(f"  Exact matches: {exact_titles}")

            # Prefix search check
            prefix_hits = []
            for c in cands:
                idx, exact = find_url_index(f, url_ptr_pos, article_count, "C", c)
                for i in range(idx, min(idx + 10, article_count)):
                    off = dirent_offset(f, url_ptr_pos, i)
                    ns, url = read_url_at(f, off)
                    if ns != "C" or not url.startswith(c):
                        break
                    entry = read_dirent(f, off)
                    if entry["kind"] != "deleted":
                        if entry["url"] not in [p["url"] for p in prefix_hits]:
                            prefix_hits.append(entry)
            prefix_titles = [e["title"] for e in prefix_hits[:5]]
            print(f"  Prefix matches (first 5): {prefix_titles}")


if __name__ == "__main__":
    main()

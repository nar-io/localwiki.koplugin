#!/usr/bin/env python3
"""
Ad-hoc profiler: report how much of a real ZIM article the cleaner removes.

This is a manual investigation tool, not part of the test suite — it needs a
real ZIM on disk and the `zstandard` package.

    python3 tests/profile_article.py path/to/wiki.zim [url ...]

URLs are `namespace + url` without a separator, e.g. `CBasketball`.
"""
import os
import re
import struct
import sys

try:
    import zstandard
except ImportError:  # pragma: no cover - manual tool
    sys.exit("this tool needs the 'zstandard' package: pip install zstandard")

DEFAULT_QUERIES = ["CBasketball", "CMichael_Jordan"]


def strip_balanced(html, start_pat, nest_open, close_str):
    out = []
    pos = 0
    nest_len = len(nest_open)
    close_len = len(close_str)
    while True:
        m = re.search(start_pat, html[pos:])
        if not m:
            out.append(html[pos:])
            return "".join(out)
        s = pos + m.start()
        e = pos + m.end()
        out.append(html[pos:s])
        depth = 1
        i = e
        while depth > 0:
            oo = html.find(nest_open, i)
            cc = html.find(close_str, i)
            if cc == -1:
                out.append(html[s:])
                return "".join(out)
            if oo != -1 and oo < cc:
                depth += 1
                i = oo + nest_len
            else:
                depth -= 1
                i = cc + close_len
        pos = i


def find_article(f, url_ptr, count, query):
    """Binary-search the URL pointer list for `query` (namespace + url)."""
    lo, hi = 0, count - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        f.seek(url_ptr + mid * 8)
        off = struct.unpack("<Q", f.read(8))[0]
        f.seek(off)
        head = f.read(4)
        mime = struct.unpack_from("<H", head, 0)[0]
        ns = chr(head[3])
        soff = off + (16 if mime < 0xFFFD else (12 if mime == 0xFFFF else 8))
        f.seek(soff)
        u = b""
        while True:
            c = f.read(1)
            if not c or c == b"\x00":
                break
            u += c
        key = ns + u.decode("utf-8", errors="ignore")
        if key == query:
            return mid
        if key < query:
            lo = mid + 1
        else:
            hi = mid - 1
    return None


def read_article(f, url_ptr, cluster_ptr, idx):
    f.seek(url_ptr + idx * 8)
    off = struct.unpack("<Q", f.read(8))[0]
    f.seek(off + 8)
    c_idx, b_idx = struct.unpack("<II", f.read(8))

    f.seek(cluster_ptr + c_idx * 8)
    cs, ce = struct.unpack("<QQ", f.read(16))
    f.seek(cs)
    info = f.read(1)[0]
    raw = f.read(ce - cs - 1)
    if (info & 0x0F) != 5:
        raise SystemExit(f"cluster {c_idx} is not zstd-compressed (info byte {info:#04x})")
    decomp = zstandard.ZstdDecompressor().decompress(raw, max_output_size=64 * 1024 * 1024)
    # Extended clusters use 8-byte offsets; classic ones use 4.
    off_size = 8 if info & 0x10 else 4
    fmt = "<Q" if off_size == 8 else "<I"
    lo_b = struct.unpack_from(fmt, decomp, b_idx * off_size)[0]
    hi_b = struct.unpack_from(fmt, decomp, (b_idx + 1) * off_size)[0]
    return decomp[lo_b:hi_b].decode("utf-8", errors="replace")


def clean(html):
    """Rough mirror of htmlclean.lua's passes, for profiling only."""
    m_b = re.search(r'<div\s+class="[^"]*mw[_-]parser[_-]output', html)
    if m_b:
        html = html[m_b.start():]
    html = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
    html = re.sub(r"<script\b[^>]*>.*?</script>", "", html, flags=re.DOTALL)
    html = re.sub(r"<style\b[^>]*>.*?</style>", "", html, flags=re.DOTALL)
    html = re.sub(r"<noscript\b[^>]*>.*?</noscript>", "", html, flags=re.DOTALL)
    for cls, tag in [("navbox", "table"), ("navbox", "div"), ("toccolours", "table"),
                     ("catlinks", "div"), ("printfooter", "div"), ("ambox", "div"),
                     ("metadata", "div")]:
        html = strip_balanced(html, rf'<{tag}\s+[^>]*class="[^"]*{cls}[^"]*"',
                              f"<{tag}", f"</{tag}>")
    html = re.sub(r'<span\s+[^>]*id="coordinates"[^>]*>.*?</span>', "", html, flags=re.DOTALL)
    html = re.sub(r'<div\s+[^>]*id="coordinates"[^>]*>.*?</div>', "", html, flags=re.DOTALL)
    html = re.sub(r'\s+style="[^"]*?(?:width|float|position|clear|margin)[^"]*?"', "", html)
    return html


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    zim_path = sys.argv[1]
    queries = sys.argv[2:] or DEFAULT_QUERIES

    if not os.path.exists(zim_path):
        sys.exit(f"archive not found: {zim_path}")

    with open(zim_path, "rb") as f:
        h = f.read(80)
        count = struct.unpack_from("<I", h, 24)[0]
        url_ptr = struct.unpack_from("<Q", h, 32)[0]
        cluster_ptr = struct.unpack_from("<Q", h, 48)[0]
        print(f"{os.path.basename(zim_path)}: {count} entries")

        for query in queries:
            idx = find_article(f, url_ptr, count, query)
            if idx is None:
                print(f"\n{query}: not found")
                continue
            html = read_article(f, url_ptr, cluster_ptr, idx)
            h_clean = clean(html)
            saved = (1 - len(h_clean) / len(html)) * 100 if html else 0
            print(f"\n{query}")
            print(f"  original : {len(html):>9,} bytes")
            print(f"  cleaned  : {len(h_clean):>9,} bytes  ({saved:.1f}% smaller)")
            print(f"  tables   : {len(re.findall(r'<table', h_clean))} left")


if __name__ == "__main__":
    main()

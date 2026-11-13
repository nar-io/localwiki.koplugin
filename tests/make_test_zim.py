#!/usr/bin/env python3
"""
Minimal ZIM v6 writer — builds a small, valid archive for testing the
KOReader plugin end to end (header, MIME list, URL pointer list, dirents,
zstd-compressed clusters, MD5 checksum).

Usage:  python3 make_test_zim.py out.zim
"""
import hashlib
import struct
import sys
import zstandard

MAGIC = 0x44D495A
NS_ARTICLES = b"C"
NS_IMAGES = b"I"

ARTICLES = [
    ("Ana_Sayfa", "Ana Sayfa",
     "<html><body><div class=\"mw-parser-output\">"
     "<h1 id=\"firstHeading\">Ana Sayfa</h1>"
     "<p>Vikipedi'ye hoş geldiniz. Bu çevrimdışı bir test arşividir.</p>"
     "<p>İstanbul, Türkiye'nin en kalabalık şehridir.</p>"
     "</div></body></html>"),
    ("İstanbul", "İstanbul",
     "<html><body><div class=\"mw-parser-output\">"
     "<h1 id=\"firstHeading\">İstanbul</h1>"
     "<table class=\"infobox\"><tr><th>Ülke</th><td>Türkiye</td></tr>"
     "<tr><th>Nüfus</th><td>15.840.900</td></tr></table>"
     "<p>İstanbul, Marmara Bölgesi'nde yer alan bir şehirdir. "
     "Boğaziçi'nde iki kıtaya yayılır.</p>"
     "<h2 id=\"Tarih\">Tarih</h2>"
     "<p>Bizantion adıyla kurulmuştur.<sup class=\"reference\">[1]</sup></p>"
     "<div class=\"navbox\">NAVBOX GURULTUSU</div>"
     "<ol class=\"references\"><li>Kaynak 1</li></ol>"
     "</div></body></html>"),
    ("Fizik", "Fizik",
     "<html><body><div class=\"mw-parser-output\">"
     "<h1 id=\"firstHeading\">Fizik</h1>"
     "<p>Fizik, madde ve enerji arasındaki etkileşimi inceleyen bilim dalıdır.</p>"
     "<p>İstanbul sayfasına gitmek için <a href=\"İstanbul\">buraya</a> dokunun.</p>"
     "</div></body></html>"),
    ("Çocuk", "Çocuk",
     "<html><body><div class=\"mw-parser-output\">"
     "<h1 id=\"firstHeading\">Çocuk</h1>"
     "<p>Çocuk, ergenlik öncesi insan yavrusudur.</p>"
     "</div></body></html>"),
    ("Işık", "Işık",
     "<html><body><div class=\"mw-parser-output\">"
     "<h1 id=\"firstHeading\">Işık</h1>"
     "<p>Işık, elektromanyetik dalgaların görülebilen kısmıdır.</p>"
     "</div></body></html>"),
]

# A 1x1 PNG so the image path can be exercised.
PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082"
)
IMAGES = [("logo.png", "logo.png", PNG_1PX)]

MIMES = ["text/html", "image/png"]


def cstring(s):
    return s.encode("utf-8") + b"\0"


def build_cluster(blobs, compress=True):
    """One cluster holding `blobs`, offsets table first (extended = 8-byte).

    The offsets table has N+1 entries: offsets[i] is where blob i starts and
    the final entry is the end of the last blob. A table with only N entries
    makes readers read the first blob's bytes as an offset.
    """
    count = len(blobs)
    header_size = (count + 1) * 8
    offsets = []
    running = header_size
    for b in blobs:
        offsets.append(running)
        running += len(b)
    offsets.append(running)  # end of the last blob
    payload = b"".join(struct.pack("<Q", o) for o in offsets) + b"".join(blobs)
    if compress:
        body = zstandard.ZstdCompressor(level=3).compress(payload)
        return bytes([0x15]) + body  # 5 = zstd, 0x10 = extended offsets
    return bytes([0x11]) + payload  # 1 = uncompressed, extended


def build(path):
    # Entry list: (namespace, url, title, mime_index, blob)
    entries = []
    for url, title, html in ARTICLES:
        entries.append((NS_ARTICLES, url, title, 0, html.encode("utf-8")))
    for url, title, data in IMAGES:
        entries.append((NS_IMAGES, url, title, 1, data))

    # ZIM requires the URL list sorted by (namespace, url) bytewise.
    entries.sort(key=lambda e: (e[0], e[1].encode("utf-8")))

    # One cluster per entry keeps the writer trivial and still exercises
    # cluster lookup + decompression.
    clusters = [build_cluster([e[4]]) for e in entries]

    # Layout: header | mime list | url ptrs | title ptrs | cluster ptrs | dirents | clusters | md5
    mime_blob = b"".join(cstring(m) for m in MIMES) + b"\0"
    header_size = 80
    mime_pos = header_size
    url_ptr_pos = mime_pos + len(mime_blob)
    title_ptr_pos = url_ptr_pos + 8 * len(entries)
    cluster_ptr_pos = title_ptr_pos + 4 * len(entries)
    dirents_pos = cluster_ptr_pos + 8 * (len(clusters) + 1)

    # Dirents (article kind only — no redirects in this fixture)
    dirents = []
    dirent_offsets = []
    off = dirents_pos
    for ns, url, title, mime_idx, blob in entries:
        d = struct.pack("<HBB", mime_idx, 0, ns[0]) + struct.pack("<I", 0)
        d += struct.pack("<II", 0, 0)  # cluster 0 / blob 0, patched below
        d += cstring(url) + cstring(title)
        dirent_offsets.append(off)
        dirents.append(d)
        off += len(d)

    clusters_pos = off
    cluster_offsets = []
    running = clusters_pos
    for c in clusters:
        cluster_offsets.append(running)
        running += len(c)
    checksum_pos = running

    # Patch cluster/blob index into each dirent (1 cluster per entry).
    patched = []
    for i, d in enumerate(dirents):
        d = bytearray(d)
        struct.pack_into("<II", d, 8, i, 0)
        patched.append(bytes(d))
    dirents = patched

    # Title pointer list: indices sorted by title.
    title_order = sorted(range(len(entries)), key=lambda i: entries[i][2].encode("utf-8"))

    out = bytearray()
    out += struct.pack("<I", MAGIC)
    out += struct.pack("<HH", 6, 1)          # major, minor
    out += b"\0" * 16                         # uuid
    out += struct.pack("<I", len(entries))    # articleCount
    out += struct.pack("<I", len(clusters))   # clusterCount
    out += struct.pack("<Q", url_ptr_pos)
    out += struct.pack("<Q", title_ptr_pos)
    out += struct.pack("<Q", cluster_ptr_pos)
    out += struct.pack("<Q", mime_pos)
    out += struct.pack("<I", 0)               # mainPage (index of Ana_Sayfa)
    out += struct.pack("<I", 0xFFFFFFFF)      # layoutPage
    out += struct.pack("<Q", checksum_pos)
    assert len(out) == header_size, len(out)

    out += mime_blob
    out += b"".join(struct.pack("<Q", o) for o in dirent_offsets)
    out += b"".join(struct.pack("<I", i) for i in title_order)
    out += b"".join(struct.pack("<Q", o) for o in cluster_offsets)
    out += struct.pack("<Q", checksum_pos)
    out += b"".join(dirents)
    out += b"".join(clusters)
    assert len(out) == checksum_pos, (len(out), checksum_pos)
    out += hashlib.md5(bytes(out)).digest()

    with open(path, "wb") as f:
        f.write(out)
    print(f"wrote {path}: {len(out)} bytes, {len(entries)} entries, {len(clusters)} clusters")
    for ns, url, title, _, _ in entries:
        print(f"  {ns.decode()} {url}")


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "test.zim")

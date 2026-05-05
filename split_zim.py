"""
Split a ZIM file into <4 GB parts named .zimaa, .zimab, … so it can live on
FAT32-formatted Kindle storage. Output bytes concatenated equal the input
byte-for-byte; the KOReader plugin reads them back as one virtual file.

Usage:
    python split_zim.py path\\to\\wikipedia_en_all_mini_2026-03.zim
        [--chunk 3GB] [--out path\\to\\output_dir]

Defaults to 3 GiB chunks (well below the 4 GiB FAT32 limit).
"""

from __future__ import annotations
import argparse, os, sys, time

CHUNK_DEFAULT = 1 * 1024 ** 3   # 1 GiB — many small parts is fine, FAT32 caps at 4 GiB
COPY_BUF      = 8 * 1024 ** 2   # 8 MiB streaming buffer

def parse_size(s: str) -> int:
    s = s.strip().upper()
    if s.endswith("GB") or s.endswith("GIB"):
        return int(float(s.rstrip("GIB").rstrip("B").rstrip("G")) * 1024**3)
    if s.endswith("MB") or s.endswith("MIB"):
        return int(float(s.rstrip("MIB").rstrip("B").rstrip("M")) * 1024**2)
    return int(s)

def part_suffix(i: int) -> str:
    if i >= 26 * 26:
        raise ValueError("too many parts (>676)")
    return chr(ord("a") + i // 26) + chr(ord("a") + i % 26)

def split(src: str, chunk: int, out_dir: str | None) -> None:
    base = os.path.basename(src)                         # wiki.zim
    out_dir = out_dir or os.path.dirname(os.path.abspath(src))
    os.makedirs(out_dir, exist_ok=True)

    total = os.path.getsize(src)
    if total <= chunk:
        print(f"{src} is {total/1024**3:.2f} GiB — already fits, no split needed.")
        return

    print(f"Splitting {src} ({total/1024**3:.2f} GiB) "
          f"into {chunk/1024**3:.2f} GiB parts -> {out_dir}\\{base}aa, {base}ab, …")

    written = 0
    t0 = time.time()
    with open(src, "rb") as fin:
        for i in range(26 * 26):
            out_path = os.path.join(out_dir, base + part_suffix(i))
            with open(out_path, "wb") as fout:
                left = chunk
                while left > 0:
                    n = min(COPY_BUF, left)
                    buf = fin.read(n)
                    if not buf:
                        break
                    fout.write(buf)
                    left -= len(buf)
                    written += len(buf)
                    pct = written * 100 / total
                    rate = written / max(time.time() - t0, 1e-6) / 1024**2
                    sys.stdout.write(f"\r  {written/1024**3:6.2f} / {total/1024**3:.2f} GiB  "
                                     f"({pct:5.1f}%, {rate:5.0f} MiB/s)")
                    sys.stdout.flush()
            size = os.path.getsize(out_path)
            print(f"\n  wrote {out_path}  ({size/1024**3:.3f} GiB)")
            if written >= total:
                break

    print(f"\nDone in {time.time()-t0:.1f} s. "
          f"Copy all the .zim?? files to your Kindle.")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zim", help="path to the .zim file to split")
    ap.add_argument("--chunk", default="1GB",
                    help="part size, e.g. 1GB, 3500MB. Default 1GB.")
    ap.add_argument("--out", default=None, help="output dir (default: same as input)")
    args = ap.parse_args()
    chunk = parse_size(args.chunk)
    if chunk >= 4 * 1024**3:
        sys.exit("chunk size must be under 4 GiB for FAT32 compatibility")
    split(args.zim, chunk, args.out)

if __name__ == "__main__":
    main()

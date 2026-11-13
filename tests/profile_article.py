import os, time, struct, zstandard, re

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

zim_path = os.path.join(os.path.dirname(__file__), '..', '..', 'wikipedia_en_basketball_maxi_2026-09.zim')
with open(zim_path, 'rb') as f:
    h = f.read(80)
    count = struct.unpack_from('<I', h, 24)[0]
    url_ptr = struct.unpack_from('<Q', h, 32)[0]
    cluster_ptr = struct.unpack_from('<Q', h, 48)[0]
    
    for query in ['CBasketball', 'CMichael_Jordan']:
        lo, hi = 0, count - 1
        idx = None
        while lo <= hi:
            mid = (lo + hi) // 2
            f.seek(url_ptr + mid * 8)
            off = struct.unpack('<Q', f.read(8))[0]
            f.seek(off)
            head = f.read(4)
            mime = struct.unpack_from('<H', head, 0)[0]
            ns = chr(head[3])
            soff = off + (16 if mime < 0xFFFD else (12 if mime == 0xFFFF else 8))
            f.seek(soff)
            u = b''
            while True:
                c = f.read(1)
                if not c or c == b'\x00': break
                u += c
            k = ns + u.decode('utf-8', errors='ignore')
            if k == query: idx = mid; break
            elif k < query: lo = mid + 1
            else: hi = mid - 1
            
        f.seek(url_ptr + idx * 8)
        off = struct.unpack('<Q', f.read(8))[0]
        f.seek(off + 8)
        c_idx, b_idx = struct.unpack('<II', f.read(8))
        
        f.seek(cluster_ptr + c_idx * 8)
        cs, ce = struct.unpack('<QQ', f.read(16))
        f.seek(cs)
        ib = f.read(1)[0]
        raw = f.read(ce - cs - 1)
        decomp = zstandard.ZstdDecompressor().decompress(raw, max_output_size=10*1024*1024)
        lo_b = struct.unpack_from('<I', decomp, b_idx * 4)[0]
        hi_b = struct.unpack_from('<I', decomp, (b_idx + 1) * 4)[0]
        html = decomp[lo_b:hi_b].decode('utf-8', errors='replace')
        
        print(f"\n{query}: Original size = {len(html)} bytes")
        
        # Test cleaning:
        h_clean = html
        m_b = re.search(r'<div\s+class="[^"]*mw[_-]parser[_-]output', h_clean)
        if m_b:
            h_clean = h_clean[m_b.start():]
            
        h_clean = re.sub(r'<!--.*?-->', '', h_clean, flags=re.DOTALL)
        h_clean = re.sub(r'<script\b[^>]*>.*?</script>', '', h_clean, flags=re.DOTALL)
        h_clean = re.sub(r'<style\b[^>]*>.*?</style>', '', h_clean, flags=re.DOTALL)
        h_clean = re.sub(r'<noscript\b[^>]*>.*?</noscript>', '', h_clean, flags=re.DOTALL)
        
        # Strip navbox / catlinks / footer
        h_clean = strip_balanced(h_clean, r'<table\s+[^>]*class="[^"]*navbox[^"]*"', '<table', '</table>')
        h_clean = strip_balanced(h_clean, r'<div\s+[^>]*class="[^"]*navbox[^"]*"', '<div', '</div>')
        h_clean = strip_balanced(h_clean, r'<table\s+[^>]*class="[^"]*toccolours[^"]*"', '<table', '</table>')
        h_clean = strip_balanced(h_clean, r'<div\s+[^>]*class="[^"]*catlinks[^"]*"', '<div', '</div>')
        h_clean = strip_balanced(h_clean, r'<div\s+[^>]*class="[^"]*printfooter[^"]*"', '<div', '</div>')
        h_clean = strip_balanced(h_clean, r'<div\s+[^>]*class="[^"]*ambox[^"]*"', '<div', '</div>')
        
        # Strip metadata & coordinates
        h_clean = re.sub(r'<span\s+[^>]*id="coordinates"[^>]*>.*?</span>', '', h_clean, flags=re.DOTALL)
        h_clean = re.sub(r'<div\s+[^>]*id="coordinates"[^>]*>.*?</div>', '', h_clean, flags=re.DOTALL)
        h_clean = strip_balanced(h_clean, r'<div\s+[^>]*class="[^"]*metadata[^"]*"', '<div', '</div>')
        
        # Strip layout breaking inline styles
        h_clean = re.sub(r'\s+style="[^"]*?(?:width|float|position|clear|margin)[^"]*?"', '', h_clean)
        
        print(f"  Cleaned size = {len(h_clean)} bytes (reduced by {(1 - len(h_clean)/len(html))*100:.1f}%)")
        rem_tables = len(re.findall(r'<table\b', h_clean))
        print(f"  Remaining tables: {rem_tables}")

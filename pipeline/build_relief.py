"""Pre-render the relief-shading pack for the native app.

    uv run --with pillow --with numpy python3 pipeline/build_relief.py [--measure N]
        [--format avif|webp|png] [--quality Q] [--bbox W,S,E,N] [--minzoom Z]
        [--maxzoom Z] [--src PATH] [--out PATH] [--workers N]

Reads data/hillshade_tas.pmtiles (LIST `Basemaps/HillshadeGrey`, grey JPEG,
CC BY 3.0 AU — adaptation allowed, LICENSING.md) and writes
data/relief_tas.pmtiles: every tile becomes RGBA black with

    alpha = round(255 * 0.4 * max(0, 1 - g / 247))

which is exactly the web app's shadeTile() (protocol.ts, SHADE_STRENGTH 0.4,
SHADE_FLAT 247). "Over" blending black at alpha a gives map * (1 - a), i.e. a
multiply; flat ground (g >= 247) stays untouched. MapLibre Native then draws
the pack as a plain raster layer — no custom tile protocol on the device.

Encoding: AVIF q85 (Pillow >= 11.3 has libavif built in) — ~3.5x smaller than
lossless for a mean alpha error of ~0.4 levels (lossless is 2-2.7x the JPEG
source because the JPEG noise lands in the alpha channel). Tiles are kept
1:1 with the source: a tile whose alpha is all zero is still stored, as ONE
shared transparent tile (identical bytes are deduplicated and consecutive
tile ids run-length encoded, so the cost is a few directory bytes). Omitting
them would let MapLibre stretch a parent tile into the gap.

The PMTiles v3 writer below is self-contained (no MBTiles detour): the source
is read in tile-id order, tiles are converted on all cores (imap keeps the
order), and data is appended to a temp file; header + directories + metadata
are assembled at the end. Not resumable — a full run takes minutes.
"""

import argparse
import gzip
import hashlib
import io
import json
import math
import os
import shutil
import struct
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
SRC = DATA / "hillshade_tas.pmtiles"
OUT = DATA / "relief_tas.pmtiles"

STRENGTH, FLAT = 0.4, 247
LUT = np.array([round(255 * STRENGTH * max(0.0, 1 - g / FLAT)) for g in range(256)], np.uint8)
TILE_TYPE = {"png": 2, "jpg": 3, "webp": 4, "avif": 5}  # PMTiles v3 spec
ATTRIBUTION = ("Relief shading from Hillshade Grey © State of Tasmania (theLIST, CC BY 3.0 AU), "
               "drawn as translucent relief shading")


# ---------------------------------------------------------------- PMTiles v3

def _varint_read(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return r, i


def _varint(n, out):
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)


def parse_dir(b):
    n, i = _varint_read(b, 0)
    ids, rls, lens, offs = [], [], [], []
    last = 0
    for _ in range(n):
        d, i = _varint_read(b, i)
        last += d
        ids.append(last)
    for _ in range(n):
        v, i = _varint_read(b, i)
        rls.append(v)
    for _ in range(n):
        v, i = _varint_read(b, i)
        lens.append(v)
    for k in range(n):
        v, i = _varint_read(b, i)
        offs.append(offs[k - 1] + lens[k - 1] if (v == 0 and k > 0) else v - 1)
    return list(zip(ids, rls, offs, lens))


def serialize_dir(entries):
    out = bytearray()
    _varint(len(entries), out)
    last = 0
    for e in entries:
        _varint(e[0] - last, out)
        last = e[0]
    for e in entries:
        _varint(e[1], out)
    for e in entries:
        _varint(e[3], out)
    for k, e in enumerate(entries):
        if k > 0 and e[2] == entries[k - 1][2] + entries[k - 1][3]:
            _varint(0, out)
        else:
            _varint(e[2] + 1, out)
    return gzip.compress(bytes(out), compresslevel=9, mtime=0)


def tileid_to_zxy(t):
    acc = 0
    for z in range(32):
        n = 1 << (2 * z)
        if acc + n > t:
            pos = t - acc
            x = y = 0
            s = 1
            while s < (1 << z):
                rx = 1 & (pos // 2)
                ry = 1 & (pos ^ rx)
                if ry == 0:
                    if rx == 1:
                        x, y = s - 1 - x, s - 1 - y
                    x, y = y, x
                x += s * rx
                y += s * ry
                pos //= 4
                s *= 2
            return z, x, y
        acc += n
    raise ValueError(t)


class Reader:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(127)
        assert h[:7] == b"PMTiles" and h[7] == 3, f"{path}: not PMTiles v3"
        (self.root_off, self.root_len, self.meta_off, self.meta_len, self.leaf_off, self.leaf_len,
         self.data_off, self.data_len, self.n_addr, self.n_entries, self.n_contents) = struct.unpack("<11Q", h[8:96])
        self.header = h
        assert h[97] == 2 and h[98] == 1, "expect gzip directories, uncompressed tiles"

    def _read(self, o, n):
        self.f.seek(o)
        return self.f.read(n)

    def metadata(self):
        return json.loads(gzip.decompress(self._read(self.meta_off, self.meta_len)))

    def entries(self):
        """Tile entries (tile_id, run_length, offset, length) in tile-id order."""
        out = []

        def walk(o, n):
            for e in parse_dir(gzip.decompress(self._read(o, n))):
                if e[1] == 0:
                    walk(self.leaf_off + e[2], e[3])
                else:
                    out.append(e)
        walk(self.root_off, self.root_len)
        return out

    def tile(self, off, n):
        return self._read(self.data_off + off, n)


def build_directories(entries):
    """Root + leaf directories, root (with header) within the 16 KiB the spec asks for."""
    root = serialize_dir(entries)
    if len(root) <= 16384 - 127:
        return root, b""
    leaf_size = 4096
    while True:
        roots, leaves = [], bytearray()
        for i in range(0, len(entries), leaf_size):
            chunk = entries[i:i + leaf_size]
            b = serialize_dir(chunk)
            roots.append((chunk[0][0], 0, len(leaves), len(b)))
            leaves += b
        root = serialize_dir(roots)
        if len(root) <= 16384 - 127:
            return root, bytes(leaves)
        leaf_size *= 2


def write_pmtiles(out, tmp_data, entries, n_addr, n_contents, meta, tile_type, minzoom, maxzoom, bounds, center):
    root, leaves = build_directories(entries)
    meta_b = gzip.compress(json.dumps(meta, ensure_ascii=False).encode(), compresslevel=9, mtime=0)
    data_len = tmp_data.stat().st_size
    root_off = 127
    meta_off = root_off + len(root)
    leaf_off = meta_off + len(meta_b)
    data_off = leaf_off + len(leaves)
    e7 = lambda v: int(round(v * 1e7))
    h = b"PMTiles" + bytes([3]) + struct.pack(
        "<11Q", root_off, len(root), meta_off, len(meta_b), leaf_off, len(leaves), data_off, data_len,
        n_addr, len(entries), n_contents)
    h += bytes([1, 2, 1, tile_type, minzoom, maxzoom])  # clustered, gzip dirs, raw tiles
    h += struct.pack("<4i", e7(bounds[0]), e7(bounds[1]), e7(bounds[2]), e7(bounds[3]))
    h += bytes([center[2]]) + struct.pack("<2i", e7(center[0]), e7(center[1]))
    assert len(h) == 127
    part = out.with_suffix(out.suffix + ".part")
    with open(part, "wb") as f:
        f.write(h + root + meta_b + leaves)
        with open(tmp_data, "rb") as d:
            shutil.copyfileobj(d, f, 16 << 20)
    os.replace(part, out)


# ---------------------------------------------------------------- conversion

_reader = None
_args = None


def _init(src, fmt, quality):
    global _reader, _args
    _reader = Reader(src)
    _args = (fmt, quality)


def shade(jpeg):
    g = np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"))[..., 1]  # grey: G == R == B
    return LUT[g]


def encode(alpha, fmt, quality):
    rgba = np.zeros(alpha.shape + (4,), np.uint8)
    rgba[..., 3] = alpha
    im = Image.fromarray(rgba, "RGBA")
    b = io.BytesIO()
    if fmt == "avif":
        im.save(b, "AVIF", quality=quality, speed=6)
    elif fmt == "webp":
        im.save(b, "WEBP", quality=50, alpha_quality=quality, method=4)
    else:
        im.save(b, "PNG", optimize=True)
    return b.getvalue()


def convert(item):
    """(tile_id, run_length, offset, length) -> (tile_id, run_length, bytes | None if blank)."""
    tid, rl, off, n = item
    a = shade(_reader.tile(off, n))
    if not a.any():
        return tid, rl, None
    return tid, rl, encode(a, *_args)


def in_scope(tid, bbox, minzoom, maxzoom):
    z, x, y = tileid_to_zxy(tid)
    if not minzoom <= z <= maxzoom:
        return False
    if bbox is None:
        return True
    w, s, e, nn = bbox
    n = 1 << z
    x0 = int((w + 180) / 360 * n)
    x1 = int((e + 180) / 360 * n)
    ty = lambda lat: int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x0 <= x <= x1 and ty(nn) <= y <= ty(s)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=SRC)
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--format", choices=["avif", "webp", "png"], default="avif")
    ap.add_argument("--quality", type=int, default=None, help="avif quality (85) / webp alpha_quality (50)")
    ap.add_argument("--bbox", help="W,S,E,N — test archives only")
    ap.add_argument("--minzoom", type=int, default=0)
    ap.add_argument("--maxzoom", type=int, default=15)
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--measure", type=int, default=0, help="convert N evenly spaced tiles, print an estimate, exit")
    a = ap.parse_args()
    quality = a.quality if a.quality is not None else {"avif": 85, "webp": 50, "png": 0}[a.format]
    bbox = tuple(float(v) for v in a.bbox.split(",")) if a.bbox else None

    src = Reader(a.src)
    smeta = src.metadata()
    expanded = src.entries()
    n_src = sum(e[1] for e in expanded)
    assert n_src == src.n_addr, (n_src, src.n_addr)
    items = [e for e in expanded if in_scope(e[0], bbox, a.minzoom, a.maxzoom)] \
        if (bbox or a.minzoom > 0 or a.maxzoom < 15) else expanded
    # a run spans consecutive tile ids — fine for in_scope at a run's first id in a bbox test,
    # and the full build keeps every entry.
    print(f"source {a.src.name}: {n_src} tiles, {len(expanded)} entries, built {smeta.get('built')}; "
          f"converting {len(items)} entries -> {a.format} q{quality} on {a.workers} workers", flush=True)

    if a.measure:
        step = max(1, len(items) // a.measure)
        sample = items[::step][:a.measure]
        t0 = time.time()
        with Pool(a.workers, _init, (str(a.src), a.format, quality)) as pool:
            res = pool.map(convert, sample, chunksize=8)
        dt = time.time() - t0
        nb = sum(1 for r in res if r[2] is None)
        mean = sum(len(r[2]) for r in res if r[2]) / max(1, len(res))
        print(f"measure: {len(sample)} tiles in {dt:.1f}s -> full run ~{dt / len(sample) * len(items) / 60:.1f} min, "
              f"~{mean * len(items) / 1e9:.2f} GB; {nb} blank in sample")
        return

    tmp = a.out.with_suffix(".data.tmp")
    a.out.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    entries = []          # (tile_id, run_length, offset, length)
    by_hash = {}          # sha1 -> (offset, length): identical tiles stored once
    blank = encode(np.zeros((256, 256), np.uint8), a.format, quality)
    blank_tiles = 0
    off = 0
    done = 0
    with open(tmp, "wb") as f, Pool(a.workers, _init, (str(a.src), a.format, quality)) as pool:
        for tid, rl, b in pool.imap(convert, items, chunksize=16):
            if b is None:
                b = blank
                blank_tiles += rl
            h = hashlib.sha1(b).digest()
            if h in by_hash:
                o, n = by_hash[h]
            else:
                f.write(b)
                o, n = off, len(b)
                by_hash[h] = (o, n)
                off += n
            last = entries[-1] if entries else None
            if last and last[0] + last[1] == tid and last[2] == o and last[3] == n:
                entries[-1] = (last[0], last[1] + rl, o, n)
            else:
                entries.append((tid, rl, o, n))
            done += 1
            if done % 10000 == 0:
                el = time.time() - t0
                print(f"  {done}/{len(items)} entries, {off / 1e9:.2f} GB, {el:.0f}s, "
                      f"eta {el / done * (len(items) - done):.0f}s", flush=True)
    n_addr = sum(e[1] for e in entries)
    sh = src.header
    bounds = [v / 1e7 for v in struct.unpack("<4i", sh[102:118])] if bbox is None else list(bbox)
    zmin, zmax = max(a.minzoom, src.header[100]), min(a.maxzoom, src.header[101])
    center = ((bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2, min(max(8, zmin), zmax))  # verify: within zooms
    meta = {
        "name": "IzzyMap Relief shading — Tasmania",
        "key": "relief",
        "type": "overlay",
        "format": a.format,
        "attribution": ATTRIBUTION,
        "copyright_text": smeta.get("copyright_text"),
        "source": f"{smeta.get('service')} (pack {a.src.name}, built {smeta.get('built')})",
        "built": smeta.get("built"),
        "rendered": time.strftime("%Y-%m-%d"),
        "shading": f"black, alpha = round(255*{STRENGTH}*max(0, 1 - g/{FLAT})) — the web app's shadeTile()",
        "encoder": f"Pillow {Image.__version__} {a.format} q{quality}" + (" speed 6" if a.format == "avif" else ""),
        "blank_tiles": blank_tiles,
        "minzoom": str(zmin),
        "maxzoom": str(zmax),
        "version": "1",
    }
    write_pmtiles(a.out, tmp, entries, n_addr, len(by_hash), meta, TILE_TYPE[a.format],
                  zmin, zmax, bounds, center)
    tmp.unlink()
    size = a.out.stat().st_size
    print(f"done: {n_addr} tiles ({blank_tiles} blank -> one shared tile), {len(entries)} entries, "
          f"{len(by_hash)} distinct, {size / 1e9:.3f} GB -> {a.out}, {time.time() - t0:.0f}s")
    if bbox is None and (a.minzoom, a.maxzoom) == (0, 15):
        assert n_addr == n_src, f"tile count {n_addr} != source {n_src}"


if __name__ == "__main__":
    sys.exit(main())

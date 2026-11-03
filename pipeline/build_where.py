#!/usr/bin/env python3
"""Build ios/IzzyMap/Resources/Data/where.bin + where_patches.json — the data
behind a vegetation card's "Where else does this grow?" mini-map: for each of
the 156 TASVEG 5.0 communities, which cells of a coarse statewide grid it
covers (shaded by area share), a land mask for the same grid (so the app can
draw Tasmania incl. King Island and the Furneaux Group with no other data),
and per community its patch count + 10 largest patches (for "show on map" /
step through patches).

Run (2026-11-03: 2 m 43 s with the parquet cache warm — rasterise 27 s,
patch graph ~2 min; a cold cache adds the ~1 min shapefile read):
  uv run --with geopandas --with pyogrio --with pyproj --with pyarrow \
    --with rasterio --with scipy python3 pipeline/build_where.py [--tasveg ZIP]
  --clip W,S,E,N   lon/lat box: measure on a subset (tripwires off; needs
                   an --out-dir other than the app bundle)
  --out-dir DIR    where to write (default ios/IzzyMap/Resources/Data)

Source: the TASVEG 5.0 statewide shapefile zip, read in place via /vsizip/,
cached as the SAME slim parquet build_records.py uses
(pipeline/cache/records/tasveg_slim.parquet, keyed on zip name + size +
mtime) — VEGCODE + geometry, EPSG:28355. Facts only (CC BY 4.0, NRE Tas).

Method
------
* Grid: equirectangular lon/lat cells, 0.02° lon × 0.015° lat. At 41.5° S
  that is 1.67 km × 1.67 km (2.78 km²) — square on the ground AND in Web
  Mercator (0.015 / cos 41.5° ≈ 0.0200), so the app draws each cell as a
  square. 236 cols × 300 rows from 143.80° E / 39.18° S (TASVEG bounds
  2026-11: 143.819–148.505° E, 43.664–39.198° S); the main island is ~190
  cells across.
* Area shares: ONE rasterisation of all polygons (TASVEG is a coverage — no
  overlaps — so one uint8 community index per pixel) at 32 × 32 pixels per
  cell (~52 m), then a per-cell bincount. share = pixels / 1024 of the cell
  (not of its land). Polygons too small to hit a pixel centre still mark
  their cell: each polygon's representative point guarantees level ≥ 1 in
  the cell it falls in (rare communities are the interesting ones).
* Levels (2 bits worth, stored as a byte): 1 = (0, 5 %), 2 = [5, 25 %),
  3 = [25, 50 %), 4 = ≥ 50 % of the cell's area.
* Land = every TASVEG polygon except OAQ (water, sea — estuaries AND lakes,
  so big lakes read as holes). Land level ≥ 4 (≥ 50 %) = the classic
  outline; level ≥ 1 keeps every islet.
* Patches: polygons of one community within 0.5 m of each other (shared
  edges, vertex touches, sliver gaps) are one patch — connected components
  of an STRtree `dwithin` graph, no dissolve needed. Per patch: area (m²
  in MGA55, exact — polygons don't overlap), lon/lat bbox, and a label
  point = the area-weighted centroid when it lies inside the patch, else a
  point on the surface of the patch's largest polygon.

where.bin (little-endian; all offsets from file start)
----------------------------------------------------
  0  char[4] magic "WHR1"
  4  u16  version = 1
  6  u16  ncomm (156; table order = sorted VEGCODE = tasveg_communities.json key order)
  8  u16  ncols (236)
 10  u16  nrows (300)
 12  i32  lon0   west edge of col 0, micro-degrees (143_800_000)
 16  i32  lat0   NORTH edge of row 0, micro-degrees (-39_180_000)
 20  i32  lonStep µdeg (20_000)
 24  i32  latStep µdeg (15_000; rows run SOUTH)
 28  u8   nlevels (4)
 29  u8   0
 30  u16[4] level lower bounds, ‰ of cell area: 0, 50, 250, 500 (level 1 = "> 0")
 38  u16  0
 40  u32  land stream offset
 44  u32  land stream length (bytes)
 48  u32  land cell count (cells with level ≥ 1)
 52  u32  file size
 56  u8[8] 0
 64  table: ncomm × 16 bytes { char[4] code ("DOB\\0"), u32 offset,
                              u32 length, u32 cell count }
 ... streams (communities in table order, then land)

 Cell index = row * ncols + col; cell spans lon [lon0 + col·lonStep, +lonStep),
 lat [lat0 − (row+1)·latStep, lat0 − row·latStep).
 Stream = runs until `length` bytes are consumed; each run =
   varint skip, varint count (≥ 1), u8 level (1…4)
 (varint = unsigned LEB128). cursor starts at 0; cells cursor+skip …
 cursor+skip+count−1 get `level`; cursor += skip + count. Unlisted cells = 0.

where_patches.json
------------------
 {"version": 1, "source": …, "levels_permille": [0, 50, 250, 500],
  "communities": {CODE: {"ha": total hectares, "patches": patch count,
     "top": [{"ha": …, "p": [lon, lat], "bbox": [w, s, e, n]}, … ≤ 10,
             largest first]}}}
 coordinates rounded to 1e-5° (~1 m), ha to 0.1.
"""

import argparse
import json
import struct
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
CACHE = HERE / "cache" / "records"          # shared with build_records.py
OUT = ROOT / "ios" / "IzzyMap" / "Resources" / "Data"
COMMUNITIES = OUT / "tasveg_communities.json"
TASVEG_SHP = "LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.shp"
ZIP_CANDIDATES = [HERE / "cache" / "LIST_TASVEG_50_STATEWIDE.zip",
                  ROOT / "data" / "LIST_TASVEG_50_STATEWIDE.zip"]

LON0, LAT0 = 143.80, -39.18          # west / north edges
LON_STEP, LAT_STEP = 0.02, 0.015
NCOLS, NROWS = 236, 300              # → 148.52° E, 43.68° S
SUB = 32                             # fine pixels per cell side (~52 m)
LEVELS_PERMILLE = [0, 50, 250, 500]  # lower bounds; level 1 means > 0
SEA = "OAQ"
TOP = 10
TOUCH_M = 0.5
MAGIC = b"WHR1"
VERSION = 1


def log(*a):
    print(*a, flush=True)


def tasveg_frame(src: Path):
    """Same cache + key as build_records.tasveg_frame (kept in sync by hand:
    importing build_records would pull its HTTP setup)."""
    import geopandas as gpd
    slim, meta = CACHE / "tasveg_slim.parquet", CACHE / "tasveg_slim.key"
    st = src.stat()
    key = f"{src.name} {st.st_size} {int(st.st_mtime)}"
    if slim.exists() and meta.exists() and meta.read_text().strip() == key:
        return gpd.read_parquet(slim)
    t = time.time()
    df = gpd.read_file(f"/vsizip/{src}/{TASVEG_SHP}", columns=["VEGCODE"], engine="pyogrio")
    log(f"TASVEG: read {len(df):,} polygons from {src.name} in {time.time() - t:.0f} s")
    assert 470_000 <= len(df) <= 500_000, len(df)
    assert df.crs.to_epsg() == 28355, df.crs
    CACHE.mkdir(parents=True, exist_ok=True)
    df.to_parquet(slim)
    meta.write_text(key)
    return df


def level_of(permille):
    """permille (float, > 0) → 1..4."""
    lv = np.ones(permille.shape, np.uint8)
    for i, lo in enumerate(LEVELS_PERMILLE[1:], start=2):
        lv[permille >= lo] = i
    return lv


def varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def encode(levels: np.ndarray) -> bytes:
    """levels: flat uint8 per cell (0 = absent) → run stream."""
    nz = np.flatnonzero(levels)
    out = bytearray()
    if not len(nz):
        return bytes(out)
    lv = levels[nz]
    # a run breaks where the index jumps or the level changes
    brk = np.flatnonzero((np.diff(nz) != 1) | (np.diff(lv) != 0)) + 1
    starts = np.concatenate([[0], brk])
    ends = np.concatenate([brk, [len(nz)]])
    cursor = 0
    for s, e in zip(starts, ends):
        first = int(nz[s])
        out += varint(first - cursor) + varint(int(e - s)) + bytes([int(lv[s])])
        cursor = first + int(e - s)
    return bytes(out)


def decode(buf: bytes, ncells: int) -> np.ndarray:
    """Reference parser (validation + what the Swift side mirrors)."""
    out = np.zeros(ncells, np.uint8)
    i = cursor = 0

    def rd():
        nonlocal i
        n = shift = 0
        while True:
            b = buf[i]; i += 1
            n |= (b & 0x7F) << shift
            if b < 0x80:
                return n
            shift += 7
    while i < len(buf):
        cursor += rd()
        cnt = rd()
        lv = buf[i]; i += 1
        assert cnt >= 1 and 1 <= lv <= len(LEVELS_PERMILLE)
        out[cursor:cursor + cnt] = lv
        cursor += cnt
    return out


def read_where(path: Path):
    """Parse where.bin → (header dict, {code: flat levels}, land levels)."""
    b = path.read_bytes()
    assert b[:4] == MAGIC
    ver, ncomm, ncols, nrows = struct.unpack_from("<4H", b, 4)
    lon0, lat0, lons, lats = struct.unpack_from("<4i", b, 12)
    nlev = b[28]
    thr = struct.unpack_from("<4H", b, 30)
    loff, llen, lcells, fsize = struct.unpack_from("<4I", b, 40)
    assert ver == VERSION and fsize == len(b) and nlev == 4
    n = ncols * nrows
    comms = {}
    for k in range(ncomm):
        code, off, ln, cells = struct.unpack_from("<4sIII", b, 64 + 16 * k)
        lv = decode(b[off:off + ln], n)
        assert int((lv > 0).sum()) == cells
        comms[code.rstrip(b"\0").decode()] = lv
    land = decode(b[loff:loff + llen], n)
    assert int((land > 0).sum()) == lcells
    hdr = dict(ncols=ncols, nrows=nrows, lon0=lon0 / 1e6, lat0=lat0 / 1e6,
               lon_step=lons / 1e6, lat_step=lats / 1e6, thresholds=thr)
    return hdr, comms, land


def cell_of(lon, lat):
    col = np.floor((lon - LON0) / LON_STEP).astype(np.int64)
    row = np.floor((LAT0 - lat) / LAT_STEP).astype(np.int64)
    ok = (col >= 0) & (col < NCOLS) & (row >= 0) & (row < NROWS)
    return row * NCOLS + col, ok


def patches(df, ll, idx_of, codes):
    """Connected components per community → stats dict."""
    import shapely
    from pyproj import Transformer
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    geoms = np.asarray(df.geometry.values)
    comm = np.array([idx_of[v] for v in df.VEGCODE], np.int32)
    t = time.time()
    tree = shapely.STRtree(geoms)
    # bbox candidates first (boxes grown by TOUCH_M), keep same-community
    # pairs, THEN the exact distance test: a `dwithin` predicate inside the
    # tree query tests every neighbour pair of every community (~7 min).
    bx = shapely.bounds(geoms)
    a, b = tree.query(shapely.box(bx[:, 0] - TOUCH_M, bx[:, 1] - TOUCH_M,
                                  bx[:, 2] + TOUCH_M, bx[:, 3] + TOUCH_M))
    keep = (a < b) & (comm[a] == comm[b])
    a, b = a[keep], b[keep]
    near = shapely.dwithin(geoms[a], geoms[b], TOUCH_M)
    a, b = a[near], b[near]
    n = len(geoms)
    g = coo_matrix((np.ones(len(a), np.int8), (a, b)), shape=(n, n))
    ncomp, lab = connected_components(g, directed=False)
    log(f"patches: {len(a):,} same-community neighbour pairs → {ncomp:,} patches ({time.time() - t:.0f} s)")
    area = shapely.area(geoms)
    cen = shapely.centroid(geoms)
    cx, cy = shapely.get_x(cen), shapely.get_y(cen)
    p_area = np.bincount(lab, area, ncomp)
    p_cx = np.bincount(lab, area * cx, ncomp) / p_area
    p_cy = np.bincount(lab, area * cy, ncomp) / p_area
    p_comm = np.zeros(ncomp, np.int32)
    p_comm[lab] = comm
    to_ll = Transformer.from_crs(28355, 4326, always_xy=True)
    bnd = ll.bounds.to_numpy()
    w = np.full(ncomp, np.inf); s = np.full(ncomp, np.inf)
    e = np.full(ncomp, -np.inf); nn = np.full(ncomp, -np.inf)
    np.minimum.at(w, lab, bnd[:, 0]); np.minimum.at(s, lab, bnd[:, 1])
    np.maximum.at(e, lab, bnd[:, 2]); np.maximum.at(nn, lab, bnd[:, 3])
    # largest member polygon per patch (fallback label point)
    order = np.lexsort((-area, lab))
    first = np.ones(n, bool); first[1:] = lab[order][1:] != lab[order][:-1]
    biggest = np.empty(ncomp, np.int64); biggest[lab[order][first]] = order[first]
    out = {}
    fallbacks = 0
    for ci, code in enumerate(codes):
        ps = np.flatnonzero(p_comm == ci)
        if not len(ps):
            continue
        ps = ps[np.argsort(-p_area[ps])]
        top = []
        for p in ps[:TOP]:
            pt = shapely.Point(p_cx[p], p_cy[p])
            hit = tree.query(pt, predicate="within")
            if not (lab[hit] == p).any():
                pt = shapely.point_on_surface(geoms[biggest[p]])
                fallbacks += 1
            lon, lat = to_ll.transform(pt.x, pt.y)
            top.append({"ha": round(float(p_area[p]) / 1e4, 1),
                        "p": [round(lon, 5), round(lat, 5)],
                        "bbox": [round(float(w[p]), 5), round(float(s[p]), 5),
                                 round(float(e[p]), 5), round(float(nn[p]), 5)]})
        out[code] = {"ha": round(float(p_area[ps].sum()) / 1e4, 1),
                     "patches": int(len(ps)), "top": top}
    log(f"patches: label point fell back to point-on-surface for {fallbacks} of "
        f"{sum(len(v['top']) for v in out.values())} top patches")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tasveg", type=Path)
    ap.add_argument("--clip", help="W,S,E,N lon/lat — subset run, tripwires off")
    ap.add_argument("--out-dir", type=Path, default=OUT)
    args = ap.parse_args()
    if args.clip and args.out_dir.resolve() == OUT.resolve():
        sys.exit("--clip writes partial data: pass --out-dir (not the app bundle)")
    src = args.tasveg or next((p for p in ZIP_CANDIDATES if p.exists()), None)
    if not src or not src.exists():
        sys.exit(f"TASVEG zip not found ({', '.join(map(str, ZIP_CANDIDATES))}); pass --tasveg")
    import shapely
    import rasterio.features as rf
    from rasterio.transform import from_origin

    T0 = time.time()
    codes = sorted(json.loads(COMMUNITIES.read_text()))
    assert len(codes) == 156 and all(len(c) == 3 for c in codes), len(codes)
    idx_of = {c: i for i, c in enumerate(codes)}

    t = time.time()
    df = tasveg_frame(src)
    log(f"TASVEG: {len(df):,} polygons loaded ({time.time() - t:.0f} s)")
    unknown = set(df.VEGCODE) - set(codes)
    assert not unknown, f"VEGCODEs not in tasveg_communities.json: {unknown}"
    if args.clip:
        W, S, E, N = map(float, args.clip.split(","))
        b = df.geometry.to_crs(4326).bounds
        df = df[(b.minx < E) & (b.maxx > W) & (b.miny < N) & (b.maxy > S)].reset_index(drop=True)
        log(f"clip: {len(df):,} polygons intersect {args.clip}")
    else:
        missing = set(codes) - set(df.VEGCODE)
        assert not missing, f"communities absent from TASVEG: {missing}"

    t = time.time()
    ll = df.geometry.to_crs(4326)
    geoms = np.asarray(ll.values)
    tb = ll.total_bounds
    log(f"reprojected to lon/lat ({time.time() - t:.0f} s); bounds {np.round(tb, 3)}")
    assert tb[0] >= LON0 and tb[2] <= LON0 + NCOLS * LON_STEP, tb
    assert tb[3] <= LAT0 and tb[1] >= LAT0 - NROWS * LAT_STEP, tb

    # ---- one fine rasterisation, community index + 1 per pixel (0 = none)
    t = time.time()
    H, Wd = NROWS * SUB, NCOLS * SUB
    vals = (np.array([idx_of[v] for v in df.VEGCODE]) + 1).astype(np.uint8)
    fine = rf.rasterize(zip(geoms, vals.tolist()), out_shape=(H, Wd),
                        transform=from_origin(LON0, LAT0, LON_STEP / SUB, LAT_STEP / SUB),
                        fill=0, dtype="uint8")
    log(f"rasterised {len(geoms):,} polygons into {Wd} × {H} px ({time.time() - t:.0f} s)")

    # per-cell counts: (cell, community+1) histogram, one band of cell rows at a time
    t = time.time()
    ncell, K = NROWS * NCOLS, len(codes) + 1
    counts = np.zeros((ncell, K), np.int32)
    col_of_px = np.arange(Wd) // SUB
    BAND = 20
    for r0 in range(0, NROWS, BAND):
        r1 = min(NROWS, r0 + BAND)
        f = fine[r0 * SUB:r1 * SUB].astype(np.int64)
        local = ((np.arange(f.shape[0]) // SUB)[:, None] * NCOLS + col_of_px[None, :])
        n = (r1 - r0) * NCOLS
        counts[r0 * NCOLS:r1 * NCOLS] = np.bincount((local * K + f).ravel(),
                                                    minlength=n * K).reshape(n, K)
    del fine
    permille = counts[:, 1:] * (1000.0 / (SUB * SUB))      # (ncell, ncomm)
    levels = np.zeros(permille.shape, np.uint8)
    pos = counts[:, 1:] > 0
    levels[pos] = level_of(permille[pos])
    # tiny polygons: representative point guarantees level ≥ 1
    rp = shapely.point_on_surface(geoms)
    cid, ok = cell_of(shapely.get_x(rp), shapely.get_y(rp))
    ci = vals.astype(np.int64) - 1
    rescued = int((ok & (levels[cid.clip(0, ncell - 1), ci] == 0)).sum())
    levels[cid[ok], ci[ok]] = np.maximum(levels[cid[ok], ci[ok]], 1)
    sea = idx_of[SEA]
    land_pm = np.delete(permille, sea, axis=1).sum(axis=1)
    land = np.zeros(ncell, np.uint8)
    land[land_pm > 0] = level_of(land_pm[land_pm > 0])
    land_rescue = np.delete(levels, sea, axis=1).max(axis=1) > 0      # islets
    land[(land == 0) & land_rescue] = 1
    log(f"cells: {(land > 0).sum():,} with land, {(land == 4).sum():,} ≥ 50 % land; "
        f"{int((levels > 0).sum()):,} community×cell pairs ({rescued} added by small polygons) "
        f"({time.time() - t:.0f} s)")

    # ---- patches
    t = time.time()
    pstats = patches(df, ll, idx_of, codes)
    log(f"patches done ({time.time() - t:.0f} s)")

    # ---- area cross-check: raster vs polygon area (catches CRS / grid slips)
    row_lat = LAT0 - (np.arange(NROWS) + 0.5) * LAT_STEP
    px_ha = np.repeat(LON_STEP / SUB * 111.32 * np.cos(np.radians(row_lat))
                      * LAT_STEP / SUB * 111.13 * 100, NCOLS)          # per cell
    for c in ("DOB", "RMT", "FAL", "MBU"):
        if c in pstats and pstats[c]["ha"] > 5000:
            r = float((counts[:, 1 + idx_of[c]] * px_ha).sum())
            dev = r / pstats[c]["ha"] - 1
            log(f"  area check {c}: raster {r:,.0f} ha vs polygons {pstats[c]['ha']:,.0f} ha ({dev:+.1%})")
            assert abs(dev) < 0.04, (c, dev)

    # ---- write where.bin
    streams = [encode(levels[:, k]) for k in range(len(codes))]
    land_s = encode(land)
    table_end = 64 + 16 * len(codes)
    offs, o = [], table_end
    for s in streams:
        offs.append(o); o += len(s)
    land_off, size = o, o + len(land_s)
    hdr = bytearray(64)
    struct.pack_into("<4sHHHH", hdr, 0, MAGIC, VERSION, len(codes), NCOLS, NROWS)
    struct.pack_into("<4i", hdr, 12, round(LON0 * 1e6), round(LAT0 * 1e6),
                     round(LON_STEP * 1e6), round(LAT_STEP * 1e6))
    struct.pack_into("<BB4HH", hdr, 28, len(LEVELS_PERMILLE), 0, *LEVELS_PERMILLE, 0)
    struct.pack_into("<4I", hdr, 40, land_off, len(land_s), int((land > 0).sum()), size)
    table = bytearray()
    for c, s, off, k in zip(codes, streams, offs, range(len(codes))):
        table += struct.pack("<4sIII", c.encode(), off, len(s), int((levels[:, k] > 0).sum()))
    blob = bytes(hdr) + bytes(table) + b"".join(streams) + land_s
    assert len(blob) == size
    args.out_dir.mkdir(parents=True, exist_ok=True)
    bin_path = args.out_dir / "where.bin"
    bin_path.write_bytes(blob)
    pj = {"version": 1,
          "source": "TASVEG 5.0 (NRE Tasmania, CC BY 4.0) — pipeline/build_where.py",
          "levels_permille": LEVELS_PERMILLE,
          "communities": {c: pstats[c] for c in codes if c in pstats}}
    pj_path = args.out_dir / "where_patches.json"
    pj_path.write_text(json.dumps(pj, separators=(",", ":"), ensure_ascii=False))

    # ---- round-trip + tripwires
    h, comms, land2 = read_where(bin_path)
    assert (land2 == land).all() and all((comms[c] == levels[:, k]).all() for k, c in enumerate(codes))
    bsz, jsz = bin_path.stat().st_size, pj_path.stat().st_size
    log(f"wrote {bin_path} ({bsz:,} B) + {pj_path.name} ({jsz:,} B) in {time.time() - T0:.0f} s total")
    if args.clip:
        log("clip run: tripwires skipped")
        return
    empty = [c for c in codes if not (comms[c] > 0).any()]
    assert not empty, f"communities with no cell: {empty}"
    assert set(pstats) == set(codes), set(codes) - set(pstats)
    full = int((land == 4).sum())
    assert 22_000 <= full <= 27_000, f"≥50 % land cells {full} (expect ~24.6k: 68,400 km² / 2.78)"
    for name, lon, lat, want in [("Hobart", 147.3257, -42.8826, True),
                                 ("Cape Grim", 144.70, -40.70, True),
                                 ("Currie, King Island", 143.87, -39.93, True),
                                 ("Whitemark, Flinders Island", 148.02, -40.12, True),
                                 ("Bass Strait", 146.5, -40.5, False),
                                 ("Tasman Sea off Freycinet", 148.6 - 0.15, -42.6, False)]:
        cid, _ = cell_of(np.array([lon]), np.array([lat]))
        got = land[cid[0]] > 0
        assert got == want, f"land mask at {name}: {got}"
    assert 50_000 <= bsz <= 1_500_000, bsz
    assert bsz + jsz <= 2_000_000, bsz + jsz
    dob = int((comms["DOB"] > 0).sum())
    assert dob >= 2_000, f"DOB in only {dob} cells"
    log(f"tripwires ok: 156 codes, all with cells (min {min(int((comms[c] > 0).sum()) for c in codes)}), "
        f"DOB {dob} cells, {full:,} ≥50 % land cells")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build data/tasveg_v2.pmtiles (statewide TASVEG 5.0 vector tiles) + the
community colour/name table, from the LISTdata statewide shapefile zip.

Run through pipeline/build_tasveg.sh (downloads the zip, supplies the uv
environment: rasterio pyogrio shapely pyproj numpy geopandas pyarrow
mapbox-vector-tile). Options:
    [--clip Z/X/Y]   # one web-mercator tile only (timing / experiments);
                     # output work/tasveg_clip/tasveg_clip.pmtiles, table untouched
    [--jobs N]       # parallel band / label workers (default 6)
Timing 2026-11-03 (statewide): read 40 s, reproject 2 min, z11–14 GeoJSON
1.5 min, rasterise 5.5 min (the slow step), bands 2 min, labels 1 min,
z11–14 tippecanoe 8.5 min in parallel with those → ~13 min end to end.

Archive layout (layers):
  tasveg          z0–10  MODE-RASTER BANDS: VEGCODE rasterised in EPSG:3857
                         at 19.1 m (¼ of a z10 point), mode-resampled per
                         zoom to one point of a 512-pt tile (78271.5/2^z m),
                         polygonised 4-connected; attribute VEGCODE only.
                  z11–14 the SOURCE POLYGONS (VEGCODE, VEGCODE_D, VEG_GROUP,
                         FOREST_STR, NOTABLE_TD, WEED_TYP_D), feature id =
                         shapefile row + 1 (stable across tiles AND rebuilds
                         of the same release: outline a selection by id).
  tasveg_labels   z13–14 one point per source polygon at its pole of
                         inaccessibility (maximum inscribed circle centre):
                         VEGCODE, area (m², MGA55), r (inscribed radius, m),
                         same id as its polygon. Overzoomed beyond z14; the
                         style filters by r/area per zoom.

Why bands (2026-11): the old single tippecanoe run needed
--coalesce-densest-as-needed at z5–10, which merges ACROSS communities —
measured ~35 % of land at z8 painted/tapped as the wrong community. Mode
resampling is the categorically correct generalisation (pre-1750 lesson);
sea is class 0 and wins the vote like any class, so coastlines neither
dilate nor erode systematically. No band or zoom may coalesce or drop
features — the strategies tripwire fails the build otherwise.
"""
import argparse
import gzip
import json
import math
import os
import sqlite3
import subprocess
import sys
import time
import zipfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache"
WORK = HERE / "work"
DATA = HERE.parent / "data"
TABLE = HERE.parent / "ios" / "IzzyMap" / "Resources" / "Data" / "tasveg_communities.json"

ZIP = CACHE / "LIST_TASVEG_50_STATEWIDE.zip"
SHP_IN_ZIP = "LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.shp"
QML_IN_ZIP = "LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.qml"
EXPECTED_FEATURES = 482138
NAME = "TASVEG 5.0"
ATTRIBUTION = "TASVEG 5.0 from theLIST (CC BY 3.0 AU) © State of Tasmania"
ATTRS = ["VEGCODE", "VEGCODE_D", "VEG_GROUP", "FOREST_STR", "NOTABLE_TD", "WEED_TYP_D"]

W = 20037508.342789244          # web-mercator half-width
PT0 = 2 * W / 512               # one point of a 512-pt tile at z0 (78271.5 m)
BAND_ZOOMS = list(range(0, 11))  # z0–10
FINE = PT0 / 2 ** 10 / 4        # 19.1 m
HI_MIN, HI_MAX = 11, 14
LABEL_MIN, LABEL_MAX = 13, 14
# Old archive bounds (tippecanoe metadata, 2026-08-29) — the tripwire allows
# ±0.01°; a CRS slip or a lost island moves them by far more.
OLD_BOUNDS = (143.818689, -43.664038, 148.504899, -39.197803)

T0 = time.time()


def log(msg: str) -> None:
    print(f"[{time.time() - T0:7.1f}s] {msg}", flush=True)


def tile_bounds(z: int, x: int, y: int):
    s = 2 * W / 2 ** z
    return (-W + x * s, W - (y + 1) * s, -W + (x + 1) * s, W - y * s)


def run(cmd, **kw):
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def strategies(mb: Path):
    with sqlite3.connect(mb) as db:
        row = db.execute("SELECT value FROM metadata WHERE name='strategies'").fetchone()
    return json.loads(row[0]) if row and row[0] else []


def check_strategies(mb: Path, label: str) -> dict:
    """tiny_polygons is the only allowed strategy: the dust square keeps its own
    feature's attributes (tippecanoe clip.cpp, see build_pre1750.py). Anything
    else (coalesced_*, dropped_*, detail_reduced, tile_size_desired…) = a tile
    overflowed and features were merged or lost → fail."""
    tiny = {}
    for z, strat in enumerate(strategies(mb)):
        bad = set(strat) - {"tiny_polygons"}
        if bad:
            raise SystemExit(f"{label}: unsafe tippecanoe strategy at z{z}: "
                             f"{ {k: strat[k] for k in bad} }")
        if strat.get("tiny_polygons"):
            tiny[z] = strat["tiny_polygons"]
    return tiny


# ---------------------------------------------------------------- source

def read_source(clip_bounds_3857):
    import pyogrio
    import shapely
    from pyproj import Transformer
    path = f"/vsizip/{ZIP}/{SHP_IN_ZIP}"
    bbox = None
    if clip_bounds_3857:
        t = Transformer.from_crs(3857, 28355, always_xy=True)
        b = clip_bounds_3857
        xs, ys = t.transform([b[0], b[0], b[2], b[2]], [b[1], b[3], b[1], b[3]])
        bbox = (min(xs), min(ys), max(xs), max(ys))
    df = pyogrio.read_dataframe(path, columns=ATTRS, bbox=bbox, fid_as_index=True, use_arrow=True)
    geoms = np.asarray(df.geometry.values)
    if set(shapely.get_type_id(geoms)) != {3}:
        raise SystemExit("expected plain Polygons only")
    cols = {a: df[a].fillna("").astype(str).tolist() for a in ATTRS}
    # feature id = shapefile FID (row number; bbox reads keep it) + 1
    ids = df.index.to_numpy(dtype=np.int64) + 1
    return geoms, cols, ids


def reproject(geoms, src: int, dst: int):
    import shapely
    from pyproj import Transformer
    tr = Transformer.from_crs(src, dst, always_xy=True)

    def f(c):
        x, y = tr.transform(c[:, 0], c[:, 1])
        return np.column_stack([x, y])
    return shapely.transform(geoms, f)


# ---------------------------------------------------------------- bands

def band_worker(args):
    """Mode-resample the fine raster to zoom z, polygonise, tile one zoom."""
    z, fine_path, origin, out_dir, codes = args
    import rasterio.features as rf
    from rasterio.crs import CRS
    from rasterio.transform import from_origin
    from rasterio.warp import reproject as rreproject, Resampling
    fine = np.load(fine_path, mmap_mode="r")
    x0, y1 = origin
    fine_tr = from_origin(x0, y1, FINE, FINE)
    factor = 4 * 2 ** (10 - z)
    cell = FINE * factor
    H, Wd = fine.shape
    M, N = math.ceil(H / factor), math.ceil(Wd / factor)
    dst = np.zeros((M, N), np.uint8)
    crs = CRS.from_epsg(3857)
    tr = from_origin(x0, y1, cell, cell)
    # No nodata anywhere: sea (0) is a class and votes like any community.
    rreproject(fine, dst, src_transform=fine_tr, src_crs=crs, dst_transform=tr, dst_crs=crs,
               resampling=Resampling.mode, src_nodata=None, dst_nodata=None,
               init_dest_nodata=False, num_threads=1)
    gj = Path(out_dir) / f"band_z{z:02d}.geojsons"
    n = 0
    with open(gj, "w") as f:
        for geom, val in rf.shapes(dst, mask=dst > 0, transform=tr, connectivity=4):
            f.write('{"type":"Feature","properties":{"VEGCODE":"%s"},"geometry":%s}\n'
                    % (codes[int(val) - 1], json.dumps(geom, separators=(",", ":"))))
            n += 1
    present = np.unique(dst)
    mb = Path(out_dir) / f"band_z{z:02d}.mbtiles"
    t = time.time()
    run(["tippecanoe", "-q", "-o", mb, "--force", "-l", "tasveg",
         "-n", NAME, "-A", ATTRIBUTION, "--projection=EPSG:3857",
         f"-Z{z}", f"-z{z}", "--no-tile-size-limit", "--no-feature-limit",
         "--detect-shared-borders", "--no-tiny-polygon-reduction", "--hilbert", gj])
    gj.unlink()
    return z, n, int((present > 0).sum()), cell, round(time.time() - t, 1)


def build_bands(geoms3857, vegcodes, codes, bounds, out_dir: Path, jobs: int):
    import rasterio.features as rf
    from rasterio.transform import from_origin
    idx = {c: i + 1 for i, c in enumerate(codes)}
    x0, y0, x1, y1 = bounds
    N = int(round((x1 - x0) / FINE))
    H = int(round((y1 - y0) / FINE))
    log(f"bands: rasterising {len(geoms3857)} polygons into {N} x {H} cells of {FINE:.2f} m")
    fine = rf.rasterize(zip(geoms3857, (idx[v] for v in vegcodes)), out_shape=(H, N),
                        transform=from_origin(x0, y1, FINE, FINE), fill=0, dtype="uint8")
    fine_path = out_dir / "fine.npy"
    np.save(fine_path, fine)
    land = int((fine > 0).sum())
    del fine
    log(f"bands: fine raster done ({land:,} land cells)")
    tasks = [(z, str(fine_path), (x0, y1), str(out_dir), codes) for z in BAND_ZOOMS]
    results = {}
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        # big (fine) zooms first: they take longest
        for z, n, ncodes, cell, tt in ex.map(band_worker, sorted(tasks, key=lambda t: -t[0])):
            results[z] = (n, ncodes)
            log(f"  band z{z}: cell {cell:,.0f} m, {n:,} polygons, {ncodes} codes, tippecanoe {tt}s")
    fine_path.unlink()
    mbs = [out_dir / f"band_z{z:02d}.mbtiles" for z in BAND_ZOOMS]
    for z, mb in zip(BAND_ZOOMS, mbs):
        check_strategies(mb, f"band z{z}")
    return mbs, results


# ---------------------------------------------------------------- hi zooms

def write_hi(geoms4326, cols, ids, path: Path):
    import shapely
    g = shapely.transform(geoms4326, lambda c: np.round(c, 7))
    gj = shapely.to_geojson(g)
    with open(path, "w", encoding="utf-8") as f:
        for i in range(len(gj)):
            props = {a: cols[a][i] for a in ATTRS}
            f.write('{"type":"Feature","id":%d,"properties":%s,"geometry":%s}\n'
                    % (ids[i], json.dumps(props, ensure_ascii=False, separators=(",", ":")), gj[i]))


def hi_cmd(src: Path, out: Path):
    # NO --coalesce-densest-as-needed (cross-community merges); the size
    # limits are lifted so an oversized tile is shipped whole rather than
    # thinned. --generate-ids only fills features without an id (none: the
    # GeoJSON carries FID + 1, stable across tiles and rebuilds).
    return ["tippecanoe", "-q", "-o", str(out), "--force", "-l", "tasveg", "-n", NAME,
            "-A", ATTRIBUTION, f"-Z{HI_MIN}", f"-z{HI_MAX}", "-P",
            "--generate-ids", "--no-tile-size-limit", "--no-feature-limit",
            "--detect-shared-borders", "--hilbert", str(src)]


# ---------------------------------------------------------------- labels

def label_chunk(wkb_chunk):
    import shapely
    g = shapely.from_wkb(wkb_chunk)
    area = shapely.area(g)
    # tolerance ~1 % of the polygon's size, 0.5–10 m: plenty for label placement
    tol = np.clip(np.sqrt(area) / 100, 0.5, 10.0)
    mic = shapely.maximum_inscribed_circle(g, tol)
    c = shapely.get_coordinates(mic).reshape(-1, 2, 2)
    centre = c[:, 0, :]
    r = np.hypot(c[:, 1, 0] - c[:, 0, 0], c[:, 1, 1] - c[:, 0, 1])
    return centre, r, area


def build_labels(geoms28355, vegcodes, ids, path: Path, jobs: int):
    import shapely
    from pyproj import Transformer
    wkb = shapely.to_wkb(geoms28355)
    chunks = np.array_split(wkb, max(1, jobs * 8))
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        parts = list(ex.map(label_chunk, chunks))
    centre = np.concatenate([p[0] for p in parts])
    r = np.concatenate([p[1] for p in parts])
    area = np.concatenate([p[2] for p in parts])
    inside = shapely.contains_properly(geoms28355, shapely.points(centre)) | (r == 0)
    tr = Transformer.from_crs(28355, 4326, always_xy=True)
    lon, lat = tr.transform(centre[:, 0], centre[:, 1])
    with open(path, "w") as f:
        for i in range(len(ids)):
            f.write('{"type":"Feature","id":%d,"properties":{"VEGCODE":"%s","area":%d,"r":%d},'
                    '"geometry":{"type":"Point","coordinates":[%.7f,%.7f]}}\n'
                    % (ids[i], vegcodes[i], round(area[i]), round(r[i]), lon[i], lat[i]))
    return r, area, int((~inside).sum())


def tile_labels(src: Path, out: Path):
    # -r1: keep EVERY point at z13 too (default drop-rate thins below maxzoom)
    run(["tippecanoe", "-q", "-o", out, "--force", "-l", "tasveg_labels", "-n", NAME,
         "-A", ATTRIBUTION, f"-Z{LABEL_MIN}", f"-z{LABEL_MAX}", "-r1",
         "--no-tile-size-limit", "--no-feature-limit", "--hilbert", src])


# ---------------------------------------------------------------- checks

def scan_tiles(mb: Path, zoom: int, layer: str):
    """→ (distinct feature ids, distinct VEGCODEs, max tile bytes) at one zoom."""
    from mapbox_vector_tile.Mapbox import vector_tile_pb2
    ids, codes, biggest = set(), set(), 0
    with sqlite3.connect(mb) as db:
        for (data,) in db.execute("SELECT tile_data FROM tiles WHERE zoom_level=?", (zoom,)):
            biggest = max(biggest, len(data))
            t = vector_tile_pb2.tile()
            t.ParseFromString(gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data)
            for lyr in t.layers:
                if lyr.name != layer:
                    continue
                k = list(lyr.keys).index("VEGCODE") if "VEGCODE" in lyr.keys else -1
                vals = [v.string_value for v in lyr.values]
                for ft in lyr.features:
                    if ft.HasField("id"):
                        ids.add(ft.id)
                    tg = ft.tags
                    for j in range(0, len(tg), 2):
                        if tg[j] == k:
                            codes.add(vals[tg[j + 1]])
                            break
    return ids, codes, biggest


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clip", help="Z/X/Y web-mercator tile (test build)")
    ap.add_argument("--jobs", type=int, default=6)
    args = ap.parse_args()
    import shapely
    clip = tuple(map(int, args.clip.split("/"))) if args.clip else None
    out_dir = WORK / ("tasveg_clip" if clip else "tasveg_v2")
    out_dir.mkdir(parents=True, exist_ok=True)
    final = (out_dir / "tasveg_clip.pmtiles") if clip else DATA / "tasveg_v2.pmtiles"

    if not clip:
        log("community table (QML + distinct codes)")
        import csv
        import pyogrio
        with zipfile.ZipFile(ZIP) as z:
            (WORK / "TASVEG_5_0.qml").write_bytes(z.read(QML_IN_ZIP))
        _, tab = pyogrio.read_arrow(f"/vsizip/{ZIP}/{SHP_IN_ZIP}",
                                    columns=["VEGCODE", "VEGCODE_D", "VEG_GROUP"], read_geometry=False)
        rows = sorted(set(zip(*(tab.column(c).to_pylist() for c in ("VEGCODE", "VEGCODE_D", "VEG_GROUP")))))
        with open(WORK / "communities.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["VEGCODE", "VEGCODE_D", "VEG_GROUP"])
            w.writerows(rows)
        run([sys.executable, HERE / "build_style.py"])

    clip_b = tile_bounds(*clip) if clip else None
    log("reading source")
    g28355, cols, ids = read_source(clip_b)
    n_src = len(g28355)
    log(f"source: {n_src:,} polygons")
    if not clip and n_src != EXPECTED_FEATURES:
        print(f"WARNING: {n_src} features, expected {EXPECTED_FEATURES} — new TASVEG release?")
    vegcodes = cols["VEGCODE"]
    codes = sorted(set(vegcodes))
    assert len(codes) < 255, len(codes)
    g3857 = reproject(g28355, 28355, 3857)
    g4326 = reproject(g28355, 28355, 4326)
    log("reprojected")

    # band grid: snapped outward to multiples of a z0 point so every band's
    # cells sit exactly on its tile grid (one cell = 8 units of a 4096 tile)
    if clip:
        bounds = clip_b
    else:
        b = shapely.total_bounds(g3857)
        snap = lambda v, up: (math.ceil if up else math.floor)((v + W) / PT0) * PT0 - W
        bounds = (snap(b[0], 0), snap(b[1], 0), snap(b[2], 1), snap(b[3], 1))

    # z11–14 source tiles in the background while the bands run
    hi_src = out_dir / "hi.geojsons"
    write_hi(g4326, cols, ids, hi_src)
    log(f"hi: GeoJSON written ({hi_src.stat().st_size / 1e9:.2f} GB); tippecanoe z{HI_MIN}-{HI_MAX} started")
    hi_mb = out_dir / "hi.mbtiles"
    t_hi = time.time()
    hi_proc = subprocess.Popen(hi_cmd(hi_src, hi_mb))

    band_mbs, band_res = build_bands(g3857, vegcodes, codes, bounds, out_dir, args.jobs)
    del g3857

    log("labels: maximum inscribed circles")
    lab_src = out_dir / "labels.geojsons"
    r, area, outside = build_labels(g28355, vegcodes, ids, lab_src, args.jobs)
    log(f"labels: {len(r):,} points; r (m) p10/50/90 = "
        f"{np.percentile(r, 10):.0f}/{np.percentile(r, 50):.0f}/{np.percentile(r, 90):.0f}; "
        f"{(r >= 20).sum():,} with r ≥ 20 m; {outside} not strictly inside")
    lab_mb = out_dir / "labels.mbtiles"
    tile_labels(lab_src, lab_mb)
    check_strategies(lab_mb, "labels")
    log("labels: tiled")

    if hi_proc.wait() != 0:
        raise SystemExit("tippecanoe (z11-14) failed")
    log(f"hi: tippecanoe done ({time.time() - t_hi:.0f}s since start)")
    tiny = check_strategies(hi_mb, "z11-14")

    # ---- tripwires on the parts
    ids14, codes14, max14 = scan_tiles(hi_mb, HI_MAX, "tasveg")
    lost = n_src - len(ids14)
    log(f"z14: {len(ids14):,} of {n_src:,} source polygons present ({lost} missing; "
        f"tiny-polygon reductions per zoom {tiny}); {len(codes14)} codes; max tile {max14 / 1024:.0f} KB")
    if lost > max(50, n_src * 0.001):
        raise SystemExit(f"z14 lost {lost} polygons")
    missing = set(codes) - codes14
    if missing:
        raise SystemExit(f"codes missing at z14: {sorted(missing)}")
    if not clip:
        table = set(json.loads(TABLE.read_text()))
        if table - codes14:
            raise SystemExit(f"table codes absent from z14 tiles: {sorted(table - codes14)}")
        if codes14 - table:
            raise SystemExit(f"tile codes missing from the table: {sorted(codes14 - table)}")
    lab_ids, _, maxl = scan_tiles(lab_mb, LABEL_MAX, "tasveg_labels")
    if len(lab_ids) != n_src:
        raise SystemExit(f"labels z14: {len(lab_ids)} of {n_src}")
    lab13, _, _ = scan_tiles(lab_mb, LABEL_MIN, "tasveg_labels")
    if len(lab13) != n_src:
        raise SystemExit(f"labels z13: {len(lab13)} of {n_src} (drop-rate?)")
    log(f"labels: all {n_src:,} at z13 and z14; max label tile {maxl / 1024:.0f} KB")

    # ---- join
    joined = out_dir / "tasveg.mbtiles"
    run(["tile-join", "-q", "-o", joined, "--force", "--no-tile-size-limit",
         "-n", NAME, "-A", ATTRIBUTION, *band_mbs, hi_mb, lab_mb])
    final.unlink(missing_ok=True)
    run(["pmtiles", "convert", joined, final], capture_output=True)
    log(f"{final}: {final.stat().st_size / 1e6:.1f} MB")
    if not clip:
        check_bounds(hi_mb, final)
    for p in (hi_src, lab_src):
        p.unlink(missing_ok=True)
    log("done")


def check_bounds(hi_mb: Path, final: Path):
    """Source-polygon tiles must match the old archive's bounds (±0.01°: a CRS
    slip or a lost island moves them far more); the whole archive may reach a
    little further — coarse band cells overhang the coast by part of a cell."""
    with sqlite3.connect(hi_mb) as db:
        hb = [float(v) for v in db.execute(
            "SELECT value FROM metadata WHERE name='bounds'").fetchone()[0].split(",")]
    show = subprocess.run(["pmtiles", "show", str(final)], capture_output=True, text=True).stdout
    line = next(l for l in show.splitlines() if l.startswith("bounds:"))
    fb = [float(v) for v in line.replace(")", " ").replace(",", " ").split() if _isnum(v)]
    log(f"bounds: z11-14 {hb}, archive {fb}")
    if max(abs(a - b) for a, b in zip(hb, OLD_BOUNDS)) > 0.01:
        raise SystemExit(f"z11-14 bounds {hb} differ from the old archive {OLD_BOUNDS}")
    if max(abs(a - b) for a, b in zip(fb, hb)) > 0.25:
        raise SystemExit(f"archive bounds {fb} reach far beyond the source {hb}")


def _isnum(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


if __name__ == "__main__":
    main()

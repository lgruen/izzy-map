#!/usr/bin/env python3
"""Build offline topo raster packs (PMTiles) from the LIST Topographic tile
service, one per region in regions.json, plus the statewide low-zoom
'overview' pack.

Usage:
    python3 build_regions.py [region_id ...]     # default: overview only
    python3 build_regions.py --all
    python3 build_regions.py --estimate          # tile counts only, no fetch

Politeness/robustness:
  - tiles cached on disk in cache/topo/{z}/{y}/{x}.png — reruns are free,
    interrupted runs resume
  - 8 concurrent requests, courtesy delay between batches
  - HTTP 404 / empty tiles are recorded as absent and skipped

The LIST service is CC BY 3.0 AU with exportTilesAllowed=true — bulk offline
caching is explicitly permitted. Attribution embedded in each pack.
NOTE: ArcGIS tile path is /tile/{z}/{y}/{x} — row (y) BEFORE column (x).

Output: ../data/topo_<id>.pmtiles (data-manifest.json is produced by upload_r2.sh).

Stdlib only (urllib + sqlite3 + concurrent.futures).
"""
import concurrent.futures
import json
import math
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BASE = "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic/MapServer/tile"
ATTRIBUTION = "Topographic Basemap from theLIST (CC BY 3.0 AU) © State of Tasmania"
HERE = Path(__file__).parent
CACHE = HERE / "cache" / "topo"
DATA = HERE.parent / "data"
CONCURRENCY = 8
RETRIES = 3


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    lat_r = math.radians(lat)
    y = int((1 - math.asinh(math.tan(lat_r)) / math.pi) / 2 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tiles_at(bbox, z):
    w, s, e, n = bbox
    x0, y0 = lonlat_to_tile(w, n, z)   # top-left
    x1, y1 = lonlat_to_tile(e, s, z)   # bottom-right
    return [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


# Tiles below this are treated as blank ocean and their descendants skipped
# (from z13 down). Empirically validated 2026-08-30 across the full statewide
# fetch: zero pruned tiles had >=1000 B, and every checked offshore islet
# (Maatsuyker, Tasman Is, Albatross Is, ...) stays comfortably above it. BUT
# the distributions overlap: ocean tiles with labels reach ~2.2 KB (false
# keeps, harmless) and the smallest land-edge tiles sit ~1.3 KB — only ~300 B
# of margin. Re-validate before raising maxzoom past 15 or reusing for other
# services. NOTE: 404s are cached as permanently-absent marker files in
# cache/topo — clear those if the LIST service had an outage during a run.
PRUNE_THRESHOLD = 1000
PRUNE_FROM_Z = 13


def fetch_tile(z, x, y):
    """Return tile bytes, b'' if absent (404/empty), raise on repeated failure."""
    p = CACHE / str(z) / str(y) / f"{x}.png"
    if p.exists():
        return p.read_bytes()  # b'' marker files mean 'known absent'
    err = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(
                f"{BASE}/{z}/{y}/{x}", headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                data = b""
                break
            err = e
        except Exception as e:  # noqa: BLE001 — retry everything else
            err = e
        time.sleep(1.5 * (attempt + 1))
    else:
        raise RuntimeError(f"tile {z}/{y}/{x} failed after {RETRIES} tries: {err}")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    return data


def build_pack(pack_id, name, bbox, zmin, zmax, prune=False, estimate_only=False):
    if estimate_only:
        total = sum(len(tiles_at(bbox, z)) for z in range(zmin, zmax + 1))
        print(f"[{pack_id}] {name}: z{zmin}-{zmax}, {total} candidate tiles (pre-prune)")
        return None
    print(f"[{pack_id}] {name}: z{zmin}-{zmax}, prune={prune}")

    mbt = HERE / "work" / f"topo_{pack_id}.mbtiles"
    mbt.parent.mkdir(exist_ok=True)
    mbt.unlink(missing_ok=True)
    db = sqlite3.connect(mbt)
    db.executescript(
        """
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER,
                            tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles
            (zoom_level, tile_column, tile_row);
        """
    )
    w, s, e, n = bbox
    for k, v in {
        "name": f"IzzyMap topo — {name}",
        "format": "png",
        "type": "baselayer",
        "version": "1",
        "minzoom": str(zmin),
        "maxzoom": str(zmax),
        "bounds": f"{w},{s},{e},{n}",
        "attribution": ATTRIBUTION,
    }.items():
        db.execute("INSERT INTO metadata VALUES (?,?)", (k, v))

    t0 = time.time()
    done = absent = pruned_total = 0
    total_bytes = 0
    kept_parents = None  # set of (x, y) at previous zoom that had content
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        for z in range(zmin, zmax + 1):
            candidates = tiles_at(bbox, z)
            if prune and z >= PRUNE_FROM_Z and kept_parents is not None:
                before = len(candidates)
                candidates = [(z, x, y) for z, x, y in candidates
                              if (x // 2, y // 2) in kept_parents]
                pruned_total += before - len(candidates)
            kept = set()
            futs = {pool.submit(fetch_tile, z, x, y): (z, x, y)
                    for z, x, y in candidates}
            for fut in concurrent.futures.as_completed(futs):
                tz, x, y = futs[fut]
                data = fut.result()
                done += 1
                if not data:
                    absent += 1
                    continue
                if len(data) >= PRUNE_THRESHOLD:
                    kept.add((x, y))
                total_bytes += len(data)
                tms_y = (2 ** tz) - 1 - y  # MBTiles uses TMS row order
                db.execute("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)",
                           (tz, x, tms_y, sqlite3.Binary(data)))
                if done % 2000 == 0:
                    rate = done / (time.time() - t0)
                    print(f"  z{tz}: {done} tiles, {total_bytes/1e6:.0f} MB, "
                          f"{rate:.0f} tiles/s", flush=True)
            db.commit()
            kept_parents = kept
            print(f"  z{z} done: {len(candidates)} fetched, {len(kept)} with content", flush=True)
    print(f"  pruned {pruned_total} ocean-descendant tiles")
    db.close()

    DATA.mkdir(exist_ok=True)
    out = DATA / f"topo_{pack_id}.pmtiles"
    subprocess.run(["pmtiles", "convert", str(mbt), str(out)], check=True)
    mbt.unlink()
    size = out.stat().st_size
    print(f"[{pack_id}] done: {done - absent} tiles ({absent} absent), "
          f"{size/1e6:.1f} MB -> {out.name}, {time.time()-t0:.0f}s")
    return {"id": pack_id, "name": name, "bbox": bbox, "minzoom": zmin,
            "maxzoom": zmax, "bytes": size, "file": out.name}


def main():
    cfg = json.loads((HERE / "regions.json").read_text())
    args = sys.argv[1:]
    estimate = "--estimate" in args
    want_all = "--all" in args or not [a for a in args if not a.startswith("--")]
    ids = [a for a in args if not a.startswith("--")]

    for r in cfg["packs"]:
        if not (want_all or r["id"] in ids):
            continue
        build_pack(r["id"], r["name"], r["bbox"], r.get("minzoom", 12),
                   r["maxzoom"], prune=r.get("prune", False),
                   estimate_only=estimate)


if __name__ == "__main__":
    main()

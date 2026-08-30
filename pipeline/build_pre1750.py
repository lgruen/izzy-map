#!/usr/bin/env python3
"""Build data/pre1750.pmtiles + app/src/generated/pre1750_units.json from
NVIS V7.0 "Estimated Pre-1750 Vegetation" (Major Vegetation Subgroups).

Source (verified 2026-08-30, CC BY 4.0): DCCEEW's national NVIS raster
distribution — 100 m cells, GDA2020 Australian Albers, in a FileGDB with
both the MVS (subgroups, ~80 classes) and MVG (groups, 31 classes) rasters
and their attribute tables. Tasmania's pre-1750 content descends from the
RFA-era reconstruction (frozen since NVIS 6.0). There is NO state-published
pre-European map — this national compilation is the best available.

Approach: crop both rasters to Tasmania, polygonize the MVS classes
(connected 1-ha cell regions), and ship MVS number + official colour in the
tiles; names/groups/areas live in pre1750_units.json (geology pattern).
Official class colours come from the NVIS_pre_mvs MapServer legend swatches
(the .lyr symbology in the zip is a binary blob; the legend is the same
renderer served as PNGs).

Run: python3 pipeline/build_pre1750.py
(osgeo + numpy come from the brew gdal formula's python bindings — the one
dependency uv cannot provide; the pillow-needing legend-swatch decode shells
out to `uv run --with pillow` per the no-pip rule. Also needs tippecanoe /
tile-join / pmtiles CLIs from brew. Downloads the 112 MB source once.)
"""
import json
import sqlite3
import subprocess
import time
import urllib.request
from pathlib import Path

import numpy as np
from osgeo import gdal

gdal.UseExceptions()

HERE = Path(__file__).parent
CACHE = HERE / "cache"
WORK = HERE / "work"
DATA = HERE.parent / "data"
GEN = HERE.parent / "app" / "src" / "generated"

ZIP_NAME = "NVIS_V7_0_AUST_RASTERS_PRE_ALL.zip"
# ArcGIS Online item "Australia - Pre1750 Major Vegetation Groups and
# Subgroups - NVIS Version 7.0 Rasters Download" (CC BY 4.0, DCCEEW)
ZIP_URL = "https://www.arcgis.com/sharing/rest/content/items/d82f6eab808542ee9d9a0ea09ea36567/data"
GDB = WORK / "NVIS_V7_0_AUST_RASTERS_PRE_ALL" / "NVIS_V7_0_AUST_PRE.gdb"
LEGEND_URL = "https://gis.environment.gov.au/gispubmap/rest/services/ogc_services/NVIS_pre_mvs/MapServer/legend?f=json"
ATTRIBUTION = "Pre-1750 vegetation: NVIS V7.0 (CC BY 4.0) © Commonwealth of Australia (DCCEEW)"

# Tasmania + Bass Strait islands, EPSG:4326 (matches the app's world).
# The -te box only sets the extent; validity comes from the cutline below —
# a plain envelope in Albers bulges north of the box corners and pulled in
# Victorian coast (Corner Inlet mangroves!) on the first attempt.
TE = ("143.5", "-44.1", "149.4", "-39.0")
# Tas–Vic maritime border: 39°12'S. Everything Tasmanian (incl. Hogan Group,
# -39.22) lies south of it. Densified so the parallel stays a parallel in
# Albers rather than a straight chord.
LAT_N, LAT_S, LON_W, LON_E = -39.2, -44.3, 143.0, 150.0
NODATA = 255


def write_cutline(path: Path) -> None:
    step = 0.05
    n = int((LON_E - LON_W) / step)
    top = [[LON_W + i * step, LAT_N] for i in range(n + 1)]
    bottom = [[LON_E - i * step, LAT_S] for i in range(n + 1)]
    ring = top + bottom + [top[0]]
    path.write_text(json.dumps({
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "EPSG:4326"}},
        "features": [{"type": "Feature", "properties": {},
                      "geometry": {"type": "Polygon", "coordinates": [ring]}}],
    }))

# Non-vegetation bookkeeping classes that must not render as "what grew
# here": open water/sea and the unknowns. Naturally bare (sand, rock) STAYS
# — dunes and mountaintops are a real pre-1750 land cover.
DROP_NAMES = {
    "Unknown/No data",
    "Sea, estuaries (includes seagrass)",
    "Salt lakes and lagoons",
    "Freshwater, dams, lakes, lagoons or aquatic plants",
}


def fetch(url: str, dest: Path, what: str) -> None:
    if dest.exists():
        return
    print(f"downloading {what} -> {dest.name}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=300) as r, open(tmp, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            tmp.rename(dest)
            return
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  download failed ({e}), retrying")
            time.sleep(5 * (attempt + 1))


def read_rat(subdataset: str) -> dict[int, dict]:
    """Raster attribute table rows keyed by pixel value."""
    ds = gdal.Open(f'OpenFileGDB:"{GDB}":{subdataset}')
    rat = ds.GetRasterBand(1).GetDefaultRAT()
    cols = [rat.GetNameOfCol(i) for i in range(rat.GetColumnCount())]
    rows = {}
    for r in range(rat.GetRowCount()):
        row = {}
        for i, name in enumerate(cols):
            t = rat.GetTypeOfCol(i)
            row[name] = (rat.GetValueAsString(r, i) if t == gdal.GFT_String
                         else rat.GetValueAsDouble(r, i) if t == gdal.GFT_Real
                         else rat.GetValueAsInt(r, i))
        rows[int(row["Value"])] = row
    return rows


def crop(subdataset: str, out: Path, cutline: Path) -> None:
    subprocess.run([
        "gdalwarp", "-overwrite",
        "-t_srs", "EPSG:9473",  # stay in the native Albers CRS
        # -tap anchors the output grid to multiples of 100 m; without it the
        # grid hangs off the reprojected -te corner and every cell resamples
        # ~20 m off the source grid (review finding). The NVIS origin itself
        # sits 0.33 m off round multiples — that residual is irreducible.
        "-te", *TE, "-te_srs", "EPSG:4326",
        "-tr", "100", "100", "-tap", "-r", "near",
        "-cutline", str(cutline),
        "-dstnodata", str(NODATA),
        "-co", "COMPRESS=DEFLATE",
        f'OpenFileGDB:"{GDB}":{subdataset}', str(out),
    ], check=True)


# Decodes the legend's base64 PNG swatches to per-label hex colours. Runs
# under `uv run --with pillow` (pillow is not a brew formula; the no-pip
# rule says uv provides it).
DECODE_SWATCHES = """
import base64, io, json, sys
from PIL import Image
layers = json.load(sys.stdin)["layers"]
colors = {}
for e in layers[0]["legend"]:
    img = Image.open(io.BytesIO(base64.b64decode(e["imageData"]))).convert("RGB")
    w, h = img.size
    px = img.getpixel((w // 2, h // 2))
    # solid-fill swatches only: if the legend ever grows borders/hatching,
    # a single sampled pixel would be a silent wrong answer — fail instead
    for dx, dy in ((-3, -3), (3, -3), (-3, 3), (3, 3)):
        other = img.getpixel((w // 2 + dx, h // 2 + dy))
        assert other == px, f"non-uniform swatch for {e['label']!r}: {px} vs {other}"
    colors[e["label"]] = "#%02x%02x%02x" % px
json.dump(colors, sys.stdout)
"""


def national_mvs_to_mvg() -> dict[int, int]:
    """MVS -> parent MVG by majority vote over the whole NATIONAL rasters
    (~13 s, cached). The Tasmania crop alone is not trustworthy for this:
    its MVG cells code the tussock grasslands as "Heathlands", contradicting
    both the MVS layer and the national pairing (review finding). The two
    grids still disagree on ~1% of boundary cells (independent
    rasterisations of the same source polygons) — hence a vote at all.
    """
    cache = WORK / "mvs_to_mvg_national.json"
    if cache.exists():
        return {int(k): v for k, v in json.loads(cache.read_text()).items()}
    print("computing national MVS->MVG pairing (one-time, ~15 s)")
    mvs_ds = gdal.Open(f'OpenFileGDB:"{GDB}":NVIS7_0_AUST_PRE_MVS_ALB')
    mvg_ds = gdal.Open(f'OpenFileGDB:"{GDB}":NVIS7_0_AUST_PRE_MVG_ALB')
    xs, ys = mvs_ds.RasterXSize, mvs_ds.RasterYSize
    pair = np.zeros(1 << 16, dtype=np.int64)
    for y0 in range(0, ys, 4096):  # block-wise: the full grids are 1.5 G cells
        n = min(4096, ys - y0)
        a = mvs_ds.GetRasterBand(1).ReadAsArray(0, y0, xs, n).ravel().astype(np.uint32)
        b = mvg_ds.GetRasterBand(1).ReadAsArray(0, y0, xs, n).ravel().astype(np.uint32)
        pair += np.bincount((a << 8) | b, minlength=1 << 16)
    best: dict[int, tuple[int, int]] = {}  # mvs -> (mvg, cells)
    for p in np.nonzero(pair)[0].tolist():
        v, g, c = p >> 8, p & 0xFF, int(pair[p])
        if v in (0, NODATA) or g in (0, NODATA):
            continue
        if v not in best or c > best[v][1]:
            best[v] = (g, c)
    mapping = {v: g for v, (g, _) in sorted(best.items())}
    cache.write_text(json.dumps({str(v): g for v, g in mapping.items()}))
    return mapping


def legend_colors() -> dict[str, str]:
    """Official colour per MVS_NAME, decoded from the service legend swatches."""
    lj = WORK / "mvs_legend.json"
    fetch(LEGEND_URL, lj, "NVIS MVS legend")
    out = subprocess.run(["uv", "run", "--with", "pillow", "python3", "-c",
                          DECODE_SWATCHES],
                         input=lj.read_text(), capture_output=True,
                         text=True, check=True)
    return json.loads(out.stdout)


def main():
    for d in (CACHE, WORK, DATA, GEN):
        d.mkdir(parents=True, exist_ok=True)
    fetch(ZIP_URL, CACHE / ZIP_NAME, "NVIS V7.0 pre-1750 rasters (112 MB)")
    if not GDB.exists():
        subprocess.run(["unzip", "-oq", str(CACHE / ZIP_NAME), "-d", str(WORK)], check=True)

    mvs_rat = read_rat("NVIS7_0_AUST_PRE_MVS_ALB")
    mvg_rat = read_rat("NVIS7_0_AUST_PRE_MVG_ALB")
    # The 0->nodata fold below and NODATA=255 both assume neither value is a
    # real class — make a future re-keyed NVIS release fail loudly instead
    # of silently punching holes in the map.
    for rat, which in ((mvs_rat, "MVS"), (mvg_rat, "MVG")):
        assert 0 not in rat and NODATA not in rat, \
            f"{which} RAT defines value 0 or {NODATA}: revisit nodata handling"

    cutline = WORK / "pre1750_cutline.geojson"
    write_cutline(cutline)
    mvs_tif = WORK / "pre1750_mvs_tas.tif"
    crop("NVIS7_0_AUST_PRE_MVS_ALB", mvs_tif, cutline)
    # With a cutline, warp reads source-mask-invalid cells (the sea) as raw
    # value 0 instead of mapping them to dstnodata — fold them into nodata
    # so the majority resampling and polygonize masks keep working.
    ds = gdal.Open(str(mvs_tif), gdal.GA_Update)
    band = ds.GetRasterBand(1)
    a = band.ReadAsArray()
    a[a == 0] = NODATA
    band.WriteArray(a)
    ds.FlushCache()
    band = None
    ds = None  # release the update handle before gdalwarp/polygonize re-open it

    mvs = a  # the array just written — no need to round-trip through disk
    valid = mvs != NODATA
    mvs_to_mvg = national_mvs_to_mvg()
    # A same-named MVG is the authoritative parent and trumps the vote:
    # bookkeeping classes ("Unclassified native vegetation") overlay noisy
    # MVG cells nationally and majority-voted into "Eucalypt Woodlands".
    mvg_by_name = {r["MVG_NAME"]: v for v, r in mvg_rat.items()}
    for v, r in mvs_rat.items():
        if r["MVS_NAME"] in mvg_by_name:
            mvs_to_mvg[v] = mvg_by_name[r["MVS_NAME"]]
    counts = np.bincount(mvs[valid], minlength=256)

    colors = legend_colors()
    print(f"{'ha':>9}  MVS  name")
    units: dict[str, dict] = {}
    kept: set[int] = set()
    for v in sorted(np.nonzero(counts)[0].tolist()):
        row = mvs_rat[v]
        name = row["MVS_NAME"]
        drop = name in DROP_NAMES
        print(f"{counts[v]:>9}  {v:>3}  {name}{'   [dropped]' if drop else ''}")
        if drop:
            continue
        kept.add(v)
        g = mvg_rat[mvs_to_mvg[v]]
        # Sanity: name vs group. Tasmania's own MVG cells file the tussock
        # grasslands (MVS 36/37, ~116k ha incl. the Midlands' most
        # conservation-significant communities) under "Heathlands" — a
        # verified upstream inconsistency the national mapping avoids; this
        # guard catches any such name/group contradiction sneaking back in.
        # (endswith, not contains: woodland classes legitimately mention a
        # "wet tussock grassland" UNDERSTOREY in their names)
        if name.lower().endswith("tussock grasslands"):
            assert "grassland" in g["MVG_NAME"].lower(), \
                f"MVS {v} '{name}' grouped under '{g['MVG_NAME']}'"
        units[str(v)] = {
            "name": name,
            "group": g["MVG_NAME"],
            "groupDesc": g["MVG_COMMON_DESC"],
            "color": colors[name],  # KeyError = legend out of sync: fail loudly
            "order": row["SORT_ORDER"],
            "groupOrder": g["SORT_ORDER"],
            "ha": int(counts[v]),  # 1 cell = 1 ha, within the Tasmania crop
        }

    units_path = GEN / "pre1750_units.json"
    units_path.write_text(json.dumps(units, indent=1, ensure_ascii=False))
    groups = {u["group"] for u in units.values()}
    print(f"{len(units)} MVS classes across {len(groups)} MVG groups; wrote {units_path}")

    # Render raster: dropped classes (water, unknown) become nodata BEFORE
    # the coarse-band mode resampling — otherwise an estuary can win a mixed
    # 1600 m block and then be discarded, leaving a hole where the runner-up
    # land class should show (review finding: coastal classes were
    # systematically under-represented at z<=6).
    render_tif = WORK / "pre1750_mvs_render.tif"
    src_ds = gdal.Open(str(mvs_tif))
    out_ds = gdal.GetDriverByName("GTiff").CreateCopy(
        str(render_tif), src_ds, options=["COMPRESS=DEFLATE"])
    src_ds = None
    a = mvs.copy()
    a[~np.isin(a, list(kept))] = NODATA
    out_ds.GetRasterBand(1).WriteArray(a)
    out_ds.FlushCache()
    out_ds = None

    # ---- zoom-banded tiling ----
    # The source is a categorical 100 m grid. Letting tippecanoe squeeze
    # oversized low-zoom tiles itself coalesces ACROSS classes (it kept as
    # little as 0.4% of features for the statewide tiles — and the statewide
    # view is the most-seen view). Instead, generalise the RASTER per zoom
    # band with majority (mode) resampling — the categorically correct
    # generalisation — polygonize each band, and tile-join. Cell size stays
    # ~1 px at each band's minzoom (57 m/px at z11 at 42°S; overzoom beyond).
    BANDS = [  # (cell metres, minzoom, maxzoom)
        (100, 10, 11),
        (200, 9, 9),
        (400, 8, 8),
        (800, 7, 7),
        (1600, 0, 6),
    ]
    # 0/1 land raster for the coastline mask below (no nodata set, so the
    # "average" resample counts sea cells as 0 and yields the land fraction)
    land_tif = WORK / "pre1750_land01.tif"
    land_ds = gdal.GetDriverByName("GTiff").Create(
        str(land_tif), int(a.shape[1]), int(a.shape[0]), 1, gdal.GDT_Byte,
        options=["COMPRESS=DEFLATE"])
    ref = gdal.Open(str(render_tif))
    land_ds.SetGeoTransform(ref.GetGeoTransform())
    land_ds.SetProjection(ref.GetProjection())
    land_ds.GetRasterBand(1).WriteArray((a != NODATA).astype(np.uint8))
    land_ds.FlushCache()
    land_ds = None
    ref = None

    band_tiles: list[Path] = []
    for cell, z0, z1 in BANDS:
        tif = render_tif if cell == 100 else WORK / f"pre1750_mvs_tas_{cell}.tif"
        if cell != 100:
            subprocess.run(["gdalwarp", "-overwrite", "-q",
                            "-tr", str(cell), str(cell), "-r", "mode",
                            "-co", "COMPRESS=DEFLATE",
                            str(render_tif), str(tif)], check=True)
            # `-r mode` ignores nodata, so one land cell wins a whole coarse
            # block — measured +8% fake land at 1600 m, a one-pixel colour
            # bleed past the topo coastline in the most-seen tiles (review
            # finding). Re-mask: keep a coarse cell only where the true land
            # fraction is >= 0.5 (area-balanced coastline, not a dilated one).
            frac_tif = WORK / f"pre1750_landfrac_{cell}.tif"
            subprocess.run(["gdalwarp", "-overwrite", "-q",
                            "-tr", str(cell), str(cell), "-r", "average",
                            "-ot", "Float32",
                            str(land_tif), str(frac_tif)], check=True)
            bd = gdal.Open(str(tif), gdal.GA_Update)
            bband = bd.GetRasterBand(1)
            ba = bband.ReadAsArray()
            frac = gdal.Open(str(frac_tif)).ReadAsArray()
            assert ba.shape == frac.shape, (cell, ba.shape, frac.shape)
            ba[frac < 0.5] = NODATA
            bband.WriteArray(ba)
            bd.FlushCache()
            bband = None
            bd = None
        gpkg = WORK / f"pre1750_polys_{cell}.gpkg"
        gpkg.unlink(missing_ok=True)
        # nodata cells are mask-excluded; connected same-class cell regions
        # become one polygon each
        subprocess.run(["gdal_polygonize", "-q", str(tif), "-f", "GPKG",
                        str(gpkg), "pre1750", "DN"], check=True)
        raw = WORK / f"pre1750_raw_{cell}.geojsonl"
        subprocess.run(["ogr2ogr", "-f", "GeoJSONSeq", str(raw),
                        "-t_srs", "EPSG:4326", str(gpkg)], check=True)
        ndjson = WORK / f"pre1750_{cell}.geojsonl"
        n = 0
        with open(raw, encoding="utf-8") as src, open(ndjson, "w", encoding="utf-8") as out:
            for line in src:
                f = json.loads(line)
                dn = int(f["properties"]["DN"])
                if dn not in kept:
                    continue
                # tiles carry only what rendering needs (geology pattern)
                f["properties"] = {"MVS": str(dn), "color": units[str(dn)]["color"]}
                out.write(json.dumps(f, ensure_ascii=False) + "\n")
                n += 1
        print(f"band {cell} m (z{z0}-z{z1}): {n} polygons")
        if cell == 100:
            assert n > 50_000, f"suspiciously few polygons: {n}"
        # --coalesce merges only SAME-property features (tap answers stay
        # correct). NO as-needed fallbacks on ANY band: those merge ACROSS
        # classes — wrong colour + wrong tap answer, silently. The banding
        # keeps every tile comfortably under the limit; if a future rebuild
        # oversizes one, tippecanoe erroring out is the correct failure mode
        # (geology stance), and the strategies check below backs it up.
        mb = WORK / f"pre1750_{cell}.mbtiles"
        subprocess.run([
            "tippecanoe", "-o", str(mb), "--force", "-q",
            "-l", "pre1750", "-n", "Pre-1750 vegetation (NVIS V7.0 MVS)",
            "-A", ATTRIBUTION,
            f"-Z{z0}", f"-z{z1}",
            "--coalesce",
            "--detect-shared-borders", "--hilbert",
            str(ndjson),
        ], check=True)
        with sqlite3.connect(mb) as db:
            row = db.execute(
                "SELECT value FROM metadata WHERE name='strategies'").fetchone()
        # tiny_polygons is the only strategy tippecanoe should report here,
        # and it is class-safe: the reduced dust square keeps its own
        # feature's attributes (verified in tippecanoe's clip.cpp). Anything
        # else (dropped_*, coalesced_as_needed, detail_reduced) means a tile
        # overflowed and features were mangled — fail the build.
        allowed = {"tiny_polygons"}
        for z, strat in enumerate(json.loads(row[0]) if row else []):
            bad = set(strat) - allowed
            if bad:
                raise SystemExit(
                    f"band {cell} m: class-unsafe tile strategy at z{z}: {bad}")
        band_tiles.append(mb)

    joined = WORK / "pre1750.mbtiles"
    subprocess.run(["tile-join", "-o", str(joined), "--force",
                    "-n", "Pre-1750 vegetation (NVIS V7.0 MVS)",
                    "-A", ATTRIBUTION,
                    *map(str, band_tiles)], check=True)
    subprocess.run(["pmtiles", "convert", str(joined),
                    str(DATA / "pre1750.pmtiles")], check=True)
    size = (DATA / "pre1750.pmtiles").stat().st_size
    print(f"pre1750.pmtiles: {size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()

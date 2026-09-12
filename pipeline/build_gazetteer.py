#!/usr/bin/env python3
"""Build the two offline search indexes committed under app/public/search/:

  gazetteer.json  – ~45k named places (Nomenclature register rows + address-
                    derived streets + property names), each with a centre,
                    type/group, locality, council and — where known — a bbox.
  addresses.json  – every street in the LIST address points, with its house
                    numbers and one coordinate per number (delta-encoded).

Sources (verified 2026-09-12, all CC BY 3.0 AU © State of Tasmania):

- Nomenclature register (35,835 points): OpenDataWFS `LIST_Nomenclature`.
  Fields used: NOM_REG_NO, FEAT_NAME, DUALNAME ("kunanyi / Mount Wellington"),
  FEAT_TYPE, FEAT_GROUP, STATUS, DISP_STAT, NAMETYPE, MUNY.  The WFS encodes
  empty text as the string "null" — see `empty()`.  Kept: STATUS == "Normal"
  and DISP_STAT == "DISPLAYED" (~32k), minus administrative abstractions
  (DROP_TYPES).
- Locality polygons (777): OpenDataWFS `LIST_Locality_and_Postcode_Areas`
  (NAME, POSTCODE) — spatial join gives every row its suburb/locality.
- Road geometry: Public/TopographyAndRelief MapServer layer 8 (Transport
  Segments, 273k polylines).  Only PRI_NOMREG / SEC_NOMREG (register numbers
  of the primary / secondary name) are pulled, at ~20 m precision, and
  reduced to one bbox per register number.  Paged REST (2000/page, ~140
  pages × 1.2 MB), one cached file per page → resumable.
- Named Feature Extents (7,344 polygons, MGA55) from LISTdata: bbox per
  register number for area features (hills, bays, plains, towns, …).
- Address points (301,619, MGA55) from LISTdata: streets + numbers, property
  names, and the streets the register lacks (address-derived extras).

WFS gotcha: with `srsName=EPSG:4326` the server emits [lat, lon] (EPSG axis
order); without srsName it emits [lon, lat].  We omit srsName AND detect the
order from the data (Tasmania's lat ≈ −42 vs lon ≈ 147 is unambiguous).
`resultType=hits` returns an empty body with GEOJSON output, so paging just
runs until a short page.  ArcGIS REST reports errors inside HTTP-200 bodies.

Run (no pip — third-party libs come from uv, everything else is stdlib):

    uv run --with shapely --with pyshp --with pyproj python3 pipeline/build_gazetteer.py
    ... --fresh   wipes pipeline/cache/gazetteer/ first (full re-download)

Idempotent: every download is cached under pipeline/cache/gazetteer/ (the
two LISTdata zips can be dropped there by hand to skip ~106 MB), outputs are
written via .part + rename with deterministic ordering (only `built`
changes between identical runs).  Runtime ≈ 80 s cold (network) + 8 s
processing, ≈ 9 s warm (measured 2026-09-12).

Refresh cadence: yearly (the register grows by a few hundred names a year;
address points are re-published quarterly).  After a refresh, eyeball the
FEAT_TYPE histogram for new administrative types to add to DROP_TYPES.

Count tripwires (31–34k kept register rows, 250–275k house numbers, 13–15k
street groups; asserted in main()) are pinned to the 2026-09 pull and are
EXPECTED to drift as LIST republishes: when one fires after a refresh,
eyeball the stage output (dropped counts, samples, histograms) and widen the
window — they exist to catch a truncated pull or a parser regression, not
growth.
"""
from __future__ import annotations

import argparse
import difflib
import gzip
import io
import json
import math
import re
import shutil
import time
import unicodedata
import urllib.parse
import urllib.request
import zipfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

import numpy as np
import shapefile  # pyshp
import shapely
from pyproj import Transformer
from shapely import STRtree
from shapely.geometry import shape

HERE = Path(__file__).parent
CACHE = HERE / "cache" / "gazetteer"
SEG_CACHE = CACHE / "segments"
OUT = HERE.parent / "app" / "public" / "search"

WFS = "https://services.thelist.tas.gov.au/arcgis/services/Public/OpenDataWFS/MapServer/WFSServer"
SEG_LAYER = "https://services.thelist.tas.gov.au/arcgis/rest/services/Public/TopographyAndRelief/MapServer/8"
EXTENTS_URL = "https://listdata.thelist.tas.gov.au/opendata/data/LIST_NAMED_FEATURE_EXTENT_STATEWIDE.zip"
ADDR_URL = "https://listdata.thelist.tas.gov.au/opendata/data/LIST_ADDRESS_POINTS_STATEWIDE.zip"
UA = "IzzyMap-pipeline/1.0 (personal use)"

SEG_PAGE = 2000  # server maxRecordCount
WFS_PAGE = 1000  # the server caps at 1000 anyway (learned per pull)
SEG_WORKERS = 4

# Tasmania + Bass Strait islands (w, s, e, n).  Macquarie Island (158.9°E)
# and anything Victorian fall outside.  A past build pulled Victorian coast
# into a Tasmania crop, hence the centroid assert on the locality polygons.
BOUNDS = (143.5, -44.2, 149.5, -39.0)

# Administrative abstractions with no place on the ground a hiker would
# search for.  Decided from the full FEAT_TYPE histogram (109 types on
# 2026-09-12): these three are the only ones; "Parish", "Municipality",
# "Region", "Postcode", "Statistical …" do not occur in the WFS layer.  The
# ⊆-observed assert in main() catches typos and renamed types.
DROP_TYPES = {"Electorate", "Municipal Area", "Land District"}

# FEAT_GROUP values in display order, plus our own "Property" bucket.
GROUPS = ["Transport", "Natural Feature", "Cultural", "Reserve", "Recreation",
          "Infrastructure", "Property"]

# PROP_NAME values that are unit/lot designations, not names.  The word must
# be followed by a number, a single letter or nothing ("LOT 2", "UNITS 1 & 2",
# "Unit A", "SHOP") so that farm names like "Flat Rock" / "Level Lodge" survive.
PROP_NOISE_RE = re.compile(r"^(?:(?:lot|unit|flat|shop|level)s?(?=\s*(?:\d|[a-z]\b|$))|(?:first|ground) floor\b|rear\b)",
                           re.I)
# a property name used in this many localities is a generic label ("Telstra
# Exchange", "Service Station", "Public Open Space"), not a place
GENERIC_PROP_LOCALITIES = 5

# address-derived extras: ST_TYPE → register FEAT_TYPE (everything else that
# is non-empty is a street type → "Road"); a spelling variant of a register
# road within this distance of the extra's centre is a duplicate, not a road
EXTRA_TRACK_TYPES = {"TRACK", "TRAIL"}
NEAR_M = 300
NEAR_RATIO = 0.9

GAZ_ATTRIBUTION = "Place and street names from theLIST © State of Tasmania (CC BY 3.0 AU)"
ADDR_ATTRIBUTION = "Street addresses from theLIST © State of Tasmania (CC BY 3.0 AU)"

# ---------------------------------------------------------------- utilities


class Stage:
    """`with Stage("name"):` prints the elapsed time when the block ends."""

    def __init__(self, name: str):
        self.name = name

    def __enter__(self):
        print(f"\n== {self.name}")
        self.t0 = time.time()
        return self

    def __exit__(self, *exc):
        print(f"   [{self.name}: {time.time() - self.t0:.1f} s]")


def empty(v) -> bool:
    """The WFS emits the string "null" for empty text fields."""
    return v is None or str(v).strip() in ("", "null", "None")


def text(v) -> str:
    return "" if empty(v) else str(v).strip()


def norm(s: str) -> str:
    """Search key: lowercase, accents stripped, non-alphanumerics → space."""
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^0-9a-z]+", " ", s.lower()).split())


_SMALL = {"of", "the", "and", "on", "at", "by", "in", "de", "du", "la", "le"}
# stays UPPER CASE ("IXL Complex", "RSL Club", "TAFE"); "Anzac" is deliberately
# not listed — it is written as a word in Tasmanian usage
_ACRONYMS = {w.lower() for w in (
    "IXL RSL CWA TAS ANZ ABC DCC HEC TAFE CSIRO YMCA SES CBD CFA SDA RAAF RSPCA NAB "
    "DPIPWE NRE PWS UTAS TMAG SBS HCC LCC GCC CCC").split()}


def title_case(s: str) -> str:
    """UPPER CASE → Title Case for address fields.  Beyond str.title():
    "O'CONNOR'S" → "O'Connor's" (only a one-letter prefix capitalises past an
    apostrophe), "MCDONALD" → "McDonald", small words stay lower mid-name,
    a letter after any separator ("/", "(", "-", "&") is capitalised, and
    _ACRONYMS keep their capitals ("RSL Club", not "Rsl Club")."""
    tokens = re.split(r"([^0-9A-Za-z']+)", s.strip().lower())  # words / separators
    out = []
    for i, tok in enumerate(tokens):
        if i % 2 == 1 or not tok:  # separator (or empty edge token)
            out.append(tok)
            continue
        if tok in _ACRONYMS:
            out.append(tok.upper())
            continue
        segs = tok.split("'")
        fixed = [segs[0][:1].upper() + segs[0][1:]]
        for k in range(1, len(segs)):
            seg = segs[k]
            # O'Brien / D'Entrecasteaux: capitalise after a 1-letter prefix
            if k == 1 and len(segs[0]) == 1:
                seg = seg[:1].upper() + seg[1:]
            fixed.append(seg)
        w = "'".join(fixed)
        if w[:2] == "Mc" and len(w) > 3:
            w = "Mc" + w[2].upper() + w[3:]
        if i > 0 and w.lower() in _SMALL and tokens[i - 1] == " ":
            w = w.lower()
        out.append(w)
    return "".join(out)


def http_get(url: str, timeout: int = 180, attempts: int = 3) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read()
                if r.headers.get("Content-Encoding", "").lower() == "gzip":
                    body = gzip.decompress(body)
            return body
        except Exception as e:  # noqa: BLE001
            if attempt == attempts - 1:
                raise
            print(f"  request failed ({e}), retrying: {url[:100]}")
            time.sleep(5 * (attempt + 1))
    raise AssertionError


def parse_arcgis_json(body: bytes, what: str) -> dict:
    try:
        d = json.loads(body)
    except ValueError:
        # WFS failures arrive as an XML ExceptionReport with HTTP 200
        raise RuntimeError(f"{what}: non-JSON response: {body[:200]!r}") from None
    if isinstance(d, dict) and "error" in d:  # ArcGIS REST errors are HTTP 200
        raise RuntimeError(f"{what}: server error {d['error']}")
    return d


def fetch(url: str, dest: Path, what: str) -> None:
    """Cached download: .part + rename so a killed run never leaves a
    truncated file that a later run would trust."""
    if dest.exists():
        return
    print(f"downloading {what} -> {dest.name}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
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


def write_json(path: Path, obj) -> tuple[int, int]:
    """Compact JSON via .part + rename; returns (raw, gzip) byte sizes."""
    data = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_bytes(data)
    tmp.rename(path)
    return len(data), len(gzip.compress(data, 9))


def in_bounds(lon: float, lat: float) -> bool:
    w, s, e, n = BOUNDS
    return w <= lon <= e and s <= lat <= n


def merge_bbox(acc: dict, key: str, xs, ys) -> None:
    w, s, e, n = min(xs), min(ys), max(xs), max(ys)
    b = acc.get(key)
    if b is None:
        acc[key] = [w, s, e, n]
    else:
        b[0] = min(b[0], w); b[1] = min(b[1], s); b[2] = max(b[2], e); b[3] = max(b[3], n)


def reg_key(v) -> str:
    """Register numbers look like "30893F" on both sides; normalise anyway
    (whitespace/case) so a format drift shows up as low coverage, loudly."""
    return text(v).upper().replace(" ", "")


# ------------------------------------------------------------------- WFS


def _first_position(coords):
    while isinstance(coords[0], (list, tuple)):
        coords = coords[0]
    return coords


def _swap(coords):
    if isinstance(coords[0], (int, float)):
        return [coords[1], coords[0]]
    return [_swap(c) for c in coords]


def fix_axis_order(fc: dict, what: str) -> None:
    """Make every geometry [lon, lat].  Decided from the data: in Tasmania
    |lat| < 90 < lon, so a first coordinate with |x| <= 90 means lat-first."""
    feats = [f for f in fc["features"] if f.get("geometry")]
    x, y = _first_position(feats[0]["geometry"]["coordinates"])
    latlon = abs(x) <= 90 < abs(y)
    if latlon:
        print(f"  {what}: WFS emitted [lat, lon] — swapping axis order")
        for f in feats:
            f["geometry"]["coordinates"] = _swap(f["geometry"]["coordinates"])
    for f in feats[:: max(1, len(feats) // 200)]:  # spot-check ~200 features
        x, y = _first_position(f["geometry"]["coordinates"])
        assert 140 <= x <= 160 and -56 <= y <= -38, f"{what}: odd coordinate {x},{y}"


def wfs_fetch(type_name: str, dest: Path, min_count: int) -> dict:
    """Whole WFS layer as one cached GeoJSON FeatureCollection.  The server
    silently caps `count` (5000 requested → 1000 delivered), so the effective
    page size is learned from the first page and paging stops at the first
    page shorter than that (or an empty one).  The count is asserted BEFORE
    the file is cached so a truncated pull can never poison later runs."""
    if dest.exists():
        fc = json.loads(dest.read_bytes())
    else:
        feats, start, cap = [], 0, None
        while True:
            q = urllib.parse.urlencode({
                "service": "WFS", "version": "2.0.0", "request": "GetFeature",
                "outputFormat": "GEOJSON",  # NO srsName: see module docstring
                "typeNames": f"Public_OpenDataWFS:{type_name}",
                "count": WFS_PAGE, "startIndex": start,
            })
            page = parse_arcgis_json(http_get(f"{WFS}?{q}"), type_name)
            got = page.get("features", [])
            feats.extend(got)
            if not got:
                break
            if cap is None:
                cap = len(got)
                if cap < WFS_PAGE:
                    print(f"  {type_name}: server page cap is {cap}")
            print(f"  {type_name}: {len(feats)} features")
            if len(got) < cap:
                break
            start += len(got)
        ids = [f["properties"].get("OBJECTID") for f in feats]
        assert len(set(ids)) == len(ids), f"{type_name}: paging returned duplicate OBJECTIDs"
        assert len(feats) >= min_count, f"{type_name}: only {len(feats)} features (expected ≥ {min_count})"
        fc = {"type": "FeatureCollection", "features": feats}
        tmp = dest.with_suffix(".part")
        tmp.write_text(json.dumps(fc, ensure_ascii=False))
        tmp.rename(dest)
    fix_axis_order(fc, type_name)
    return fc


# -------------------------------------------------------- transport segments


def seg_page_url(offset: int) -> str:
    q = urllib.parse.urlencode({
        "where": "1=1",
        "outFields": "PRI_NOMREG,SEC_NOMREG",
        "outSR": "4326",
        "geometryPrecision": "5",
        "maxAllowableOffset": "0.0002",  # ~20 m generalisation: bbox-only use
        "orderByFields": "OBJECTID",  # explicit stable paging order
        "resultOffset": offset,
        "resultRecordCount": SEG_PAGE,
        "f": "geojson",
    })
    return f"{SEG_LAYER}/query?{q}"


def fetch_segments() -> tuple[dict[str, list[float]], dict]:
    """bbox per register number over all transport segments, from one cached
    JSON file per REST page (skips pages already on disk, redoes corrupt
    ones).  Returns (bboxes, stats)."""
    SEG_CACHE.mkdir(parents=True, exist_ok=True)
    count_file = SEG_CACHE / "count.json"
    if count_file.exists():
        # keep the count the cached pages were fetched against
        total = json.loads(count_file.read_text())["count"]
    else:
        total = parse_arcgis_json(
            http_get(f"{SEG_LAYER}/query?where=1%3D1&returnCountOnly=true&f=json"),
            "segments count")["count"]
        count_file.write_text(json.dumps({"count": total}))
    n_pages = math.ceil(total / SEG_PAGE)
    print(f"  {total} segments → {n_pages} pages of {SEG_PAGE}")

    fetched = Counter()

    def full(d: dict, i: int) -> bool:
        """Every page but the last must hold exactly SEG_PAGE features — a
        shorter one is a truncated/partial server response, not a cache hit."""
        return i == n_pages - 1 or len(d["features"]) == SEG_PAGE

    def get_page(i: int) -> dict:
        path = SEG_CACHE / f"page-{i:05d}.json"
        if path.exists():
            try:
                d = json.loads(path.read_bytes())
                if "features" in d and full(d, i):
                    fetched["cached"] += 1
                    return d
                print(f"  segments page {i}: cached copy is short ({len(d.get('features', []))} features) → refetching")
            except ValueError:
                pass
            path.unlink()  # corrupt (killed mid-write without .part?) or truncated → redo
        body = http_get(seg_page_url(i * SEG_PAGE))
        d = parse_arcgis_json(body, f"segments page {i}")
        if "features" not in d:
            raise RuntimeError(f"segments page {i}: no features key: {body[:200]!r}")
        if not full(d, i):
            raise RuntimeError(f"segments page {i}: server returned {len(d['features'])} features, expected {SEG_PAGE}")
        tmp = path.with_suffix(".part")
        tmp.write_bytes(body)
        tmp.rename(path)
        fetched["network"] += 1
        if fetched["network"] % 10 == 0:
            print(f"  fetched {fetched['network']} pages")
        return d

    bboxes: dict[str, list[float]] = {}
    stats = Counter()
    samples: list[str] = []
    with ThreadPoolExecutor(SEG_WORKERS) as ex:
        for page in ex.map(get_page, range(n_pages)):
            for f in page["features"]:
                stats["segments"] += 1
                p = f.get("properties") or {}
                regs = [reg_key(p.get("PRI_NOMREG")), reg_key(p.get("SEC_NOMREG"))]
                if regs[0]:
                    stats["with PRI_NOMREG"] += 1
                    if len(samples) < 8:
                        samples.append(regs[0])
                if regs[1]:
                    stats["with SEC_NOMREG"] += 1
                g = f.get("geometry")
                if not g or not any(regs):
                    continue
                lines = g["coordinates"] if g["type"] == "MultiLineString" else [g["coordinates"]]
                xs = [c[0] for line in lines for c in line]
                ys = [c[1] for line in lines for c in line]
                if not xs:
                    continue
                for r in regs:
                    if r:
                        merge_bbox(bboxes, r, xs, ys)
    print(f"  pages: {fetched['cached']} cached, {fetched['network']} fetched")
    drift = abs(stats["segments"] - total) / total
    assert drift < 0.01, f"segments: pages hold {stats['segments']}, count says {total}"
    stats["register numbers with bbox"] = len(bboxes)
    stats["samples"] = samples  # type: ignore[assignment]
    return bboxes, stats


# ----------------------------------------------------------------- shapefiles


def open_zip_shapefile(zip_path: Path, stem: str) -> shapefile.Reader:
    with zipfile.ZipFile(zip_path) as z:
        members = {ext: io.BytesIO(z.read(f"{stem}.{ext}")) for ext in ("shp", "shx", "dbf")}
    return shapefile.Reader(shp=members["shp"], shx=members["shx"], dbf=members["dbf"],
                            encoding="utf-8", encodingErrors="replace")


def load_extents(zip_path: Path) -> tuple[dict[str, list[float]], Counter]:
    """bbox (EPSG:4326) per register number from the MGA55 extent polygons.
    All vertices are reprojected (not just the MGA bbox corners — a
    projected rectangle's edges bow in geographic coordinates)."""
    sf = open_zip_shapefile(zip_path, "list_named_feature_extent_statewide")
    tr = Transformer.from_crs("EPSG:28355", "EPSG:4326", always_xy=True)
    bboxes: dict[str, list[float]] = {}
    types = Counter()
    for shp, rec in zip(sf.iterShapes(), sf.iterRecords(fields=["NOM_REG_NO", "FEAT_TYPE"])):
        reg = reg_key(rec["NOM_REG_NO"])
        if not reg or not shp.points:
            continue
        pts = np.asarray(shp.points, dtype=float)
        lon, lat = tr.transform(pts[:, 0], pts[:, 1])
        merge_bbox(bboxes, reg, lon, lat)
        types[rec["FEAT_TYPE"]] += 1
    return bboxes, types


# -------------------------------------------------------------------- main


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--fresh", action="store_true", help="wipe the cache dir first")
    args = ap.parse_args()
    t_all = time.time()

    if args.fresh and CACHE.exists():
        print(f"--fresh: removing {CACHE}")
        shutil.rmtree(CACHE)
    CACHE.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)

    # ---------------------------------------------------------------- pull
    with Stage("fetch nomenclature (WFS)"):
        nomen = wfs_fetch("LIST_Nomenclature", CACHE / "nomenclature.geojson", 35_000)
        print(f"  {len(nomen['features'])} raw nomenclature features")
        assert len(nomen["features"]) >= 35_000, "suspiciously few nomenclature rows"

    with Stage("fetch localities (WFS)"):
        locs = wfs_fetch("LIST_Locality_and_Postcode_Areas", CACHE / "localities.geojson", 700)
        print(f"  {len(locs['features'])} locality polygons")
        assert 700 <= len(locs["features"]) <= 900, "unexpected locality count"

    with Stage("fetch transport segments (REST, paged, cached)"):
        seg_bbox, seg_stats = fetch_segments()
        print(f"  segments: {seg_stats['segments']}, with PRI_NOMREG {seg_stats['with PRI_NOMREG']}, "
              f"with SEC_NOMREG {seg_stats['with SEC_NOMREG']}, register numbers with bbox "
              f"{seg_stats['register numbers with bbox']}")
        print(f"  PRI_NOMREG samples: {seg_stats['samples']}")

    with Stage("fetch LISTdata zips"):
        ext_zip = CACHE / "LIST_NAMED_FEATURE_EXTENT_STATEWIDE.zip"
        addr_zip = CACHE / "LIST_ADDRESS_POINTS_STATEWIDE.zip"
        fetch(EXTENTS_URL, ext_zip, "named feature extents (13.5 MB)")
        fetch(ADDR_URL, addr_zip, "address points (93 MB)")

    # ------------------------------------------------------------ localities
    with Stage("locality polygons"):
        loc_geoms, loc_names = [], []
        for f in locs["features"]:
            g = shape(f["geometry"])
            if not g.is_valid:
                g = g.buffer(0)
            c = g.centroid
            assert in_bounds(c.x, c.y), f"locality {f['properties'].get('NAME')} centroid outside Tasmania: {c}"
            loc_geoms.append(g)
            loc_names.append(text(f["properties"].get("NAME")))
        loc_tree = STRtree(loc_geoms)
        loc_by_norm = {norm(n): i for i, n in enumerate(loc_names)}
        print(f"  {len(loc_geoms)} polygons, e.g. {loc_names[:5]}")

    # ---------------------------------------------------------- nomenclature
    with Stage("nomenclature rows"):
        feats = nomen["features"]
        type_hist = Counter(text(f["properties"].get("FEAT_TYPE")) for f in feats)
        print(f"  FEAT_TYPE histogram ({len(type_hist)} types, all rows):")
        for t, n in type_hist.most_common():
            print(f"    {n:6d}  {t}")
        missing = DROP_TYPES - set(type_hist)
        assert not missing, f"DROP_TYPES not observed (typo?): {missing}"
        print(f"  DROP_TYPES = {sorted(DROP_TYPES)}")

        status = Counter((text(f["properties"].get("STATUS")), text(f["properties"].get("DISP_STAT")))
                         for f in feats)
        print(f"  (STATUS, DISP_STAT) top: {status.most_common(6)}")
        nom_samples = [reg_key(f["properties"].get("NOM_REG_NO")) for f in feats[:8]]
        print(f"  NOM_REG_NO samples: {nom_samples}  vs PRI_NOMREG: {seg_stats['samples']}")

        # candidate rows after status / type / bounds filters
        cand = []  # dicts
        drop = Counter()
        for f in feats:
            p = f["properties"]
            if text(p.get("STATUS")) != "Normal" or text(p.get("DISP_STAT")) != "DISPLAYED":
                drop["status"] += 1
                continue
            ftype = text(p.get("FEAT_TYPE"))
            if ftype in DROP_TYPES:
                drop["type"] += 1
                continue
            g = f.get("geometry")
            if g and g.get("coordinates"):
                lon, lat = g["coordinates"]
            else:
                lon, lat = float(p.get("LONGITUDE")), float(p.get("LATITUDE"))
            if not in_bounds(lon, lat):
                drop["bounds"] += 1
                continue
            dual = text(p.get("DUALNAME"))
            name = dual or text(p.get("FEAT_NAME"))
            if not name:
                drop["noname"] += 1
                continue
            cand.append({
                "name": name, "dual": dual, "feat_name": text(p.get("FEAT_NAME")),
                "type": ftype, "group": text(p.get("FEAT_GROUP")),
                "nametype": text(p.get("NAMETYPE")), "muny": text(p.get("MUNY")),
                "reg": reg_key(p.get("NOM_REG_NO")), "lon": lon, "lat": lat,
            })
        print(f"  dropped: {dict(drop)} → {len(cand)} candidates")

        # Standalone Aboriginal-name rows that are already one half of a kept
        # dual name would show twice in search results.
        dual_parts = set()
        for r in cand:
            if r["dual"]:
                dual_parts.update(norm(x) for x in r["dual"].split("/"))
        abor = [r for r in cand if r["nametype"] == "Aboriginal"]
        print(f"  NAMETYPE=Aboriginal rows ({len(abor)}):")
        for r in abor:
            print(f"    {r['name']!r:45} {r['type']:20} dual={r['dual']!r}")
        before = len(cand)
        cand = [r for r in cand if not (r["nametype"] == "Aboriginal" and not r["dual"]
                                        and norm(r["name"]) in dual_parts)]
        print(f"  dropped {before - len(cand)} standalone Aboriginal rows duplicated by a dual name; kept: "
              f"{[r['name'] for r in cand if r['nametype'] == 'Aboriginal' and not r['dual']]}")

        # exact duplicates (same name, type and position) — belt and braces
        seen = set()
        uniq = []
        for r in cand:
            k = (r["name"], r["type"], round(r["lat"], 5), round(r["lon"], 5))
            if k not in seen:
                seen.add(k)
                uniq.append(r)
        print(f"  {len(cand) - len(uniq)} exact duplicates removed → {len(uniq)} name rows")
        cand = uniq
        assert 31_000 <= len(cand) <= 34_000, f"kept name rows out of range: {len(cand)}"

    # ---------------------------------------------------------- spatial join
    with Stage("locality join (STRtree within)"):
        pts = shapely.points(np.array([[r["lon"], r["lat"]] for r in cand]))
        pi, li = loc_tree.query(pts, predicate="within")
        row_loc = {}
        for a, b in zip(pi.tolist(), li.tolist()):
            row_loc.setdefault(a, b)  # localities don't overlap; first wins
        for i, r in enumerate(cand):
            r["loc"] = row_loc.get(i)  # polygon index or None
        joined = sum(1 for r in cand if r["loc"] is not None)
        print(f"  {joined}/{len(cand)} rows inside a locality polygon ({100 * joined / len(cand):.1f} %)")

        # locality → council: majority MUNY of the register points inside it
        # (features spanning councils carry a comma list — skipped as votes)
        votes: dict[int, Counter] = defaultdict(Counter)
        for r in cand:
            if r["loc"] is not None and r["muny"] and "," not in r["muny"]:
                votes[r["loc"]][r["muny"]] += 1
        loc_muny = {i: c.most_common(1)[0][0] for i, c in votes.items()}
        print(f"  council derived for {len(loc_muny)}/{len(loc_geoms)} localities")

    # --------------------------------------------------------------- extents
    with Stage("named feature extents"):
        ext_bbox, ext_types = load_extents(ext_zip)
        print(f"  {sum(ext_types.values())} polygons → {len(ext_bbox)} register numbers; "
              f"types: {ext_types.most_common(8)}")

    # ---------------------------------------------------------------- bboxes
    with Stage("attach bboxes"):
        src = Counter()
        outside = 0
        for r in cand:
            b = seg_bbox.get(r["reg"]) or ext_bbox.get(r["reg"])
            if b:
                src["segments" if r["reg"] in seg_bbox else "extents"] += 1
                pad = 0.01  # ~1 km: register points are not always inside
                if not (b[0] - pad <= r["lon"] <= b[2] + pad and b[1] - pad <= r["lat"] <= b[3] + pad):
                    outside += 1
                # the app frames the bbox and marks the point: make sure the
                # point is inside (a copy — the source bboxes are shared per reg)
                b = [min(b[0], r["lon"]), min(b[1], r["lat"]), max(b[2], r["lon"]), max(b[3], r["lat"])]
            r["bbox"] = b
        roads = [r for r in cand if r["type"] == "Road"]
        roads_bb = sum(1 for r in roads if r["bbox"])
        routes = [r for r in cand if r["type"] == "Route"]
        routes_bb = sum(1 for r in routes if r["bbox"])
        ext_matched = sum(1 for r in cand if r["reg"] in ext_bbox)
        print(f"  bbox source: {dict(src)}; rows with bbox {sum(1 for r in cand if r['bbox'])}/{len(cand)}")
        print(f"  roads with bbox: {roads_bb}/{len(roads)} ({100 * roads_bb / max(1, len(roads)):.1f} %)")
        print(f"  routes with bbox: {routes_bb}/{len(routes)}")
        print(f"  extents matched to kept rows: {ext_matched}; point outside own bbox (+1 km): {outside} (bbox widened to include it)")
        assert all(b[0] <= r["lon"] <= b[2] and b[1] <= r["lat"] <= b[3] for r in cand if (b := r["bbox"]))
        assert roads_bb >= 0.9 * len(roads), "road bbox coverage < 90 % — check the register-number join"
        assert ext_matched >= 6_000, f"extents matched only {ext_matched}"

    # ------------------------------------------------------------- addresses
    with Stage("address points (pyshp + pyproj)"):
        sf = open_zip_shapefile(addr_zip, "list_address_points_statewide")
        fields = ["PROP_NAME", "ST_NO_FROM", "NO1_SUFFIX", "STREET", "ST_TYPE", "ST_SUFFIX", "LOCALITY"]
        xy = np.array([s.points[0] if s.points else (np.nan, np.nan) for s in sf.iterShapes()], dtype=float)
        tr = Transformer.from_crs("EPSG:28355", "EPSG:4326", always_xy=True)
        lon, lat = tr.transform(xy[:, 0], xy[:, 1])
        recs = list(sf.iterRecords(fields=fields))
        assert len(recs) == len(lon) >= 290_000, f"address points: {len(recs)}"

        # (street, locality) → {(number, suffix): [sum_lon, sum_lat, n]}
        streets: dict[tuple[str, str], dict[tuple[int, str], list[float]]] = defaultdict(dict)
        # (street, locality) → ST_TYPE histogram (empty = the label had no type)
        st_types: dict[tuple[str, str], Counter] = defaultdict(Counter)
        # (property name, locality) → [sum_lon, sum_lat, n]
        props: dict[tuple[str, str], list[float]] = {}
        adrop = Counter()
        noise_seen: Counter = Counter()
        for i, rec in enumerate(recs):
            x, y = float(lon[i]), float(lat[i])
            if not (x == x) or not in_bounds(x, y):
                adrop["bounds/nogeom"] += 1
                continue
            locality = title_case(text(rec["LOCALITY"]))
            pname = text(rec["PROP_NAME"])
            if pname and len(pname) >= 3 and not re.fullmatch(r"[\d\s\-/]+", pname):
                if PROP_NOISE_RE.match(pname):
                    adrop["property noise"] += 1
                    noise_seen[pname] += 1
                else:
                    k = (title_case(pname), locality)
                    acc = props.setdefault(k, [0.0, 0.0, 0])
                    acc[0] += x; acc[1] += y; acc[2] += 1
            street = text(rec["STREET"])
            no = rec["ST_NO_FROM"]
            if not street or empty(no):
                adrop["no street/number"] += 1
                continue
            no = int(float(no))
            if no <= 0:
                adrop["number<=0"] += 1
                continue
            label = " ".join(title_case(t) for t in (street, text(rec["ST_TYPE"]), text(rec["ST_SUFFIX"])) if t)
            acc = streets[(label, locality)].setdefault((no, text(rec["NO1_SUFFIX"]).upper()), [0.0, 0.0, 0])
            acc[0] += x; acc[1] += y; acc[2] += 1  # units collapse onto the building number
            st_types[(label, locality)][text(rec["ST_TYPE"]).upper()] += 1
        n_numbers = sum(len(v) for v in streets.values())
        print(f"  {len(recs)} points; skipped {dict(adrop)}")
        print(f"  property-name noise dropped ({len(noise_seen)} distinct): {sorted(noise_seen)}")
        print(f"  {len(streets)} street groups, {n_numbers} distinct numbers, {len(props)} property names")
        assert 13_000 <= len(streets) <= 15_000, f"street groups: {len(streets)}"
        assert 250_000 <= n_numbers <= 275_000, f"numbers: {n_numbers}"

    # ------------------------------------------------- address-derived extras
    with Stage("address-derived street extras"):
        # register roads (all Transport-group rows: a "Track" may carry addresses)
        by_name: dict[str, list[dict]] = defaultdict(list)
        for r in cand:
            if r["group"] == "Transport":
                by_name[norm(r["name"])].append(r)
                if r["dual"]:
                    for part in r["dual"].split("/"):
                        by_name[norm(part)].append(r)
        # register Transport rows by position (points) and by padded bbox, for
        # the spelling-variant check ("Hawkesford Road" vs register "Hawksford Road")
        tr_rows = [r for r in cand if r["group"] == "Transport"]
        near_lat = NEAR_M / 111_000
        near_lon = near_lat / math.cos(math.radians(42))
        tr_pt_tree = STRtree(shapely.points(np.array([[r["lon"], r["lat"]] for r in tr_rows])))
        tr_bb_rows = [r for r in tr_rows if r["bbox"]]
        tr_bb_tree = STRtree([shapely.box(b[0] - near_lon, b[1] - near_lat, b[2] + near_lon, b[3] + near_lat)
                              for b in (r["bbox"] for r in tr_bb_rows)])
        assert {"Road", "Track"} <= {r["type"] for r in cand}

        def near_variant(name: str, cx: float, cy: float):
            """(register row, ratio, how) for a Transport row whose name is a
            near-spelling of `name` and whose point is within NEAR_M of
            (cx, cy) — or whose road bbox, padded by NEAR_M, contains it."""
            key = norm(name)
            cands = [(tr_rows[j], "point") for j in
                     tr_pt_tree.query(shapely.box(cx - near_lon, cy - near_lat, cx + near_lon, cy + near_lat)).tolist()]
            cands += [(tr_bb_rows[j], "bbox") for j in tr_bb_tree.query(shapely.Point(cx, cy)).tolist()]
            best = None
            for r, how in cands:
                for n in [r["name"]] + (r["dual"].split("/") if r["dual"] else []):
                    ratio = difflib.SequenceMatcher(None, key, norm(n)).ratio()
                    if ratio >= NEAR_RATIO and (best is None or ratio > best[1]):
                        best = (r, ratio, how)
            return best

        st_type_vocab = {t for c in st_types.values() for t in c if t}  # every ST_TYPE seen
        extras = []
        reasons = Counter()
        near_dups, untyped = [], []
        for (label, locality), nums in streets.items():
            xs = [a[0] / a[2] for a in nums.values()]
            ys = [a[1] / a[2] for a in nums.values()]
            gb = (min(xs), min(ys), max(xs), max(ys))
            loc_idx = loc_by_norm.get(norm(locality))
            matched = False
            for r in by_name.get(norm(label), []):
                # same locality (register point's polygon vs the address LOCALITY)
                if loc_idx is not None and r["loc"] == loc_idx:
                    matched, why = True, "locality"; break
                if r["loc"] is not None and norm(loc_names[r["loc"]]) == norm(locality):
                    matched, why = True, "locality"; break
                pad = 0.002  # ~200 m
                if r["bbox"]:
                    b = r["bbox"]
                    if b[0] - pad <= gb[2] and gb[0] <= b[2] + pad and b[1] - pad <= gb[3] and gb[1] <= b[3] + pad:
                        matched, why = True, "bbox"; break
                elif gb[0] - 0.005 <= r["lon"] <= gb[2] + 0.005 and gb[1] - 0.005 <= r["lat"] <= gb[3] + 0.005:
                    matched, why = True, "point"; break
            if matched:
                reasons[why] += 1
                continue
            typed = {t: n for t, n in st_types[(label, locality)].items() if t}
            if not typed and label.split()[-1].upper() in st_type_vocab:
                typed = {label.split()[-1].upper(): 1}  # STREET="ESPLANADE", no ST_TYPE: the name IS the type
            if not typed:  # "Preservation Island", "Foreshore Reserve": not a street
                reasons["skipped: no ST_TYPE"] += 1
                untyped.append(f"{label} ({locality})")
                continue
            cx, cy = sum(xs) / len(xs), sum(ys) / len(ys)
            dup = near_variant(label, cx, cy)
            if dup:
                reasons["skipped: near-duplicate"] += 1
                near_dups.append(f"{label} ({locality}) ~ register {dup[0]['name']!r} "
                                 f"[{dup[0]['type']}] ratio {dup[1]:.2f} by {dup[2]}")
                continue
            reasons["extra"] += 1
            st_type = max(typed, key=typed.get)
            extras.append({
                "name": label, "type": "Track" if st_type in EXTRA_TRACK_TYPES else "Road", "group": "Transport",
                "locality": locality, "loc": loc_idx,
                "muny": loc_muny.get(loc_idx, "") if loc_idx is not None else "",
                "lon": cx, "lat": cy, "bbox": list(gb),
            })
        print(f"  street groups matched to register roads by {dict(reasons)}")
        print(f"  {len(untyped)} groups without ST_TYPE skipped: {sorted(untyped)}")
        print(f"  {len(near_dups)} near-duplicates of register roads skipped:")
        for d in sorted(near_dups):
            print(f"    {d}")
        sample = [f"{e['name']} ({e['locality']})" for e in extras[:25]]
        print(f"  {len(extras)} address-derived street rows added "
              f"({Counter(e['type'] for e in extras).most_common()}), e.g. {sample}")

    with Stage("property rows"):
        # props is already one entry per (name, locality); a name spread over
        # GENERIC_PROP_LOCALITIES+ localities is a generic label, not a place
        name_locs: dict[str, set[str]] = defaultdict(set)
        for pname, locality in props:
            name_locs[norm(pname)].add(locality)
        generic = {n for n, ls in name_locs.items() if len(ls) >= GENERIC_PROP_LOCALITIES}
        prop_rows = []
        dropped: Counter = Counter()
        for (pname, locality), acc in props.items():
            if norm(pname) in generic:
                dropped[pname] += 1
                continue
            loc_idx = loc_by_norm.get(norm(locality))
            prop_rows.append({
                "name": pname, "type": "Property", "group": "Property",
                "locality": locality, "loc": loc_idx,
                "muny": loc_muny.get(loc_idx, "") if loc_idx is not None else "",
                "lon": acc[0] / acc[2], "lat": acc[1] / acc[2], "bbox": None,
            })
        print(f"  {len(generic)} generic property names (≥ {GENERIC_PROP_LOCALITIES} localities) dropped, "
              f"{sum(dropped.values())} rows:")
        for n, c in dropped.most_common():
            print(f"    {c:4d}  {n}")
        print(f"  {len(prop_rows)} property rows added; most repeated remaining names (one row per locality): "
              f"{Counter(r['name'] for r in prop_rows).most_common(8)}")

    # ------------------------------------------------------- gazetteer.json
    with Stage("write gazetteer.json"):
        # type table: register types by frequency, then our Property bucket
        type_counts = Counter(r["type"] for r in cand)
        types = [t for t, _ in sorted(type_counts.items(), key=lambda kv: (-kv[1], kv[0]))] + ["Property"]
        type_idx = {t: i for i, t in enumerate(types)}
        # FEAT_TYPE → FEAT_GROUP should be functional; take the majority if not
        tg_votes: dict[str, Counter] = defaultdict(Counter)
        for r in cand:
            tg_votes[r["type"]][r["group"]] += 1
        for t, c in tg_votes.items():
            if len(c) > 1:
                print(f"  WARNING type {t!r} spans groups {dict(c)} — using majority")
        observed_groups = {g for c in tg_votes.values() for g in c}
        assert observed_groups <= set(GROUPS), f"unexpected FEAT_GROUP values: {observed_groups - set(GROUPS)}"
        group_idx = {g: i for i, g in enumerate(GROUPS)}
        type_group = [group_idx[tg_votes[t].most_common(1)[0][0]] if t != "Property" else group_idx["Property"]
                      for t in types]

        # place table: locality polygon names, then address localities the
        # polygons don't know (should be rare — printed)
        places = [""] + sorted(set(loc_names))
        place_idx = {norm(p): i for i, p in enumerate(places) if p}
        unknown_places = sorted({r["locality"] for r in extras + prop_rows
                                 if r["locality"] and norm(r["locality"]) not in place_idx})
        for p in unknown_places:
            place_idx[norm(p)] = len(places)
            places.append(p)
        if unknown_places:
            print(f"  {len(unknown_places)} address localities without a polygon: {unknown_places[:10]}")

        munis = [""] + sorted({r["muny"] for r in cand + extras + prop_rows if r["muny"]})
        muni_idx = {m: i for i, m in enumerate(munis)}

        def row_of(r: dict) -> list:
            if "locality" in r:  # extras / properties: place from the address LOCALITY
                place = place_idx.get(norm(r["locality"]), 0) if r["locality"] else 0
            else:
                place = place_idx[norm(loc_names[r["loc"]])] if r["loc"] is not None else 0
            if place and norm(places[place]) in {norm(x) for x in r["name"].split("/")}:
                place = 0  # "Sandy Bay" in Sandy Bay says nothing (either half of a dual name)
            lat5, lon5 = round(r["lat"] * 1e5), round(r["lon"] * 1e5)
            row = [r["name"], type_idx[r["type"]], place, muni_idx[r["muny"]], lat5, lon5]
            if r["bbox"]:
                w, s, e, n = r["bbox"]
                delta = [round(w * 1e5) - lon5, round(s * 1e5) - lat5,
                         round(e * 1e5) - lon5, round(n * 1e5) - lat5]
                if delta[0] != delta[2] or delta[1] != delta[3]:  # a zero-extent bbox says nothing
                    row.append(delta)
            return row

        rows = [row_of(r) for r in cand + extras + prop_rows]
        rows.sort(key=lambda row: (norm(row[0]), row[1], row[2], row[4], row[5]))
        gaz = {
            "version": 1, "built": date.today().isoformat(),
            "attribution": GAZ_ATTRIBUTION,
            "types": types, "groups": GROUPS, "typeGroup": type_group,
            "places": places, "munis": munis, "rows": rows,
        }
        raw, gz = write_json(OUT / "gazetteer.json", gaz)
        per_group = Counter(GROUPS[type_group[row[1]]] for row in rows)
        with_bbox = sum(1 for row in rows if len(row) > 6)
        with_place = sum(1 for row in rows if row[2])
        print(f"  {len(rows)} rows ({len(cand)} register + {len(extras)} extras + {len(prop_rows)} properties)")
        print(f"  per group: {dict(per_group)}")
        print(f"  {with_bbox} rows with bbox, {with_place} with a place, {len(types)} types, "
              f"{len(places)} places, {len(munis)} councils")
        print(f"  gazetteer.json: {raw / 1e6:.2f} MB raw, {gz / 1e6:.2f} MB gzip")
        assert raw < 5_000_000, "gazetteer.json too large"

    # ------------------------------------------------------- addresses.json
    with Stage("write addresses.json"):
        def num_key(k: tuple[int, str]) -> tuple[int, str]:
            return k

        entries = []
        for (label, locality), nums in streets.items():
            keys = sorted(nums, key=num_key)
            numbers, lons, lats = [], [], []
            for no, suf in keys:
                acc = nums[(no, suf)]
                numbers.append(no if not suf else f"{no}{suf}")
                lons.append(round(acc[0] / acc[2] * 1e5))
                lats.append(round(acc[1] / acc[2] * 1e5))
            dlon = [0] + [lons[i] - lons[i - 1] for i in range(1, len(lons))]
            dlat = [0] + [lats[i] - lats[i - 1] for i in range(1, len(lats))]
            entries.append([label, locality, lons[0], lats[0], numbers, dlon, dlat])
        entries.sort(key=lambda e: (norm(e[0]), e[1]))
        addr = {
            "version": 1, "built": date.today().isoformat(),
            "attribution": ADDR_ATTRIBUTION, "streets": entries,
        }
        raw, gz = write_json(OUT / "addresses.json", addr)
        print(f"  {len(entries)} streets, {sum(len(e[4]) for e in entries)} numbers")
        print(f"  addresses.json: {raw / 1e6:.2f} MB raw, {gz / 1e6:.2f} MB gzip")
        assert raw < 5_000_000, "addresses.json too large"

    print(f"\ndone in {time.time() - t_all:.0f} s → {OUT}")


if __name__ == "__main__":
    main()

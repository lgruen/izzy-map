#!/usr/bin/env python3
"""Build app/src/generated/records.json + nearby.bin — Atlas of Living
Australia (ALA) plant occurrence records in Tasmania, reduced to

  C1 "often recorded in this community": per TASVEG 5.0 VEGCODE, the
     Understorey Network (UN) species most characteristic of it, by an
     IndVal-style score over ~100 m cells (records.json "communities");
  C2 "recorded near here": a 0.01° grid (~1.1 km × 0.8 km) of species ×
     distinct ~100 m cells per grid cell (nearby.bin, format in the
     shared contract; records.json "grid").

Species vocabulary: UN plant database (WordPress REST, verified 2026-10-25:
1,884 posts, 19 pages of 100)
  https://database.understorey-network.org.au/wp-json/wp/v2/plant?per_page=100&page=N&_fields=id,title
key = first two words of the (HTML-unescaped) title; titles whose 2nd word
is "sp."/"x"/"×" have no key (same rule as build_plants.py / the contract).

ALA acquisition (verified 2026-10-25) — biocache-ws faceting, no raw record
download, no email-gated offline download:
  https://biocache-ws.ala.org.au/ws/occurrences/search?q=*:*&fq=…&pageSize=0
      &facets=point-0.001,dataResourceUid,license&flimit=-1
  * ONE request per species: the `point-0.001` facet = record count per
    coordinate ROUNDED (not truncated: 296/297 sampled Acacia dealbata
    records equal round(lat, 3), round(lon, 3); the last differs only in
    "148" vs "148.0" formatting) — so cell centres sit on multiples of
    0.001°, as the contract's grid assumes. flimit=-1 returns every value
    (A. dealbata: 9,185 points + "Not supplied" summing exactly to
    totalRecords 9,654). The same request carries the dataResourceUid and
    license facets (attribution tallies at no extra request cost).
  * Species matching: ALA's `species` field is the species-rank parent of
    the matched name, so subsp./var. records roll up onto it (a record of
    "Acacia dealbata subsp. dealbata" has species "Acacia dealbata") —
    the same collapse the UN key uses. UN names absent from the statewide
    `species` facet go through ALA's name-matching service
    (https://namematching-ws.ala.org.au/api/search?q=) for the accepted
    species (synonyms, e.g. a genus transfer).
  * stateProvince:Tasmania is assigned by ALA from the coordinates and
    includes King Island (~13.6k records in the -40,144 1° cell) and the
    Furneaux Group (~48.9k at -40,148) — and Macquarie Island (~10.5k at
    -55,159), which the bounding-box filter below removes along with
    sign-flipped/garbage coordinates.

Record filters (each one an fq on every request; effect measured statewide
for Plantae in Tasmania, 1,514,032 records, 2026-10-25):
  * occurrenceStatus ABSENT excluded (106,563 records): survey plots list
    species looked for and NOT found — counting them as presence would be
    exactly wrong.
  * dataGeneralizations present / sensitive excluded (~300): threatened
    species generalised to 10 km by DPIPWE — their points snap onto a
    coarse grid and would create fake hotspots (and C1 joins at a
    generalised point mean nothing).
  * coordinateUncertaintyInMeters > 1000 excluded (~194k): our cells are
    100 m (C1) and ~1 km (C2); a record known only to within kilometres
    would land in the wrong polygon more often than the right one. Records
    with NO uncertainty value are kept (146k, mostly iNaturalist/NVA —
    dropping them would lose over a quarter of the iNaturalist data).
  * basisOfRecord FOSSIL_SPECIMEN excluded (4): not today's flora.
    LIVING_SPECIMEN is deliberately KEPT: checked 2026-10-25, these are
    seed-bank / living-collection accessions (Tas Seed Conservation
    Centre, RBG Edinburgh, ANBG seedbank…) georeferenced at their WILD
    collecting sites (top 0.01° cells: Cradle Mtn, Freycinet, Mt
    Wellington), not at a botanic garden — valid presence evidence.
  * The ABSENT filter removes nothing for UN species today (the 106,563
    absences are marine algal transect surveys) but stays as a guard.
  * bbox lat -44…-39.2 (the Tas/Vic border is 39°12'S), lon 143.5…149:
    Macquarie Island and misplaced points out.
  * Coarse georeferences (applied locally, not as an fq): cells whose lat
    AND lon both round a whole arc-minute are left out of C1 (≈ 8 % of
    pairs vs ≈ 0.36 % by chance — legacy/herbarium localities up to ~1 km
    off, meaningless against 100 m polygons); cells on the 0.1° grid are
    left out of C1 and C2 (~11 km precision).
  No year cut-off: pre-1950 records are ~6.6 % of the kept set (and ~41.8k
  carry ALA's "1599" unknown-year placeholder, which says nothing about
  location quality); counting distinct cells rather than records already
  damps historic repeat collecting. Kept: ~1.17 M records statewide (all
  taxa, incl. algae/mosses/weeds that UN does not list).

C1 score (IndVal, Dufrêne & Legendre 1997, with ~100 m cells as sites):
each distinct 0.001° cell centre is joined to the TASVEG polygon containing
it (STRtree over the cell points, queried with prepared polygons — native
GEOS). For community c and species s, sites_cs = distinct cells of s in c,
Sites_c = cells in c with any kept UN species record;
  f_cs = Wilson95_lower(sites_cs, Sites_c)   (z = 1.96)
  A = f_cs / Σ_c' f_c's                       specificity
  B = f_cs                                    fidelity
score = A × B, sites_cs ≥ 3, ≤ 40 per community, best first. The Wilson
lower bound replaces the raw proportion sites_cs / Sites_c so small samples
can't look certain: in a 330-cell community 3 sites (0.9 %) count as
0.3 %, while 120 sites (36 %) still count as 31 %. (It does not demote
species that are genuinely concentrated in a community: GPL's top three,
riparian Acacia axillaris 37 / Senecio squarrosus 22 / Bedfordia 21 sites,
stay on top; Poa labillardierei moved 9th -> 7th.) records.json "sites" = Sites_c per
code. Codes with Sites_c < 30 get NO indicator ranking: their list is a
plain tally of every species recorded there (sites desc, ties by name,
≤ 40, no sites ≥ 3 floor) with score = null, so the app can word it
"recorded here" — every code with a recorded site has a non-empty list.

Licences: ALA records carry their providers' licences (mostly CC BY 3.0 AU
NVA, CC BY / CC BY-NC iNaturalist, herbaria); we commit only derived facts
(species lists and per-cell counts, no records), and keep the provider
tallies in records.json "sources" so the app can attribute them.

Run: uv run --with geopandas --with pyogrio --with pyproj --with pyarrow python3 pipeline/build_records.py
       [--tasveg PATH] [--fresh] [--sample N]
  --tasveg P  TASVEG 5.0 zip (default: data/LIST_TASVEG_50_STATEWIDE.zip in this repo)
  --fresh     drop cached ALA/UN responses (the slim TASVEG parquet is kept)
  --sample N  pull/join only the first N species (timing; writes nothing)
Cache: pipeline/cache/records/ (gitignored) — one file per species, so an
interrupted pull resumes; tasveg_slim.parquet is keyed on the zip's size +
mtime. TASVEG itself is read in place — never committed.
"""
import gzip
import html
import json
import os
import re
import struct
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent
CACHE = HERE / "cache" / "records"
GEN = ROOT / "app" / "src" / "generated"

UN_API = "https://database.understorey-network.org.au/wp-json/wp/v2/plant"
ALA_SEARCH = "https://biocache-ws.ala.org.au/ws/occurrences/search"
NAMEMATCH = "https://namematching-ws.ala.org.au/api/search?q="
UA = {"User-Agent": "IzzyMap-pipeline/1.0 (personal, non-commercial)", "Accept-Encoding": "gzip"}
TIMEOUT = 120
WORKERS = 3  # be polite to ALA

LAT_MIN, LAT_MAX, LON_MIN, LON_MAX = -44.0, -39.2, 143.5, 149.0
FQ = [
    "stateProvince:Tasmania",
    "kingdom:Plantae",
    "-occurrenceStatus:ABSENT",
    "-dataGeneralizations:*",
    "-sensitive:*",
    "-basisOfRecord:FOSSIL_SPECIMEN",
    "-coordinateUncertaintyInMeters:[1000.001 TO *]",
    f"decimalLatitude:[{LAT_MIN} TO {LAT_MAX}] AND decimalLongitude:[{LON_MIN} TO {LON_MAX}]",
]
FQ_SIG = "|".join(FQ)

GRID = {"step": 0.01, "lat0": -44.0, "lon0": 143.5}
GRID["nlon"] = round((LON_MAX - GRID["lon0"]) / GRID["step"]) + 1  # 551
MAGIC = 0x4E425931  # "NBY1"

MIN_SITES = 3   # sites_cs floor for a C1 entry
MAX_LIST = 40   # C1 entries per community
TALLY_BELOW = 30  # Sites_c below this: plain tally (all species, sites desc, score null), no IndVal

TASVEG_ZIP = ROOT / "data" / "LIST_TASVEG_50_STATEWIDE.zip"  # default; --tasveg PATH overrides
TASVEG_URL = "https://listdata.thelist.tas.gov.au/opendata/data/LIST_TASVEG_50_STATEWIDE.zip"
TASVEG_SHP ="LIST_TASVEG_50_STATEWIDE/TASVEG_5_0.shp"

stats = Counter()


# ---------------------------------------------------------------- HTTP ---

def http_get(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers=UA)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                body = r.read()
                if r.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
                stats["bytes"] += len(body)
                stats["requests"] += 1
                return body
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  {url[:100]}… failed ({e}), retrying")
            time.sleep(3 + 7 * attempt)
    raise AssertionError


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_suffix(path.suffix + ".part")
    part.write_text(text, encoding="utf-8")
    os.replace(part, path)


def ala_search(fq, **params):
    q = [("q", "*:*")] + [("fq", f) for f in fq] + [("pageSize", "0")] + list(params.items())
    body = json.loads(http_get(ALA_SEARCH + "?" + urllib.parse.urlencode(q)))
    if body.get("status") not in (None, "OK"):
        raise RuntimeError(f"ALA error: {body.get('status')} {body.get('errorMessage')}")
    return body


def facets(body):
    return {f["fieldName"]: f["fieldResult"] for f in body.get("facetResults", [])}


# ------------------------------------------------------ UN vocabulary ---

def species_key(title):
    """First two words of the UN title; None for "sp."/hybrid entries."""
    w = html.unescape(title).replace(" ", " ").split()
    if len(w) < 2 or w[1].lower() in ("sp.", "sp", "spp.", "x", "×") or not w[0][:1].isupper():
        return None
    return f"{w[0]} {w[1]}"


def un_keys():
    keys = set()
    page, pages = 1, None
    while pages is None or page <= pages:
        path = CACHE / "un" / f"page-{page:02d}.json"
        if path.exists():
            d = json.loads(path.read_text(encoding="utf-8"))
        else:
            url = f"{UN_API}?per_page=100&page={page}&_fields=id,title"
            req = urllib.request.Request(url, headers={"User-Agent": UA["User-Agent"]})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                d = {"pages": int(r.headers["X-WP-TotalPages"]), "total": int(r.headers["X-WP-Total"]),
                     "items": json.load(r)}
            write_atomic(path, json.dumps(d, ensure_ascii=False))
        pages = d["pages"]
        for it in d["items"]:
            k = species_key(it["title"]["rendered"])
            if k:
                keys.add(k)
        total = d["total"]
        page += 1
    print(f"UN: {total} plant posts, {len(keys)} species keys")
    assert 1500 <= len(keys) <= 2000, f"UN key count {len(keys)} outside 1500–2000 — check the REST pull"
    return sorted(keys)


# ---------------------------------------------------- name resolution ---

def ala_species_facet():
    path = CACHE / "ala_species.json"
    if path.exists():
        d = json.loads(path.read_text(encoding="utf-8"))
        if d.get("fq") == FQ_SIG:
            return d
    body = ala_search(FQ, facets="species", flimit="-1")
    counts = {x["label"]: x["count"] for x in facets(body)["species"] if x["label"] != "Not supplied"}
    d = {"fq": FQ_SIG, "total": body["totalRecords"], "species": counts}
    write_atomic(path, json.dumps(d, ensure_ascii=False))
    return d


def resolve(keys, ala_counts):
    """UN key -> ALA species name (the `species` facet value to query)."""
    path = CACHE / "namematch.json"
    nm = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    todo = [k for k in keys if k not in ala_counts and k not in nm]
    for k in todo:
        try:
            r = json.loads(http_get(NAMEMATCH + urllib.parse.quote(k), timeout=30))
        except Exception as e:  # noqa: BLE001
            print(f"  namematch {k}: {e}")
            continue
        nm[k] = {f: r.get(f) for f in ("success", "scientificName", "rank", "species", "matchType", "issues")}
    if todo:
        write_atomic(path, json.dumps(nm, ensure_ascii=False, indent=0))
    out, via, missing = {}, [], []
    for k in keys:
        if k in ala_counts:
            out[k] = k
            continue
        m = nm.get(k) or {}
        sp = m.get("species")
        if m.get("success") and sp and sp in ala_counts:
            out[k] = sp
            via.append(f"{k} -> {sp}")
        else:
            missing.append(k)
    # two UN keys resolving to one ALA species: the exact-name key keeps it
    # (else the first alphabetically) — a duplicate entry in a list helps no one
    by = defaultdict(list)
    for k, sp in out.items():
        by[sp].append(k)
    dup = []
    for sp, ks in by.items():
        if len(ks) > 1:
            keep = sp if sp in ks else sorted(ks)[0]
            for k in ks:
                if k != keep:
                    del out[k]
                    dup.append(f"{k} (-> {sp}, kept {keep})")
    print(f"names: {len(keys)} UN keys | {len(keys) - len(missing) - len(via) - len(dup)} exact in ALA's Tasmanian "
          f"species facet | {len(via)} via name matching | {len(dup)} duplicates dropped | {len(missing)} no "
          f"kept Tasmanian record")
    print(f"  via name matching (sample): {'; '.join(via[:12])}")
    if dup:
        print(f"  duplicates: {'; '.join(dup)}")
    print(f"  unmatched (sample): {', '.join(missing[:20])}")
    return out


# ------------------------------------------------------- per-species ---

def safe(name):
    return re.sub(r"[^A-Za-z0-9.-]+", "_", name)


def pull_species(sp):
    path = CACHE / "occ" / f"{safe(sp)}.json"
    if path.exists():
        d = json.loads(path.read_text(encoding="utf-8"))
        if d.get("fq") == FQ_SIG:
            return d, False
    body = ala_search(FQ + [f'species:"{sp}"'], facets="point-0.001,dataResourceUid,license", flimit="-1")
    f = facets(body)
    pts = {x["label"]: x["count"] for x in f.get("point-0.001", []) if x["label"] != "Not supplied"}
    dr = {}
    for x in f.get("dataResourceUid", []):
        m = re.search(r'"(dr\d+)"', x.get("fq", ""))
        dr[m.group(1) if m else x["label"]] = [x["label"], x["count"]]
    lic = {x["label"]: x["count"] for x in f.get("license", [])}
    d = {"fq": FQ_SIG, "species": sp, "total": body["totalRecords"], "points": pts, "dr": dr, "licence": lic}
    # every kept record has coordinates (bbox fq), so the point facet must
    # account for all of them — a shortfall = truncated facet
    assert sum(pts.values()) == body["totalRecords"], (sp, sum(pts.values()), body["totalRecords"])
    write_atomic(path, json.dumps(d, ensure_ascii=False, separators=(",", ":")))
    return d, True


def pull_all(names):
    t0 = time.time()
    done = [0]
    fetched = [0]

    def one(sp):
        d, new = pull_species(sp)
        done[0] += 1
        fetched[0] += new
        if new and fetched[0] % 100 == 0:
            el = time.time() - t0
            print(f"  {done[0]}/{len(names)} species ({fetched[0]} fetched, {el:.0f} s, "
                  f"{stats['bytes'] / 1e6:.0f} MB)")
        return d
    with ThreadPoolExecutor(WORKERS) as pool:
        out = list(pool.map(one, names))
    print(f"ALA pull: {len(names)} species, {fetched[0]} fetched this run in {time.time() - t0:.0f} s "
          f"({stats['requests']} requests, {stats['bytes'] / 1e6:.1f} MB decompressed)")
    return out


# --------------------------------------------------------- TASVEG join ---

def tasveg_frame(src):
    """VEGCODE + geometry, cached as a slim parquet keyed on the zip's
    size + mtime (a TASVEG refresh rebuilds it)."""
    import geopandas as gpd
    slim = CACHE / "tasveg_slim.parquet"
    meta = CACHE / "tasveg_slim.key"
    st = src.stat()
    key = f"{src.name} {st.st_size} {int(st.st_mtime)}"
    if slim.exists() and meta.exists() and meta.read_text().strip() == key:
        return gpd.read_parquet(slim)
    t = time.time()
    df = gpd.read_file(f"/vsizip/{src}/{TASVEG_SHP}", columns=["VEGCODE"], engine="pyogrio")
    print(f"TASVEG: read {len(df):,} polygons from {src.name} in {time.time() - t:.0f} s (crs {df.crs.to_epsg()})")
    assert 470_000 <= len(df) <= 500_000, len(df)
    assert df.crs.to_epsg() == 28355, df.crs
    df.to_parquet(slim)
    meta.write_text(key)
    return df


def join_cells(lat_k, lon_k, tasveg):
    """Cell centres (integer thousandths of a degree) -> VEGCODE or None."""
    import numpy as np
    import shapely
    from pyproj import Transformer
    veg = tasveg_frame(tasveg)
    t = time.time()
    tr = Transformer.from_crs(4283, 28355, always_xy=True)  # GDA94 ≈ ALA's WGS84 to ~1.8 m
    x, y = tr.transform(lon_k / 1000.0, lat_k / 1000.0)
    pts = shapely.points(x, y)
    tree = shapely.STRtree(pts)
    # prepared POLYGONS as the query input: each of the 482k polygons is
    # prepared once and tested against the few points under its envelope
    poly_i, pt_i = tree.query(np.asarray(veg.geometry), predicate="intersects")
    codes = veg["VEGCODE"].to_numpy()
    out = np.full(len(pts), None, dtype=object)
    # boundary points can touch two polygons — first hit wins (deterministic order)
    order = np.lexsort((poly_i, pt_i))
    pt_s, poly_s = pt_i[order], poly_i[order]
    first = np.ones(len(pt_s), dtype=bool)
    first[1:] = pt_s[1:] != pt_s[:-1]
    out[pt_s[first]] = codes[poly_s[first]]
    stats["join_multi"] = int((~first).sum())
    print(f"join: {len(pts):,} cells -> {int(first.sum()):,} inside a TASVEG polygon "
          f"({stats['join_multi']} boundary double hits) in {time.time() - t:.1f} s")
    return out


def on_minute(k):
    """True where a coordinate in integer thousandths of a degree is the
    0.001° rounding of a whole arc-minute: |k/1000 − m/60| ≤ 0.0005°,
    i.e. |60·k − 1000·m| ≤ 30 for the nearest minute m (≈ 1 in 16.7)."""
    import numpy as np
    k = np.asarray(k, dtype=np.int64)
    m = np.rint(k * 60 / 1000).astype(np.int64)
    return np.abs(60 * k - 1000 * m) <= 30


# ------------------------------------------------------------- output ---

def main():
    args = sys.argv[1:]
    fresh = "--fresh" in args
    sample = None
    if "--sample" in args:
        sample = int(args[args.index("--sample") + 1])
    tasveg = Path(args[args.index("--tasveg") + 1]).expanduser() if "--tasveg" in args else TASVEG_ZIP
    if not tasveg.is_file():
        raise SystemExit(f"TASVEG zip not found: {tasveg}\n  download {TASVEG_URL}\n  into data/ "
                         f"or pass --tasveg PATH (the zip, read in place via /vsizip/)")
    CACHE.mkdir(parents=True, exist_ok=True)
    if fresh:
        for p in CACHE.rglob("*.json"):
            p.unlink()
        print("--fresh: dropped cached UN/ALA responses (TASVEG parquet kept)")
    t_start = time.time()

    keys = un_keys()
    sf = ala_species_facet()
    print(f"ALA: {sf['total']:,} kept records statewide (all plants incl. non-UN taxa), "
          f"{len(sf['species']):,} species names")
    k2a = resolve(keys, sf["species"])
    names = sorted(set(k2a.values()))
    if sample:
        names = names[:sample]
    data = {d["species"]: d for d in pull_all(names)}

    import numpy as np

    # (key, cell) pairs; cells as integer thousandths (lat_k, lon_k)
    a2k = {}
    for k, sp in k2a.items():
        a2k.setdefault(sp, k)
    species = sorted(a2k[sp] for sp in names if data[sp]["points"])
    sidx = {k: i for i, k in enumerate(species)}
    s_list, lat_list, lon_list = [], [], []
    records = 0
    dr_tot, lic_tot = Counter(), Counter()
    dr_name = {}
    for sp in names:
        d = data[sp]
        if not d["points"]:
            continue
        i = sidx[a2k[sp]]
        for lab, n in d["points"].items():
            la, lo = lab.split(",")
            s_list.append(i)
            lat_list.append(round(float(la) * 1000))
            lon_list.append(round(float(lo) * 1000))
            records += n
        for uid, (nm, n) in d["dr"].items():
            dr_tot[uid] += n
            dr_name[uid] = nm
        for lic, n in d["licence"].items():
            lic_tot[lic] += n
    s_arr = np.array(s_list, dtype=np.int64)
    lat_k = np.array(lat_list, dtype=np.int64)
    lon_k = np.array(lon_list, dtype=np.int64)
    # a 0.001° cell key (rows of 0.001° from lat -44, cols from lon 143.5)
    ckey = (lat_k + 44000) * 10000 + (lon_k - 143500)
    assert (lat_k >= -44000).all() and (lat_k <= -39200).all() and (lon_k >= 143500).all() and (lon_k <= 149000).all()
    cells, inv = np.unique(ckey, return_inverse=True)
    print(f"records: {records:,} kept for {len(species):,} UN species | {len(s_arr):,} (species, ~100 m cell) "
          f"pairs | {len(cells):,} distinct ~100 m cells")

    # ---- C1: TASVEG join + IndVal
    c_lat = cells // 10000 - 44000
    c_lon = cells % 10000 + 143500
    vc = join_cells(c_lat, c_lon, tasveg)
    # Coarse georeferences: ~8 % of (species, cell) pairs sit on whole
    # arc-minute points (chance ≈ 0.36 %) and 0.25 % on the 0.1° grid —
    # herbarium/legacy localities with no uncertainty value, up to ~1 km
    # (minute) or ~11 km (0.1°) off. Joined to 100 m polygons they dump
    # hundreds of species into whatever polygon the grid point hits
    # ((-42.900, 147.233) -> 212 species into HHE). C1 drops minute-grid
    # cells (a superset of the 0.1° grid) from sites_cs AND Sites_c; C2
    # (~1 km cells) keeps minute points but drops 0.1° points below.
    minute = on_minute(c_lat) & on_minute(c_lon)
    in_veg = vc != None  # noqa: E711
    print(f"C1: {int(minute.sum()):,} arc-minute-grid cells excluded ({int((minute & in_veg).sum()):,} inside "
          f"TASVEG) = {int(minute[inv].sum()):,} of {len(inv):,} (species, cell) pairs "
          f"({int((minute & in_veg)[inv].sum()):,} inside TASVEG)")
    vc = vc.copy()
    vc[minute] = None
    pair_code = vc[inv]
    inside = pair_code != None  # noqa: E711
    codes = sorted(set(vc[vc != None]))  # noqa: E711
    cidx = {c: j for j, c in enumerate(codes)}
    pc = np.array([cidx[c] for c in pair_code[inside]], dtype=np.int64)
    ps = s_arr[inside]
    nC, nS = len(codes), len(species)
    sites = np.zeros((nC, nS), dtype=np.int64)
    np.add.at(sites, (pc, ps), 1)  # pairs are unique per (species, cell)
    cell_code = np.array([cidx[c] if c is not None else -1 for c in vc])
    Sites = np.bincount(cell_code[cell_code >= 0], minlength=nC).astype(float)
    # Wilson 95 % score-interval LOWER bound of sites_cs / Sites_c (0 when
    # sites_cs = 0), used for both fidelity B and the specificity shares A
    z = 1.96
    nn = Sites[:, None]
    p = sites / nn
    rel = (p + z * z / (2 * nn) - z * np.sqrt(p * (1 - p) / nn + z * z / (4 * nn * nn))) / (1 + z * z / nn)
    rel = np.maximum(rel, 0.0)                         # fidelity B (float noise at k = 0)
    A = rel / np.maximum(rel.sum(axis=0, keepdims=True), 1e-12)
    score = A * rel
    communities = {}
    for j, c in enumerate(codes):
        if Sites[j] < TALLY_BELOW:
            # too few recorded cells for an indicator ranking: a plain
            # "recorded here" tally — every species, sites desc, ties by name
            # (species indices are alphabetical); score null marks it for the app
            ok = np.nonzero(sites[j] >= 1)[0]
            best = ok[np.lexsort((ok, -sites[j, ok]))][:MAX_LIST]
            communities[c] = [[int(s), int(sites[j, s]), None] for s in best]
            continue
        ok = np.nonzero(sites[j] >= MIN_SITES)[0]
        best = ok[np.argsort(-score[j, ok], kind="stable")][:MAX_LIST]
        if len(best):
            communities[c] = [[int(s), int(sites[j, s]), float(f"{score[j, s]:.4g}")] for s in best]
    assert set(communities) == set(codes), f"empty lists: {sorted(set(codes) - set(communities))}"

    # group members (plants.json "groups", written by build_plants.py): the
    # app ranks a group's members by sites in the tapped community, which
    # the ≤ 40 C1 lists can't supply — full per-code site counts (same C1
    # sites, minute cells out, no floor) for every member species
    members = {}
    plants_path = GEN / "plants.json"
    groups = json.loads(plants_path.read_text(encoding="utf-8")).get("groups") if plants_path.exists() else None
    if groups:
        mem = sorted({sidx[s] for g in groups.values() for s in g.get("species", []) if s in sidx})
        for j, c in enumerate(codes):
            row = [(s, int(sites[j, s])) for s in mem if sites[j, s] >= 1]
            if row:
                members[c] = [[s, n] for s, n in sorted(row, key=lambda t: (-t[1], t[0]))]
        print(f"members: {len(groups)} groups, {len(mem)} member species with records, {len(members)} codes")
    else:
        print("members: no plants.json groups — nothing emitted")
    lens = sorted(len(v) for v in communities.values())
    print(f"C1: {nC} VEGCODEs with records, {len(communities)} with a list ({sum(1 for v in communities.values() if v[0][2] is None)} plain tallies), "
          f"median list {lens[len(lens) // 2] if lens else 0}, {sum(1 for x in lens if x == MAX_LIST)} full")
    small = [f"{c}({int(Sites[cidx[c]])})" for c in codes if Sites[cidx[c]] < 30]
    print(f"  VEGCODEs with < 30 recorded cells (noisy lists): {' '.join(small) or '-'}")
    for c in ("RMT", "DAC", "GPL", "HHE", "DOB", "SCA", "MBU", "WOB"):
        if c in communities:
            print(f"  {c} ({int(Sites[cidx[c]])} cells): " +
                  ", ".join(f"{species[s]} {n}" for s, n, _ in communities[c][:8]))

    # ---- C2: 0.01° grid (half-up in integer thousandths), 0.1°-grid points out
    deci = (lat_k % 100 == 0) & (lon_k % 100 == 0)
    print(f"C2: {int(deci.sum()):,} of {len(deci):,} pairs on the 0.1° grid excluded")
    s_arr, lat_k, lon_k = s_arr[~deci], lat_k[~deci], lon_k[~deci]
    row = (lat_k + 44000 + 5) // 10
    col = (lon_k - 143500 + 5) // 10
    gcell = row * GRID["nlon"] + col
    key2 = gcell * 65536 + s_arr
    u, cnt = np.unique(key2, return_counts=True)
    g_cell, g_sp = u // 65536, u % 65536
    cnt = np.minimum(cnt, 65535)
    order = np.lexsort((g_sp, -cnt, g_cell))  # cell asc, sites desc, species asc
    g_cell, g_sp, cnt = g_cell[order], g_sp[order], cnt[order]
    gcells, starts = np.unique(g_cell, return_index=True)
    offs = np.append(starts, len(g_cell)).astype("<u4")
    assert len(species) < 65536
    blob = (struct.pack("<II", MAGIC, len(gcells)) + gcells.astype("<u4").tobytes() + offs.tobytes()
            + np.rec.fromarrays([g_sp.astype("<u2"), cnt.astype("<u2")], dtype=[("s", "<u2"), ("n", "<u2")]).tobytes())
    print(f"C2: {len(gcells):,} grid cells, {len(g_cell):,} (cell, species) pairs, "
          f"median {int(np.median(np.diff(offs)))} species/cell, nearby.bin {len(blob) / 1e6:.2f} MB")

    if sample:
        print(f"--sample {sample}: nothing written ({time.time() - t_start:.0f} s)")
        return

    # tripwires pinned to the 2026-10 pull (1,729 species, ~862k records,
    # ~127k cells, 156 VEGCODEs with a list, 2.3 MB grid) — they catch truncated
    # pulls and broken joins, not growth: widen them when ALA grows
    assert 1600 <= len(species) <= 1900, len(species)
    assert 750_000 <= records <= 1_100_000, records
    assert 110_000 <= len(cells) <= 170_000, len(cells)
    assert len(communities) >= 140, len(communities)
    assert len(blob) <= 3_500_000, f"nearby.bin {len(blob)} bytes — over the ~3 MB budget"
    # ecology tripwire: a coordinate-order or CRS slip in the join would
    # scramble this long before anything else looks wrong
    top_rmt = {species[s] for s, _, _ in communities.get("RMT", [])[:5]}
    assert "Nothofagus cunninghamii" in top_rmt, f"RMT top 5 lacks myrtle beech: {top_rmt}"

    top = dr_tot.most_common()
    resources = [[uid, dr_name[uid], n] for uid, n in top[:10]]
    if len(top) > 10:
        resources.append([None, f"{len(top) - 10} other data resources", sum(n for _, n in top[10:])])
    out = {
        "version": 1,
        "built": date.today().isoformat(),
        "species": species,
        "communities": communities,
        "sites": {c: int(Sites[cidx[c]]) for c in codes},  # Sites_c: recorded ~100 m cells per code
        **({"members": members} if members else {}),       # group members: full [speciesIdx, sites] per code
        "grid": GRID,
        "sources": {
            "ala": "Atlas of Living Australia (https://www.ala.org.au), occurrence search "
                   "https://biocache-ws.ala.org.au, accessed " + date.today().isoformat(),
            "records": records,
            "filters": "Plantae, stateProvince Tasmania; excluding absences, generalised/sensitive records, "
                       "fossils, coordinate uncertainty > 1 km",
            "resources": resources,      # [dataResourceUid, name, kept records]
            "licences": [[k, n] for k, n in lic_tot.most_common()],
        },
    }
    GEN.mkdir(parents=True, exist_ok=True)
    dest = GEN / "records.json"
    write_atomic(dest, json.dumps(out, ensure_ascii=False, separators=(",", ":")))
    binp = GEN / "nearby.bin"
    part = binp.with_suffix(".bin.part")
    part.write_bytes(blob)
    os.replace(part, binp)
    print(f"sources: top {', '.join(f'{nm} {n:,}' for _, nm, n in resources[:4])}")
    print(f"wrote {dest} ({dest.stat().st_size / 1e6:.2f} MB), {binp} ({binp.stat().st_size / 1e6:.2f} MB) "
          f"in {time.time() - t_start:.0f} s")


if __name__ == "__main__":
    main()

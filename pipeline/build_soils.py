#!/usr/bin/env python3
"""Build the Soils overlay: ios/IzzyMap/Resources/Data/soils.pmtiles (bundled
in the app, copy in data/soils.pmtiles) + ios/IzzyMap/Resources/Data/
soil_units.json, from LIST's "Correlated Reconnaissance Soils (Soil Types)".

Source (verified 2026-11-18, CC BY 3.0 AU © State of Tasmania; custodian NRE
Tas Natural & Cultural Heritage Division, NOT Land Tasmania): the LISTdata
open-data zip (shapefile + FGDB + MapInfo, MGA55, 2,478 polygons, 165
CODEs, 11 reconnaissance 1:100,000 map sheets — north-west coast, Tamar,
Midlands, Derwent Valley, south-east). No symbology in the zip (no
.lyr/.qml/.sld; LISTdata's separate LIST_LAYER_FILES.zip has binary .lyr
files only). The official fill colours come from LIST's own renderer: REST
`Public/GeologicalAndSoils/MapServer/19` drawingInfo (uniqueValue on CODE,
162 entries, all esriSFSSolid), fetched on every full run and diffed against
the cached copy. That renderer misses 6 data codes and has 5 codes no
polygon uses — ALIASES below resolves them explicitly; any new mismatch
fails the build.

Run (2026-11-18: ~14 s cold, ~12 s warm, --tiles-only ~3 s):
    uv run --with geopandas --with pyogrio --with shapely --with pyproj \\
      --with numpy --with mapbox-vector-tile python3 -I pipeline/build_soils.py
    [--fresh]       re-download the zip and ACCEPT a changed renderer (else
                    the zip is cached in pipeline/cache/soils/; the licence
                    check and the renderer fetch are live on every run)
    [--tiles-only]  re-tile the cached work/soils/*.geojsons (no network,
                    soil_units.json untouched; refuses if the cached colours
                    disagree with ALIASES + the cached renderer)

Archive layout (tippecanoe, tile-join, PMTiles; the app overzooms past z12):
  soils             z0-12  source polygons (water dropped, 5 self-intersecting
                           rings repaired with make_valid): CODE, color
                           ("#rrggbb"), sheet (key into soil_units.json
                           sheets). feature id = shapefile FID + 1 (= FGDB
                           OBJECTID in this release) on every tile piece.
                           No coalescing/dropping: only tiny_polygons may fire.
  soils_labels      z9-12  one point per polygon at the maximum-inscribed-
                           circle centre: CODE, r (inscribed radius, m, MGA55),
                           same id. -r1: every point at every zoom.
  soils_extent      z0-12  the mapped FRAME: union of the kept polygons AND the
                           dropped water polygons (sheet frames straight across
                           bays/estuaries, lakes inside), holes < 1 ha filled
                           (2025-07 zip: the 4 sub-0.01-ha digitising gaps).
  soils_boundaries  z8-12  property-free LineStrings: ONLY the edges shared by
                           two polygons of DIFFERENT CODE (case-sensitive).
                           Not the frame (soils_extent draws it), not
                           shorelines against dropped water (the base map
                           draws those), not the same-unit seams (143 pairs,
                           ~214 km, mostly straight sheet edges where one unit
                           continues onto the next sheet). Needed because 34
                           neighbouring unit pairs share one colour (~212 km).

Why z12: 1:100,000 linework is accurate to ~50-100 m on the ground; a z12
tile has 2.4 m units (4096 per 9.8 km), so deeper tiles would only add bytes.
Why labels from z9: at z9 one point ≈ 113 m at 42.5° S, so a short code
(r ≥ ~20 pt) fits only in polygons with r ≥ ~2.3 km — the first zoom where a
handful of big units qualify (19 in the 2025-07 zip; 143 at z10, 540 at
z11 — the build prints the counts per zoom).
Why boundaries from z8: one point ≈ 225 m there — about the accuracy of the
linework; below it the 12,600 km of edges are a grey smear on a 1-2 km wide
patchwork, and the fills alone read better.
"""
import argparse
import datetime as dt
import email.message
import email.utils
import gzip
import json
import math
import re
import sqlite3
import struct
import subprocess
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache" / "soils"
WORK = HERE / "work" / "soils"
DATA = HERE.parent / "data"
GEN = HERE.parent / "ios" / "IzzyMap" / "Resources" / "Data"
OUT = GEN / "soils.pmtiles"
TABLE = GEN / "soil_units.json"
RENDERER_CACHE = CACHE / "layer19.json"

ZIP_URL = ("https://listdata.thelist.tas.gov.au/opendata/data/"
           "LIST_CORRELATED_RECONNAISSANCE_SOILS_SOIL_TYPES_STATEWIDE.zip")
ZIP = CACHE / "LIST_CORRELATED_RECONNAISSANCE_SOILS_SOIL_TYPES_STATEWIDE.zip"
STEM_IN_ZIP = "list_correlated_reconnaissance_soils_soil_types_statewide"
LAYER = "https://services.thelist.tas.gov.au/arcgis/rest/services/Public/GeologicalAndSoils/MapServer/19"
OPENDATA_JS = "https://listdata.thelist.tas.gov.au/opendata/resources/opendata.js"
OPENDATA_KEY = "LIST_CORRELATED_RECONNAISSANCE_SOILS_SOIL_TYPES"
REPORT_RE = re.compile(r"https://nrmdatalibrary\.dpipwe\.tas\.gov\.au/FactSheets/WfW/SoilReports/"
                       r"([A-Z][A-Za-z_]+)_report\.pdf")

TITLE = "Correlated Reconnaissance Soils (Soil Types)"
CUSTODIAN = "Department of Natural Resources and Environment Tasmania (Natural and Cultural Heritage Division)"
LICENCE = "CC BY 3.0 AU"
ATTRIBUTION = "Soil types: Correlated Reconnaissance Soils from theLIST (CC BY 3.0 AU) © State of Tasmania"
NAME = "Soil types (Correlated Reconnaissance Soils)"

POLY_MIN, POLY_MAX = 0, 12
LABEL_MIN, LABEL_MAX = 9, 12
BOUND_MIN, BOUND_MAX = 8, 12
SIZE_CAP = 12_000_000  # bytes; the archive is bundled in the app
HOLE_MIN_M2 = 1e4      # extent holes below 1 ha (digitising gaps) are filled
# The vector_layers contract the app is written against (name -> zooms, fields).
EXPECT_LAYERS = {
    "soils": (POLY_MIN, POLY_MAX, {"CODE", "color", "sheet"}),
    "soils_labels": (LABEL_MIN, LABEL_MAX, {"CODE", "r"}),
    "soils_extent": (POLY_MIN, POLY_MAX, set()),
    "soils_boundaries": (BOUND_MIN, BOUND_MAX, set()),
}

# Licence evidence (both checked on every full run; any change aborts):
# 1. readme.txt inside the zip, "Licensing:" paragraph (whitespace collapsed;
#    the © arrives in Latin-1).
README_LICENCE = ("All Data is Copyright © State of Tasmania. Data is supplied under "
                  "Creative Commons Attribution 3.0 Australia (CC BY 3.0 AU) "
                  "http://creativecommons.org/licenses/by/3.0/au/ "
                  "For appropriate attribution see the Land Tasmania Attribution Guidelines at "
                  "http://listdata.thelist.tas.gov.au/public/LandTasmaniaDataAttributionGuidelines.pdf")
# 2. the LISTdata open-data catalogue (opendata.js) lists this file with
#    licence code "ccNotLT" (= CC BY 3.0 AU badge, custodian not Land
#    Tasmania), whose branch renders a link to creativecommons.org/licenses/by/3.0/au/.
OPENDATA_LICENCE_CODE = "ccNotLT"
CC_BY_3_AU = "http://creativecommons.org/licenses/by/3.0/au/"

# Pinned to the 2025-07-17 zip (tripwires catch truncation, not growth).
EXPECT_POLYGONS = (2400, 2560)       # 2,478 incl. 10 water polygons
EXPECT_CODES = (155, 175)            # 165 incl. 'Water' + 'water'
EXPECT_SHEETS = 11
EXPECT_AREA_KM2 = (12200, 12450)     # 12,337 km² incl. 845 km² water
WATER_CODES = {"Water", "water"}
TAS_BOX = (143.5, -43.8, 148.6, -39.2)  # main island + Bass Strait islands

# Colour aliases: data CODE -> renderer CODE whose colour it takes. LIST's
# renderer on MapServer/19 has no entry for these data codes (LIST itself
# draws them uncoloured); every pairing is argued here. ALIASES_OURS marks
# the ones where the colour is OUR choice, not a LIST renderer entry for an
# evident spelling variant. Note LIST colours by unit FAMILY, so a colour is
# often shared by several units (34 neighbouring pairs of different units
# share one colour — hence the soils_boundaries layer).
ALIASES = {
    # Breadalbane Association (Longford + South Esk sheets): the renderer
    # carries the same three-unit family spelled 'BD', 'BD-Ps', 'BDKp' — the
    # identical suffix structure (with Panshanger sand dunes; krasnozem
    # phase) as the data's 'Bde', 'Bde-Ps', 'BdeKp', and no polygon uses
    # the 'BD' spellings. All three take the one renderer colour #d6a7a8.
    # That colour is ALSO LIST's colour for the six 'Bd*' "Brown soils on
    # dolerite" units of the southern sheets (Bd, Bd1, Bd-Bld1, Bd-Pd1,
    # Bd1-Bfs2, Bd1-Pd1), so Breadalbane shares a legend swatch with them;
    # they never touch (checked by the reviewer, 2026-11-18).
    "Bde": "BD",
    "Bde-Ps": "BD-Ps",
    "BdeKp": "BDKp",
    # 'Eastfield & Kraznozems & hydromorphic soils on basalt' (1 polygon,
    # Beaconsfield). The renderer's unused 'Ea-F' is the only Eastfield
    # compound not in the data, and every Eastfield code in the renderer
    # (Ea, Ea-Ar, Ea-Ps, Ea-Wk, Ea-F) has the same colour #7a9e9c, so the
    # colour is unambiguous whichever spelling LIST meant.
    "Ea+K": "Ea-F",
    # 'Macquarie with Brickendon' (South Esk): renderer 'Mq+Bk' = same two
    # components with '+' for '-'; the Mq family (Mq, Mq-Ps, Mq+Bk) shares
    # one colour #da666c.
    "Mq-Bk": "Mq+Bk",
    # 'Black soils on basalt 1 with brown soils on basalt 1' (13 polygons,
    # Ellendale): NO renderer counterpart. OUR CHOICE: the colour of its
    # first component 'Blb1' (#fdc5c8). In LIST's renderer 50 of 52 compound
    # codes "X-Y" take X's colour, including the sibling 'Blb1-RBb1'.
    "Blb1-Bb1": "Blb1",
}
ALIASES_OURS = {"Blb1-Bb1"}

# Australian Soil Classification orders (Isbell, The Australian Soil
# Classification): plain-English glosses of what DEFINES each order (its
# key), with typical features marked as such ("typically", "often").
TEXTURE_CONTRAST = "Soils with a clear or abrupt increase in clay from topsoil to subsoil (texture contrast)"
ASC_ORDERS = {
    "Calcarosol": "Soils that are calcareous (contain lime, often as soft or nodular carbonate) "
                  "throughout or from close below the topsoil, without a clear increase in clay "
                  "into the subsoil.",
    "Chromosol": f"{TEXTURE_CONTRAST}, where the upper subsoil is neither strongly acid nor sodic.",
    "Dermosol": "Soils with a well-structured subsoil (it breaks into distinct peds) but no clear "
                "texture contrast, and not as iron-rich as a Ferrosol.",
    "Ferrosol": "Iron-rich soils without a clear texture contrast: typically deep, red or brown, "
                "friable, well-structured clays formed on basalt (the old 'krasnozems').",
    "Hydrosol": "Seasonally or permanently wet soils: most of the profile is saturated for at least "
                "two to three months in most years, often with grey or mottled subsoil.",
    "Kandosol": "Soils with a massive or only weakly structured subsoil of at least 15 % clay and "
                "no clear texture contrast (the old red, yellow and brown earths).",
    "Kurosol": f"{TEXTURE_CONTRAST}, where the upper subsoil is strongly acid (pH below 5.5).",
    "Organosol": "Peat soils: made largely of organic matter, either a thick layer (more than 40 cm "
                 "in the top 80 cm) or a shallower one resting directly on rock.",
    "Podosol": "Sandy soils with a subsoil layer where organic matter, aluminium and/or iron washed "
               "down from above have accumulated, often a bleached sand over a dark or rusty pan.",
    "Rudosol": "Barely formed soils: hardly any soil development beyond a minimal topsoil, so "
               "little more than the raw parent material, such as fresh sand, alluvium or stony rubble.",
    "Sodosol": f"{TEXTURE_CONTRAST}, where the upper subsoil is sodic (exchangeable sodium 6 % or "
               "more) and not strongly acid; such subsoils typically disperse when wet, set hard "
               "when dry and drain poorly.",
    "Tenosol": "Weakly developed soils: a developed topsoil but little or no subsoil development, "
               "often sandy or gravelly.",
    "Vertosol": "Cracking clay soils (35 % clay or more) that shrink and swell, opening deep cracks "
                "when dry.",
}
ASC_FIXES = {"Chrmosol": "Chromosol"}           # upstream typo (4 polygons)
ASC_NONE = {"Insufficient Data", ""}            # -> no order
PROFILE_NONE = {"Insufficient Data", "No data available", ""}

# Text cut off upstream (DBF/REST field widths: MAP_UNIT_C 200, SOIL_PROF
# 58; the FGDB copy in the zip is identical). (CODE, field) -> (the
# whitespace-collapsed tail as published, the tail we keep); we ship
# value[:-len(tail)] + kept + "…" (U+2026; SwiftUI text only). We never
# invent the missing words: a final token whose completeness is unknown is
# dropped, dangling punctuation goes. Stale entries (LIST fixed the text)
# fail the build.
ELLIPSIS = "…"
TRUNCATED = {
    ("Bu", "MAP_UNIT_C"): ("approximately 200", "approximately"),   # at width 200; '200' may go on ('2000', '200 m')
    ("On", "MAP_UNIT_C"): ("rainfall is gre", "rainfall is"),       # at width 200, mid-word
    ("Ca-Ta", "MAP_UNIT_C"): ("neutral reactio*", "neutral"),        # at width 200, mid-word + stray '*'
    ("Bgb", "MAP_UNIT_C"): ("rolling (", "rolling"),                 # 182 chars; slope class after '(' missing
    ("Lw", "MAP_UNIT_C"): ("depressions/", "depressions"),           # 171 chars; '/' then nothing
    ("Vl", "MAP_UNIT_C"): ("capping low h", "capping low"),          # 164 chars, mid-word
    # 173 chars, "...(3-32%) land.  With poorly drained soil" — a final
    # sentence without its full stop (every other multi-sentence value that
    # lacks one reads complete). JUDGEMENT, not provable: the cut is not
    # mid-word, so the detector below cannot see it; 'soil' is kept (true
    # whether or not an 's' followed).
    ("K", "MAP_UNIT_C"): ("With poorly drained soil", "With poorly drained soil"),
    ("Lw", "SOIL_PROF"): ("Solifluction Depo", "Solifluction"),     # at width 58, mid-word ('Deposits')
}
# Exactly at the field width but reads complete — AMBIGUOUS, left verbatim
# (pinned so a change is noticed): 'siliceous sands' could be a cut of
# 'siliceous sandstone' (its description says "deep sands on siliceous
# sandstone"; unit Pss is "... on sandstone"), or intended.
AT_WIDTH_VERBATIM = {
    ("Bms1-Pss", "MAP_UNIT_N"): "Brown soils on micaeous Sandstone 1 - podzol and podzolic soils on siliceous sands",
}
TEXT_FIELDS = {"MAP_UNIT_N": "name", "MAP_UNIT_C": "description", "SOIL_PROF": "profile"}
DANGLING_WORDS = {"a", "an", "and", "or", "the", "of", "to", "with", "on", "in", "at", "from", "by"}

T0 = time.time()
UA = {"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"}


def log(msg: str) -> None:
    print(f"[{time.time() - T0:6.1f}s] {msg}", flush=True)


def run(cmd, **kw):
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def http(url: str, method: str = "GET", timeout: int = 60):
    for attempt in range(3):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, method=method, headers=UA),
                                          timeout=timeout)
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  {method} {url} failed ({e}), retrying")
            time.sleep(3)
    raise AssertionError


# ------------------------------------------------------------ sources

def fetch_zip(fresh: bool) -> str:
    """→ the zip's Last-Modified date (YYYY-MM-DD). Cached; --fresh re-pulls.
    A changed upstream zip is announced, never silently mixed in."""
    CACHE.mkdir(parents=True, exist_ok=True)
    meta_path = CACHE / "zip.json"
    with http(ZIP_URL, "HEAD") as r:
        remote = {"last_modified": r.headers["Last-Modified"], "length": int(r.headers["Content-Length"])}
    if fresh or not ZIP.exists() or not meta_path.exists():
        log(f"downloading {ZIP_URL} ({remote['length'] / 1e6:.1f} MB)")
        tmp = ZIP.with_suffix(".part")
        with http(ZIP_URL, timeout=300) as r, open(tmp, "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        if tmp.stat().st_size != remote["length"]:
            raise SystemExit(f"zip truncated: {tmp.stat().st_size} of {remote['length']} bytes")
        tmp.replace(ZIP)
        meta_path.write_text(json.dumps(remote))
    meta = json.loads(meta_path.read_text())
    if meta != remote:
        print(f"NOTE: upstream zip changed ({meta} -> {remote}); run with --fresh to rebuild from it")
    if ZIP.stat().st_size != meta["length"]:
        raise SystemExit("cached zip size differs from its recorded Content-Length — run --fresh")
    return email.utils.parsedate_to_datetime(meta["last_modified"]).date().isoformat()


def check_licence() -> None:
    with zipfile.ZipFile(ZIP) as z:
        readme = z.read("readme.txt").decode("latin-1")
    m = re.search(r"Licensing:(.*?)\n\s*\n", readme, re.S)
    got = " ".join(m.group(1).split()) if m else None
    if got != README_LICENCE:
        raise SystemExit(f"REFUSING: the zip's readme.txt licence text changed:\n  {got!r}\n"
                         f"expected:\n  {README_LICENCE!r}")
    with http(OPENDATA_JS) as r:
        js = r.read().decode("utf-8", "replace")
    entry = next((json.loads(m.group(0)) for m in re.finditer(r'\["[^\[\]]*",\s*"[^"]*",\s*"[^"]*",\s*"[^"]*",'
                                                              r'\s*\[[^\]]*\],\s*"[^"]*"\]', js)
                  if json.loads(m.group(0))[5] == OPENDATA_KEY), None)
    if not entry or entry[3] != OPENDATA_LICENCE_CODE:
        raise SystemExit(f"REFUSING: LISTdata catalogue entry for {OPENDATA_KEY} changed: {entry}")
    branch = re.search(r'datasets\[i\]\[3\] == "%s"\)\s*\{(.*?)\}' % OPENDATA_LICENCE_CODE, js, re.S)
    if not branch or f"href='{CC_BY_3_AU}'" not in branch.group(1):
        raise SystemExit(f"REFUSING: LISTdata's '{OPENDATA_LICENCE_CODE}' badge no longer links {CC_BY_3_AU}")
    log(f"licence: readme.txt + LISTdata catalogue ({entry[0]!r}, {entry[3]}) say {LICENCE}")


def strip_volatile(o):
    """The layer JSON minus `authoringInfo` (ArcGIS editor state, not drawing)."""
    if isinstance(o, dict):
        return {k: strip_volatile(v) for k, v in o.items() if k != "authoringInfo"}
    if isinstance(o, list):
        return [strip_volatile(v) for v in o]
    return o


def renderer_colours(body: dict) -> dict[str, str]:
    ren = body["drawingInfo"]["renderer"]
    if ren["type"] != "uniqueValue" or ren.get("field1") != "CODE" or ren.get("field2"):
        raise SystemExit(f"renderer is no longer uniqueValue on CODE: {ren['type']} {ren.get('field1')}")
    colours = {}
    for u in ren["uniqueValueInfos"]:
        s = u["symbol"]
        if s["type"] != "esriSFS" or s["style"] != "esriSFSSolid" or s["color"][3] != 255:
            raise SystemExit(f"renderer entry {u['value']!r} is not an opaque solid fill: {s}")
        if u["value"] in colours:
            raise SystemExit(f"renderer lists {u['value']!r} twice")
        colours[u["value"]] = "#%02x%02x%02x" % tuple(s["color"][:3])
    if ren.get("defaultSymbol"):
        raise SystemExit("renderer gained a defaultSymbol — revisit ALIASES (LIST may now colour everything)")
    return colours


def fetch_renderer() -> tuple[dict, dict | None]:
    """Live renderer on EVERY full run (≈ 55 KB) → (live layer JSON, cached
    layer JSON or None), both without authoringInfo. main() decides what a
    difference means once it knows which colours the data uses."""
    with http(f"{LAYER}?f=json") as r:
        live = json.load(r)
    if "error" in live:  # ArcGIS reports errors inside HTTP-200 bodies
        raise SystemExit(f"renderer: server error {live['error']}")
    cached = json.loads(RENDERER_CACHE.read_text()) if RENDERER_CACHE.exists() else None
    return strip_volatile(live), (strip_volatile(cached) if cached else None)


def resolve_colours(colours: dict[str, str], data_codes: set[str]) -> dict[str, str]:
    """data CODE → '#rrggbb' via LIST's renderer + ALIASES; fails loudly."""
    for code, target in ALIASES.items():
        if code in colours:
            raise SystemExit(f"alias {code!r} is stale: LIST's renderer now colours it directly "
                             f"({colours[code]}) — drop the alias")
        if code not in data_codes:
            raise SystemExit(f"alias {code!r} no longer occurs in the data — drop it")
        if target not in colours:
            raise SystemExit(f"alias target {target!r} missing from LIST's renderer")
    unmatched = sorted(data_codes - set(colours) - set(ALIASES))
    if unmatched:
        raise SystemExit(f"NEW data codes without a LIST renderer colour: {unmatched} — "
                         f"add a justified entry to ALIASES")
    return {c: colours[ALIASES.get(c, c)] for c in data_codes}


def head_report(url: str) -> tuple[str, int]:
    """HEAD only — the PDFs are never downloaded (no licence stated). → (final
    URL after redirects, bytes)."""
    with http(url, "HEAD") as r:
        msg = email.message.Message()
        msg["Content-Type"] = r.headers.get("Content-Type", "")
        if r.status != 200 or msg.get_content_type() != "application/pdf":  # lower-cased, params dropped
            raise SystemExit(f"report {url}: HTTP {r.status} {r.headers.get('Content-Type')}")
        return r.url, int(r.headers["Content-Length"])


# ------------------------------------------------------------ attributes

def text(v) -> str:
    return " ".join(v.split()) if isinstance(v, str) else ""


def orders_of(v) -> list[str]:
    out = []
    for tok in (v or "").split(","):
        tok = tok.strip()
        if tok in ASC_NONE:
            continue
        tok = ASC_FIXES.get(tok, tok)
        if tok not in ASC_ORDERS:
            raise SystemExit(f"unknown ASC order {tok!r} in {v!r} — add a gloss (or a typo fix)")
        if tok not in out:
            out.append(tok)
    return out


def sheet_key(stem: str) -> str:
    return stem.lower().replace("_", "-")


def dbf_widths() -> dict[str, int]:
    """Character field widths from the zip's DBF header (the cut-off limit)."""
    with zipfile.ZipFile(ZIP) as z:
        d = z.read(f"{STEM_IN_ZIP}.dbf")
    hl = struct.unpack("<H", d[8:10])[0]
    return {d[i:i + 11].split(b"\0")[0].decode("ascii"): d[i + 16]
            for i in range(32, hl - 1, 32) if d[i + 11:i + 12] == b"C"}


def looks_cut(raw: str, width: int) -> list[str]:
    """Conservative signs that upstream text was cut off: filled to the field
    width, or ending in dangling punctuation, a lone letter or a function word."""
    t = text(raw)
    why = []
    if len(raw.rstrip()) >= width:
        why.append(f"fills the field width {width}")
    if re.search(r"[(\[/*\-,&:;]$", t):
        why.append(f"ends in {t[-1]!r}")
    last = t.split(" ")[-1] if t else ""
    if len(last) == 1 and last.isalpha():
        why.append(f"ends in a lone letter {last!r}")
    if last.lower() in DANGLING_WORDS and len(t.split(" ")) > 1:
        why.append(f"ends in {last!r}")
    return why


def check_truncation(per_code: dict[str, dict[str, str]], widths: dict[str, int]) -> None:
    """Fail on any cut-looking value not in TRUNCATED / AT_WIDTH_VERBATIM, and
    on stale entries. Logs exactly what the detector flags."""
    flagged = {}
    for code, row in per_code.items():
        for field in TEXT_FIELDS:
            raw = row[field]
            if raw and (why := looks_cut(raw, widths[field])):
                flagged[(code, field)] = why
    log("truncation detector flags: " + "; ".join(f"{c}.{f} ({', '.join(w)})"
                                                  for (c, f), w in sorted(flagged.items())))
    new = sorted(k for k in flagged if k not in TRUNCATED and k not in AT_WIDTH_VERBATIM)
    if new:
        raise SystemExit("text that looks cut off upstream, not in TRUNCATED: " +
                         "; ".join(f"{c}.{f}: …{text(per_code[c][f])[-50:]!r} ({', '.join(flagged[(c, f)])})"
                                   for c, f in new))
    for (code, field), (tail, _) in TRUNCATED.items():
        if code not in per_code or not text(per_code[code][field]).endswith(tail):
            raise SystemExit(f"TRUNCATED[{code}.{field}] is stale (text now "
                             f"{text(per_code.get(code, {}).get(field))[-60:]!r}) — drop or update it")
    for (code, field), value in AT_WIDTH_VERBATIM.items():
        if code not in per_code or text(per_code[code][field]) != value:
            raise SystemExit(f"AT_WIDTH_VERBATIM[{code}.{field}] changed — review it")
    unseen = sorted(k for k in TRUNCATED if k not in flagged)
    log(f"truncated upstream: {len(TRUNCATED)} values ({len(TRUNCATED) - len(unseen)} detected, "
        f"pinned by judgement: {unseen}); ambiguous, left verbatim: {sorted(AT_WIDTH_VERBATIM)}")


def cleaned(code: str, field: str, raw) -> str:
    t = text(raw)
    if (code, field) in TRUNCATED:
        tail, kept = TRUNCATED[(code, field)]
        t = t[: len(t) - len(tail)] + kept
        t = t.rstrip(" (/*-,&:;") + ELLIPSIS
    return t


# ------------------------------------------------------------ geometry

def read_polygons():
    import pyogrio
    import shapely
    df = pyogrio.read_dataframe(f"/vsizip/{ZIP}/{STEM_IN_ZIP}.shp", fid_as_index=True)
    if str(df.crs.to_epsg()) != "28355":
        raise SystemExit(f"expected MGA55 (EPSG:28355), got {df.crs}")
    bad = df.index[df.CODE.isna() | (df.CODE.fillna("").astype(str).str.strip() == "")].tolist()
    if bad:
        raise SystemExit(f"{len(bad)} polygon(s) with a null/empty CODE (FIDs {bad[:20]}) — "
                         f"decide how to treat them before building")
    geoms = np.asarray(df.geometry.values)
    if set(shapely.get_type_id(geoms)) != {3}:
        raise SystemExit("expected plain Polygons only")
    return df, geoms


def repair(geoms):
    """make_valid the few self-intersecting rings; keep only polygonal parts
    and make sure the area barely moves."""
    import shapely
    bad = np.where(~shapely.is_valid(geoms))[0]
    out = geoms.copy()
    notes = []
    for i in bad:
        g = shapely.make_valid(geoms[i])
        if g.geom_type == "GeometryCollection":
            g = shapely.union_all([p for p in g.geoms if p.geom_type in ("Polygon", "MultiPolygon")])
        if g.geom_type not in ("Polygon", "MultiPolygon") or not g.is_valid:
            raise SystemExit(f"repair of row {i} gave {g.geom_type}")
        a0, a1 = shapely.area(geoms[i]), g.area
        if abs(a1 - a0) > max(100.0, 0.001 * a0):
            raise SystemExit(f"repair of row {i} changed its area {a0:.0f} -> {a1:.0f} m²")
        notes.append((int(i), shapely.is_valid_reason(geoms[i]), round(a1 - a0, 1), g.geom_type))
        out[i] = g
    return out, notes


def to_4326(geoms):
    import shapely
    from pyproj import Transformer
    tr = Transformer.from_crs(28355, 4326, always_xy=True)

    def f(c):
        x, y = tr.transform(c[:, 0], c[:, 1])
        return np.round(np.column_stack([x, y]), 7)
    return shapely.transform(geoms, f)


def labels(geoms):
    """Maximum-inscribed-circle centre + radius (m) per polygon (MGA55), as
    build_tasveg.py; for a repaired MultiPolygon, its biggest circle."""
    import shapely
    area = shapely.area(geoms)
    tol = np.clip(np.sqrt(area) / 100, 0.5, 10.0)
    mic = shapely.maximum_inscribed_circle(geoms, tol)
    c = shapely.get_coordinates(mic).reshape(-1, 2, 2)
    centre = c[:, 0, :]
    r = np.hypot(c[:, 1, 0] - c[:, 0, 0], c[:, 1, 1] - c[:, 0, 1])
    inside = shapely.contains_properly(geoms, shapely.points(centre))
    return centre, r, int((~inside).sum())


def line_parts(geoms):
    """Every LineString inside (Multi)LineStrings / GeometryCollections."""
    import shapely
    parts = shapely.get_parts(shapely.get_parts(np.asarray(geoms, dtype=object)))
    return parts[shapely.get_type_id(parts) == 1]


def boundaries(geoms, codes, colour_of, land_outline, frame_outline, water_outline):
    """Edges shared by two kept polygons of different CODE (MGA55).

    The source coverage is vertex-identical along shared edges (verified:
    the pairwise boundary intersections add up to the implied internal
    length (Σ perimeters − land outline) / 2 within 0.1 %), so a plain
    intersection of neighbouring boundaries recovers each shared edge.
    Edges against DROPPED water have no kept neighbour, so shorelines are
    never boundaries (the base map draws them); the frame outline is
    soils_extent's."""
    import shapely
    bd = shapely.boundary(geoms)
    i, j = shapely.STRtree(geoms).query(geoms, predicate="intersects")
    keep = i < j
    i, j = i[keep], j[keep]
    inter = shapely.intersection(bd[i], bd[j])
    length = shapely.length(inter)
    shared = length > 0
    i, j, inter, length = i[shared], j[shared], inter[shared], length[shared]
    codes = np.asarray(codes)
    diff = codes[i] != codes[j]
    same_colour = diff & np.array([colour_of[a] == colour_of[b] for a, b in zip(codes[i], codes[j])])
    implied = (shapely.length(bd).sum() - land_outline.length) / 2
    stats = {
        "shared_km": length.sum() / 1e3, "implied_km": implied / 1e3,
        "seam_km": length[~diff].sum() / 1e3, "seam_pairs": int((~diff).sum()),
        "diff_km": length[diff].sum() / 1e3, "diff_pairs": int(diff.sum()),
        "same_colour_km": length[same_colour].sum() / 1e3,
        "same_colour_unit_pairs": len({tuple(sorted(p)) for p in zip(codes[i][same_colour], codes[j][same_colour])}),
        "same_colour_polygon_pairs": int(same_colour.sum()),
    }
    if abs(stats["shared_km"] - stats["implied_km"]) > 0.001 * stats["implied_km"]:
        raise SystemExit(f"shared edges {stats['shared_km']:.1f} km vs implied {stats['implied_km']:.1f} km — "
                         f"the coverage is no longer vertex-identical; node it (or snap) before intersecting")
    lines = shapely.line_merge(shapely.multilinestrings(line_parts(inter[diff])))
    merged = line_parts([lines])
    ml = shapely.multilinestrings(merged)
    for what, outline in (("the extent (frame) outline", frame_outline), ("a kept/water shoreline", water_outline)):
        on = shapely.length(shapely.intersection(ml, outline))
        if on > 1.0:
            raise SystemExit(f"{on:.0f} m of boundary lines lie on {what}")
    stats["lines"] = len(merged)
    stats["lines_km"] = shapely.length(merged).sum() / 1e3
    if abs(stats["lines_km"] - stats["diff_km"]) > 0.001 * stats["diff_km"]:
        raise SystemExit(f"merged boundary lines {stats['lines_km']:.1f} km != pairwise {stats['diff_km']:.1f} km")
    pairs = sorted({tuple(sorted(map(str, p))) for p in zip(codes[i][same_colour], codes[j][same_colour])})
    return merged, stats, pairs


# ------------------------------------------------------------ tiles

def strategies(mb: Path):
    with sqlite3.connect(mb) as db:
        row = db.execute("SELECT value FROM metadata WHERE name='strategies'").fetchone()
    return json.loads(row[0]) if row and row[0] else []


def check_strategies(mb: Path, label: str) -> dict:
    """tiny_polygons is the only allowed strategy (the dust square keeps its
    feature's attributes and id). Anything else = features merged or lost."""
    tiny = {}
    for z, strat in enumerate(strategies(mb)):
        bad = set(strat) - {"tiny_polygons"}
        if bad:
            raise SystemExit(f"{label}: unsafe tippecanoe strategy at z{z}: { {k: strat[k] for k in bad} }")
        if strat.get("tiny_polygons"):
            tiny[z] = strat["tiny_polygons"]
    return tiny


def tippecanoe(src: Path, out: Path, layer: str, zmin: int, zmax: int, *extra):
    # NO coalescing/dropping flags (cross-unit merges = wrong colour, wrong
    # tap answer); size limits lifted so an oversized tile is shipped whole.
    # cwd=WORK + bare file names: the command lines end up in the archive's
    # generator_options metadata, which ships in the app (no local paths).
    run(["tippecanoe", "-q", "-o", out.name, "--force", "-l", layer, "-n", NAME, "-A", ATTRIBUTION,
         f"-Z{zmin}", f"-z{zmax}", "--no-tile-size-limit", "--no-feature-limit", "--hilbert",
         *extra, src.name], cwd=WORK)


def scan(mb: Path, zoom: int, layer: str, key: str | None = None, line_m: bool = False):
    """One zoom of an mbtiles → (distinct feature ids, distinct values of
    `key`, max tile bytes, tiles, ground length of the layer's lines in m —
    clipped to each tile so the buffer zone isn't counted twice)."""
    import mapbox_vector_tile
    import shapely
    import shapely.geometry
    from mapbox_vector_tile.Mapbox import vector_tile_pb2
    ids, vals, biggest, n, metres = set(), set(), 0, 0, 0.0
    W = 20037508.342789244
    with sqlite3.connect(mb) as db:
        rows = db.execute("SELECT tile_row, tile_data FROM tiles WHERE zoom_level=?", (zoom,)).fetchall()
    for row, data in rows:
        n += 1
        biggest = max(biggest, len(data))
        raw = gzip.decompress(data) if data[:2] == b"\x1f\x8b" else data
        t = vector_tile_pb2.tile()
        t.ParseFromString(raw)
        for lyr in t.layers:
            if lyr.name != layer:
                continue
            k = list(lyr.keys).index(key) if key and key in lyr.keys else -1
            for ft in lyr.features:
                if ft.HasField("id"):
                    ids.add(ft.id)
                tg = ft.tags
                for j in range(0, len(tg), 2):
                    if tg[j] == k:
                        vals.add(lyr.values[tg[j + 1]].string_value)
            if line_m:
                ext = lyr.extent
                y = (2 ** zoom - 1 - row) + 0.5                    # TMS row -> XYZ, tile centre
                lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / 2 ** zoom))))
                unit = 2 * W / 2 ** zoom / ext * math.cos(math.radians(lat))
                dec = mapbox_vector_tile.decode(raw)
                for f in dec[layer]["features"]:
                    g = shapely.clip_by_rect(shapely.geometry.shape(f["geometry"]), 0, 0, ext, ext)
                    metres += g.length * unit
    return ids, vals, biggest, n, metres


def check_archive(joined: Path, n_poly: int, table_codes: set[str], bound_m: float | None):
    """Tripwires on the FINAL joined archive (what pmtiles convert ships)."""
    meta = dict(sqlite3.connect(joined).execute("SELECT name, value FROM metadata").fetchall())
    layers = {v["id"]: v for v in json.loads(meta["json"])["vector_layers"]}
    if set(layers) != set(EXPECT_LAYERS):
        raise SystemExit(f"vector_layers {sorted(layers)} != {sorted(EXPECT_LAYERS)}")
    for name, (zmin, zmax, fields) in EXPECT_LAYERS.items():
        v = layers[name]
        if (v["minzoom"], v["maxzoom"]) != (zmin, zmax) or set(v.get("fields", {})) != fields:
            raise SystemExit(f"vector_layers[{name}] = z{v['minzoom']}-{v['maxzoom']} {sorted(v.get('fields', {}))}, "
                             f"expected z{zmin}-{zmax} {sorted(fields)}")
    check_strategies(joined, "joined archive")
    ids, codes, _, _, _ = scan(joined, POLY_MAX, "soils", "CODE")
    if len(ids) != n_poly:
        raise SystemExit(f"soils z{POLY_MAX}: {len(ids)} of {n_poly} polygon ids present")
    if codes != table_codes:
        raise SystemExit(f"tile codes != table codes: only tiles {sorted(codes - table_codes)}, "
                         f"only table {sorted(table_codes - codes)}")
    for z in range(LABEL_MIN, LABEL_MAX + 1):
        lids, lcodes, _, _, _ = scan(joined, z, "soils_labels", "CODE")
        if lids != ids or lcodes != table_codes:
            raise SystemExit(f"labels z{z}: {len(lids)} of {len(ids)} ids, {len(lcodes)} codes")
    eids, _, _, _, _ = scan(joined, POLY_MAX, "soils_extent")
    if not eids:
        raise SystemExit("soils_extent missing at z12")
    _, _, _, nb, metres = scan(joined, BOUND_MAX, "soils_boundaries", line_m=True)
    msg = f"boundaries at z{BOUND_MAX}: {metres / 1e3:,.1f} km in {nb} tiles"
    if bound_m is not None:
        if abs(metres - bound_m) > 0.01 * bound_m:
            raise SystemExit(f"{msg} vs {bound_m / 1e3:,.1f} km computed — more than 1 % off")
        msg += f" (source {bound_m / 1e3:,.1f} km, {100 * (metres / bound_m - 1):+.2f} %)"
    log(f"final archive: vector_layers as expected; all {n_poly} polygon ids and {len(table_codes)} "
        f"codes at z{POLY_MAX}; every label at z{LABEL_MIN}-{LABEL_MAX}; extent present; {msg}")


def build_tiles(n_poly: int, table_codes: set[str], bound_m: float | None):
    srcs = {k: WORK / f"{k}.geojsons" for k in ("soils", "labels", "extent", "boundaries")}
    for p in srcs.values():
        if not p.exists():
            raise SystemExit(f"missing {p} — run without --tiles-only first")
    mbs = {k: WORK / f"part_{k}.mbtiles" for k in srcs}
    tippecanoe(srcs["soils"], mbs["soils"], "soils", POLY_MIN, POLY_MAX, "--detect-shared-borders",
               "--no-tiny-polygon-reduction-at-maximum-zoom")  # every polygon whole at z12
    tippecanoe(srcs["labels"], mbs["labels"], "soils_labels", LABEL_MIN, LABEL_MAX, "-r1")
    tippecanoe(srcs["extent"], mbs["extent"], "soils_extent", POLY_MIN, POLY_MAX)
    # lines: -r1 so no line is ever thinned by the drop rate below maxzoom
    tippecanoe(srcs["boundaries"], mbs["boundaries"], "soils_boundaries", BOUND_MIN, BOUND_MAX, "-r1")
    tiny = {k: check_strategies(mb, k) for k, mb in mbs.items()}
    log(f"tiled; tiny-polygon reductions per zoom: {tiny}")

    joined = WORK / "soils.mbtiles"
    run(["tile-join", "-q", "-o", joined.name, "--force", "--no-tile-size-limit",
         "-n", NAME, "-A", ATTRIBUTION, *(mbs[k].name for k in srcs)], cwd=WORK)
    check_archive(joined, n_poly, table_codes, bound_m)
    tmp = WORK / "soils.pmtiles"
    tmp.unlink(missing_ok=True)
    run(["pmtiles", "convert", joined, tmp], capture_output=True)
    run(["pmtiles", "verify", tmp], capture_output=True)
    size = tmp.stat().st_size
    if size > SIZE_CAP:
        raise SystemExit(f"soils.pmtiles is {size / 1e6:.1f} MB > {SIZE_CAP / 1e6:.0f} MB cap — not shipped")
    show = subprocess.run(["pmtiles", "show", str(tmp)], capture_output=True, text=True, check=True).stdout
    b = [float(v) for v in re.search(r"bounds: \(long: ([-\d.]+), lat: ([-\d.]+)\) \(long: ([-\d.]+), "
                                     r"lat: ([-\d.]+)\)", show).groups()]
    if not (TAS_BOX[0] <= b[0] < b[2] <= TAS_BOX[2] and TAS_BOX[1] <= b[1] < b[3] <= TAS_BOX[3]):
        raise SystemExit(f"archive bounds {b} outside Tasmania {TAS_BOX}")
    with sqlite3.connect(mbs["soils"]) as db:  # tile-join rounds bounds out to z12 tiles
        pb = [float(v) for v in db.execute("SELECT value FROM metadata WHERE name='bounds'")
              .fetchone()[0].split(",")]
    if max(abs(x - y) for x, y in zip(b, pb)) > 0.1:
        raise SystemExit(f"archive bounds {b} far from the polygons' {pb}")
    if "/Users/" in show:
        raise SystemExit("a local path leaked into the archive metadata")
    with sqlite3.connect(joined) as db:
        per_zoom = db.execute("SELECT zoom_level, COUNT(*), MAX(LENGTH(tile_data)) FROM tiles "
                              "GROUP BY zoom_level").fetchall()
    if f"addressed tiles count: {sum(n for _, n, _ in per_zoom)}" not in show:
        raise SystemExit("PMTiles tile count differs from the checked mbtiles")
    DATA.mkdir(exist_ok=True)
    (DATA / "soils.pmtiles").write_bytes(tmp.read_bytes())
    tmp.replace(OUT)
    log("tiles per zoom: " + ", ".join(f"z{z} {n} (max {m / 1024:.0f} KB)" for z, n, m in per_zoom))
    log(f"bounds: polygons {pb}, archive (tile-rounded) {b}; wrote {OUT} ({size / 1e6:.2f} MB) + data/soils.pmtiles")


def tiles_only():
    """Re-tile cached GeoJSON, refusing stale colours (e.g. after an ALIASES
    edit): every cached feature colour must equal today's resolution from
    the cached renderer + ALIASES, and the table's."""
    table = json.loads(TABLE.read_text())
    if not RENDERER_CACHE.exists():
        raise SystemExit("no cached renderer — run a full build")
    colour_of = resolve_colours(renderer_colours(strip_volatile(json.loads(RENDERER_CACHE.read_text()))),
                                set(table["units"]))
    stale = {c for c, u in table["units"].items() if u["color"] != colour_of[c]}
    with open(WORK / "soils.geojsons", encoding="utf-8") as f:
        for line in f:
            p = json.loads(line)["properties"]
            if colour_of.get(p["CODE"]) != p["color"]:
                stale.add(p["CODE"])
    if stale:
        raise SystemExit(f"cached colours are stale for {sorted(stale)} — run a full build, not --tiles-only")
    stats_path = WORK / "stats.json"
    stats = json.loads(stats_path.read_text()) if stats_path.exists() else {}
    build_tiles(table["source"]["polygons"], set(table["units"]), stats.get("boundaries_m"))


# ------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("Run")[0])
    ap.add_argument("--fresh", action="store_true", help="re-download the zip; accept a changed renderer")
    ap.add_argument("--tiles-only", action="store_true", help="re-tile cached work files")
    args = ap.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    if args.tiles_only:
        return tiles_only()

    import shapely
    from pyproj import Transformer
    modified = fetch_zip(args.fresh)
    check_licence()
    live_layer, cached_layer = fetch_renderer()
    colours = renderer_colours(live_layer)

    df, geoms = read_polygons()
    n_all = len(df)
    log(f"source: {n_all} polygons, {df.CODE.nunique()} codes, zip of {modified}")
    if not EXPECT_POLYGONS[0] <= n_all <= EXPECT_POLYGONS[1]:
        raise SystemExit(f"{n_all} polygons, expected {EXPECT_POLYGONS}")
    if not EXPECT_CODES[0] <= df.CODE.nunique() <= EXPECT_CODES[1]:
        raise SystemExit(f"{df.CODE.nunique()} codes, expected {EXPECT_CODES}")
    area_all = shapely.area(geoms)
    if not EXPECT_AREA_KM2[0] <= area_all.sum() / 1e6 <= EXPECT_AREA_KM2[1]:
        raise SystemExit(f"total area {area_all.sum() / 1e6:.0f} km², expected {EXPECT_AREA_KM2}")

    # ---- water: LIST's renderer has no entry for it (not drawn); 10 polygons
    # of estuary/bay/lake water — dropped from tiles, table and extent.
    is_water = df.CODE.isin(WATER_CODES).to_numpy()
    if df.CODE[~is_water].str.lower().eq("water").any():
        raise SystemExit("a new spelling of 'water' — add it to WATER_CODES")
    log(f"water: dropped {is_water.sum()} polygons, {area_all[is_water].sum() / 1e6:.1f} km² "
        f"({', '.join(f'{a / 1e6:.1f}' for a in sorted(area_all[is_water], reverse=True))} km²)")
    keep = ~is_water
    df = df[keep]
    water, wnotes = repair(geoms[is_water])  # kept only for the extent frame
    if wnotes:
        log(f"repaired {len(wnotes)} water polygon(s)")
    geoms, notes = repair(geoms[keep])
    for n in notes:
        log(f"repaired FID {df.index[n[0]]} ({df.CODE.iloc[n[0]]}): {n[1]} -> {n[3]}, area {n[2]:+} m²")
    ids = df.index.to_numpy(np.int64) + 1  # feature id = shapefile FID + 1
    area = shapely.area(geoms)
    n_poly = len(df)

    union = shapely.union_all(geoms)
    overlap = area.sum() - union.area
    log(f"kept {n_poly} polygons, {area.sum() / 1e6:.1f} km²; union {union.area / 1e6:.1f} km² "
        f"(overlap {overlap / 1e4:.1f} ha); area p10/50/90 "
        f"{np.percentile(area, 10) / 1e4:.1f}/{np.percentile(area, 50) / 1e4:.0f}/"
        f"{np.percentile(area, 90) / 1e4:.0f} ha; {(area < 1e4).sum()} under 1 ha")

    # ---- per-unit attributes (a function of CODE; asserted)
    codes = df.CODE.tolist()
    if any(not c.isascii() or c != c.strip() for c in codes):
        raise SystemExit("map-label CODEs must be ASCII without padding")
    folded = {}
    for c in set(codes):
        folded.setdefault(c.lower(), []).append(c)
    case_twins = sorted(sorted(v) for v in folded.values() if len(v) > 1)
    if case_twins:
        log(f"NOTE: codes differing only in case (distinct units, keep exact-case matching): {case_twins}")
    sheets_of = []
    for rep in df.REPORT:
        m = REPORT_RE.fullmatch(rep or "")
        if not m:
            raise SystemExit(f"unexpected REPORT {rep!r}")
        sheets_of.append(sheet_key(m.group(1)))
    raw_of = {}
    for i, c in enumerate(codes):
        raw_of.setdefault(c, {f: (df[f].iloc[i] if isinstance(df[f].iloc[i], str) else "") for f in TEXT_FIELDS})
    check_truncation(raw_of, dbf_widths())
    units: dict[str, dict] = {}
    problems, reordered = [], set()
    for i, c in enumerate(codes):
        row = df.iloc[i]
        prof = text(row.SOIL_PROF)
        u = {
            "name": cleaned(c, "MAP_UNIT_N", row.MAP_UNIT_N),
            "description": cleaned(c, "MAP_UNIT_C", row.MAP_UNIT_C),
            "orders": orders_of(row.AUSTRALIAN),
            "profile": None if prof in PROFILE_NONE else cleaned(c, "SOIL_PROF", prof),
        }
        if not u["name"]:
            problems.append(f"{c}: empty MAP_UNIT_N")
        if c not in units:
            units[c] = {**u, "color": None, "ha": 0.0, "polygons": 0, "sheets": set()}
        else:
            prev = units[c]
            for k in ("name", "description", "profile"):
                if prev[k] != u[k]:
                    problems.append(f"{c}: {k} differs: {prev[k]!r} vs {u[k]!r}")
            if prev["orders"] != u["orders"]:
                if set(prev["orders"]) != set(u["orders"]):
                    problems.append(f"{c}: orders differ: {prev['orders']} vs {u['orders']}")
                elif c not in reordered:  # same set, other order (Br-Ta): keep the lowest FID's
                    reordered.add(c)
                    log(f"NOTE: {c} lists its orders in two orders ({prev['orders']} / {u['orders']}); "
                        f"kept the lowest FID's")
        units[c]["ha"] += area[i] / 1e4
        units[c]["polygons"] += 1
        units[c]["sheets"].add(sheets_of[i])
    if problems:
        raise SystemExit("attributes are not a function of CODE:\n  " + "\n  ".join(problems))

    # ---- colours (LIST's live renderer; changes vs the cached copy surface here)
    data_codes = set(units)
    colour_of = resolve_colours(colours, data_codes)
    used = {ALIASES.get(c, c) for c in data_codes}
    if cached_layer is not None and cached_layer != live_layer:
        old = renderer_colours(cached_layer)
        changed = sorted(c for c in used if old.get(c) != colours.get(c))
        detail = "; ".join(f"{c}: {old.get(c)} -> {colours.get(c)}" for c in changed)
        if changed and not args.fresh:
            # A shipped colour is data: a silent change would restyle the
            # map without review. Fail; --fresh accepts it deliberately.
            raise SystemExit(f"LIST changed colours the map uses: {detail} — review, then rerun with --fresh")
        others = sorted(set(old.items()) ^ set(colours.items()))
        log(f"NOTE: LIST's renderer changed since the cached copy ("
            f"{'ACCEPTED with --fresh: ' + detail if changed else 'no colour the map uses'}; "
            f"other entry changes: {len(others)}; non-colour changes possible) — cache updated")
    RENDERER_CACHE.write_text(json.dumps(live_layer, sort_keys=True))
    unused = sorted(set(colours) - data_codes - set(ALIASES.values()))
    if unused:
        log(f"NOTE: renderer codes no polygon uses: {unused}")
    for c, u in units.items():
        u["color"] = colour_of[c]
    log(f"colours: {len(data_codes) - len(ALIASES)} codes direct from LIST's renderer, "
        f"{len(ALIASES)} aliased ({len(ALIASES_OURS)} our choice: {sorted(ALIASES_OURS)}); "
        f"{len({u['color'] for u in units.values()})} distinct colours")

    # ---- sheets (report PDFs: HEAD only, never downloaded)
    stems = {}
    for rep in df.REPORT:
        stems[sheet_key(REPORT_RE.fullmatch(rep).group(1))] = (REPORT_RE.fullmatch(rep).group(1), rep)
    if len(stems) != EXPECT_SHEETS:
        raise SystemExit(f"{len(stems)} map sheets, expected {EXPECT_SHEETS}")
    g4326 = to_4326(geoms)
    sheets_arr = np.array(sheets_of)
    sheets = {}
    for key in sorted(stems):
        stem, rep = stems[key]
        url, size = head_report(rep)
        sel = sheets_arr == key
        b = shapely.total_bounds(g4326[sel])
        sheets[key] = {"name": stem.replace("_", " "), "url": url, "bytes": size,
                       "ha": round(float(area[sel].sum()) / 1e4, 1),
                       "bbox": [round(float(v), 4) for v in b]}
    log("sheets: " + ", ".join(f"{k} {v['ha'] / 100:.0f} km² {v['bytes'] / 1e6:.1f} MB"
                               for k, v in sheets.items()))
    tb = shapely.total_bounds(g4326)
    if not (TAS_BOX[0] <= tb[0] < tb[2] <= TAS_BOX[2] and TAS_BOX[1] <= tb[1] < tb[3] <= TAS_BOX[3]):
        raise SystemExit(f"bounds {tb} outside Tasmania — CRS slip?")

    # ---- labels
    centre, r, outside = labels(geoms)
    lon, lat = Transformer.from_crs(28355, 4326, always_xy=True).transform(centre[:, 0], centre[:, 1])
    m_per_pt = {z: 78271.517 * np.cos(np.radians(42.5)) / 2 ** z for z in range(8, 14)}
    fit = ", ".join(f"z{z} {(r >= 20 * m).sum()}" for z, m in m_per_pt.items())
    log(f"labels: r (m) p10/50/90 = {np.percentile(r, 10):.0f}/{np.percentile(r, 50):.0f}/"
        f"{np.percentile(r, 90):.0f}; polygons with r ≥ 20 pt per zoom: {fit}; "
        f"{outside} centres not strictly inside")

    # ---- extent = the mapped FRAME: kept polygons + the dropped water (so
    # the line follows sheet frames straight across bays and estuaries and
    # the genuine outer edge of the mapping, never a shoreline or lake
    # ring); holes under HOLE_MIN_M2 (digitising gaps) are filled.
    water_union = shapely.union_all(water)
    frame = shapely.make_valid(shapely.union_all([union, water_union]))
    if abs(frame.area - union.area - water_union.area) > 1e4:
        raise SystemExit("water polygons overlap the kept ones — the frame would double-count")
    parts, dropped = [], []
    for p in getattr(frame, "geoms", [frame]):
        keep_h = [h for h in p.interiors if shapely.Polygon(h).area >= HOLE_MIN_M2]
        dropped += [shapely.Polygon(h).area for h in p.interiors if shapely.Polygon(h).area < HOLE_MIN_M2]
        parts.append(shapely.Polygon(p.exterior, keep_h))
    holes = [shapely.Polygon(h).area for p in parts for h in p.interiors]
    log(f"extent (frame incl. {len(water)} water polygons): {len(parts)} parts, {len(holes)} holes kept "
        f"({sum(holes) / 1e4:.1f} ha); {len(dropped)} holes < {HOLE_MIN_M2 / 1e4:g} ha filled "
        f"({sum(dropped):.0f} m² in all)")
    if holes:
        raise SystemExit(f"the frame has {len(holes)} holes ≥ {HOLE_MIN_M2 / 1e4:g} ha — unmapped land "
                         f"inside the sheets? Inspect before shipping")
    ext4326 = to_4326(np.array(parts, dtype=object))
    frame_outline = shapely.union_all([p.boundary for p in parts])

    # ---- boundaries between different units
    blines, bst, same_colour_pairs = boundaries(geoms, codes, colour_of, union.boundary,
                                                frame_outline, water_union.boundary)
    log(f"boundaries: shared edges {bst['shared_km']:,.1f} km (implied {bst['implied_km']:,.1f} km); "
        f"same-unit seams {bst['seam_km']:.1f} km over {bst['seam_pairs']} polygon pairs (left out); "
        f"different units {bst['diff_km']:,.1f} km over {bst['diff_pairs']} pairs -> {bst['lines']} lines; "
        f"of which same colour {bst['same_colour_km']:.1f} km ({bst['same_colour_unit_pairs']} unit pairs, "
        f"{bst['same_colour_polygon_pairs']} polygon pairs)")
    breadalbane = {"Bde", "Bde-Ps", "BdeKp"}
    bd_touch = [p for p in same_colour_pairs if len(breadalbane & set(p)) == 1]
    if bd_touch:  # the ALIASES comment says they never touch
        raise SystemExit(f"Breadalbane now touches a same-colour Bd* unit: {bd_touch} — revisit ALIASES")

    # ---- write GeoJSON sequences (id = FID + 1 on polygon AND label)
    gj = shapely.to_geojson(g4326)
    with open(WORK / "soils.geojsons", "w", encoding="utf-8") as f:
        for i in range(n_poly):
            props = {"CODE": codes[i], "color": units[codes[i]]["color"], "sheet": sheets_of[i]}
            f.write('{"type":"Feature","id":%d,"properties":%s,"geometry":%s}\n'
                    % (ids[i], json.dumps(props, separators=(",", ":")), gj[i]))
    with open(WORK / "labels.geojsons", "w", encoding="utf-8") as f:
        for i in range(n_poly):
            f.write('{"type":"Feature","id":%d,"properties":{"CODE":%s,"r":%d},'
                    '"geometry":{"type":"Point","coordinates":[%.7f,%.7f]}}\n'
                    % (ids[i], json.dumps(codes[i]), round(r[i]), lon[i], lat[i]))
    with open(WORK / "extent.geojsons", "w", encoding="utf-8") as f:
        for i, g in enumerate(shapely.to_geojson(ext4326), 1):
            f.write('{"type":"Feature","id":%d,"properties":{},"geometry":%s}\n' % (i, g))
    with open(WORK / "boundaries.geojsons", "w", encoding="utf-8") as f:
        for g in shapely.to_geojson(to_4326(blines)):
            f.write('{"type":"Feature","properties":{},"geometry":%s}\n' % g)
    # for --tiles-only's length tripwire (work dir only, never shipped)
    (WORK / "stats.json").write_text(json.dumps({"boundaries_m": bst["diff_km"] * 1e3}))

    # ---- table
    table = {
        "version": 1,
        "source": {"title": TITLE, "custodian": CUSTODIAN, "licence": LICENCE,
                   "attribution": ATTRIBUTION, "url": ZIP_URL, "modified": modified,
                   "built": dt.date.today().isoformat(), "polygons": n_poly},
        "units": {c: {"name": u["name"], "description": u["description"], "orders": u["orders"],
                      "profile": u["profile"], "color": u["color"], "ha": round(u["ha"], 1),
                      "polygons": u["polygons"], "sheets": sorted(u["sheets"])}
                  for c, u in sorted(units.items())},
        "sheets": sheets,
        "orders": {o: {"gloss": ASC_ORDERS[o]}
                   for o in sorted({o for u in units.values() for o in u["orders"]})},
    }
    # contract checks (the Swift decoder relies on these)
    assert all(u["sheets"] and set(u["sheets"]) <= set(sheets) for u in table["units"].values())
    assert all(set(u["orders"]) <= set(table["orders"]) for u in table["units"].values())
    assert all(re.fullmatch(r"#[0-9a-f]{6}", u["color"]) for u in table["units"].values())
    assert abs(sum(u["ha"] for u in table["units"].values()) - sum(s["ha"] for s in sheets.values())) < 1
    build_tiles(n_poly, set(table["units"]), bst["diff_km"] * 1e3)
    TABLE.write_text(json.dumps(table, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    multi = sum(len(u["sheets"]) > 1 for u in table["units"].values())
    log(f"wrote {TABLE} ({TABLE.stat().st_size / 1e3:.0f} KB): {len(units)} units ({multi} on > 1 sheet), "
        f"{len(sheets)} sheets, {len(table['orders'])} ASC orders")


if __name__ == "__main__":
    main()

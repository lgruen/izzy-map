#!/usr/bin/env python3
"""Build data/geology.pmtiles + ios/IzzyMap/Resources/Data/geology_units.json from
MRT's statewide 1:500,000 geology units.

Source (verified 2026-08-30, CC BY 3.0 AU): MRT's own ArcGIS server — NOT
LISTdata (geology isn't there) and NOT LIST's GeologicalAndSoils service
(grey renderer). The official unit colour ships as the per-polygon RGBHex
attribute; `description` is a plain-English lithology sentence.

Fetched via paged REST GeoJSON queries (the mrt.tas.gov.au download page is
Cloudflare-blocked to scripts). ~7,700 polygons, ~26 MB raw.

Run: python3 pipeline/build_geology.py   (stdlib + tippecanoe/pmtiles CLIs)
     python3 pipeline/build_geology.py --tiles-only   (re-tile the cached
     work/geology.geojsonl; no fetch, units JSON left untouched)

Feature ids: every polygon carries the source OBJECTID as its tile feature
id (lines cached before OBJECTID was fetched get their 1-based line number:
the pull is OBJECTID-ordered). tippecanoe copies the id onto every clipped
piece, so a tapped unit's outline can be filtered by id across tile edges.
"""
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

LAYER = "https://data.stategrowth.tas.gov.au/ags/rest/services/MRT/Geology_Tasmania/MapServer/16"
FIELDS = "OBJECTID,map_symb,description,strat_name,max_age,min_age,max_age_ma,min_age_ma,ga_strat_no,RGBHex"
PAGE = 2000  # server maxRecordCount
HERE = Path(__file__).parent
WORK = HERE / "work"
DATA = HERE.parent / "data"
GEN = HERE.parent / "ios" / "IzzyMap" / "Resources" / "Data"
ATTRIBUTION = "Geology: Mineral Resources Tasmania (CC BY 3.0 AU) © State of Tasmania"


def fetch_page(offset: int) -> dict:
    params = urllib.parse.urlencode({
        "where": "1=1",
        "outFields": FIELDS,
        "outSR": "4326",
        "f": "geojson",
        "orderByFields": "OBJECTID",  # explicit stable paging order
        "resultOffset": offset,
        "resultRecordCount": PAGE,
    })
    req = urllib.request.Request(
        f"{LAYER}/query?{params}",
        headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                body = json.load(r)
            if "error" in body:  # ArcGIS reports errors in HTTP-200 bodies
                raise RuntimeError(f"server error: {body['error']}")
            return body
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  page @{offset} failed ({e}), retrying")
            time.sleep(5)
    raise AssertionError


import re


def normalise_color(rgbhex: str | None) -> str:
    """'#RRGGBBAA' -> '#rrggbb', or an rgba() string when MRT's alpha is not
    FF (only 'Geology not mapped' uses 50% white — keep it half-strength
    instead of tinting the topo like a real unit)."""
    if not rgbhex or not re.fullmatch(r"#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?", rgbhex):
        return "#c8c8c8"
    rgb = rgbhex[:7].lower()
    alpha = int(rgbhex[7:9], 16) if len(rgbhex) == 9 else 255
    if alpha == 255:
        return rgb
    r, g, b = (int(rgb[i : i + 2], 16) for i in (1, 3, 5))
    return f"rgba({r},{g},{b},{alpha / 255:.2f})"


def group_of(strat_name: str | None) -> str:
    """Legend bucket: the top level of the '>'-delimited stratigraphy."""
    if strat_name and strat_name.strip():
        return strat_name.split(">")[0].strip()
    return "Other units"


def main():
    WORK.mkdir(exist_ok=True)
    DATA.mkdir(exist_ok=True)
    if "--tiles-only" in sys.argv[1:]:
        return build_tiles(WORK / "geology.geojsonl")

    features = []
    offset = 0
    while True:
        page = fetch_page(offset)
        got = page.get("features", [])
        features.extend(got)
        print(f"  fetched {len(features)} features")
        if len(got) < PAGE and not page.get("exceededTransferLimit"):
            break
        offset += len(got)
    assert len(features) > 7000, f"suspiciously few features: {len(features)}"

    # Per-unit table for legend/details; per-feature colour stays in the tile.
    units: dict[str, dict] = {}
    ndjson_path = WORK / "geology.geojsonl"
    with open(ndjson_path, "w", encoding="utf-8") as out:
        for f in features:
            p = f.get("properties") or {}
            symb = (p.get("map_symb") or "?").strip()
            desc = (p.get("description") or "").strip()
            color = normalise_color(p.get("RGBHex"))
            strat = (p.get("strat_name") or "").strip()
            link = (p.get("ga_strat_no") or "").strip()
            # strict allowlist: only real ASUD record URLs may reach the app
            if link.endswith("/UNK") or not link.startswith("https://asud.ga.gov.au/"):
                link = ""
            unit = units.setdefault(symb, {
                "description": desc,
                "group": group_of(strat),
                "strat": strat.split(">")[-1].strip() if strat else "",
                "maxAge": (p.get("max_age") or "").strip(),
                "minAge": (p.get("min_age") or "").strip(),
                "maxMa": p.get("max_age_ma"),
                "minMa": p.get("min_age_ma"),
                "color": color,
                "link": link,
            })
            # keep a link if any polygon of the unit has one
            if link and not unit["link"]:
                unit["link"] = link
            # tiles carry only what rendering needs; everything the details
            # sheet shows comes from geology_units.json keyed by SYMB
            # (verified constant per unit in the source data)
            f["properties"] = {"SYMB": symb, "color": color}
            f["id"] = int(p.get("OBJECTID", f.get("id")))  # stable tile feature id
            out.write(json.dumps(f, ensure_ascii=False) + "\n")

    GEN.mkdir(parents=True, exist_ok=True)
    units_path = GEN / "geology_units.json"
    units_path.write_text(json.dumps(dict(sorted(units.items())), indent=1, ensure_ascii=False))
    groups = sorted({u["group"] for u in units.values()})
    print(f"{len(features)} polygons, {len(units)} units, {len(groups)} legend groups")
    print(f"wrote {units_path}")
    build_tiles(ndjson_path)


def build_tiles(ndjson_path: Path):
    # Every feature needs a unique integer id (outline-by-id in the app).
    ids_path = WORK / "geology_ids.geojsonl"
    seen: set[int] = set()
    with open(ndjson_path, encoding="utf-8") as src, \
            open(ids_path, "w", encoding="utf-8") as out:
        for i, line in enumerate(src, 1):
            f = json.loads(line)
            f.setdefault("id", i)  # pre-OBJECTID cache: OBJECTID-ordered line no.
            assert isinstance(f["id"], int) and f["id"] not in seen, f["id"]
            seen.add(f["id"])
            out.write(json.dumps(f, ensure_ascii=False) + "\n")
    assert len(seen) > 7000, f"suspiciously few features: {len(seen)}"
    print(f"{len(seen)} features with unique ids")

    # 1:500k linework: z11 native detail is ample; overzoom renders beyond.
    # NO coalescing flags: coalescing can merge polygons ACROSS units (wrong
    # colour + wrong tap answer, silently). At 7.7k features the tiles stay
    # far below the size limit; if that ever changes, tippecanoe erroring
    # out is the correct failure mode.
    subprocess.run([
        "tippecanoe", "-o", str(WORK / "geology.mbtiles"), "--force",
        "-l", "geology", "-n", "Geology 1:500k (MRT)",
        "-A", ATTRIBUTION,
        "-Z0", "-z11",
        "--detect-shared-borders", "--hilbert",
        str(ids_path),
    ], check=True)
    # belt-and-braces: fail loudly if any feature-merging strategy fired
    import sqlite3
    with sqlite3.connect(WORK / "geology.mbtiles") as db:
        row = db.execute("SELECT value FROM metadata WHERE name='strategies'").fetchone()
    if row and "coalesce" in row[0]:
        raise SystemExit(f"tile build coalesced features across units: {row[0]}")
    subprocess.run(["pmtiles", "convert", str(WORK / "geology.mbtiles"),
                    str(DATA / "geology.pmtiles")], check=True)
    size = (DATA / "geology.pmtiles").stat().st_size
    print(f"geology.pmtiles: {size/1e6:.1f} MB")


if __name__ == "__main__":
    main()

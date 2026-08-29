#!/usr/bin/env python3
"""Build data/geology.pmtiles + app/src/generated/geology_units.json from
MRT's statewide 1:500,000 geology units.

Source (verified 2026-08-30, CC BY 3.0 AU): MRT's own ArcGIS server — NOT
LISTdata (geology isn't there) and NOT LIST's GeologicalAndSoils service
(grey renderer). The official unit colour ships as the per-polygon RGBHex
attribute; `description` is a plain-English lithology sentence.

Fetched via paged REST GeoJSON queries (the mrt.tas.gov.au download page is
Cloudflare-blocked to scripts). ~7,700 polygons, ~26 MB raw.

Run: python3 pipeline/build_geology.py   (stdlib + tippecanoe/pmtiles CLIs)
"""
import json
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

LAYER = "https://data.stategrowth.tas.gov.au/ags/rest/services/MRT/Geology_Tasmania/MapServer/16"
FIELDS = "map_symb,description,strat_name,max_age,min_age,max_age_ma,min_age_ma,ga_strat_no,RGBHex"
PAGE = 2000  # server maxRecordCount
HERE = Path(__file__).parent
WORK = HERE / "work"
DATA = HERE.parent / "data"
GEN = HERE.parent / "app" / "src" / "generated"
ATTRIBUTION = "Geology: Mineral Resources Tasmania (CC BY 3.0 AU) © State of Tasmania"


def fetch_page(offset: int) -> dict:
    params = urllib.parse.urlencode({
        "where": "1=1",
        "outFields": FIELDS,
        "outSR": "4326",
        "f": "geojson",
        "resultOffset": offset,
        "resultRecordCount": PAGE,
    })
    req = urllib.request.Request(
        f"{LAYER}/query?{params}",
        headers={"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            print(f"  page @{offset} failed ({e}), retrying")
            time.sleep(5)
    raise AssertionError


def normalise_color(rgbhex: str | None) -> str:
    """'#RRGGBBAA' -> '#rrggbb' (alpha comes from the layer's fill-opacity)."""
    if not rgbhex or not rgbhex.startswith("#") or len(rgbhex) < 7:
        return "#c8c8c8"
    return rgbhex[:7].lower()


def group_of(strat_name: str | None, description: str) -> str:
    """Legend bucket: the top level of the '>'-delimited stratigraphy."""
    if strat_name and strat_name.strip():
        return strat_name.split(">")[0].strip()
    return "Other units"


def main():
    WORK.mkdir(exist_ok=True)
    DATA.mkdir(exist_ok=True)

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
            if link.endswith("/UNK") or "asud" not in link.lower():
                link = ""
            unit = units.setdefault(symb, {
                "description": desc,
                "group": group_of(strat, desc),
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
            f["properties"] = {
                "SYMB": symb,
                "DESC": desc,
                "STRAT": strat.split(">")[-1].strip() if strat else "",
                "AGE_MAX": unit["maxAge"],
                "AGE_MIN": unit["minAge"],
                "color": color,
            }
            out.write(json.dumps(f, ensure_ascii=False) + "\n")

    GEN.mkdir(parents=True, exist_ok=True)
    units_path = GEN / "geology_units.json"
    units_path.write_text(json.dumps(dict(sorted(units.items())), indent=1, ensure_ascii=False))
    groups = sorted({u["group"] for u in units.values()})
    print(f"{len(features)} polygons, {len(units)} units, {len(groups)} legend groups")
    print(f"wrote {units_path}")

    # 1:500k linework: z11 native detail is ample; overzoom renders beyond.
    subprocess.run([
        "tippecanoe", "-o", str(WORK / "geology.mbtiles"), "--force",
        "-l", "geology", "-n", "Geology 1:500k (MRT)",
        "-A", ATTRIBUTION,
        "-Z0", "-z11",
        "--coalesce-densest-as-needed", "--detect-shared-borders", "--hilbert",
        str(ndjson_path),
    ], check=True)
    subprocess.run(["pmtiles", "convert", str(WORK / "geology.mbtiles"),
                    str(DATA / "geology.pmtiles")], check=True)
    size = (DATA / "geology.pmtiles").stat().st_size
    print(f"geology.pmtiles: {size/1e6:.1f} MB")


if __name__ == "__main__":
    main()

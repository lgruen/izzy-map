#!/usr/bin/env python3
"""Tasmania silhouette for the app's mini-maps (UX_VISUAL_REVIEW §2 asset B).

The union of LIST's Locality and Postcode Areas (777 polygons, CC BY 3.0 AU
© State of Tasmania — the same WFS pull build_gazetteer.py caches), clipped
to the state's bounding box (drops Macquarie Island), simplified, and
written as compact rings of [lon, lat] rounded to 0.001° (~100 m — the
mini-maps are ≤ 160 pt across, ~2 km per point).

  uv run --with shapely python3 pipeline/build_outline.py

Input:  pipeline/cache/gazetteer/localities.geojson (run build_gazetteer.py)
Output: ios/IzzyMap/Resources/Data/tasmania_outline.json (committed; facts)
"""
import json
import sys
from pathlib import Path

from shapely.geometry import box, mapping, shape
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "pipeline/cache/gazetteer/localities.geojson"
OUT = ROOT / "ios/IzzyMap/Resources/Data/tasmania_outline.json"
# Tasmania incl. King Island and the Furneaux Group; not Macquarie Island
BBOX = box(143.5, -44.0, 149.0, -39.2)
TOLERANCE = 0.004  # degrees, Douglas–Peucker
MIN_AREA = 0.0004  # deg² (~3 km²): islets below this vanish at mini-map scale


def main() -> None:
    if not SRC.exists():
        sys.exit(f"missing {SRC} — run pipeline/build_gazetteer.py first")
    feats = json.loads(SRC.read_text())["features"]
    geoms = [shape(f["geometry"]).buffer(0) for f in feats if f.get("geometry")]
    # a tiny buffer closes the slivers between neighbouring localities
    land = unary_union([g.buffer(0.0005) for g in geoms]).buffer(-0.0005).intersection(BBOX)
    land = land.simplify(TOLERANCE, preserve_topology=True)
    polys = [p for p in getattr(land, "geoms", [land]) if p.area >= MIN_AREA]
    rings = []
    for p in sorted(polys, key=lambda p: -p.area):
        ring = [[round(x, 3), round(y, 3)] for x, y in p.exterior.coords]
        # drop consecutive duplicates the rounding made
        ring = [pt for i, pt in enumerate(ring) if i == 0 or pt != ring[i - 1]]
        if len(ring) >= 4:
            rings.append(ring)
    n = sum(len(r) for r in rings)
    lons = [pt[0] for r in rings for pt in r]
    lats = [pt[1] for r in rings for pt in r]
    assert 3 <= len(rings) <= 400, f"{len(rings)} rings — check MIN_AREA/TOLERANCE"
    assert 143.7 < min(lons) and max(lons) < 148.6 and -43.7 < min(lats) and max(lats) < -39.4, "bounds off"
    out = {
        "version": 1,
        "source": "LIST Locality and Postcode Areas, union, simplified",
        "licence": "CC BY 3.0 AU",
        "attribution": "© State of Tasmania (theLIST)",
        "bbox": [round(min(lons), 3), round(min(lats), 3), round(max(lons), 3), round(max(lats), 3)],
        "rings": rings,
    }
    OUT.write_text(json.dumps(out, separators=(",", ":")))
    print(f"{len(rings)} rings, {n} points, {OUT.stat().st_size / 1024:.1f} KB → {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()

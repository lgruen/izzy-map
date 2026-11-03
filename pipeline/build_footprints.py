#!/usr/bin/env python3
"""Coverage footprints of the on-demand map packs, for the Storage screen's
thumbnails (docs/UX_VISUAL_REVIEW.md §3.14 / §3.10: "for packs not on the
device, a bundled footprint bitset from the build").

For every z11 tile over Tasmania (~19 km), one bit: does the pack's PMTiles
archive hold that tile? Seasons are patchworks (blank tiles are pruned by
build_raster.py), so their bits draw where each season was flown; the
statewide packs come out as the land. Only tile EXISTENCE is read out — no
imagery is copied — so the result is a fact table, committed like the other
generated tables. Installed packs are re-read on the device with the same
grid (the 2025–26 season grows after this build).

  uv run --with pmtiles python3 pipeline/build_footprints.py [--data DIR]

Input:  data/*.pmtiles (the developer's packs)
Output: ios/IzzyMap/Resources/Data/pack_footprints.json
"""
import argparse
import base64
import json
import math
from pathlib import Path

from pmtiles.reader import MmapSource, Reader

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios/IzzyMap/Resources/Data/pack_footprints.json"
ZOOM = 11
# Tasmania incl. King Island and the Furneaux Group (the outline's frame)
WEST, SOUTH, EAST, NORTH = 143.75, -43.70, 148.55, -39.50
# pack id (pipeline/asset_packs.json) → archive file
PACKS = {
    "aerial": "aerial_tas.pmtiles",
    "tasmap": "tasmap_tas.pmtiles",
    **{f"season-{y}": f"aerial_{y}.pmtiles" for y in range(2020, 2027)},
}


def tile_x(lon: float) -> int:
    return math.floor((lon + 180) / 360 * 2**ZOOM)


def tile_y(lat: float) -> int:
    r = math.radians(lat)
    return math.floor((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * 2**ZOOM)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=ROOT / "data")
    args = ap.parse_args()
    x0, x1 = tile_x(WEST), tile_x(EAST)
    y0, y1 = tile_y(NORTH), tile_y(SOUTH)
    cols, rows = x1 - x0 + 1, y1 - y0 + 1
    packs = {}
    for pack, name in PACKS.items():
        path = args.data / name
        if not path.exists():
            raise SystemExit(f"missing {path}")
        bits = bytearray((cols * rows + 7) // 8)
        n = 0
        with path.open("rb") as f:
            reader = Reader(MmapSource(f))
            for r in range(rows):
                for c in range(cols):
                    if reader.get(ZOOM, x0 + c, y0 + r) is not None:
                        i = r * cols + c
                        bits[i >> 3] |= 1 << (i & 7)
                        n += 1
        print(f"{pack:12s} {n:5d} of {cols * rows} z{ZOOM} cells")
        assert n > 0, f"{pack}: no tiles at z{ZOOM} — wrong grid?"
        packs[pack] = base64.b64encode(bytes(bits)).decode()
    # statewide packs cover the state; a season far beyond them = a grid slip
    land = packs["aerial"]
    assert sum(bin(b).count("1") for b in base64.b64decode(land)) > 250, "aerial covers too little"
    out = {
        "version": 1,
        "source": "tile existence in the pipeline's PMTiles (build_raster.py), z11",
        "zoom": ZOOM,
        "x0": x0,
        "y0": y0,
        "cols": cols,
        "rows": rows,
        "packs": packs,
    }
    OUT.write_text(json.dumps(out, separators=(",", ":")) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bytes, {cols}×{rows} grid)")


if __name__ == "__main__":
    main()

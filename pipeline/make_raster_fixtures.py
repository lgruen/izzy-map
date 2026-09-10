#!/usr/bin/env python3
"""Synthetic raster PMTiles fixtures for the Playwright tests (no licensed
imagery): solid-colour tiles around the test GPS point (-42.92, 147.235),
z12-15, so pixel-readback tests can prove JPEG/PNG decoding through the
raster:// protocol and the season stacking rules.

  aerial_test        red JPEG everywhere              (compilation)
  tasmap_test        cream JPEG everywhere            (paper map)
  aerial_2023_test   green JPEG, tiles with x <= centre column   (older season)
  aerial_2024_test   blue JPEG, tiles with x >= centre column AND y <= centre
                     row; at z15 the centre tile is a PNG whose LEFT half is
                     transparent (edge-of-project tile) so the older season
                     must show through it.

Run:  uv run --with pillow python3 pipeline/make_raster_fixtures.py
Writes app/tests/fixtures/<name>.pmtiles (needs the pmtiles CLI, brew).
"""
import io
import math
import sqlite3
import subprocess
from pathlib import Path

from PIL import Image

HERE = Path(__file__).parent
OUT = HERE.parent / "app" / "tests" / "fixtures"
BBOX = [147.15, -42.98, 147.32, -42.86]   # w, s, e, n
CENTRE = (147.235, -42.92)
ZOOMS = range(12, 16)

COLOURS = {
    "aerial_test": (200, 30, 30),
    "tasmap_test": (243, 233, 198),
    "aerial_2023_test": (40, 150, 80),
    "aerial_2024_test": (40, 80, 200),
}


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def jpeg(rgb):
    buf = io.BytesIO()
    Image.new("RGB", (256, 256), rgb).save(buf, "JPEG", quality=75)
    return buf.getvalue()


def half_transparent_png(rgb):
    im = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    im.paste((*rgb, 255), (128, 0, 256, 256))  # right half opaque
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return buf.getvalue()


def covers(name, z, x, y):
    cx, cy = lonlat_to_tile(*CENTRE, z)
    if name == "aerial_2023_test":
        return x <= cx
    if name == "aerial_2024_test":
        return x >= cx and y <= cy
    return True


def build(name):
    OUT.mkdir(parents=True, exist_ok=True)
    mbt = HERE / "work" / f"{name}.mbtiles"
    mbt.parent.mkdir(exist_ok=True)
    mbt.unlink(missing_ok=True)
    db = sqlite3.connect(mbt)
    db.executescript("""
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);""")
    w, s, e, n = BBOX
    for k, v in {"name": name, "format": "jpg", "type": "baselayer", "version": "1",
                 "minzoom": str(ZOOMS[0]), "maxzoom": str(ZOOMS[-1]),
                 "bounds": f"{w},{s},{e},{n}", "attribution": "synthetic test fixture"}.items():
        db.execute("INSERT INTO metadata VALUES (?,?)", (k, v))
    solid = jpeg(COLOURS[name])
    count = 0
    for z in ZOOMS:
        x0, y0 = lonlat_to_tile(w, n, z)
        x1, y1 = lonlat_to_tile(e, s, z)
        cx, cy = lonlat_to_tile(*CENTRE, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                if not covers(name, z, x, y):
                    continue
                data = solid
                if name == "aerial_2024_test" and z == 15 and (x, y) == (cx, cy):
                    data = half_transparent_png(COLOURS[name])
                db.execute("INSERT INTO tiles VALUES (?,?,?,?)", (z, x, (2 ** z) - 1 - y, sqlite3.Binary(data)))
                count += 1
    db.commit()
    db.close()
    out = OUT / f"{name}.pmtiles"
    out.unlink(missing_ok=True)
    subprocess.run(["pmtiles", "convert", str(mbt), str(out)], check=True, capture_output=True)
    mbt.unlink()
    print(f"{out.name}: {count} tiles, {out.stat().st_size/1e3:.0f} KB")


if __name__ == "__main__":
    for name in COLOURS:
        build(name)
    cx, cy = lonlat_to_tile(*CENTRE, 15)
    print(f"centre tile z15: x={cx} y={cy}")

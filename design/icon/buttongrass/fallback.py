"""Fallback AppIcon.appiconset PNGs (pre-iOS-26 / fallback rendition) for a generated .icon:
full-bleed, opaque 1024 squares like the fagus set: icon.png (Default), icon-dark.png,
icon-tinted.png (greyscale content on black). The SVG layers are rasterised by macOS `sips`
(CoreSVG, the renderer Icon Composer uses) and composited here in the package's layer order.
Usage: uv run --with pillow python fallback.py <pkg.icon> <out-dir>"""
import json, os, subprocess, sys, tempfile
from PIL import Image, ImageChops, ImageFilter

pkg, out = sys.argv[1], sys.argv[2]
doc = json.load(open(os.path.join(pkg, "icon.json")))
tmp = tempfile.mkdtemp(dir=os.path.dirname(os.path.abspath(__file__)))


def raster(name):
    dst = os.path.join(tmp, name + ".png")
    subprocess.run(["/usr/bin/sips", "-s", "format", "png", os.path.join(pkg, "Assets", name), "--out", dst],
                   check=True, capture_output=True)
    return Image.open(dst).convert("RGBA").resize((1024, 1024), Image.LANCZOS)


def colour(s):
    v = [float(x) for x in s.split(":")[1].split(",")]
    return tuple(round(c * 255) for c in v[:3])


def background(spec):
    g = spec["linear-gradient"]
    a, b = colour(g[0]), colour(g[1])
    o = spec["orientation"]
    sx, sy, ex, ey = o["start"]["x"], o["start"]["y"], o["stop"]["x"], o["stop"]["y"]
    dx, dy = ex - sx, ey - sy
    n = dx * dx + dy * dy
    im = Image.new("RGB", (1024, 1024))
    px = im.load()
    for y in range(1024):
        for x in range(1024):
            t = min(1, max(0, ((x / 1023 - sx) * dx + (y / 1023 - sy) * dy) / n))
            px[x, y] = tuple(round(p + (q - p) * t) for p, q in zip(a, b))
    return im.convert("RGBA")


# groups are listed top-first, and so are the layers inside a group: composite bottom-up
stack = []
for g in reversed(doc["groups"]):
    sh = g.get("shadow", {})
    for L in reversed(g["layers"]):
        tinted = next((f["value"]["solid"] for f in L.get("fill-specializations", [])
                       if f.get("appearance") == "tinted"), None)
        stack.append((raster(L["image-name"]), sh.get("opacity", 0) if sh.get("kind") != "none" else 0, tinted))


def shadow(layer, op):
    a = layer.getchannel("A").filter(ImageFilter.GaussianBlur(10))
    a = a.point(lambda v: round(v * op * 0.8))
    s = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    s.putalpha(a)
    return ImageChops.offset(s, 0, 8)


fills = {f.get("appearance", "default"): f["value"] for f in doc["fill-specializations"]}
os.makedirs(out, exist_ok=True)
for fn, key in (("icon.png", "default"), ("icon-dark.png", "dark")):
    im = background(fills[key])
    for layer, op, _ in stack:
        if op:
            im.alpha_composite(shadow(layer, op))
        im.alpha_composite(layer)
    im.convert("RGB").save(os.path.join(out, fn), optimize=True)

# tinted: luminance of the artwork on black (the system tints it); a layer with a tinted
# solid fill becomes that grey silhouette
im = Image.new("RGBA", (1024, 1024), (0, 0, 0, 255))
for layer, op, tinted in stack:
    if tinted:
        gv = colour(tinted)
        flat = Image.new("RGBA", layer.size, gv + (255,))
        flat.putalpha(layer.getchannel("A"))
        layer = flat
    else:
        lum = layer.convert("L").point(lambda v: min(255, round(40 + v * 0.95)))
        layer = Image.merge("RGBA", (lum, lum, lum, layer.getchannel("A")))
    im.alpha_composite(layer)
im.convert("L").convert("RGB").save(os.path.join(out, "icon-tinted.png"), optimize=True)
for f in os.listdir(tmp):
    os.remove(os.path.join(tmp, f))
os.rmdir(tmp)
print("wrote", out)

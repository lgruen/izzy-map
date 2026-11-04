"""compare.png: icons side by side at 1024 / 180 / 40 px, on light and dark home-screen-like
backgrounds, plus each icon's six renditions -- all rendered by Apple's ictool.
Usage: uv run --with pillow python compare.py <out.png> "<label>=<pkg.icon>" ...
"""
import os
import subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

IC = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
OUTPNG = sys.argv[1]
TMP = tempfile.mkdtemp(dir=os.path.dirname(os.path.abspath(OUTPNG)))
R = lambda *p: os.path.join(TMP, *p)
F = "/System/Library/Fonts/HelveticaNeue.ttc"
f_big, f_mid, f_small = (ImageFont.truetype(F, s) for s in (44, 30, 22))
ICONS = [tuple(a.split("=", 1)) for a in sys.argv[2:]]
REND = ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"]


for i, (_, pkg) in enumerate(ICONS):
    os.makedirs(R(str(i)), exist_ok=True)
    for r in REND:
        subprocess.run([IC, pkg, "--export-image", "--output-file", R(str(i), f"{r}.png"),
                        "--platform", "iOS", "--rendition", r, "--width", "1024", "--height", "1024",
                        "--scale", "1"], check=True, capture_output=True)


def load(i, r="Default"):
    return Image.open(R(str(i), f"{r}.png")).convert("RGBA")


def vgrad(w, h, top, bot):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))
    return im


COL = 1024 + 60
W = max(len(ICONS) * COL + 60, 6 * 172 + 80)
H1 = 90 + 1024 + 70           # 1024 row
H2 = 380                       # home screen light
H3 = 380                       # home screen dark
H4 = 260                       # renditions
sheet = Image.new("RGB", (W, H1 + H2 + H3 + H4 + 40), (232, 230, 225))
d = ImageDraw.Draw(sheet)
d.text((40, 24), "IzzyMap app icon: fagus (Nothofagus gunnii) and buttongrass (Gymnoschoenus sphaerocephalus)",
       font=f_big, fill=(28, 28, 28))
for i, (label, name) in enumerate(ICONS):
    x = 40 + i * COL
    im = load(i)
    sheet.paste(im, (x, 100), im)
    d.text((x, 100 + 1024 + 16), f"{label}: 1024 px", font=f_mid, fill=(28, 28, 28))

# home-screen-like rows: light wallpaper with Default, dark wallpaper with Dark
y0 = H1
for k, (top, bot, rend, ink, title) in enumerate([
        ((236, 231, 222), (200, 212, 216), "Default", (20, 20, 20), "Light home screen (Default)"),
        ((16, 20, 24), (34, 46, 52), "Dark", (235, 235, 235), "Dark home screen (Dark)")]):
    y = y0 + k * H2
    bg = vgrad(W, H2 - 20, top, bot)
    sheet.paste(bg, (0, y))
    d.text((40, y + 14), title + ": 180 px and 40 px", font=f_mid, fill=ink)
    for i, (label, name) in enumerate(ICONS):
        x = 40 + i * COL
        im = load(i, rend)
        a = im.resize((180, 180), Image.LANCZOS)
        sheet.paste(a, (x, y + 70), a)
        d.text((x + 90, y + 262), "IzzyMap", font=f_small, fill=ink, anchor="mt")
        b = im.resize((40, 40), Image.LANCZOS)
        sheet.paste(b, (x + 230, y + 70), b)
        # 40 px row like a Spotlight / Settings list
        sheet.paste(b, (x + 230, y + 150), b)
        d.text((x + 284, y + 160), "IzzyMap", font=f_small, fill=ink)
        # 40 px magnified 4x (nearest) to judge the actual pixels
        z = b.resize((160, 160), Image.NEAREST)
        sheet.paste(z, (x + 420, y + 70), z)
        d.text((x + 420, y + 240), "40 px, magnified 4x", font=f_small, fill=ink)

# renditions strip
y = H1 + H2 + H3
d.text((40, y + 6), "Renditions: Default, Dark, Tinted light, Tinted dark, Clear light, Clear dark (ictool)",
       font=f_mid, fill=(28, 28, 28))
for i, (label, name) in enumerate(ICONS):
    x = 40 + i * COL
    for j, r in enumerate(REND):
        im = load(i, r).resize((160, 160), Image.LANCZOS)
        dark = r.endswith("Dark")
        tile = Image.new("RGBA", (172, 172), (24, 24, 26, 255) if dark else (214, 214, 210, 255))
        tile.alpha_composite(im, (6, 6))
        sheet.paste(tile, (x + j * 172, y + 56))
out = OUTPNG
sheet.save(out, optimize=True)
if os.path.getsize(out) > 1_500_000:
    # 5 bits per channel keeps every hue (a 256-colour palette turned the rusty old head olive)
    from PIL import ImageOps
    ImageOps.posterize(sheet, 5).save(out, optimize=True)
print(out, os.path.getsize(out), sheet.size)

import shutil
shutil.rmtree(TMP)

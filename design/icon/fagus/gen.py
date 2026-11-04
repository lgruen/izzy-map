"""Nothofagus gunnii (fagus) app icon: geometry, SVG layers and the .icon package.

Drawn to MORPHOLOGY.md (published descriptions + Leo's field photo), not traced:
  broadly ovate-orbicular blade, L:W ~1.08, truncate to shallowly cuneate base,
  nearly sessile (petiole <= 0.05 L, straight, no knob);
  6 straight, sub-parallel secondary veins per side, each ending in a SINUS;
  one rounded lobe between successive vein tips, + a small basal and an apical
  lobe = 7 lobes per side; sinuses sharp and cut fairly deep (crenate-serrate
  silhouette), lobes leaning slightly toward the apex;
  apex obtuse with only a very shallow notch where the midrib ends;
  plicate: every lobe is a pleat (ridge midrib -> lobe tip) between two impressed
  veins, shaded as a hillshade lit from the NW.
"""
import json, math, os, random, shutil

OUT = os.path.dirname(os.path.abspath(__file__))
C = 1024

# ---------------------------------------------------------------- outline
# Half-outline control points (u along the midrib from the base, v half-width).
# Base truncate/shallowly cuneate: the base edge leaves the petiole at ~77 deg
# to the midrib. Widest ~0.42 L, obtuse apex.
CTRL = [(0.0, 0.0), (0.045, 0.20), (0.11, 0.33), (0.21, 0.415), (0.33, 0.458),
        (0.45, 0.466), (0.58, 0.442), (0.71, 0.378), (0.83, 0.283), (0.925, 0.165),
        (0.978, 0.075), (1.0, 0.0)]


def _spline(pts, n=80):
    out = []
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[i]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else p2
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t
                                    + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    out.append(pts[-1])
    return out


PTS = _spline(CTRL)
ARC = [0.0]
for _a, _b in zip(PTS, PTS[1:]):
    ARC.append(ARC[-1] + math.dist(_a, _b))
TOT = ARC[-1]


def h(u):
    u = min(max(u, 0.0), 1.0)
    for a, b in zip(PTS, PTS[1:]):
        if a[0] <= u <= b[0]:
            f = (u - a[0]) / ((b[0] - a[0]) or 1)
            return a[1] + f * (b[1] - a[1])
    return 0.0


def at_arc(fr):
    """Point and outward unit normal of the half envelope at arc fraction fr."""
    t = min(max(fr, 0.0), 1.0) * TOT
    for i in range(1, len(ARC)):
        if ARC[i] >= t:
            a, b = PTS[i - 1], PTS[i]
            f = (t - ARC[i - 1]) / ((ARC[i] - ARC[i - 1]) or 1)
            p = (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]))
            tx_, ty_ = b[0] - a[0], b[1] - a[1]
            ln = math.hypot(tx_, ty_) or 1
            n = (ty_ / ln, -tx_ / ln)
            if n[1] < 0 and abs(n[1]) > abs(n[0]) * 0.2 or (n[0] * (p[0] - 0.45) + n[1] * p[1]) < 0:
                n = (-n[0], -n[1])
            return p, n
    return PTS[-1], (1.0, 0.0)


def arc_of(u):
    i = min(range(len(PTS)), key=lambda k: abs(PTS[k][0] - u))
    return ARC[i] / TOT


def hit(u0, ang):
    dx, dy = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    t = 0.0
    while True:
        t += 0.0004
        u, v = u0 + dx * t, dy * t
        if v >= h(u) or u >= 1:
            return u


# ---------------------------------------------------------------- venation
NV = 6                                         # secondary veins per side
ORIG = [0.01, 0.14, 0.28, 0.44, 0.61, 0.79]  # origins on the midrib (u)
ANGLES = [56, 53, 50, 47, 45, 42]                # angle to the midrib, base -> apex
SINUS = 0.046        # sinus depth, stepped back along the vein (sharp, fairly deep)
TOOTH = 0.016        # lobe bulge beyond the envelope
NOTCH = 0.010        # very shallow apical notch where the midrib ends
LEAN = 0.58          # lobe tip position between its sinuses (> 0.5 = leans apically)

VEIN_ARC = [arc_of(hit(u, a)) for u, a in zip(ORIG, ANGLES)]
N_BASE = 3                 # lobes on the truncate base below vein 1
BRANCH_AT = [0.16, 0.42]   # where the exmedial branches leave vein 1 (fraction of its length)


def half(side):
    sg = lambda p: (p[0], side * p[1])
    sinus, origins = [], []
    for u0, fr in zip(ORIG, VEIN_ARC):
        p, _ = at_arc(fr)
        dx, dy = p[0] - u0, p[1]
        ln = math.hypot(dx, dy)
        sinus.append(sg((p[0] - dx / ln * SINUS, p[1] - dy / ln * SINUS)))
        origins.append((u0, 0.0))
    # basal crenations: the truncate base below the lowest secondary carries
    # N_BASE lobes, their sinuses fed by short exmedial branches of vein 1
    o1, s1 = origins[0], sinus[0]
    branch = []
    barcs = [VEIN_ARC[0] * k / N_BASE for k in range(1, N_BASE)]
    for k, fr in enumerate(barcs):
        p, n = at_arc(fr)
        sp = (p[0] - n[0] * SINUS * 0.45, p[1] - n[1] * SINUS * 0.45)
        f = BRANCH_AT[k]
        bo = (o1[0] + (s1[0] * 1 - o1[0]) * f, abs(s1[1]) * f)
        branch.append((bo, sp))
    stations = [((0.0, 0.0), (0.0, 0.0))] + [(sg(o), sg(sp)) for o, sp in branch] + \
               list(zip(origins, sinus)) + [((1.0 - NOTCH, 0.0), (1.0 - NOTCH, 0.0))]
    arcs = [0.0] + barcs + VEIN_ARC + [1.0]
    tips = []
    for k in range(len(arcs) - 1):
        a, b = arcs[k], arcs[k + 1]
        p, n = at_arc(min(a + (b - a) * LEAN, 0.992))
        bulge = TOOTH * (0.35 if k < N_BASE else 1.0)   # basal crenations: low
        tips.append(sg((p[0] + n[0] * bulge, p[1] + n[1] * bulge)))
    return dict(stations=stations, tips=tips, side=side)


def tooth_segs(a, tip, b, round_=0.55, sharp=0.22):
    """Lobe from sinus a over a round tip to sinus b. The sinus ends leave
    almost along the lobe flank (sharp V-sinus); the tip is round."""
    tx_, ty_ = b[0] - a[0], b[1] - a[1]
    ln = math.hypot(tx_, ty_)
    tx_, ty_ = tx_ / ln, ty_ / ln
    da, db = math.dist(a, tip) * round_, math.dist(tip, b) * round_
    mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
    ox, oy = tip[0] - mid[0], tip[1] - mid[1]
    c1 = (a[0] + ox * 0.6 + (tip[0] - a[0]) * sharp * 0.4, a[1] + oy * 0.6 + (tip[1] - a[1]) * sharp * 0.4)
    c2 = (tip[0] - tx_ * da, tip[1] - ty_ * da)
    c3 = (tip[0] + tx_ * db, tip[1] + ty_ * db)
    c4 = (b[0] + ox * 0.6 + (tip[0] - b[0]) * sharp * 0.4, b[1] + oy * 0.6 + (tip[1] - b[1]) * sharp * 0.4)
    return [(a, c1, c2, tip), (tip, c3, c4, b)]


def half_margin(hf):
    st, tips = hf["stations"], hf["tips"]
    segs = []
    for k in range(len(tips)):
        segs += tooth_segs(st[k][1], tips[k], st[k + 1][1])
    return segs


def rev(segs):
    return [(d, c, b, a) for (a, b, c, d) in reversed(segs)]


def bez_pts(seg, n=12):
    a, b, c, d = seg
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        out.append((mt**3*a[0] + 3*mt*mt*t*b[0] + 3*mt*t*t*c[0] + t**3*d[0],
                    mt**3*a[1] + 3*mt*mt*t*b[1] + 3*mt*t*t*c[1] + t**3*d[1]))
    return out


LEFT, RIGHT = half(+1), half(-1)
OUTLINE = half_margin(LEFT) + rev(half_margin(RIGHT))

# ------------------------------------------------------------ placement
ANG = math.radians(-124)   # leaf axis on canvas: apex to the upper LEFT, into the NW light
SCALE = 720
ORIGIN = (0.0, 0.0)        # set by fit()


def tx(p):
    u, v = p
    ca, sa = math.cos(ANG), math.sin(ANG)
    return (ORIGIN[0] + SCALE * (u * ca + v * sa), ORIGIN[1] + SCALE * (u * sa - v * ca))


def fit(target=0.72):
    """Scale + centre so the leaf (blade + petiole) spans `target` of the canvas."""
    global SCALE, ORIGIN
    pts = []
    for s in OUTLINE:
        pts += bez_pts(s, 8)
    pts += [(-PET_LEN, 0.0)]
    SCALE, ORIGIN = 1.0, (0.0, 0.0)
    xs = [tx(p)[0] for p in pts]; ys = [tx(p)[1] for p in pts]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    SCALE = target * C / span
    xs = [tx(p)[0] for p in pts]; ys = [tx(p)[1] for p in pts]
    ORIGIN = (C / 2 - (max(xs) + min(xs)) / 2, C / 2 - (max(ys) + min(ys)) / 2)


def fmt(p):
    x, y = tx(p)
    return f"{x:.1f},{y:.1f}"


def path_d(segs):
    d = [f"M{fmt(segs[0][0])}"]
    for a, b, c, e in segs:
        d.append(f"C{fmt(b)} {fmt(c)} {fmt(e)}")
    return " ".join(d) + " Z"


def poly_d(pts):
    return "M" + " L".join(fmt(p) for p in pts) + " Z"


# ------------------------------------------------------------- relief
def panels(hf):
    """Each lobe is a pleat: a ridge from the midrib to the lobe tip, between
    two impressed veins. Split along the ridge into two flanks.
    Yields (poly, ridge_m, ridge_t, crease) with crease = (origin, sinus) of the
    vein the flank leans against, or None at the base/apex (no impressed vein)."""
    st, tips = hf["stations"], hf["tips"]
    ms = half_margin(hf)
    out = []
    for k in range(len(tips)):
        (oa, sa), (ob, sb) = st[k], st[k + 1]
        m1, m2 = bez_pts(ms[2 * k]), bez_pts(ms[2 * k + 1])
        tip = m1[-1]
        rm = ((oa[0] + ob[0]) / 2, 0.0)
        out.append(([oa] + m1 + [rm], rm, tip, None if k == 0 else (oa, sa)))
        out.append(([rm] + m2 + [ob], rm, tip, None if k == len(tips) - 1 else (ob, sb)))
    return out


def light_vec(el_deg=42):
    el = math.radians(el_deg)
    # from the NNW, straight down the leaf axis (apex points into the light), so
    # both halves show the pleats equally; close to the app's NW hillshade light
    lx, ly = math.cos(ANG), math.sin(ANG)
    return (lx * math.cos(el), ly * math.cos(el), math.sin(el))


def flank_shade(poly, rm, rt, light, slope=1.3):
    cx = sum(p[0] for p in poly) / len(poly)
    cy = sum(p[1] for p in poly) / len(poly)
    a, b, c = tx(rm), tx(rt), tx((cx, cy))
    dx, dy = b[0] - a[0], b[1] - a[1]
    ln = math.hypot(dx, dy)
    px, py = -dy / ln, dx / ln
    if (c[0] - a[0]) * px + (c[1] - a[1]) * py < 0:
        px, py = -px, -py
    n = (px * slope, py * slope, 1.0)
    ln = math.sqrt(sum(x * x for x in n))
    return sum(x * y for x, y in zip(n, light)) / ln


def H(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def hexc(c):
    return "#%02X%02X%02X" % tuple(c)


def ramp(stops, t):
    t = min(max(t, 0.0), 1.0)
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            f = (t - t0) / ((t1 - t0) or 1)
            return tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
    return stops[-1][1]


PAL = dict(
    # autumn: yellow to golden, amber-brown in the creases (FoA/TSO/UN + field photo)
    ramp=[(0.0, H("#B5600C")), (0.33, H("#D98A16")), (0.6, H("#EDB026")), (0.84, H("#F8D04A")),
          (1.0, H("#FDE68C"))],
    lo=0.05, hi=0.95,
    vein=H("#B8650F"), petiole=H("#A65E12"), blush=H("#E2621C"), speck=H("#8A4A12"),
)
PAL_TURN = dict(PAL, green=[(0.0, H("#7C8E16")), (0.33, H("#A0AE1E")), (0.6, H("#C2CA30")),
                              (0.84, H("#DDDF58")), (1.0, H("#F0EE98"))])
PET_LEN = 0.045        # nearly sessile
BLUSH = [12, 13, 14, 15]   # flanks of two lobes on one side (orange flush at the tips)


def point_in(poly, x, y):
    ins = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / ((yj - yi) or 1e-9) + xi:
            ins = not ins
        j = i
    return ins


def leaf_svgs(pal=PAL):
    light = light_vec()
    flanks = panels(LEFT) + panels(RIGHT)
    vals = [flank_shade(p, rm, rt, light) for p, rm, rt, _ in flanks]
    lo, hi = min(vals), max(vals)
    tone = lambda s: pal["lo"] + (pal["hi"] - pal["lo"]) * (s - lo) / (hi - lo)
    tflat = tone(light[2])

    # base layer: blade silhouette + the (very short, straight) petiole
    pet = poly_d([(0.03, 0.024), (-PET_LEN, 0.018), (-PET_LEN - 0.007, 0.0),
                  (-PET_LEN, -0.018), (0.03, -0.024)])
    blade = (f'<path d="{pet}" fill="{hexc(pal["petiole"])}"/>'
             f'<path d="{path_d(OUTLINE)}" fill="{hexc(ramp(pal["ramp"], tflat))}"/>')

    # relief layer: per flank a gradient from a crisp crease at the vein to the
    # flat tone at the rounded ridge -> the lamina bulges between impressed veins
    def relief_fills(rmp, pre):
        defs, fills = [], []
        nfl = len(flanks) // 2
        for fi, (poly, rm, rt, crease) in enumerate(flanks):
            t = tone(flank_shade(poly, rm, rt, light))
            if fi % nfl < 2 * N_BASE:      # basal crenations: shallow pleats, softer relief
                t = tflat + (t - tflat) * 0.45
            col = ramp(rmp, t)
            mid = ramp(rmp, tflat + (t - tflat) * 0.85)
            if crease is None:          # basal / apical half-lobe: no impressed vein
                ref = (poly[0][0] * 0.5 + poly[len(poly) // 2][0] * 0.5,
                       poly[0][1] * 0.5 + poly[len(poly) // 2][1] * 0.5)
                col = ramp(rmp, tflat + (t - tflat) * 0.6)
            else:
                o, s = crease
                ref = (o[0] + (s[0] - o[0]) * 0.6, o[1] + (s[1] - o[1]) * 0.6)
            ax, ay = tx(ref); r0 = tx(rm); r1 = tx(rt)
            dx, dy = r1[0] - r0[0], r1[1] - r0[1]
            k = ((ax - r0[0]) * dx + (ay - r0[1]) * dy) / (dx * dx + dy * dy)
            fx, fy = r0[0] + dx * k, r0[1] + dy * k
            gid = f"{pre}{len(defs)}"
            defs.append(f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{ax:.1f}" '
                        f'y1="{ay:.1f}" x2="{fx:.1f}" y2="{fy:.1f}"><stop offset="0" stop-color="{hexc(col)}"/>'
                        f'<stop offset="0.6" stop-color="{hexc(mid)}"/><stop offset="1" '
                        f'stop-color="{hexc(ramp(rmp, tflat))}"/></linearGradient>')
            fills.append(f'<path d="{poly_d(poly)}" fill="url(#{gid})"/>')
        return defs, fills

    defs, fills = relief_fills(pal["ramp"], "g")
    if "green" in pal:
        # mid-turn: chlorophyll lingers along the midrib and base; the margin turns first.
        # A green copy of the relief, masked by a radial falloff from the lower midrib.
        gd, gf = relief_fills(pal["green"], "q")
        cx, cy = tx((0.30, 0.0))
        defs += gd
        defs.append(f'<radialGradient id="mg" gradientUnits="userSpaceOnUse" cx="{cx:.1f}" cy="{cy:.1f}" '
                    f'r="{0.56 * SCALE:.1f}"><stop offset="0" stop-color="#FFFFFF"/>'
                    f'<stop offset="0.30" stop-color="#D8D8D8"/><stop offset="0.85" stop-color="#000000"/>'
                    f'</radialGradient><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="{C}" '
                    f'height="{C}"><rect x="0" y="0" width="{C}" height="{C}" fill="url(#mg)"/></mask>')
        fills.append('<g mask="url(#m)">' + "".join(gf) + "</g>")
    # autumn variability: a faint orange blush on two lobes (FoA: "yellow to golden-brown or red")
    rp = panels(RIGHT) + panels(LEFT)
    blush = []
    for i in BLUSH:
        poly, rm, tip, _ = rp[i]
        cx, cy = tx(tip)
        gid = f"b{i}"
        defs.append(f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{cx:.1f}" cy="{cy:.1f}" '
                    f'r="{0.30 * SCALE:.1f}"><stop offset="0" stop-color="{hexc(pal["blush"])}" stop-opacity="0.55"/>'
                    f'<stop offset="1" stop-color="{hexc(pal["blush"])}" stop-opacity="0"/></radialGradient>')
        blush.append(f'<path d="{poly_d(poly)}" fill="url(#{gid})"/>')
    blush = "".join(blush)
    # fine brown speckling (field photo): sub-pixel at 40 px, so it only adds texture at large sizes
    rnd = random.Random(7)
    outline_px = [tx(p) for s in OUTLINE for p in bez_pts(s, 6)]
    xs = [p[0] for p in outline_px]; ys = [p[1] for p in outline_px]
    specks = []
    while len(specks) < 420:
        x, y = rnd.uniform(min(xs), max(xs)), rnd.uniform(min(ys), max(ys))
        if point_in(outline_px, x, y):
            r = rnd.uniform(0.9, 2.1)
            specks.append(f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{r:.1f}" ry="{r * 0.6:.1f}" '
                          f'transform="rotate(-34 {x:.1f} {y:.1f})" fill="{hexc(pal["speck"])}" '
                          f'fill-opacity="{rnd.uniform(0.18, 0.4):.2f}"/>')
    relief = "<defs>" + "".join(defs) + "</defs>" + "".join(fills) + blush + "".join(specks)

    # vein layer: thin amber grooves (darker than every blade tone -> survives tint/clear)
    def taper(a, b, w0, w1):
        ax, ay = tx(a); bx, by = tx(b)
        dx, dy = bx - ax, by - ay
        ln = math.hypot(dx, dy)
        nx, ny = -dy / ln, dx / ln
        pts = [(ax + nx * w0 / 2, ay + ny * w0 / 2), (bx + nx * w1 / 2, by + ny * w1 / 2),
               (bx - nx * w1 / 2, by - ny * w1 / 2), (ax - nx * w0 / 2, ay - ny * w0 / 2)]
        return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"

    veins = [taper((0.0, 0.0), (1.0 - NOTCH - 0.004, 0.0), 9, 3)]
    for hf in (LEFT, RIGHT):
        for i, (o, s) in enumerate(hf["stations"][1:-1]):
            e = (o[0] + (s[0] - o[0]) * 0.99, o[1] + (s[1] - o[1]) * 0.99)
            w0, w1 = (3.2, 1.6) if i < N_BASE - 1 else (5, 2.2)
            veins.append(taper(o, e, w0, w1))
    vein_svg = "".join(f'<path d="{d}" fill="{hexc(pal["vein"])}"/>' for d in veins)
    return dict(blade=blade, relief=relief, veins=vein_svg)


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{C}" height="{C}" '
            f'viewBox="0 0 {C} {C}">{body}</svg>\n')


def srgb(hx):
    r, g, b = H(hx)
    return f"srgb:{r/255:.5f},{g/255:.5f},{b/255:.5f},1.00000"


def grad(a, b):
    return {"linear-gradient": [srgb(a), srgb(b)],
            "orientation": {"start": {"x": 0, "y": 0}, "stop": {"x": 1, "y": 1}}}


BG_LIGHT = ("#34503A", "#1C2F23")   # natural dark green, NW -> SE
BG_DARK = ("#142219", "#08110C")


def write_icon(name="Fagus", pal=PAL):
    fit(0.72)
    pkg = os.path.join(OUT, f"{name}.icon")
    if os.path.exists(pkg):
        shutil.rmtree(pkg)
    os.makedirs(os.path.join(pkg, "Assets"))
    parts = leaf_svgs(pal)
    files = {"blade.svg": parts["blade"], "plication.svg": parts["relief"], "veins.svg": parts["veins"]}
    master = os.path.join(OUT, "svg", name)
    os.makedirs(master, exist_ok=True)
    for fn, body in files.items():
        for d in (os.path.join(pkg, "Assets"), master):
            with open(os.path.join(d, fn), "w") as f:
                f.write(svg(body))
    doc = {
        "fill-specializations": [
            {"value": grad(*BG_LIGHT)},
            {"appearance": "dark", "value": grad(*BG_DARK)},
        ],
        "groups": [{
            "name": "Leaf",
            "layers": [
                {"name": "veins", "image-name": "veins.svg", "glass": False},
                {"name": "plication", "image-name": "plication.svg", "glass": False},
                {"name": "blade", "image-name": "blade.svg", "glass": True},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.3},
            "specular": True,
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": ["iOS"]},
    }
    with open(os.path.join(pkg, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
    return pkg


def report():
    pts = []
    for s in OUTLINE:
        pts += bez_pts(s, 20)
    us = [p[0] for p in pts]; vs = [p[1] for p in pts]
    Lb, W = max(us) - min(us), max(vs) - min(vs)
    arcs = [0.0] + [VEIN_ARC[0] * k / N_BASE for k in range(1, N_BASE)] + VEIN_ARC + [1.0]
    print("vein pairs", NV, "angles", [round(math.degrees(math.atan2(abs(s[1]), s[0] - o[0])))
                                        for o, s in LEFT["stations"][N_BASE:-1]])
    print("lobes/side", len(LEFT["tips"]), "lobe arc widths", [round(b - a, 3) for a, b in zip(arcs, arcs[1:])])
    print("blade L", round(Lb, 3), "W", round(W, 3), "L:W", round(Lb / W, 2),
          "petiole/L", round(PET_LEN / Lb, 3), "sinus depth/L", SINUS, "notch/L", NOTCH)


if __name__ == "__main__":
    report()
    print(write_icon("Fagus", PAL))
    print(write_icon("FagusTurning", PAL_TURN))

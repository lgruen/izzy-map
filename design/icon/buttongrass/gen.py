"""Buttongrass (Gymnoschoenus sphaerocephalus) app icon: geometry, SVG layers and the
Icon Composer .icon package. Drawn to MORPHOLOGY.md, not traced from any photo.

  python3 gen.py              -> out/ButtongrassTussock.icon + master/ButtongrassTussock/*.svg
  python3 gen.py --install    -> also replaces ios/IzzyMap/Resources/AppIcon.icon (same name,
                                 so project.yml is unchanged); then run fallback.py for the
                                 AppIcon.appiconset PNGs (see MORPHOLOGY.md, "Install")
  python3 gen.py --concepts   -> out/concepts/: the 3 concepts x 3 backgrounds explored

Model (ratios in head-radius units R; real head D 15-20 mm -> R ~ 8.75 mm):
  head = globose cluster of flattened spikelets (~5 mm = 0.57 R) radiating from the culm
  tip; none where the culm attaches. Flowering: fine cream linear anthers (2.5-3 mm +
  apical appendage) hang out of the spikelets, twisted and drooping. Older heads: dark
  chocolate to blackish, no anthers. Involucral bracts usually 3, broad and sheathing at
  the base of the head, up to ~ as long as it. Culm rigid, terete, 1-2.5 mm, smooth.
Spikelets are 3-D: each is a lanceolate solid along its outward normal, projected
orthographically (convex hull of its cross-section ellipses), so the rim ones read
side-on and the face ones end-on as ovate glume backs -- the head's texture comes from
that foreshortening, lit from the NW like the app's hillshade.
"""
import json, math, os, random, shutil, sys

OUT = os.path.dirname(os.path.abspath(__file__))
C = 1024
GOLD = math.pi * (3 - math.sqrt(5))
LIGHT = (lambda v: tuple(x / math.sqrt(sum(y * y for y in v)) for x in v))((-0.45, -0.62, 0.64))


def H(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def hexc(c):
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(x))) for x in c)


def mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def norm(v):
    ln = math.sqrt(sum(x * x for x in v)) or 1
    return tuple(x / ln for x in v)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def hull(pts):
    pts = sorted(set((round(x, 2), round(y, 2)) for x, y in pts))
    if len(pts) < 3:
        return pts
    def half(seq):
        h = []
        for p in seq:
            while len(h) >= 2 and ((h[-1][0] - h[-2][0]) * (p[1] - h[-2][1])
                                   - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0])) <= 0:
                h.pop()
            h.append(p)
        return h
    lo, up = half(pts), half(reversed(pts))
    return lo[:-1] + up[:-1]


def poly(pts):
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"


# ------------------------------------------------------------------ palettes
PAL = dict(
    # flowering head (Leo's photos 5-7, UN photo): olive to brown-green spikelet bodies,
    # dark brown glume tips/margins, cream anthers, white stigmas
    deep=H("#1C180E"), core=H("#2C2816"), body_lo=H("#4A4624"), body_hi=H("#A99A56"), apex=H("#2A1D12"),
    glint=H("#C9B36A"),
    anther_lo=H("#CDBB86"), anther=H("#EDE2BC"), anther_hi=H("#FBF6E2"), stigma=H("#FFFFFF"),
    # older head: rusty brown to near-black (photos 5, UN habit photo)
    old_lo=H("#24160D"), old_mid=H("#3A2416"), old_hi=H("#6A3F22"), old_apex=H("#0E0906"), old_glint=H("#7E5534"),
    # culm: pale olive-green below, golden straw, a warm brown flush under the head
    culm=[(0.0, H("#7F8A3C")), (0.55, H("#B9A452")), (0.88, H("#A87F3E")), (1.0, H("#7A4A26"))],
    culm_hi=H("#E4D48E"),
    bract=H("#8A6A3A"), bract_tip=H("#3A2416"),
    leaf=[H("#3B3A1E"), H("#514C26"), H("#6A5F30"), H("#83743C"), H("#9A8746"), H("#AE9852"), H("#BFA75E")],
    leaf_base=H("#33241A"),
)


# ------------------------------------------------------------------ the head
def spikelet_dirs(n, attach, seed, exclude_deg=34):
    rnd = random.Random(seed)
    out = []
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(max(0.0, 1 - z * z))
        ph = i * GOLD
        v = (r * math.cos(ph), r * math.sin(ph), z)
        v = norm(tuple(x + rnd.uniform(-0.07, 0.07) for x in v))
        if dot(v, attach) > math.cos(math.radians(exclude_deg)):
            continue      # receptacle sits on the culm: no spikelets there
        out.append(v)
    return out


def spikelet_hull(c, R, n, ln, w, t, r0, roll):
    """Projected outline of a flattened lanceolate spikelet along normal n."""
    # local frame: a = n (axis), b = width direction, cvec = thickness direction
    up = (0, 0, 1) if abs(n[2]) < 0.9 else (0, 1, 0)
    b = norm(cross(n, up))
    cv = cross(n, b)
    cr, sr = math.cos(roll), math.sin(roll)
    b, cv = tuple(cr * x + sr * y for x, y in zip(b, cv)), tuple(-sr * x + cr * y for x, y in zip(b, cv))
    pts = []
    for k in range(9):
        s = k / 8
        wf = (s / WMAX_AT) ** 0.7 if s < WMAX_AT else ((1 - s) / (1 - WMAX_AT)) ** 0.75
        rad = r0 + ln * s
        for j in range(12):
            a = 2 * math.pi * j / 12
            off = [b[q] * w * wf * math.cos(a) + cv[q] * t * wf * math.sin(a) for q in range(3)]
            p = [n[q] * rad + off[q] for q in range(3)]
            pts.append((c[0] + R * p[0], c[1] + R * p[1]))
    return hull(pts)


NA = 8   # samples along an anther


def anther_path(p0, d3, R, L, w, sag, twist, phase):
    """A linear anther hanging on its filament: a fine ribbon from p0 (screen) along 3-D
    direction d3 that sags under gravity (+y) and twists (its apparent width pulses as
    the flat ribbon turns), ending in a short pointed appendage."""
    d = norm(d3)
    dx, dy = R * L * d[0], R * L * d[1]
    ln = math.hypot(dx, dy) or 1
    cen = []
    for k in range(NA + 1):
        s = k / NA
        cen.append((p0[0] + dx * s, p0[1] + dy * s + sag * R * L * s * s))
    left, right = [], []
    for k, (x, y) in enumerate(cen):
        s = k / NA
        a, b = cen[max(0, k - 1)], cen[min(NA, k + 1)]
        tx, ty = b[0] - a[0], b[1] - a[1]
        tl = math.hypot(tx, ty) or 1
        tw = 0.45 + 0.55 * abs(math.cos(phase + twist * s * math.pi))
        hw = w * tw * (0.3 if s < 0.12 else (1.0 if s < 0.86 else max(0.05, (1 - s) / 0.14)))
        left.append((x - ty / tl * hw, y + tx / tl * hw))
        right.append((x + ty / tl * hw, y - tx / tl * hw))
    return poly(left + right[::-1]), ln


SPK_W = 0.15     # spikelet half-width (R units): ~2.6 mm wide on a 5 mm spikelet
WMAX_AT = 0.58   # widest at the exposed outer glumes (ovate glume backs seen on the face)
ANTHER_W = 1.0   # >1 thickens anthers for small heads (legibility), documented in MORPHOLOGY


def head(cx, cy, R, state, attach, seed, n=72, detail=1.0, aw=1.0):
    """Returns dict of SVG fragments: back (behind the core), front, fringe (anthers)."""
    rnd = random.Random(seed)
    P = PAL
    dirs = spikelet_dirs(n, attach, seed)
    back, front, fringe_back, fringe = [], [], [], []
    defs = []
    gid = [0]

    def grad(p0, p1, stops):
        gid[0] += 1
        i = f"s{seed}_{gid[0]}"
        defs.append(f'<linearGradient id="{i}" gradientUnits="userSpaceOnUse" x1="{p0[0]:.1f}" y1="{p0[1]:.1f}" '
                    f'x2="{p1[0]:.1f}" y2="{p1[1]:.1f}">' +
                    "".join(f'<stop offset="{o}" stop-color="{hexc(c)}"/>' for o, c in stops) + "</linearGradient>")
        return f"url(#{i})"

    items = []
    for v in dirs:
        if v[2] < -0.55:
            continue
        lam = max(0.0, dot(v, LIGHT))
        sh = 0.18 + 0.82 * lam
        ln = (0.60 if state == "flower" else 0.66) + rnd.uniform(-0.05, 0.05)
        r0 = 1.0 - ln + rnd.uniform(-0.03, 0.02)
        w = SPK_W + rnd.uniform(-0.012, 0.012)
        t = SPK_W * 0.6
        roll = rnd.uniform(0, math.pi)
        hl = spikelet_hull((cx, cy), R, v, ln, w, t, r0, roll)
        base = (cx + R * v[0] * r0, cy + R * v[1] * r0)
        tip = (cx + R * v[0] * (r0 + ln), cy + R * v[1] * (r0 + ln))
        if state == "flower":
            body = mix(P["body_lo"], P["body_hi"], sh)
            apex, deep = P["apex"], P["deep"]
        else:
            body = mix(P["old_mid"], P["old_hi"], sh * 0.9)
            apex, deep = P["old_apex"], P["old_lo"]
        proj = math.hypot(tip[0] - base[0], tip[1] - base[1])
        if proj > 0.22 * R * ln:
            fill = grad(base, tip, [(0, deep), (0.38, body), (0.72, mix(body, apex, 0.25)), (1, apex)])
        else:          # seen end-on: a lens with a dark apex
            fill = hexc(mix(body, apex, 0.15))
        frag = (f'<path d="{poly(hl)}" fill="{fill}" stroke="{hexc(apex)}" stroke-width="{R * 0.007:.1f}" '
                f'stroke-linejoin="round" stroke-opacity="0.7"/>') if SPK_STROKE else f'<path d="{poly(hl)}" fill="{fill}"/>'
        # dark glume apex (end-on spikelets show it as a dark eye)
        ap = spikelet_hull((cx, cy), R, v, ln * 0.2, w * 0.42, t * 0.5, r0 + ln * 0.8, roll)
        frag += f'<path d="{poly(ap)}" fill="{hexc(apex)}" fill-opacity="0.85"/>'
        if lam > 0.55 and v[2] > 0:   # glistening glume: a small highlight on lit spikelets
            gl = spikelet_hull((cx, cy), R, v, ln * 0.35, w * 0.35, t * 0.3, r0 + ln * 0.36, roll)
            glint = P["glint"] if state == "flower" else P["old_glint"]
            frag += f'<path d="{poly(gl)}" fill="{hexc(glint)}" fill-opacity="{0.25 + 0.4 * (lam - 0.55):.2f}"/>'
        items.append((v[2], frag, v, tip, lam))
    items.sort(key=lambda it: it[0])
    for z, frag, v, tip, lam in items:
        (back if z < -0.08 else front).append(frag)

    # anthers + stigmas (flowering only)
    if state == "flower":
        for z, frag, v, tip, lam in items:
            k = K_FRONT if z > -0.3 else K_BACK       # 2 flowers x 3 stamens -> up to 6 per spikelet
            if rnd.random() < 0.18 * (1 - detail):
                continue
            # the anthers of one spikelet hang out together, roughly parallel (no V/Y forks)
            d0 = (v[0] + rnd.uniform(-0.25, 0.25), v[1] + rnd.uniform(-0.05, 0.2), v[2])
            for a in range(k):
                d3 = norm(tuple(d0[q] + rnd.uniform(-0.24, 0.24) for q in range(3)))
                L = rnd.uniform(0.30, 0.62)
                w = R * rnd.uniform(0.018, 0.023) * aw
                # each anther leaves the spikelet from its own floret, not from one shared point
                p0 = (tip[0] + rnd.uniform(-0.08, 0.08) * R, tip[1] + rnd.uniform(-0.08, 0.08) * R)
                # front-facing spikelets: anthers hang down across the face of the head
                sag = rnd.uniform(0.08, 0.3) + 0.35 * max(0.0, z)
                path, plen = anther_path(p0, d3, R, L, w, sag,
                                         rnd.uniform(0.8, 1.6), rnd.uniform(0, math.pi))
                lit = max(0.0, dot(d3, LIGHT))
                col = mix(P["anther_lo"], P["anther_hi"], 0.25 + 0.75 * lit) if z > -0.1 else P["anther_lo"]
                tgt = fringe if z > -0.08 else fringe_back
                tgt.append((z, f'<path d="{path}" fill="{hexc(col)}"/>'))
            if detail >= 1 and z > -0.2 and rnd.random() < 0.35:
                d3 = norm(tuple(v[q] + rnd.uniform(-0.4, 0.4) for q in range(3)))
                path, _ = anther_path(tip, d3, R, rnd.uniform(0.22, 0.32), R * 0.011,
                                      rnd.uniform(-0.2, 0.3), 2.0, rnd.uniform(0, math.pi))
                fringe.append((z + 0.01, f'<path d="{path}" fill="{hexc(P["stigma"])}" fill-opacity="0.9"/>'))
    fringe.sort(key=lambda it: it[0])
    fringe_back.sort(key=lambda it: it[0])

    core_col = P["core"] if state == "flower" else P["old_lo"]
    core = f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R * 0.84:.1f}" fill="{hexc(core_col)}"/>'
    return dict(state=state, defs="".join(defs),
                back="".join(f for _, f in fringe_back) + "".join(back),
                front=core + "".join(front),
                fringe="".join(f for _, f in fringe))


# ------------------------------------------------------------------ culm, bracts, leaves
def bez(p0, p1, p2, s):
    return ((1 - s) ** 2 * p0[0] + 2 * (1 - s) * s * p1[0] + s * s * p2[0],
            (1 - s) ** 2 * p0[1] + 2 * (1 - s) * s * p1[1] + s * s * p2[1])


def ribbon(p0, p1, p2, w0, w1, n=24, taper_tip=False):
    L, Rr = [], []
    for k in range(n + 1):
        s = k / n
        x, y = bez(p0, p1, p2, s)
        tx = 2 * (1 - s) * (p1[0] - p0[0]) + 2 * s * (p2[0] - p1[0])
        ty = 2 * (1 - s) * (p1[1] - p0[1]) + 2 * s * (p2[1] - p1[1])
        tl = math.hypot(tx, ty) or 1
        hw = (w0 + (w1 - w0) * s) / 2
        if taper_tip:
            hw *= min(1.0, (1 - s) / 0.25) if s > 0.75 else 1.0
        L.append((x - ty / tl * hw, y + tx / tl * hw))
        Rr.append((x + ty / tl * hw, y - tx / tl * hw))
    return poly(L + Rr[::-1])


def culm(p0, p1, p2, w0, w1, uid):
    """Terete culm: gradient along its length + a NW-side highlight (cylinder shading)."""
    stops = "".join(f'<stop offset="{o}" stop-color="{hexc(c)}"/>' for o, c in PAL["culm"])
    defs = (f'<linearGradient id="c{uid}" gradientUnits="userSpaceOnUse" x1="{p0[0]:.1f}" y1="{p0[1]:.1f}" '
            f'x2="{p2[0]:.1f}" y2="{p2[1]:.1f}">{stops}</linearGradient>')
    body = f'<path d="{ribbon(p0, p1, p2, w0, w1)}" fill="url(#c{uid})"/>'
    # shadow side (SE) and highlight (NW) as thin offset ribbons
    def off(p, d):
        return (p[0] + d[0], p[1] + d[1])
    hi = ribbon(off(p0, (-w0 * 0.18, -w0 * 0.05)), off(p1, (-w0 * 0.16, -w0 * 0.05)),
                off(p2, (-w1 * 0.16, -w1 * 0.05)), w0 * 0.22, w1 * 0.22)
    lo = ribbon(off(p0, (w0 * 0.30, w0 * 0.06)), off(p1, (w0 * 0.30, w0 * 0.06)),
                off(p2, (w1 * 0.30, w1 * 0.06)), w0 * 0.30, w1 * 0.30)
    if CULM_SHADE:
        body += f'<path d="{lo}" fill="#3A2A12" fill-opacity="0.28"/>'
    body += f'<path d="{hi}" fill="{hexc(PAL["culm_hi"])}" fill-opacity="0.55"/>'
    return defs, body


def bract(base, ang_deg, length, width, uid):
    a = math.radians(ang_deg)
    d = (math.cos(a), math.sin(a))
    nrm = (-d[1], d[0])
    tip = (base[0] + d[0] * length, base[1] + d[1] * length)
    # broad, sheathing base -> acuminate tip, slightly curved
    c1 = (base[0] + d[0] * length * 0.45 + nrm[0] * width * 0.9, base[1] + d[1] * length * 0.45 + nrm[1] * width * 0.9)
    c2 = (base[0] + d[0] * length * 0.45 - nrm[0] * width * 0.7, base[1] + d[1] * length * 0.45 - nrm[1] * width * 0.7)
    b1 = (base[0] + nrm[0] * width * 0.5, base[1] + nrm[1] * width * 0.5)
    b2 = (base[0] - nrm[0] * width * 0.5, base[1] - nrm[1] * width * 0.5)
    d_ = (f"M{b1[0]:.1f},{b1[1]:.1f} Q{c1[0]:.1f},{c1[1]:.1f} {tip[0]:.1f},{tip[1]:.1f} "
          f"Q{c2[0]:.1f},{c2[1]:.1f} {b2[0]:.1f},{b2[1]:.1f} Z")
    defs = (f'<linearGradient id="b{uid}" gradientUnits="userSpaceOnUse" x1="{base[0]:.1f}" y1="{base[1]:.1f}" '
            f'x2="{tip[0]:.1f}" y2="{tip[1]:.1f}"><stop offset="0" stop-color="{hexc(PAL["bract"])}"/>'
            f'<stop offset="0.7" stop-color="{hexc(mix(PAL["bract"], PAL["bract_tip"], 0.35))}"/>'
            f'<stop offset="1" stop-color="{hexc(PAL["bract_tip"])}"/></linearGradient>')
    return defs, f'<path d="{d_}" fill="url(#b{uid})"/>'


FRONT_Z = 0.72   # leaves in front of the culm bases (drawn above them)
CROWN = 190   # half-width of the tussock crown (many tillers), px


def tussock(base, n, rdome, seed, wmax=6.0):
    """Hummock of fine wiry leaves radiating from the crown; outer ones arch over and droop.
    Drawn back to front: shaded inner leaves first, sunlit straw-tipped ones on top."""
    rnd = random.Random(seed)
    leaves = []
    for i in range(n):
        z = rnd.random()                       # 0 = deep inside the tussock, 1 = front
        ang = -90 + rnd.uniform(-1, 1) * 84 * rnd.uniform(0.55, 1.0)
        bx = base[0] + rnd.uniform(-1, 1) * CROWN
        a = math.radians(ang)
        d = (math.cos(a), math.sin(a))
        out = 1 - abs(math.sin(a))
        L = rdome * rnd.uniform(0.75, 1.08) * (1.0 + 0.25 * out)
        droop = L * (0.04 + out * out * rnd.uniform(0.5, 0.9))
        tip = (bx + d[0] * L, base[1] + d[1] * L * (1 - 0.2 * out) + droop)
        mid = (bx + d[0] * L * 0.62, base[1] + d[1] * L * 0.72 - droop * 0.05)
        ramp = PAL["leaf"]
        k = min(len(ramp) - 1, int((0.25 * z + 0.75 * z * z) * len(ramp) + rnd.uniform(-0.6, 0.6)))
        leaves.append((z, ribbon((bx, base[1]), mid, tip, rnd.uniform(0.55, 1.0) * wmax, 1.2, n=8, taper_tip=True),
                       max(0, k)))
    leaves.sort()
    # dead leaf bases: each colour fades to dark brown toward the crown (one shared
    # vertical gradient per colour, so the layer stays small)
    y0, y1 = base[1] - 120, base[1] - 290
    defs = "<defs>" + "".join(
        f'<linearGradient id="lf{k}" gradientUnits="userSpaceOnUse" x1="0" y1="{y0}" x2="0" y2="{y1}">'
        f'<stop offset="0" stop-color="{hexc(PAL["leaf_base"])}"/><stop offset="1" stop-color="{hexc(c)}"/>'
        f'</linearGradient>' for k, c in enumerate(PAL["leaf"])) + "</defs>"
    back = defs + "".join(f'<path d="{d}" fill="url(#lf{k})"/>' for z, d, k in leaves if z < FRONT_Z)
    front = defs + "".join(f'<path d="{d}" fill="url(#lf{k})"/>' for z, d, k in leaves if z >= FRONT_Z)
    return back, front


# ------------------------------------------------------------------ concepts
def attach_dir(p1, p2):
    d = norm((p1[0] - p2[0], p1[1] - p2[1], 0.0))
    return norm((d[0], d[1], -0.25))    # culm comes from slightly behind


def concept_single():
    """(a) one culm, gentle curve, flowering head upper right."""
    hc, R = (584, 380), 172
    p0, p1, p2 = (318, 1130), (410, 660), (hc[0], hc[1] + R * 0.2)
    cd, cb = culm(p0, p1, p2, 30, 22, "a")
    # involucral bracts: broad sheathing base, one ~0.8 D poking out beside the head
    bd1, bb1 = bract((hc[0] + R * 0.28, hc[1] + R * 0.62), -44, R * 1.62, R * 0.22, "a1")
    bd2, bb2 = bract((hc[0] - R * 0.22, hc[1] + R * 0.62), -150, R * 0.95, R * 0.2, "a2")
    hd = head(hc[0], hc[1], R, "flower", attach_dir(p1, p2), seed=11, n=96, aw=1.25)
    return dict(stem="<defs>" + cd + bd1 + bd2 + "</defs>" + bb1 + bb2 + cb, heads=[hd])


TUSSOCK_SPECS = {
    # (head centre, R, state, lean of the culm's control point, seed)
    "4": [((292, 318), 92, "flower", -12, 21), ((528, 204), 98, "flower", 4, 22),
          ((770, 300), 74, "old", 14, 23), ((668, 512), 80, "flower", 10, 24)],
    # many small buttons on stiff stalks: heads ~20 % smaller, two more culms
    "6": [((268, 352), 74, "flower", -10, 21), ((452, 214), 78, "flower", -4, 22),
          ((610, 300), 70, "flower", 4, 25), ((792, 262), 62, "old", 12, 23),
          ((712, 520), 64, "flower", 8, 24), ((352, 560), 58, "old", -6, 26)],
}
TUSSOCK = "4"
CULM_SHADE = False     # SE shade ribbon on culms (off: invisible at size, costs Assets.car bytes)
SPK_STROKE = True      # thin dark glume margins
CULM_SHADOW = 0         # culm group drop shadow (off for the same reason)
N_LEAVES = 360
K_FRONT, K_BACK = 5, 3   # anthers drawn per spikelet (front-facing / rim)
LEAF_W = 9.4           # fewer, slightly broader blades: same mass, ~0.3 MB less in Assets.car


def concept_tussock(variant=None):
    """(b) a tussock: fine wiry yellow-brown leaves, stiff culms, flowering heads and old dark ones."""
    base = (512, 1130)
    leaves, front = tussock(base, N_LEAVES, 420, seed=5, wmax=LEAF_W)
    defs, body, heads = [], [], []
    for i, (hc, R, st, lean, sd) in enumerate(TUSSOCK_SPECS[variant or TUSSOCK]):
        p0 = (base[0] + (hc[0] - base[0]) * 0.22, base[1] - 110)
        p2 = (hc[0], hc[1] + R * 0.2)
        # rigid culm: almost straight, a slight lean only
        p1 = ((p0[0] + p2[0]) / 2 + lean, (p0[1] + p2[1]) / 2)
        cd, cb = culm(p0, p1, p2, 14, 11, f"t{i}")
        defs.append(cd); body.append(cb)
        side = -1 if hc[0] < 512 else 1
        # involucral bracts: broad sheathing bases at the BOTTOM of the head, ~60 deg out
        for j, (sg, ln) in enumerate(((side, 1.25), (-side, 0.8))):
            bd, bb = bract((hc[0] + sg * R * 0.08, hc[1] + R * 0.9), -90 + sg * 60, R * ln, R * 0.2, f"t{i}{j}")
            defs.append(bd); body.append(bb)
        heads.append(head(hc[0], hc[1], R, st, attach_dir(p1, p2), seed=sd, n=72, detail=0.6, aw=1.25))
    return dict(leaves=leaves, front=front, stem="<defs>" + "".join(defs) + "</defs>" + "".join(body), heads=heads)


def concept_close():
    """(c) the button itself: head-dominant crop, culm entering from below."""
    hc, R = (500, 452), 284
    p0, p1, p2 = (600, 1140), (570, 900), (hc[0] + 10, hc[1] + R * 0.3)
    cd, cb = culm(p0, p1, p2, 54, 46, "c")
    bd1, bb1 = bract((hc[0] + R * 0.3, hc[1] + R * 0.62), -40, R * 1.55, R * 0.22, "c1")
    bd2, bb2 = bract((hc[0] - R * 0.25, hc[1] + R * 0.62), -152, R * 0.9, R * 0.2, "c2")
    hd = head(hc[0], hc[1], R, "flower", attach_dir(p1, p2), seed=31, n=110)
    return dict(stem="<defs>" + cd + bd1 + bd2 + "</defs>" + bb1 + bb2 + cb, heads=[hd])


CONCEPTS = dict(single=concept_single, tussock=concept_tussock, close=concept_close)


# ------------------------------------------------------------------ packaging
def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{C}" height="{C}" '
            f'viewBox="0 0 {C} {C}">{body}</svg>\n')


def srgb(hx):
    r, g, b = H(hx)
    return f"srgb:{r/255:.5f},{g/255:.5f},{b/255:.5f},1.00000"


def lgrad(a, b, start=(0, 0), stop=(1, 1)):
    return {"linear-gradient": [srgb(a), srgb(b)],
            "orientation": {"start": {"x": start[0], "y": start[1]}, "stop": {"x": stop[0], "y": stop[1]}}}


BGS = {
    # current app icon: natural dark forest green, NW -> SE
    "forest": dict(light=("#34503A", "#1C2F23"), dark=("#142219", "#08110C"), orient=((0, 0), (1, 1))),
    # dusk, deeper: slate sky over dark olive moorland (keeps straw culms/leaves readable)
    "dusk2": dict(light=("#2F3D52", "#5A5230"), dark=("#121A24", "#25220F"), orient=((0.5, 0), (0.5, 1))),
    # golden-olive moorland: sunlit tussock tones (Leo's photo 6), top -> bottom
    "moor": dict(light=("#A08C4A", "#5C5628"), dark=("#2E2A14", "#14130A"), orient=((0.5, 0), (0.5, 1))),
}


OLD_MONO = "srgb:0.50000,0.50000,0.50000,1.00000"


def write_icon(concept, bg, name=None):
    parts = CONCEPTS[concept]()
    name = name or f"Buttongrass-{concept}-{bg}"
    final = "-" not in name
    sub = "out" if final else os.path.join("out", "concepts")
    pkg = os.path.join(OUT, sub, f"{name}.icon")
    if os.path.exists(pkg):
        shutil.rmtree(pkg)
    os.makedirs(os.path.join(pkg, "Assets"))
    hs = parts["heads"]
    defs_of = lambda hh: "<defs>" + "".join(h["defs"] for h in hh) + "</defs>"
    fl = [h for h in hs if h["state"] == "flower"]
    old = [h for h in hs if h["state"] == "old"]
    files = {
        "stem.svg": parts["stem"],
        "head-back.svg": defs_of(fl) + "".join(h["back"] for h in fl),
        "head.svg": defs_of(fl) + "".join(h["front"] for h in fl),
        "anthers.svg": "".join(h["fringe"] for h in fl),
    }
    if old:
        files["old-head.svg"] = defs_of(old) + "".join(h["back"] + h["front"] for h in old)
    if "leaves" in parts:
        files["leaves.svg"] = parts["leaves"]
        files["leaves-front.svg"] = parts["front"]
    master = os.path.join(OUT, "master", name)
    dirs = [os.path.join(pkg, "Assets")]
    if final:
        os.makedirs(master, exist_ok=True)
        dirs.append(master)
    for fn, body in files.items():
        for d in dirs:
            with open(os.path.join(d, fn), "w") as f:
                f.write(svg(body))
    B = BGS[bg]
    head_layers = [
        {"name": "anthers", "image-name": "anthers.svg", "glass": False},
        {"name": "head", "image-name": "head.svg", "glass": False},
        {"name": "head-back", "image-name": "head-back.svg", "glass": False},
    ]
    if old:
        # an old (rusty to near-black) head is dark -> nearly invisible in the mono (tinted/clear)
        # renditions, which map luminance; there it becomes a solid light silhouette
        head_layers.append({"name": "old-head", "image-name": "old-head.svg", "glass": False,
                            "fill-specializations": [{"appearance": "tinted", "value": {"solid": OLD_MONO}}]})
    groups = [{
        "name": "Heads",
        "layers": head_layers,
        "shadow": {"kind": "neutral", "opacity": 0.35},
        "specular": True,
        "translucency": {"enabled": False, "value": 0.5},
    }, {
        "name": "Culms",
        "layers": ([{"name": "leaves-front", "image-name": "leaves-front.svg", "glass": False}]
                   if "leaves" in parts else []) + [{"name": "stem", "image-name": "stem.svg", "glass": True}],
        "shadow": ({"kind": "neutral", "opacity": CULM_SHADOW} if CULM_SHADOW
                   else {"kind": "none", "opacity": 0.5}),
        "specular": True,
        "translucency": {"enabled": False, "value": 0.5},
    }]
    if "leaves" in parts:
        groups.append({
            "name": "Tussock",
            "layers": [{"name": "leaves", "image-name": "leaves.svg", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.2},
            "specular": False,
            "translucency": {"enabled": False, "value": 0.5},
        })
    doc = {
        "fill-specializations": [
            {"value": lgrad(*B["light"], *B["orient"])},
            {"appearance": "dark", "value": lgrad(*B["dark"], *B["orient"])},
        ],
        "groups": groups,
        "supported-platforms": {"squares": ["iOS"]},
    }
    with open(os.path.join(pkg, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
    return pkg


if __name__ == "__main__":
    pkg = write_icon("tussock", "dusk2", "ButtongrassTussock")
    print(pkg)
    if "--concepts" in sys.argv:
        for c in CONCEPTS:
            for b in ("forest", "dusk2", "moor"):
                write_icon(c, b)
    if "--install" in sys.argv:
        dst = os.path.join(OUT, "..", "..", "..", "ios", "IzzyMap", "Resources", "AppIcon.icon")
        dst = os.path.normpath(dst)
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(pkg, dst)
        print("installed", dst)

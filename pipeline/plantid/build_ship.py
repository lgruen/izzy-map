#!/usr/bin/env python3
"""Plant-ID shipping artefacts for the native app's `plantid` asset pack, built
from the 2026-11-02 evaluation (README.md; evaluate.py's chosen method:
BioCLIP 2.5 ViT-H/14, linear head ⊕ kNN + local prior, top-1 94.7 %).

Subcommands (run in order; each is resumable / cheap to repeat):

  data       head, kNN banks (fp16 / int8 / k-means prototypes), location
             prior, labels.json, credits, pipeline.json — and the end-to-end
             test numbers of every bank variant, scored FROM THE WRITTEN FILES
             with the reference scorer below (`Ship`), on the cached
             (cloud, PyTorch fp16) embeddings. ~3 min on the M4.
  encoders   8-bit (linear, per-channel) and 4-bit (k-means palettised,
             per-grouped-channel LUT) Core ML encoders from the fp16 one.
  fp32ref    PyTorch fp32 embeddings of N test photos (cosine reference).
  embed      Core ML embeddings of the test photos with one encoder variant
             (~0.09 s/photo on the M4 ANE; resumable 512-photo parts).
  bench      load time + one prediction (run under /usr/bin/time -l by
             `report` for the peak memory footprint).
  report     encoder variants end to end + sizes/timings → ship/results.json.
  v2         the single model (README "Single model (v2)", run V2_RUN):
             v2-head.bin, v2-prior.bin, v2-labels.json, credits for every
             training photo, pipeline.json "v2" + provenance, then a check
             of the written files against the evaluation (eval env with
             V2DATA=…/data-final.npz; ~3 min).
  v3         the final configuration (README "Final configuration (v3):
             shipping"; final_sweep.py `mpA01|adaptive|box`): v3-head.bin (two
             multi-prototype heads), v3-prior.bin (v2's counts + the adaptive
             σ raster), pipeline.json "v3" + provenance + `model`; then a check
             of the written files against the sweep's test.json (~1 min;
             --check-only / --check-n N). v2-labels.json + credits stay.
  fixture    numbers-only test fixtures for the Swift scorer/preprocessing
             (ios/IzzyKit/Tests/Fixtures/plantid-*; needs only numpy,
             pyarrow, pillow: `uv run --with numpy --with pyarrow --with
             pillow python3 -I pipeline/plantid/build_ship.py fixture`).

Environment (one for all subcommands; numpy < 2.3 for coremltools):

  uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \\
      --with open_clip_torch --with coremltools --with 'numpy<2.3' \\
      --with scipy --with pyarrow --with pillow --with scikit-learn \\
      python3 -I pipeline/plantid/build_ship.py data

Output: pipeline/cache/plantid/ship/ (gitignored; never committed — the
training-photo licences are CC BY / BY-NC, see README "Licences").

File format of every *.bin here ("IZPL" blob): little-endian
  bytes 0–3  magic "IZPL"; 4–7 uint32 format version (1); 8–11 uint32 n =
  JSON header length; 12…12+n UTF-8 JSON header; data section starts at the
  next multiple of 64; header["arrays"][name] = {dtype, shape, offset (from
  data start, 64-aligned), bytes}. Row-major. The rest of the header holds
  that file's parameters.
"""
import argparse
import collections
import glob
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

import warnings

import numpy as np
import pyarrow.parquet as pq

# numpy < 2.3 + macOS Accelerate raise spurious FP flags in matmul (results are
# finite; the build asserts the eval's numbers reproduce)
warnings.filterwarnings("ignore", r".*encountered in matmul", RuntimeWarning)

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
SHIP = os.path.join(CACHE, "ship")
MODEL = "bioclip25"
HF = "hf-hub:imageomics/bioclip-2.5-vith14"
# the evaluation's chosen parameters (report/report.md, "linear (all) ⊕ kNN + local")
EVAL = {"mu": 1e-5, "epochs": 40, "k": 50, "tau": 0.05, "omega": 0.5, "lam": 0.5,
        "sigma": 5.0, "alpha": 32.0, "top1": 0.947, "top5": 0.990}
KM_LON = 111.32 * float(np.cos(np.radians(-42.0)))  # evaluate.project()
KM_LAT = 110.57
MEAN = [0.48145466, 0.4578275, 0.40821073]
STD = [0.26862954, 0.26130258, 0.27577711]


# ------------------------------------------------------------------ blob I/O

def write_blob(path, header, arrays):
    entries, off = {}, 0
    for name, a in arrays.items():
        a = np.ascontiguousarray(a)
        entries[name] = {"dtype": a.dtype.name, "shape": list(a.shape), "offset": off,
                         "bytes": a.nbytes}
        off += -(-a.nbytes // 64) * 64
    h = json.dumps({**header, "arrays": entries}, ensure_ascii=False).encode()
    start = -(-(12 + len(h)) // 64) * 64
    with open(path + ".part", "wb") as f:
        f.write(b"IZPL" + np.uint32(1).tobytes() + np.uint32(len(h)).tobytes() + h)
        f.write(b"\0" * (start - 12 - len(h)))
        for name, a in arrays.items():
            b = np.ascontiguousarray(a).astype(a.dtype.newbyteorder("<"), copy=False).tobytes()
            f.write(b + b"\0" * (-len(b) % 64))
    os.replace(path + ".part", path)


def read_blob(path):
    raw = np.memmap(path, dtype=np.uint8, mode="r")
    assert bytes(raw[:4]) == b"IZPL" and int(raw[4:8].view("<u4")[0]) == 1, path
    n = int(raw[8:12].view("<u4")[0])
    h = json.loads(bytes(raw[12:12 + n]))
    start = -(-(12 + n) // 64) * 64
    arrs = {}
    for name, e in h["arrays"].items():
        o = start + e["offset"]
        arrs[name] = np.frombuffer(raw[o:o + e["bytes"]], dtype=np.dtype(e["dtype"]).newbyteorder("<")
                                   ).reshape(e["shape"])
    return h, arrs


def size_of(path):
    if os.path.isdir(path):
        return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(path) for f in fs)
    return os.path.getsize(path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


# --------------------------------------------------------- reference scorer

def unit(Z):
    return Z / np.linalg.norm(Z, axis=1, keepdims=True)


def log_softmax(z):
    z = z - z.max(1, keepdims=True)
    return z - np.log(np.exp(z).sum(1, keepdims=True))


def knn_neighbours(Q, B, scale=None, k=50, chunk=1024):
    """Top-k bank rows per query: (similarities, indices), best first."""
    sims, idx = [], []
    Bf = B.astype(np.float32)
    for i in range(0, len(Q), chunk):
        S = Q[i:i + chunk] @ Bf.T
        if scale is not None:
            S *= scale[None, :]
        nb = np.argpartition(-S, k - 1, axis=1)[:, :k]
        s = np.take_along_axis(S, nb, 1)
        o = np.argsort(-s, 1)
        sims.append(np.take_along_axis(s, o, 1))
        idx.append(np.take_along_axis(nb, o, 1))
    return np.concatenate(sims), np.concatenate(idx)


def knn_vote(sims, idx, labels, C, k, tau, weight=None, rho=0.0):
    """evaluate.knn_logp on precomputed neighbours: softmax-weighted vote of
    the k nearest bank rows (× row weight^ρ for prototypes = photos they
    stand for), smoothed with a 1e-6/C floor."""
    s, nb = sims[:, :k], idx[:, :k]
    w = np.exp((s - s[:, :1]) / tau)
    if weight is not None and rho:
        w = w * weight[nb].astype(np.float64) ** rho
    n = len(s)
    flat = (np.arange(n)[:, None] * C + labels[nb].astype(np.int64)).ravel()
    P = np.bincount(flat, w.ravel(), minlength=n * C).reshape(n, C)
    P /= P.sum(1, keepdims=True)
    return np.log(P + 1e-6 / C)


class Prior:
    """Shipping location prior: pool-record counts on a 2.5 km (σ/2) grid in
    the eval's equirectangular km, Gaussian kernel (σ, cut at 3σ) applied at
    the query point — exactly evaluate.GeoPrior — then shrunk to the
    statewide frequency: p(s | place) = (K_s + α f_s) / (Σ K + α)."""

    def __init__(self, path):
        self.h, a = read_blob(path)
        self.rowptr, self.sp, self.cnt = a["rowptr"], a["species"], a["count"]
        tot = a["species_total"].astype(np.float64) + 1.0
        self.freq = tot / tot.sum()

    def density(self, lat, lon):
        h = self.h
        g, sig = h["cell_km"], h["sigma_km"]
        r = h["radius_sigmas"] * sig
        qx = np.asarray(lon, float) * h["km_per_deg_lon"]
        qy = np.asarray(lat, float) * h["km_per_deg_lat"]
        w = int(np.ceil(r / g)) + 1
        d = np.arange(-w, w + 1)
        cx = np.floor(qx / g).astype(np.int64)[:, None, None] + d[None, None, :]
        cy = np.floor(qy / g).astype(np.int64)[:, None, None] + d[None, :, None]
        dx = (cx + 0.5) * g - qx[:, None, None]
        dy = (cy + 0.5) * g - qy[:, None, None]
        d2 = dx ** 2 + dy ** 2
        ix, iy = cx - h["x0"], cy - h["y0"]
        ok = (d2 <= r * r) & (ix >= 0) & (ix < h["nx"]) & (iy >= 0) & (iy < h["ny"])
        q, _, _ = np.nonzero(ok)
        cell = (iy * h["nx"] + ix)[ok]
        wt = np.exp(-d2[ok] / (2 * sig * sig))
        lo, hi = self.rowptr[cell].astype(np.int64), self.rowptr[cell + 1].astype(np.int64)
        n = hi - lo
        rep = np.repeat(np.arange(len(cell)), n)
        pos = np.repeat(lo - np.cumsum(n) + n, n) + np.arange(n.sum())
        C = len(self.freq)
        flat = q[rep] * C + self.sp[pos].astype(np.int64)
        return np.bincount(flat, wt[rep] * self.cnt[pos], minlength=len(qx) * C).reshape(-1, C)

    def log_prior(self, lat, lon):
        K = self.density(lat, lon)
        a = self.h["alpha"]
        return np.log((K + a * self.freq[None, :]) / (K.sum(1, keepdims=True) + a))


class Ship:
    """What the app computes, from the shipped files only. `emb` = raw
    encoder output (any norm). Returns final log p over the labels."""

    def __init__(self, d, bank):
        hh, ha = read_blob(os.path.join(d, "head.bin"))
        self.W, self.mu, self.head_temp = ha["weight"].astype(np.float32), ha["centre"], hh["temp"]
        self.bh, ba = read_blob(os.path.join(d, bank))
        self.B, self.blabels = ba["vectors"], ba["labels"]
        self.bscale = ba.get("scale")
        self.bscale = None if self.bscale is None else self.bscale.astype(np.float32)
        self.bweight = ba.get("weight")
        self.prior = Prior(os.path.join(d, "prior.bin"))
        self.C = self.W.shape[0]

    def query(self, emb):
        return unit(unit(np.asarray(emb, np.float32)) - self.mu[None, :]).astype(np.float32)

    def head_logp(self, q):
        return log_softmax(self.head_temp * (q @ self.W.T))

    def image_logp(self, q, nbrs=None):
        p = self.bh["scoring"]
        if p.get("head_only"):
            return self.head_logp(q)
        sims, idx = nbrs if nbrs is not None else knn_neighbours(q, self.B, self.bscale, p["k"])
        Lk = log_softmax(p["knn_temp"] * knn_vote(sims, idx, self.blabels, self.C, p["k"],
                                                   p["tau"], self.bweight, p.get("rho", 0)))
        return log_softmax(p["blend_temp"] * (self.head_logp(q) + p["omega"] * Lk))

    def logp(self, emb, lat, lon, nbrs=None):
        q = self.query(emb)
        L = self.image_logp(q, nbrs)
        return log_softmax(L + self.bh["scoring"]["lam"] * self.prior.log_prior(lat, lon))


# ------------------------------------- Australia-wide model (train_australia.py)

class DegPrior:
    """Australia-wide location prior (au-prior.bin, kind "plantid-prior-deg"):
    pool-record counts per (cell, class) on a lat/lon grid of `cell_deg`
    degrees (row iy = floor((lat − lat0)/cell_deg), column ix = floor((lon −
    lon0)/cell_deg), r = iy·nx + ix, CSR rows like prior.bin). At a query point
    every cell whose centre is within radius_sigmas·σ adds count·exp(−d²/2σ²),
    d in km with y = Δlat·km_per_deg_lat and x = Δlon·km_per_deg_lon·cos(lat
    of the QUERY) — correct to < 1 % at σ ≤ 50 km anywhere in Australia
    (Tasmania's prior.bin uses a fixed cos 42°, wrong by 25 % in the tropics).
    Then the shrinkage of prior.bin: (K + α f) / (ΣK + α)."""

    def __init__(self, path):
        self.h, a = read_blob(path)
        self.rowptr, self.sp, self.cnt = a["rowptr"], a["species"], a["count"]
        tot = a["species_total"].astype(np.float64) + 1.0
        self.freq = tot / tot.sum()

    def density(self, lat, lon, sigma=None, chunk=512):
        lat, lon = np.atleast_1d(np.asarray(lat, float)), np.atleast_1d(np.asarray(lon, float))
        if len(lat) > chunk:
            return np.concatenate([self.density(lat[i:i + chunk], lon[i:i + chunk], sigma)
                                   for i in range(0, len(lat), chunk)])
        h = self.h
        g, sig = h["cell_deg"], sigma or h["sigma_km"]
        r = h["radius_sigmas"] * sig
        ky = h["km_per_deg_lat"]
        kx = h["km_per_deg_lon"] * np.cos(np.radians(lat))
        wy = int(np.ceil(r / (ky * g))) + 1
        wx = int(np.ceil(r / (kx.min() * g))) + 1
        iy0 = np.floor((lat - h["lat0"]) / g).astype(np.int64)
        ix0 = np.floor((lon - h["lon0"]) / g).astype(np.int64)
        shp = (len(lat), 2 * wy + 1, 2 * wx + 1)
        iy = np.broadcast_to(iy0[:, None, None] + np.arange(-wy, wy + 1)[None, :, None], shp)
        ix = np.broadcast_to(ix0[:, None, None] + np.arange(-wx, wx + 1)[None, None, :], shp)
        dy = (h["lat0"] + (iy + 0.5) * g - lat[:, None, None]) * ky
        dx = (h["lon0"] + (ix + 0.5) * g - lon[:, None, None]) * kx[:, None, None]
        d2 = dx ** 2 + dy ** 2
        ok = (d2 <= r * r) & (iy >= 0) & (iy < h["ny"]) & (ix >= 0) & (ix < h["nx"])
        q = np.nonzero(ok)[0]
        cell = (iy * h["nx"] + ix)[ok]
        wt = np.exp(-d2[ok] / (2 * sig * sig))
        lo, hi = self.rowptr[cell].astype(np.int64), self.rowptr[cell + 1].astype(np.int64)
        n = hi - lo
        rep = np.repeat(np.arange(len(cell)), n)
        pos = np.repeat(lo - np.cumsum(n) + n, n) + np.arange(n.sum())
        C = len(self.freq)
        flat = q[rep] * C + self.sp[pos].astype(np.int64)
        return np.bincount(flat, wt[rep] * self.cnt[pos], minlength=len(lat) * C).reshape(-1, C)

    def log_prior(self, lat, lon, sigma=None, alpha=None):
        K = self.density(lat, lon, sigma)
        a = alpha or self.h["alpha"]
        return np.log((K + a * self.freq[None, :]) / (K.sum(1, keepdims=True) + a))


def write_deg_prior(path, cy, cx, cls, cnt, C, grid, sigma, alpha, about):
    """(cy, cx, class, count) rows (aggregated) → au-prior.bin."""
    ny, nx = grid["ny"], grid["nx"]
    assert cy.min() >= 0 and cx.min() >= 0 and cy.max() < ny and cx.max() < nx
    cell = cy.astype(np.int64) * nx + cx
    o = np.lexsort((cls, cell))
    cell, cls, cnt = cell[o], np.asarray(cls)[o], np.asarray(cnt)[o]
    rowptr = np.zeros(nx * ny + 1, np.int64)
    np.add.at(rowptr, cell + 1, 1)
    rowptr = np.cumsum(rowptr).astype(np.uint32)
    cdt = np.uint16 if cnt.max() < 65536 else np.uint32
    hdr = {"kind": "plantid-prior-deg", "version": 2, "about": about,
           "records": int(cnt.sum()), "cell_deg": grid["cell"], "lat0": grid["lat0"],
           "lon0": grid["lon0"], "ny": ny, "nx": nx, "km_per_deg_lat": KM_LAT,
           "km_per_deg_lon": 111.32, "sigma_km": float(sigma), "radius_sigmas": 3.0,
           "alpha": float(alpha),
           "recipe": "row r = iy·nx + ix with iy = floor((lat−lat0)/cell_deg), ix = floor((lon−lon0)/"
                     "cell_deg); cell centre (lat0+(iy+½)·cell_deg, lon0+(ix+½)·cell_deg); for every "
                     "cell whose centre is within radius_sigmas·σ of the point (dy = Δlat·"
                     "km_per_deg_lat, dx = Δlon·km_per_deg_lon·cos(point lat)), K[class] += count·"
                     "exp(−d²/2σ²) for class, count in species/count[rowptr[r]..<rowptr[r+1]]; f = "
                     "(species_total+1)/Σ(species_total+1); prior = (K + α·f) / (ΣK + α)"}
    write_blob(path, hdr, {"rowptr": rowptr, "species": cls.astype(np.uint16), "count": cnt.astype(cdt),
                           "species_total": np.bincount(cls, cnt, minlength=C).astype(np.uint32)})
    print(f"au prior: {int(cnt.sum()):,} records → {len(cnt):,} (cell, class) pairs on a {ny}×{nx} "
          f"grid of {grid['cell']}°, {size_of(path) / 1e6:.2f} MB")


def int8_rows(X):
    """Per-row symmetric int8 (scale = max|x|/127), as bank-int8."""
    X = np.asarray(X, np.float32)
    scale = np.maximum(np.abs(X).max(1), 1e-12) / 127.0
    return np.clip(np.round(X / scale[:, None]), -127, 127).astype(np.int8), scale.astype(np.float16)


TAS_BOX = (143.5, -44.0, 149.0, -39.2)  # W, S, E, N — incl. King Island and the Furneaux Group


def in_tas(lat, lon):
    lat, lon = np.asarray(lat, float), np.asarray(lon, float)
    return (lon >= TAS_BOX[0]) & (lat >= TAS_BOX[1]) & (lon <= TAS_BOX[2]) & (lat <= TAS_BOX[3])


class AuShip:
    """The Australia-wide scorer, from the shipped files only (the spec for
    the Swift side). Classes = au-labels.json (22,122). `logp_au` is the
    trained model alone; `hybrid` combines it with the Tasmanian `Ship`
    (head.bin, bank-int8.bin, prior.bin over its 2,675 labels = au label
    `ship` ≥ 0) exactly as pipeline.json "australia" describes."""

    def __init__(self, d, ship=None):
        hh, ha = read_blob(os.path.join(d, "au-head.bin"))
        W = ha["weight"].astype(np.float32)
        if "scale" in ha:
            W = W * ha["scale"].astype(np.float32)[:, None]
        self.W, self.mu, self.hh = W, ha["centre"].astype(np.float32), hh
        self.ph, pa_ = read_blob(os.path.join(d, "au-protos.bin"))
        self.P, self.plabels = pa_["vectors"], pa_["labels"]
        self.pscale = pa_["scale"].astype(np.float32) if "scale" in pa_ else None
        self.pweight = pa_.get("weight")
        self.prior = DegPrior(os.path.join(d, "au-prior.bin"))
        self.C = len(self.W)
        self.T = None
        if self.ph["scoring"].get("zs_omega"):
            _, ta = read_blob(os.path.join(d, "au-text.bin"))
            self.T = ta["vectors"].astype(np.float32) * ta["scale"].astype(np.float32)[:, None]
        self.ship = ship
        if ship is not None:
            lab = json.load(open(os.path.join(d, "au-labels.json")))["labels"]
            self.ship2u = np.full(ship.C, -1)
            for u, l in enumerate(lab):
                if l.get("ship", -1) >= 0:
                    self.ship2u[l["ship"]] = u
            assert (self.ship2u >= 0).all()
            self.nonlocal_ = np.ones(self.C, bool)
            self.nonlocal_[self.ship2u] = False

    def query(self, emb):
        return unit(unit(np.asarray(emb, np.float32)) - self.mu[None, :]).astype(np.float32)

    def image_logp(self, q):
        s = self.ph["scoring"]
        L = log_softmax(self.hh["temp"] * (q @ self.W.T))
        if s["omega"]:
            sims, idx = knn_neighbours(q, self.P, self.pscale, s["k"])
            Lk = log_softmax(s["knn_temp"] * knn_vote(sims, idx, self.plabels, self.C, s["k"], s["tau"],
                                                       self.pweight, s.get("rho", 0)))
            L = log_softmax(s["blend_temp"] * (L + s["omega"] * Lk))
        if s.get("zs_omega"):
            L = log_softmax(s.get("image_weight", 1.0) * L +
                            s["zs_omega"] * log_softmax(s["zs_kappa"] * (q @ self.T.T)))
        return L

    def logp_au(self, emb, lat=None, lon=None, calibrated=True):
        """Final log p over the 22,122 classes; lat/lon None → no prior."""
        s = self.ph["scoring"]
        L = self.image_logp(self.query(emb))
        if lat is not None:
            L = log_softmax(L + s["lam"] * self.prior.log_prior(lat, lon))
        return log_softmax(L / s["final_temp"]) if calibrated else L

    def hybrid(self, emb, lat=None, lon=None):
        """→ (log p over the 22,122 classes, calibrated; named class per photo).
        The AU model's mass on the 2,675 Tasmanian labels is handed to the
        Tasmanian scorer; a non-Tasmanian class is named first only if it
        beats the best Tasmanian one by e^m (uncalibrated)."""
        hy = self.ph["hybrid"]
        La = self.logp_au(emb, lat, lon, calibrated=False) / hy["tau"]
        La = La - hy["b"] * self.nonlocal_[None, :]
        La = log_softmax(La)
        if lat is None:
            Ls = log_softmax(self.ship.image_logp(self.ship.query(emb)))
        else:
            Ls = self.ship.logp(emb, lat, lon)
        p_out = np.exp(La[:, self.nonlocal_]).sum(1, keepdims=True).clip(0, 1)
        Lf = La.copy()
        Lf[:, self.ship2u] = np.log((1 - p_out).clip(1e-30)) + Ls
        top = Lf.argmax(1)
        bl = self.ship2u[Ls.argmax(1)]
        swap = self.nonlocal_[top] & (Lf[np.arange(len(top)), top] - Lf[np.arange(len(top)), bl]
                                      <= hy["m"])
        named = np.where(swap, bl, top)
        return log_softmax(Lf / hy["final_temp"]), named

    def answer(self, emb, lat=None, lon=None):
        """The pipeline's default: the hybrid inside the Tasmania box (or with
        no location), the Australia-wide model alone elsewhere."""
        Lh, named = self.hybrid(emb, lat, lon)
        if lat is None:
            return Lh, named
        L1 = self.logp_au(emb, lat, lon)
        t = in_tas(lat, lon)
        return np.where(t[:, None], Lh, L1), np.where(t, named, L1.argmax(1))


# ------------------------------------------------------------- shared loading

def load_eval_mod():
    sys.path.insert(0, HERE)
    import evaluate  # noqa: E402  (torch + scipy; the eval's own functions)
    return evaluate


def load_sets():
    """Labels, train embeddings and val/test eval dicts exactly as evaluate.py
    builds them (same weights, same photo order)."""
    E_ = load_eval_mod()
    sets = os.path.join(CACHE, "sets")
    L = E_.load_table(os.path.join(sets, "labels.parquet"))
    cls_of = {s: i for i, s in enumerate(L["species_id"])}
    C = len(cls_of)
    d = os.path.join(CACHE, "emb", MODEL)
    z = np.load(os.path.join(d, "text.npz"))
    T = np.zeros((C, z["emb"].shape[1]), np.float32)
    for s, e in zip(z["species_id"], z["emb"]):
        T[cls_of[int(s)]] = e
    idx, E = E_.load_emb(d)
    tr = E_.load_table(os.path.join(sets, "train.parquet"),
                       ["photo_id", "species_id", "observer_id", "license"])
    te = E_.load_table(os.path.join(sets, "test.parquet"),
                       ["photo_id", "ext", "species_id", "taxon_id", "lat", "lon", "split",
                        "n_split", "observed_on"])
    pr = E_.load_table(os.path.join(sets, "prior.parquet"))

    import rare_heldout  # rare species' held-out observations moved into training (by construction)
    moved = rare_heldout.moved_photo_ids()

    def gather(tab):
        keep = [i for i, p in enumerate(tab["photo_id"]) if p in idx and p not in moved]
        X = E[[idx[tab["photo_id"][i]] for i in keep]]
        y = np.array([cls_of.get(tab["species_id"][i], -1) for i in keep], dtype=np.int64)
        return keep, X, y

    ktr, Xtr, ytr = gather(tr)
    ev = {}
    for split in ("val", "test"):
        rows = [i for i, s in enumerate(te["split"]) if s == split]
        sub = {k: [te[k][i] for i in rows] for k in te}
        keep, X, y = gather(sub)
        keys = np.array([sub["species_id"][i] if sub["species_id"][i] is not None
                         else -sub["taxon_id"][i] for i in keep])
        sampled = dict(zip(*np.unique(keys, return_counts=True)))
        w = np.array([sub["n_split"][i] / sampled[k] for i, k in zip(keep, keys)])
        lat = np.array([sub["lat"][i] for i in keep])
        lon = np.array([sub["lon"][i] for i in keep])
        ev[split] = dict(X=X, y=y, w=w, sp=keys, lat=lat, lon=lon, xy=E_.project(lat, lon),
                         period=np.array([E_.period_of(sub["observed_on"][i]) for i in keep]),
                         photo_id=np.array([sub["photo_id"][i] for i in keep]),
                         ext=[sub["ext"][i] for i in keep])
    genus_of = np.array(L["genus"], dtype=object)
    gnames = {g: i for i, g in enumerate(sorted({str(g) for g in genus_of}))}
    gidx = np.array([gnames[str(g)] for g in genus_of])
    import scipy.sparse as sp
    ctx = {"genus_of": genus_of, "gidx": gidx,
           "Gm": sp.csr_matrix((np.ones(C), (np.arange(C), gidx)), shape=(C, len(gnames))),
           "group_of": [E_.GROUPS.get(f) or E_.GROUPS.get(c) for f, c in zip(L["family"], L["cls"])],
           "name_of": L["name"]}
    tr_kept = {k: [tr[k][i] for i in ktr] for k in tr}
    return dict(E_=E_, L=L, C=C, T=T, Xtr=Xtr, ytr=ytr, tr=tr_kept, ev=ev, pr=pr,
                cls_of=cls_of, ctx=ctx, gnames=sorted(gnames))


def summarise(r):
    lad = r["ladder"]
    return {k: (None if r[k] is None else round(100 * r[k], 2))
            for k in ("top1", "top5", "genus1", "top1_species", "top1_all_photos")} | {
        "ladder": {k: round(100 * v, 2) for k, v in lad.items() if v is not None}}


# ------------------------------------------------------------------- data

def build_labels(S):
    L = S["L"]
    plants = json.load(open(os.path.join(HERE, "..", "..", "ios", "IzzyMap", "Resources",
                                         "Data", "plants.json")))["plants"]
    by_species = {}
    for p in plants:
        if p.get("species"):
            by_species.setdefault(p["species"], []).append(p)
    names = set(L["name"])
    # UN names with no exact label: same genus + a near-identical epithet
    # (gender endings, -ei/-ii, a hyphen), only when exactly one label qualifies
    def ed(a, b):
        D = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            prev, D[0] = D[0], i
            for j, cb in enumerate(b, 1):
                prev, D[j] = D[j], min(D[j] + 1, D[j - 1] + 1, prev + (ca != cb))
        return D[-1]
    by_genus = {}
    for n in L["name"]:
        by_genus.setdefault(n.split()[0], []).append(n)
    fuzzy = {}
    for sname in sorted(set(by_species) - names):
        g, *rest = sname.split()
        if not rest:
            continue
        def close(e1, e2):  # one or two letters, ≤ 20 % of the word, same first letter
            d = ed(e1, e2)
            return d <= 2 and d <= 0.2 * max(len(e1), len(e2)) and e1[0] == e2[0]
        cands = [n for n in by_genus.get(g, []) if len(n.split()) > 1
                 and close(n.split()[1], rest[0]) and n not in by_species]
        if len(cands) == 1:
            fuzzy[cands[0]] = sname
    out = []
    for i in range(S["C"]):
        n = L["name"][i]
        un_name = n if n in by_species else fuzzy.get(n)
        ps = by_species.get(un_name, []) if un_name else []
        e = {"name": n, "inat": int(L["species_id"][i]), "genus": L["genus"][i],
             "family": L["family"][i], "order": L["ord"][i], "class": L["cls"][i],
             "tas_records": int(L["n_tas_pool"][i])}
        if ps:
            e["un"] = {"key": un_name, "ids": sorted(p["id"] for p in ps)}
            if un_name != n:
                e["un"]["match"] = "spelling"
        out.append(e)
    linked = sum("un" in e for e in out)
    print(f"labels: {len(out)}, {linked} linked to a UN profile "
          f"({len(fuzzy)} by spelling variant: " +
          ", ".join(f"{a} ← {b}" for a, b in sorted(fuzzy.items())) + ")")
    unlinked_un = sorted(set(by_species) - names - set(fuzzy.values()))
    return {"version": 1, "model": HF, "count": len(out),
            "note": "index = row of head.bin / class id in banks and prior; genus drives the "
                    "answer ladder; un.key = plants.json `species` (PlantSheet key), un.ids = "
                    "plants.json ids (several when UN splits a species into subsp./var.)",
            "labels": out}, unlinked_un


def train_head(S, device):
    E_ = S["E_"]
    Xtr, ytr, T = S["Xtr"], S["ytr"], S["T"]
    mu_i = Xtr.mean(0)
    Xc = unit(Xtr - mu_i)
    Tc = unit(T - T.mean(0))
    t = time.time()
    W = E_.linear(Xc, ytr, Tc, EVAL["mu"], checkpoints=(EVAL["epochs"],), device=device)[EVAL["epochs"]]
    print(f"head: trained {EVAL['epochs']} epochs on {len(ytr):,} photos in {time.time() - t:.0f} s")
    return W.astype(np.float32), mu_i.astype(np.float32), Xc


def spherical_kmeans(X, m, rng, iters=25):
    """k-means on unit vectors (cosine); k-means++ init. Returns centroids
    (unit) and member counts."""
    n = len(X)
    if n <= m:
        return X.copy(), np.ones(n, np.int64)
    c = [rng.integers(n)]
    d = 1 - X @ X[c[0]]
    for _ in range(1, m):
        p = np.maximum(d, 0) ** 2
        c.append(rng.choice(n, p=p / p.sum()) if p.sum() > 0 else rng.integers(n))
        d = np.minimum(d, 1 - X @ X[c[-1]])
    Cn = X[c].copy()
    for _ in range(iters):
        a = (X @ Cn.T).argmax(1)
        new = np.zeros_like(Cn)
        np.add.at(new, a, X)
        cnt = np.bincount(a, minlength=m)
        empty = cnt == 0
        new[empty] = Cn[empty]
        new = unit(new)
        if np.allclose(new, Cn):
            break
        Cn = new
    a = (X @ Cn.T).argmax(1)
    cnt = np.bincount(a, minlength=m)
    keep = cnt > 0
    return Cn[keep], cnt[keep]


def build_prior(S, path):
    pr, cls_of, C = S["pr"], S["cls_of"], S["C"]
    cls = np.array([cls_of[s] for s in pr["species_id"]], np.int64)
    write_prior(path, np.asarray(pr["lat"]), np.asarray(pr["lon"]), cls, C,
                "pool-observer research-grade iNat records (sets/prior.parquet; no val/test "
                "observer), counts per (2.5 km cell, label)")


def write_prior(path, lat, lon, cls, C, about):
    g = EVAL["sigma"] / 2
    cx = np.floor(lon * KM_LON / g).astype(np.int64)
    cy = np.floor(lat * KM_LAT / g).astype(np.int64)
    x0, y0 = cx.min(), cy.min()
    nx, ny = int(cx.max() - x0 + 1), int(cy.max() - y0 + 1)
    cell = (cy - y0) * nx + (cx - x0)
    key = cell * C + cls
    uk, cnt = np.unique(key, return_counts=True)
    ucell, usp = uk // C, uk % C
    rowptr = np.zeros(nx * ny + 1, np.uint32)
    np.add.at(rowptr, ucell + 1, 1)
    rowptr = np.cumsum(rowptr).astype(np.uint32)
    assert cnt.max() < 65536
    hdr = {"kind": "plantid-prior", "version": 1,
           "about": about,
           "records": int(len(cls)), "km_per_deg_lon": KM_LON, "km_per_deg_lat": KM_LAT,
           "cell_km": g, "x0": int(x0), "y0": int(y0), "nx": nx, "ny": ny,
           "sigma_km": EVAL["sigma"], "radius_sigmas": 3.0, "alpha": EVAL["alpha"],
           "recipe": "x = lon·km_per_deg_lon, y = lat·km_per_deg_lat; cell (i, j) = "
                     "(floor(x/cell_km), floor(y/cell_km)); for every cell whose centre "
                     "((i+0.5)·cell_km, (j+0.5)·cell_km) is within radius_sigmas·σ of the "
                     "point, K[species] += count · exp(−d²/2σ²); row r = (j−y0)·nx + (i−x0) "
                     "holds species[rowptr[r]..<rowptr[r+1]] with count; f = (species_total+1)"
                     "/Σ(species_total+1); prior = (K + α·f) / (ΣK + α)"}
    write_blob(path, hdr, {"rowptr": rowptr, "species": usp.astype(np.uint16),
                           "count": cnt.astype(np.uint16),
                           "species_total": np.bincount(cls, minlength=C).astype(np.uint32)})
    print(f"prior: {len(cls):,} records → {len(uk):,} (cell, species) pairs over "
          f"{len(np.unique(ucell)):,} cells of a {nx}×{ny} grid, {size_of(path) / 1e6:.2f} MB")


def presmoothed_check(S, ev_mod):
    """The alternative the plan floated: density pre-evaluated at 0.05° cell
    centres (lookup only). Size (nnz) only, not shipped."""
    E_ = ev_mod
    pr = S["pr"]
    rec_cls = np.array([S["cls_of"][s] for s in pr["species_id"]], np.int64)
    geo = E_.GeoPrior(E_.project(pr["lat"], pr["lon"]), rec_cls, S["C"])
    lat = np.arange(-43.7, -39.45, 0.05) + 0.025
    lon = np.arange(143.8, 148.55, 0.05) + 0.025
    LA, LO = np.meshgrid(lat, lon, indexing="ij")
    K = geo.density("grid", E_.project(LA.ravel(), LO.ravel()), EVAL["sigma"])
    nnz = int((K > 0).sum())
    keep = (K > 1e-3).sum()
    return geo, {"cells": int(K.shape[0]), "nnz": nnz, "nnz_gt_1e-3": int(keep),
                 "approx_mb_uint16_species_plus_uint8_value": round(3 * nnz / 1e6, 1)}


def cmd_data(a):
    import torch
    os.makedirs(SHIP, exist_ok=True)
    t0 = time.time()
    S = load_sets()
    E_, C, ev, ctx = S["E_"], S["C"], S["ev"], S["ctx"]
    print(f"{len(S['ytr']):,} train photos, val {len(ev['val']['y']):,}, test {len(ev['test']['y']):,}")

    labels, unlinked_un = build_labels(S)
    json.dump(labels, open(os.path.join(SHIP, "labels.json"), "w"), ensure_ascii=False, indent=0)

    # ---- head
    hp = os.path.join(SHIP, "head.bin")
    W, mu, Xc = train_head(S, a.device if a.device else
                           ("mps" if torch.backends.mps.is_available() else "cpu"))
    Q = {s: unit(ev[s]["X"] - mu) for s in ev}
    raw = {s: Q[s] @ W.T for s in ev}
    Llin, t_head = E_.calibrate(raw, ev)
    write_blob(hp, {"kind": "plantid-head", "version": 1, "model": HF, "labels": C,
                    "temp": t_head, "bias": None,
                    "recipe": "q = normalise(normalise(embedding) − centre); "
                              "log p = log_softmax(temp · weight·q) (no bias: the evaluated "
                              "head has none; rows of species without train photos are their "
                              "centred text embeddings)",
                    "trained": {"photos": int(len(S["ytr"])), "mu": EVAL["mu"],
                                "epochs": EVAL["epochs"], "built": time.strftime("%Y-%m-%d")}},
               {"weight": W.astype(np.float16), "centre": mu})

    # ---- banks
    ytr = S["ytr"]
    banks = {}
    Bp = os.path.join(SHIP, "bank-fp16.bin")
    write_blob(Bp, {"kind": "plantid-bank", "variant": "fp16", "rows": int(len(ytr))},
               {"vectors": Xc.astype(np.float16), "labels": ytr.astype(np.uint16)})
    banks["fp16"] = Bp
    scale = np.abs(Xc).max(1) / 127.0
    q8 = np.clip(np.round(Xc / scale[:, None]), -127, 127).astype(np.int8)
    Bp = os.path.join(SHIP, "bank-int8.bin")
    write_blob(Bp, {"kind": "plantid-bank", "variant": "int8", "rows": int(len(ytr)),
                    "recipe": "similarity = scale[row] · (q · vectors[row]) (int8 per-row "
                              "symmetric, scale = max|x|/127)"},
               {"vectors": q8, "scale": scale.astype(np.float16), "labels": ytr.astype(np.uint16)})
    banks["int8"] = Bp
    rng = np.random.default_rng(0)
    order = np.argsort(ytr, kind="stable")
    bounds = np.r_[0, np.cumsum(np.bincount(ytr, minlength=C))]
    for m in a.protos:
        t = time.time()
        vecs, labs, cnts = [], [], []
        for c in range(C):
            rows = order[bounds[c]:bounds[c + 1]]
            if not len(rows):
                continue
            cen, cnt = spherical_kmeans(Xc[rows], m, rng)
            vecs.append(cen)
            labs.append(np.full(len(cen), c))
            cnts.append(cnt)
        V, Lb, Ct = np.concatenate(vecs), np.concatenate(labs), np.concatenate(cnts)
        Bp = os.path.join(SHIP, f"bank-proto{m}.bin")
        write_blob(Bp, {"kind": "plantid-bank", "variant": f"proto{m}", "rows": int(len(V)),
                        "recipe": f"spherical k-means, ≤ {m} centroids per species over its "
                                  "centred train embeddings; weight = photos per centroid"},
                   {"vectors": V.astype(np.float16), "labels": Lb.astype(np.uint16),
                    "weight": Ct.astype(np.uint16)})
        banks[f"proto{m}"] = Bp
        print(f"bank proto{m}: {len(V):,} rows in {time.time() - t:.0f} s")

    # ---- prior
    build_prior(S, os.path.join(SHIP, "prior.bin"))
    prior = Prior(os.path.join(SHIP, "prior.bin"))
    lp_ship = {s: prior.log_prior(ev[s]["lat"], ev[s]["lon"]) for s in ev}
    rec_cls = np.array([S["cls_of"][s] for s in S["pr"]["species_id"]], np.int64)
    geo = E_.GeoPrior(E_.project(S["pr"]["lat"], S["pr"]["lon"]), rec_cls, C)
    lp_eval = {s: geo.log_prior(s, ev[s]["xy"], "local", EVAL["sigma"], EVAL["alpha"]) for s in ev}
    dmax = max(float(np.abs(lp_ship[s] - lp_eval[s]).max()) for s in ev)
    print(f"prior: max |log p_ship − log p_eval| = {dmax:.2e}")
    assert dmax < 1e-4, "shipping prior does not reproduce the eval's GeoPrior"

    # ---- tune (val) and score (test) each bank variant through the files
    n_tr = np.bincount(ytr, minlength=C)
    results = {"eval_reference": EVAL, "head": {"temp": t_head}, "variants": {}}

    def fin(Limg, lam=EVAL["lam"], lp=lp_ship):
        return {s: log_softmax(Limg[s] + lam * lp[s]) for s in Limg}

    rh = E_.score(fin(Llin)["test"], ev["test"], ctx, n_tr)
    rh.pop("_pred")
    results["variants"]["head only"] = {"bank": None, **summarise(rh)}
    print(f"  head only + prior: top1 {rh['top1']:.4f} top5 {rh['top5']:.4f}")

    grids_tau = [0.01, 0.02, 0.05, 0.1]
    omegas = [0, 0.25, 0.5, 1.0, 2.0]
    for name, path in banks.items():
        bh, ba = read_blob(path)
        sc = ba.get("scale")
        sc = None if sc is None else sc.astype(np.float32)
        nb = {s: knn_neighbours(Q[s].astype(np.float32), ba["vectors"], sc, EVAL["k"]) for s in ev}
        wt = ba.get("weight")
        if name in ("fp16", "int8"):  # the eval's own parameters (no re-selection)
            p = {"k": EVAL["k"], "tau": EVAL["tau"], "rho": 0.0}
            om = EVAL["omega"]
            Lk_raw = {s: knn_vote(*nb[s], ba["labels"], C, p["k"], p["tau"]) for s in ev}
        else:  # new hyper-parameters: chosen on val like evaluate.py (kNN alone first)
            best = None
            for k in (10, 25, 50):
                for tau in grids_tau:
                    for rho in (0.0, 0.5, 1.0):
                        Lv = knn_vote(*nb["val"], ba["labels"], C, k, tau, wt, rho)
                        v = E_.objective(Lv, ev["val"])
                        if best is None or v > best[0]:
                            best = (v, {"k": k, "tau": tau, "rho": rho})
            p = best[1]
            Lk_raw = {s: knn_vote(*nb[s], ba["labels"], C, p["k"], p["tau"], wt, p["rho"])
                      for s in ev}
            om = None
        Lk, t_knn = E_.calibrate(Lk_raw, ev)
        if om is None:
            om = max(omegas, key=lambda o: E_.objective(Llin["val"] + o * Lk["val"], ev["val"]))
        Lb, t_bl = E_.calibrate({s: Llin[s] + om * Lk[s] for s in ev}, ev)
        scoring = {**p, "knn_temp": t_knn, "omega": om, "blend_temp": t_bl, "lam": EVAL["lam"]}
        write_blob(path, {**bh, "scoring": scoring}, ba)  # store the variant's parameters
        r = E_.score(fin(Lb)["test"], ev["test"], ctx, n_tr)
        r.pop("_pred")
        results["variants"][name] = {"bank": os.path.basename(path), "bytes": size_of(path),
                                     "rows": bh["rows"], "scoring": scoring, **summarise(r)}
        print(f"  {name:7s} {size_of(path) / 1e6:7.1f} MB  top1 {r['top1']:.4f} top5 "
              f"{r['top5']:.4f}  {scoring}")
        if name == "fp16":  # also with the eval's exact prior (GeoPrior), to separate effects
            r2 = E_.score(fin(Lb, lp=lp_eval)["test"], ev["test"], ctx, n_tr)
            r2.pop("_pred")
            results["fp16_with_eval_prior"] = summarise(r2)
            r3 = E_.score(fin(Lb, lam=0)["test"], ev["test"], ctx, n_tr)
            r3.pop("_pred")
            results["fp16_no_prior"] = summarise(r3)
    # a head-only "bank" header so the scorer can run it too
    write_blob(os.path.join(SHIP, "bank-none.bin"),
               {"kind": "plantid-bank", "variant": "none", "rows": 0,
                "scoring": {"head_only": True, "lam": EVAL["lam"]}},
               {"vectors": np.zeros((0, W.shape[1]), np.float16), "labels": np.zeros(0, np.uint16)})

    # ---- cross-check: the reference scorer on the files reproduces the numbers
    for name in ["fp16", "proto2"] if "proto2" in banks else ["fp16"]:
        sh = Ship(SHIP, os.path.basename(banks[name]))
        Lt = sh.logp(ev["test"]["X"], ev["test"]["lat"], ev["test"]["lon"])
        r = E_.score(Lt, ev["test"], ctx, n_tr)
        assert abs(r["top1"] - results["variants"][name]["top1"] / 100) < 2e-3, (name, r["top1"])
        print(f"  Ship() scorer on {name}: top1 {r['top1']:.4f} (matches)")

    # pre-smoothed alternative (size only + its top-1 with a cell-centre lookup)
    try:
        _, alt = presmoothed_check(S, E_)
        results["presmoothed_0.05deg_alternative"] = alt
        print(f"  pre-smoothed 0.05° alternative: {alt}")
    except MemoryError:
        pass

    # ---- credits
    results["credits"] = build_credits(S, a.observers)

    # ---- pipeline.json
    files = {}
    for f in sorted(os.listdir(SHIP)):
        p = os.path.join(SHIP, f)
        if os.path.isfile(p) and (f.endswith(".bin") or f.endswith(".json") or f.endswith(".gz")) \
                and f not in ("pipeline.json", "results.json"):
            files[f] = {"bytes": size_of(p), "sha256": sha256(p)}
    pipe = {
        "version": 1, "built": time.strftime("%Y-%m-%d"), "model": HF,
        "encoder": {"input": "pixel_values float32 1×3×224×224", "output": "embedding (1024)",
                    "preprocess": {"resize": "shortest side → 224, bicubic (Pillow)",
                                   "crop": "centre 224×224", "mean": MEAN, "std": STD,
                                   "colour": "decode RGB ignoring the embedded colour profile "
                                             "(no Display P3 → sRGB conversion)"}},
        "labels": "labels.json", "head": "head.bin", "prior": "prior.bin",
        "bank_default": a.default_bank, "banks": {k: os.path.basename(v) for k, v in banks.items()},
        "steps": [
            "q = normalise(normalise(embedding) − head.centre)",
            "L_head = log_softmax(head.temp · head.weight · q)",
            "kNN: s = q · bank.vectors (× bank.scale for int8); take the k largest; "
            "w = exp((s − s_max)/tau) (× weight^rho for prototypes); P[label] = Σw / Σ all w; "
            "L_knn = log_softmax(knn_temp · log(P + 1e-6/C))",
            "L_img = log_softmax(blend_temp · (L_head + omega · L_knn))",
            "L = log_softmax(L_img + lam · log prior(lat, lon))   (no location: lam = 0)",
            "answer ladder: species if max p ≥ 0.5; else the genus with summed p ≥ 0.5; "
            "else 'not sure'"],
        "ladder": {"species": 0.5, "genus": 0.5},
        "files": files}
    json.dump(pipe, open(os.path.join(SHIP, "pipeline.json"), "w"), indent=1, ensure_ascii=False)
    results["unlinked_un_species"] = unlinked_un
    old = json.load(open(os.path.join(SHIP, "results.json"))) if \
        os.path.exists(os.path.join(SHIP, "results.json")) else {}
    json.dump({**old, "data": results}, open(os.path.join(SHIP, "results.json"), "w"), indent=1,
              ensure_ascii=False)
    print(f"data done in {time.time() - t0:.0f} s → {SHIP}")


def build_credits(S, observers):
    tr = S["tr"]
    want = set(tr["observer_id"])
    logins = {}
    op = gzip.open(observers, "rt") if observers.endswith(".gz") else open(observers)
    with op as f:
        next(f)
        for line in f:
            i, login, *name = line.rstrip("\n").split("\t")
            if int(i) in want:
                logins[int(i)] = (login, name[0] if name else "")
    miss = want - logins.keys()
    print(f"credits: {len(tr['photo_id']):,} photos by {len(want):,} observers "
          f"({len(miss)} without a login in {os.path.basename(observers)})")
    with gzip.open(os.path.join(SHIP, "credits-photos.tsv.gz"), "wt") as f:
        f.write("photo_id\tobserver_login\tlicense\n")
        for p, o, lic in sorted(zip(tr["photo_id"], tr["observer_id"], tr["license"])):
            f.write(f"{p}\t{logins.get(o, ('?',))[0]}\t{lic}\n")
    per = {}
    for o, lic in zip(tr["observer_id"], tr["license"]):
        d = per.setdefault(o, {})
        d[lic] = d.get(lic, 0) + 1
    obs = sorted(([logins.get(o, ("?", ""))[0], logins.get(o, ("?", ""))[1], sum(d.values()), d]
                  for o, d in per.items()), key=lambda r: (-r[2], r[0].lower()))
    lic_tot = {}
    for lic in tr["license"]:
        lic_tot[lic] = lic_tot.get(lic, 0) + 1
    json.dump({"version": 1,
               "about": "The plant-ID head and kNN bank were trained on these iNaturalist "
                        "photos (iNaturalist Open Dataset, 2026-10 snapshot). Each photo © its "
                        "observer, under the licence listed (CC0, CC BY or CC BY-NC; no ND/SA). "
                        "CC BY-NC binds IzzyMap to non-commercial use. Per-photo list: "
                        "credits-photos.tsv.gz; photo page https://www.inaturalist.org/photos/<id>.",
               "photos": len(tr["photo_id"]), "licences": lic_tot,
               "observers": [{"login": r[0], "name": r[1], "photos": r[2], "licences": r[3]}
                             for r in obs]},
              open(os.path.join(SHIP, "credits.json"), "w"), ensure_ascii=False, indent=0)
    return {"photos": len(tr["photo_id"]), "observers": len(want), "missing_logins": len(miss),
            "licences": lic_tot}


# --------------------------------------------------------------- encoders

ENC = {"fp16": "PlantEncoder-fp16.mlpackage", "w8": "PlantEncoder-w8.mlpackage",
       "p4": "PlantEncoder-p4.mlpackage", "p6": "PlantEncoder-p6.mlpackage"}


def cmd_encoders(a):
    import coremltools as ct
    import coremltools.optimize.coreml as cto
    src = os.path.join(CACHE, "coreml", MODEL, "PlantEncoder.mlpackage")
    d = os.path.join(SHIP, "encoder")
    os.makedirs(d, exist_ok=True)
    fp = os.path.join(d, ENC["fp16"])
    if not os.path.exists(fp):
        shutil.copytree(src, fp)
    for v in a.variants:
        out = os.path.join(d, ENC[v])
        if os.path.exists(out) and not a.force:
            print(f"{v}: exists")
            continue
        t = time.time()
        ml = ct.models.MLModel(fp, skip_model_load=True)
        if v == "w8":
            cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8", granularity="per_channel"))
            m = cto.linear_quantize_weights(ml, config=cfg)
            desc = "int8 weights (linear symmetric, per output channel)"
        else:
            nb = 4 if v == "p4" else 6
            cfg = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
                mode="kmeans", nbits=nb, granularity="per_grouped_channel", group_size=16,
                num_kmeans_workers=a.workers))
            m = cto.palettize_weights(ml, config=cfg)
            desc = f"{nb}-bit palettised weights (k-means LUT per 16 output channels)"
        m.short_description = f"{HF} image encoder, {desc}"
        if os.path.exists(out):
            shutil.rmtree(out)
        m.save(out)
        print(f"{v}: {size_of(out) / 1e9:.3f} GB in {time.time() - t:.0f} s")


# ------------------------------------------------------------ embeddings

def test_photos(split="test"):
    t = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"),
                      columns=["photo_id", "ext", "split"]).to_pydict()
    return sorted((p, e) for p, e, s in zip(t["photo_id"], t["ext"], t["split"]) if s == split)


def preprocess(path):
    """open_clip's eval transform: shortest side → 224 bicubic, centre crop,
    to tensor, CLIP mean/std (Pillow ignores the embedded ICC profile)."""
    from PIL import Image
    with Image.open(path) as im:
        x = resize_crop(im.convert("RGB")).astype(np.float32) / 255.0
    x = (x - np.array(MEAN, np.float32)) / np.array(STD, np.float32)
    return x.transpose(2, 0, 1)[None]


def resize_crop(im):
    """The geometric half of `preprocess` on an RGB PIL image → uint8 224×224×3."""
    from PIL import Image
    w, h = im.size
    # torchvision Resize(int): short side = 224, long side = int(224·long/short)
    nw, nh = (224, int(224 * h / w)) if w <= h else (int(224 * w / h), 224)
    im = im.resize((nw, nh), Image.BICUBIC)
    # torchvision CenterCrop: offsets round((W − 224) / 2)
    l, t = int(round((nw - 224) / 2.0)), int(round((nh - 224) / 2.0))
    return np.asarray(im.crop((l, t, l + 224, t + 224)), np.uint8)


def cmd_embed(a):
    import coremltools as ct
    from concurrent.futures import ThreadPoolExecutor
    photos = test_photos()
    if a.subset:
        photos = [photos[i] for i in np.random.default_rng(0).permutation(len(photos))[:a.subset]]
        photos.sort()
    out = os.path.join(SHIP, "eval", f"coreml-{a.variant}")
    os.makedirs(out, exist_ok=True)
    t = time.time()
    m = ct.models.MLModel(os.path.join(SHIP, "encoder", ENC[a.variant]),
                          compute_units=ct.ComputeUnit[a.compute_units])
    print(f"{a.variant}: loaded in {time.time() - t:.1f} s; {len(photos):,} photos")
    root = os.path.join(CACHE, "photos")
    t0, n = time.time(), 0
    with ThreadPoolExecutor(4) as pool:
        for part in range(0, len(photos), 512):
            f = os.path.join(out, f"part-{part // 512:04d}.npz")
            chunk = photos[part:part + 512]
            if os.path.exists(f):
                continue
            embs = []
            for x in pool.map(lambda pe: preprocess(os.path.join(root, f"{pe[0]}.{pe[1]}")), chunk):
                embs.append(m.predict({"pixel_values": x})["embedding"].reshape(-1))
            np.savez(f + ".tmp.npz", photo_id=np.array([p for p, _ in chunk]),
                     emb=np.stack(embs).astype(np.float32))
            os.replace(f + ".tmp.npz", f)
            n += len(chunk)
            print(f"  {part + len(chunk):,}/{len(photos):,}  {(time.time() - t0) / n:.3f} s/photo",
                  flush=True)


def load_parts(d):
    ids, es = [], []
    for f in sorted(glob.glob(os.path.join(d, "part-*.npz"))):
        z = np.load(f)
        ids.append(z["photo_id"])
        es.append(z["emb"])
    if not ids:
        return None, None
    return np.concatenate(ids), np.concatenate(es)


def cmd_fp32ref(a):
    import open_clip
    import torch
    photos = test_photos()
    photos = [photos[i] for i in np.random.default_rng(1).permutation(len(photos))[:a.n]]
    model, _, tf = open_clip.create_model_and_transforms(HF)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    vis = model.visual.to(dev).float().eval()
    root = os.path.join(CACHE, "photos")
    ids, es, mine = [], [], []
    t = time.time()
    from PIL import Image
    with torch.no_grad():
        for i in range(0, len(photos), 16):
            ch = photos[i:i + 16]
            xs = []
            for p, e in ch:
                with Image.open(os.path.join(root, f"{p}.{e}")) as im:
                    xs.append(tf(im.convert("RGB")))
                mine.append(preprocess(os.path.join(root, f"{p}.{e}"))[0])
            es.append(vis(torch.stack(xs).to(dev)).cpu().numpy())
            ids += [p for p, _ in ch]
            if i == 0:  # our numpy preprocessing must equal open_clip's transform
                dpx = float(np.abs(np.stack(mine) - torch.stack(xs).numpy()).max())
                print(f"preprocess max |numpy − open_clip| = {dpx:.2e}")
                assert dpx < 1e-4
    np.savez(os.path.join(SHIP, "eval", "fp32ref.npz"), photo_id=np.array(ids),
             emb=np.concatenate(es))
    print(f"fp32 reference: {len(ids)} photos on {dev} in {time.time() - t:.0f} s")


def cmd_bench(a):
    import coremltools as ct
    t = time.time()
    m = ct.models.MLModel(os.path.join(SHIP, "encoder", ENC[a.variant]),
                          compute_units=ct.ComputeUnit.ALL)
    load = time.time() - t
    photo = test_photos()[0]
    x = preprocess(os.path.join(CACHE, "photos", f"{photo[0]}.{photo[1]}"))
    m.predict({"pixel_values": x})
    t = time.time()
    for _ in range(10):
        m.predict({"pixel_values": x})
    print(json.dumps({"load_s": round(load, 2), "predict_s": round((time.time() - t) / 10, 4)}))


def cmd_report(a):
    S = load_sets()
    E_, C, ev, ctx = S["E_"], S["C"], S["ev"], S["ctx"]
    te = ev["test"]
    pos = {int(p): i for i, p in enumerate(te["photo_id"])}
    n_tr = np.bincount(S["ytr"], minlength=C)
    res = json.load(open(os.path.join(SHIP, "results.json")))
    enc = res.get("encoders", {})
    ref_ids, ref = None, None
    if os.path.exists(os.path.join(SHIP, "eval", "fp32ref.npz")):
        z = np.load(os.path.join(SHIP, "eval", "fp32ref.npz"))
        ref_ids, ref = z["photo_id"], unit(z["emb"].astype(np.float64))
    ship = Ship(SHIP, a.bank)
    # the cached cloud embeddings (PyTorch fp16, CUDA) as their own row
    variants = [("cloud-fp16 (cached)", None)] + [(v, os.path.join(SHIP, "eval", f"coreml-{v}"))
                                                  for v in ENC]
    for v, d in variants:
        if d is None:
            ids, E = te["photo_id"], te["X"]
        else:
            ids, E = load_parts(d)
            if ids is None:
                continue
        rows = np.array([pos[int(p)] for p in ids])
        sub = {k: (val[rows] if isinstance(val, np.ndarray) else [val[i] for i in rows])
               for k, val in te.items()}
        # weights stay those of the full test set (a subset is a sample of it)
        L = ship.logp(E, sub["lat"], sub["lon"])
        r = E_.score(L, sub, ctx, n_tr)
        r.pop("_pred")
        row = {"photos": int(len(ids)), **summarise(r)}
        Ecos = unit(np.asarray(E, np.float64))
        row["cos_vs_cloud_fp16"] = {"mean": float((Ecos * unit(te["X"][rows].astype(np.float64))
                                                   ).sum(1).mean()),
                                    "min": float((Ecos * unit(te["X"][rows].astype(np.float64))
                                                  ).sum(1).min())}
        if ref is not None:
            m = {int(p): i for i, p in enumerate(ids)}
            both = [(m[int(p)], j) for j, p in enumerate(ref_ids) if int(p) in m]
            if both:
                i1, i2 = map(np.array, zip(*both))
                c = (Ecos[i1] * ref[i2]).sum(1)
                row["cos_vs_fp32"] = {"n": len(both), "mean": float(c.mean()),
                                      "min": float(c.min()), "p01": float(np.quantile(c, 0.01))}
        if d is not None:
            p = os.path.join(SHIP, "encoder", ENC[v])
            row["bytes"] = size_of(p)
            row.update(enc.get(v, {}))
        res.setdefault("encoders_eval", {})[f"{v} / {a.bank}"] = row
        print(f"{v:22s} n={len(ids):5d} top1 {row['top1']:.2f} top5 {row['top5']:.2f} "
              f"cos32 {row.get('cos_vs_fp32', {}).get('mean', float('nan')):.5f} "
              f"min {row.get('cos_vs_fp32', {}).get('min', float('nan')):.4f}")
    json.dump(res, open(os.path.join(SHIP, "results.json"), "w"), indent=1, ensure_ascii=False)


FIXTURES = os.path.normpath(os.path.join(HERE, "..", "..", "ios", "IzzyKit", "Tests", "Fixtures"))


def ladder_of(lp, genus, s_thr=0.5, g_thr=0.5):
    """The answer ladder on one log p vector (evaluate.score's rule)."""
    p = np.exp(lp)
    i = int(p.argmax())
    if p[i] >= s_thr:
        return {"kind": "species", "label": i, "p": float(p[i])}
    tot = {}
    for j, g in enumerate(genus):
        tot[g] = tot.get(g, 0.0) + float(p[j])
    g = max(tot, key=tot.get)
    if tot[g] >= g_thr:
        return {"kind": "genus", "genus": g, "p": tot[g]}
    return {"kind": "notSure"}


def synthetic_rgb(w, h):
    """The preprocessing fixture's source image (no photo): IzzyKit's
    PlantIDPreprocessTests builds the same bytes."""
    y, x = np.mgrid[0:h, 0:w].astype(np.int64)
    r = (x * 7 + y * 3) & 255
    g = (x * y + 5 * x) & 255
    b = ((x ^ y) * 9 + 40) & 255
    return np.stack([r, g, b], -1).astype(np.uint8)


def cmd_fixture(a):
    """Test fixtures for the Swift port (numbers only — never a photo):

    - plantid-mini/bank-int8.bin: a tiny synthetic Tasmanian photo bank (6
      labels, 8 dims), the Tasmania-box term of the mini single model.
    - plantid-mini/v3-*, v2-labels.json + plantid-v3-mini.json: a 9-class
      model with two multi-prototype heads (K 1–4 per class) and an adaptive
      prior raster, V3Ship's log p / ladder for 14 embeddings (+ the
      no-location switch) — runs in CI.
    - plantid-v3-real.json: w8 Core ML embeddings of test photos (Tasmania,
      mainland, eucalypts; some without a location) and V3Ship's top 10 +
      ladder on ship/ — the Swift test skips when the files are absent.
    - plantid-preprocess.{json,bin}: Pillow's resize + centre crop of a
      synthetic image (whole, and a square crop), uint8 224×224×3 each."""
    from PIL import Image
    FIX = a.out or FIXTURES
    os.makedirs(FIX, exist_ok=True)
    rng = np.random.default_rng(7)

    # ---- mini Tasmanian bank (its query centre goes into the mini v2 head)
    md = os.path.join(FIX, "plantid-mini")
    os.makedirs(md, exist_ok=True)
    C, D = 6, 8
    W = rng.normal(size=(C, D)).astype(np.float16)
    mu = (0.1 * rng.normal(size=D)).astype(np.float32)
    protos = unit(W.astype(np.float32))
    rows, labs = [], []
    for c in range(C):
        for _ in range(3 + c):
            rows.append(protos[c] + 0.6 * rng.normal(size=D))
            labs.append(c)
    X = unit(np.array(rows, np.float32))
    labs = np.array(labs, np.uint16)
    scale = np.abs(X).max(1) / 127.0
    q8 = np.clip(np.round(X / scale[:, None]), -127, 127).astype(np.int8)
    sc = {"k": 5, "tau": 0.05, "rho": 0.0, "knn_temp": 0.9, "omega": 0.5, "blend_temp": 0.7, "lam": 0.5}
    write_blob(os.path.join(md, "bank-int8.bin"),
               {"kind": "plantid-bank", "variant": "int8", "rows": len(X), "scoring": sc},
               {"vectors": q8, "scale": scale.astype(np.float16), "labels": labs})

    # ---- preprocessing
    src = synthetic_rgb(317, 241)
    im = Image.fromarray(src, "RGB")
    crop = (40, 10, 220, 190)
    outs = [resize_crop(im), resize_crop(im.crop(crop))]
    with open(os.path.join(FIX, "plantid-preprocess.bin"), "wb") as f:
        for o in outs:
            f.write(o.tobytes())
    x = (outs[0].astype(np.float32) / 255.0 - np.array(MEAN, np.float32)) / np.array(STD, np.float32)
    json.dump({"version": 1, "source": [317, 241], "formula": "synthetic_rgb in build_ship.py",
               "cases": [{"crop": None}, {"crop": list(crop)}],
               "bytes_per_case": 224 * 224 * 3, "layout": "uint8 HWC RGB, row-major",
               "tensor_samples": [[c, yy, xx, float(x[yy, xx, c])]
                                  for c, yy, xx in [(0, 0, 0), (1, 100, 37), (2, 223, 223), (0, 57, 201)]]},
              open(os.path.join(FIX, "plantid-preprocess.json"), "w"), indent=1)
    print(f"fixtures → {FIX}")

    # ---- the final configuration v3 (real cases only when its files exist in ship/)
    v3_fixtures(FIX, md, rng, a.n, mu, real=os.path.exists(os.path.join(SHIP, "v3-head.bin")))


def v2_write_prior(path, cy, cx, cls, cnt, C, grid, sigma, alpha, about):
    """A v2-prior.bin from (cell, class, count) rows (fixtures)."""
    write_deg_prior(path + ".deg", cy, cx, cls, cnt, C, grid, sigma, alpha, about)
    h, a = read_blob(path + ".deg")
    raw = a["count"].astype(np.float64)
    fr = {}
    for t in ("log1p", "sqrt"):
        tot = np.bincount(a["species"].astype(np.int64), V2Prior.T[t](raw), minlength=C) + 1.0
        fr["freq_" + t] = tot / tot.sum()
    write_blob(path, {k: v for k, v in h.items() if k != "arrays"},
               {"rowptr": a["rowptr"], "species": a["species"], "count": a["count"],
                "species_total": a["species_total"], **fr})
    os.remove(path + ".deg")


def v2_case(sh, e, loc):
    lat, lon = (None, None) if loc is None else ([loc[0]], [loc[1]])
    L, Li, path = sh.logp(e[None], lat, lon)
    return L[0], Li[0], str(path[0])


def v2_fixtures(FIX, md, rng, n_real, tas_centre, real=True):
    """plantid-mini/v2-* + plantid-v2-mini.json (a 9-class model on top of the
    mini Tasmanian bank; CI) and plantid-v2-real.json (w8 embeddings of
    Tasmanian, mainland and eucalypt test photos, some without a location;
    V2Ship on ship/ — the Swift test skips without the files)."""
    C, D = 9, 8
    genus = ["Alpha", "Alpha", "Alpha", "Beta", "Beta", "Gamma", "Delta", "Delta", "Alpha"]
    names = ["Alpha prima", "Alpha secunda", "Alpha tertia", "Beta una", "Beta duo", "Gamma sola",
             "Delta borealis", "Delta australis", "Alpha gemina"]
    photos = [120, 30, 4, 0, 60, 9, 55, 2, 0]
    ship_of = [3, 0, 5, -1, 1, 4, -1, 2, -1]      # mini bank labels (6 Tasmanian classes)
    W = rng.normal(size=(C, D)).astype(np.float32)
    W[6] = 0.8 * W[7] + 0.3 * rng.normal(size=D)    # close congeners (Delta)
    q8, sc8 = int8_rows(4.0 * W)
    bias = (0.2 * rng.normal(size=C)).astype(np.float32)
    bias[8] = -1e4                                  # a merged twin
    mu = (0.1 * rng.normal(size=D)).astype(np.float32)
    s2u = np.zeros(6, np.int64)
    for u, j in enumerate(ship_of):
        if j >= 0:
            s2u[j] = u
    s2u[4] = 2                                      # two Tasmanian labels on one class: the last wins
    prm = {"temperature": 1.4, "lam": 0.8, "prior": {"transform": "log1p", "sigma_km": 10.0, "alpha": 8.0},
           "tasmania": {"box": list(TAS_BOX), "omega": 1.5, "knn_floor": -30.0, "lam": 1.0,
                        "prior": {"transform": "sqrt", "sigma_km": 5.0, "alpha": 4.0}, "bank": "bank-int8.bin"},
           "ladder": {"species": [0.6, 0.5, 0.5, 0.75], "bucket_edges": list(BUCKET_EDGES), "genus": 0.55,
                      "image_floor": 0.0, "congener_ratio": 1.0}}
    write_blob(os.path.join(md, "v2-head.bin"), {"kind": "plantid-head-v2", "version": 1, "labels": C,
                                                 "variant": "int8 per-row", "scoring": prm},
               {"weight": q8, "scale": sc8.astype(np.float32), "bias": bias, "centre": mu,
                "tas_centre": np.asarray(tas_centre, np.float32), "tas_classes": s2u.astype(np.int32)})
    g = {"cell": 0.1, "lat0": -44.0, "lon0": 144.0, "ny": 110, "nx": 80}
    pts = [(-42.88 + 0.1 * rng.normal(), 147.33 + 0.1 * rng.normal(), int(rng.integers(0, 6))) for _ in range(50)] + \
          [(-33.87 + 0.1 * rng.normal(), 151.21 + 0.1 * rng.normal(), int(rng.choice([3, 6, 7]))) for _ in range(40)]
    key = {}
    for la, lo, c in pts:
        k_ = (int((la - g["lat0"]) // g["cell"]), int((lo - g["lon0"]) // g["cell"]), c)
        key[k_] = key.get(k_, 0) + int(rng.integers(1, 30))
    kk = np.array(list(key))
    v2_write_prior(os.path.join(md, "v2-prior.bin"), kk[:, 0], kk[:, 1], kk[:, 2], np.array(list(key.values())),
                   C, g, 10.0, 8.0, "synthetic test records near Hobart and Sydney")
    lab = []
    for u in range(C):
        r = {"name": names[u], "genus": genus[u], "family": genus[u] + "aceae", "native": True, "photos": photos[u],
             "inat": 1000 + u}
        if ship_of[u] >= 0:
            r["ship"] = ship_of[u]
        if u == 1:
            r["common"] = "second alpha"
        if u == 8:
            r["merged_into"] = 0
        lab.append(r)
    json.dump({"version": 1, "count": C, "labels": lab}, open(os.path.join(md, "v2-labels.json"), "w"), indent=0)
    sh = V2Ship(md)
    E = rng.normal(size=(14, D)).astype(np.float32)
    Wn = unit(W)
    E[:6] = 3 * Wn[[0, 3, 6, 1, 4, 7]] + 0.3 * E[:6]
    locs = [(-42.88, 147.33), (-33.87, 151.21), (-42.95, 147.2), None, (-37.8, 145.0), (-39.9, 144.0), (-41.4, 146.8)] * 2
    cases = []
    for e, l in zip(E, locs):
        L, Li, path = v2_case(sh, e, l)
        alt = dict(sh.sc["ladder"], image_floor=0.3, congener_ratio=0.5)
        sh.sc["ladder"], keep = alt, sh.sc["ladder"]
        lad_alt = sh.ladder(L, Li)
        sh.sc["ladder"] = keep
        cases.append({"embedding": e.tolist(), "location": list(l) if l else None, "path": path,
                      "logp": L.tolist(), "image": Li.tolist(), "ladder": sh.ladder(L, Li), "ladder_alt": lad_alt})
    json.dump({"version": 1, "ladder_alt": {"image_floor": 0.3, "congener_ratio": 0.5}, "cases": cases},
              open(os.path.join(FIX, "plantid-v2-mini.json"), "w"), indent=0)
    if not real:
        print(f"v2 fixtures: mini only (no ship/v2-head.bin) → {FIX}")
        return
    # ---- real: Tasmania (A-test), mainland + eucalypts (C report half), some without a location
    sh = V2Ship(SHIP)
    ids, embs = load_parts(os.path.join(SHIP, "eval", "coreml-w8"))
    te = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["photo_id", "lat", "lon"]).to_pydict()
    where = {p: (la, lo) for p, la, lo in zip(te["photo_id"], te["lat"], te["lon"])}
    au_dir = os.path.join(CACHE, "australia")
    cid, cemb = load_parts(os.path.join(au_dir, "emb-w8"))
    C_ = pq.read_table(os.path.join(au_dir, "C.parquet"), columns=["photo_id", "lat", "lon", "subset", "half"]).to_pydict()
    cinfo = {p: (la, lo, s_, h_) for p, la, lo, s_, h_ in zip(C_["photo_id"], C_["lat"], C_["lon"], C_["subset"], C_["half"])}
    r3 = np.random.default_rng(3)
    n_tas, n_euc = n_real * 3 // 10, n_real * 3 // 10
    pick = [("tasmania", embs[i], where[int(ids[i])]) for i in np.sort(r3.permutation(len(ids))[:n_tas])]
    rep = [i for i in range(len(cid)) if cinfo.get(int(cid[i]), (0, 0, "", ""))[3] == "report"]
    euc = [i for i in rep if cinfo[int(cid[i])][2] == "euc"]
    main = [i for i in rep if cinfo[int(cid[i])][2] == "main"]
    pick += [("eucalypt", cemb[i], cinfo[int(cid[i])][:2]) for i in sorted(r3.choice(euc, n_euc, replace=False))]
    pick += [("mainland", cemb[i], cinfo[int(cid[i])][:2])
             for i in sorted(r3.choice(main, n_real - n_tas - n_euc, replace=False))]
    cases = []
    for j, (kind, e, (la, lo)) in enumerate(pick):
        e = np.asarray(e, np.float32)
        loc = None if j % 6 == 5 else (round(float(la), 3), round(float(lo), 3))
        L, Li, path = v2_case(sh, e, loc)
        top = np.argsort(-L)[:10]
        cases.append({"set": kind, "embedding": __import__("base64").b64encode(e.astype("<f4").tobytes()).decode(),
                      "location": list(loc) if loc else None, "path": path,
                      "top": [[int(t), float(L[t])] for t in top], "image_named": float(Li[top[0]]),
                      "ladder": sh.ladder(L, Li)})
    pj = json.load(open(os.path.join(SHIP, "pipeline.json")))["files"]
    json.dump({"version": 1, "encoder": "w8",
               "note": "embeddings = PlantEncoder-w8 Core ML outputs of test photos (A-test Tasmania, C report half "
                       "eucalypts / mainland; numbers only); expected = build_ship.V2Ship on ship/ (v2-head, "
                       "v2-prior, v2-labels, bank-int8 inside the Tasmania box)",
               "files": {f: pj[f]["sha256"] for f in V2_FILES + ("bank-int8.bin",)},
               "cases": cases}, open(os.path.join(FIX, "plantid-v2-real.json"), "w"), indent=0)
    kinds = collections.Counter((c["set"], c["ladder"]["kind"]) for c in cases)
    print(f"v2 fixtures: mini {len(json.load(open(os.path.join(FIX, 'plantid-v2-mini.json')))['cases'])} cases, "
          f"real {len(cases)} cases {dict(kinds)} → {FIX}")


def v3_fixtures(FIX, md, rng, n_real, tas_centre, real=True):
    """plantid-mini/v3-* + v2-labels.json + plantid-v3-mini.json (a 9-class model:
    two multi-prototype heads with different K per class, an adaptive prior
    raster, the mini Tasmanian bank; CI) and plantid-v3-real.json (w8 embeddings
    of Tasmanian, mainland and eucalypt test photos, some without a location;
    V3Ship on ship/ — the Swift test skips without the files)."""
    for f in ("v2-head.bin", "v2-prior.bin"):
        if os.path.exists(os.path.join(md, f)):
            os.remove(os.path.join(md, f))
    for f in ("plantid-v2-mini.json", "plantid-v2-real.json"):
        if os.path.exists(os.path.join(FIX, f)):
            os.remove(os.path.join(FIX, f))
    C, D = 9, 8
    genus = ["Alpha", "Alpha", "Alpha", "Beta", "Beta", "Gamma", "Delta", "Delta", "Alpha"]
    names = ["Alpha prima", "Alpha secunda", "Alpha tertia", "Beta una", "Beta duo", "Gamma sola",
             "Delta borealis", "Delta australis", "Alpha gemina"]
    photos = [120, 30, 4, 0, 60, 9, 55, 2, 0]
    ship_of = [3, 0, 5, -1, 1, 4, -1, 2, -1]      # mini bank labels (6 Tasmanian classes)
    base = rng.normal(size=(C, D)).astype(np.float32)
    base[6] = 0.8 * base[7] + 0.3 * rng.normal(size=D)   # close congeners (Delta)
    KCS = [[4, 2, 1, 1, 2, 1, 4, 1, 1], [2, 2, 1, 1, 4, 1, 2, 1, 2]]
    W8, S8, B, KC, R0, hh = [], [], [], [], [], []
    r = 0
    for h, Kc in enumerate(KCS):
        Kc = np.array(Kc)
        row0 = v3_row0(Kc)
        W = np.zeros((int(Kc.sum()), D), np.float32)
        for c in range(C):
            W[row0[c]:row0[c] + Kc[c]] = 4.0 * base[c] + 1.5 * rng.normal(size=(Kc[c], D))
        q8, s8 = int8_rows32(W)
        b = (0.2 * rng.normal(size=C)).astype(np.float32)
        b[8] = -1e4                                  # a merged twin
        W8.append(q8), S8.append(s8), B.append(b), KC.append(Kc.astype(np.uint8)), R0.append((row0 + r).astype(np.int32))
        hh.append({"run": f"mini-{h}", "rows": [r, r + len(W)], "pool_temperature": [2.0, 3.5][h]})
        r += len(W)
    mu = (0.1 * rng.normal(size=D)).astype(np.float32)
    s2u = np.zeros(6, np.int64)
    for u, j in enumerate(ship_of):
        if j >= 0:
            s2u[j] = u
    s2u[4] = 2                                      # two Tasmanian labels on one class: the last wins
    prm = {"temperature": 1.4, "image_temperature": 0.8, "lam": 0.8,
           "prior": {"kind": "adaptive", "transform": "log1p", "file": "v3-prior.bin"},
           "tasmania": {"box": list(TAS_BOX), "omega": 1.5, "knn_floor": -1.5, "bank": "bank-int8.bin"},
           "no_location": "australia",
           "ladder": {"species": [0.6, 0.5, 0.5, 0.75], "bucket_edges": list(BUCKET_EDGES), "genus": 0.55,
                      "image_floor": 0.0, "congener_ratio": 1.0}}
    write_blob(os.path.join(md, "v3-head.bin"), {"kind": "plantid-head-v3", "version": 1, "labels": C, "id": "mini",
                                                 "variant": "int8 per prototype row", "heads": hh, "scoring": prm},
               {"weight": np.concatenate(W8), "scale": np.concatenate(S8), "bias": np.stack(B), "kc": np.stack(KC),
                "row0": np.stack(R0), "centre": mu, "tas_centre": np.asarray(tas_centre, np.float32),
                "tas_classes": s2u.astype(np.int32)})
    g = {"cell": 0.1, "lat0": -44.0, "lon0": 144.0, "ny": 110, "nx": 80}
    pts = [(-42.88 + 0.1 * rng.normal(), 147.33 + 0.1 * rng.normal(), int(rng.integers(0, 6))) for _ in range(50)] + \
          [(-33.87 + 0.1 * rng.normal(), 151.21 + 0.1 * rng.normal(), int(rng.choice([3, 6, 7])))
           for _ in range(40)]
    key = {}
    for la, lo, c in pts:
        k_ = (int((la - g["lat0"]) // g["cell"]), int((lo - g["lon0"]) // g["cell"]), c)
        key[k_] = key.get(k_, 0) + int(rng.integers(1, 30))
    kk = np.array(list(key))
    v2_write_prior(os.path.join(md, "v3-prior.bin"), kk[:, 0], kk[:, 1], kk[:, 2], np.array(list(key.values())),
                   C, g, 10.0, 8.0, "synthetic test records near Hobart and Sydney")
    ph, pa = read_blob(os.path.join(md, "v3-prior.bin"))
    iy, ix = np.mgrid[0:g["ny"], 0:g["nx"]]
    code = ((iy // 7 + ix // 5) % 7).astype(np.uint8)          # σ varies cell to cell (stripes)
    sig = 2.0 * 2.0 ** (np.arange(7) / 3.0)
    alp = 8.0 * (sig / 10.0) ** 0.5                               # α per level too (δ 0.5)
    ph = {k: v for k, v in ph.items() if k != "arrays"}
    ph.update({"version": 3, "adaptive": {"about": "synthetic stripes"}})
    write_blob(os.path.join(md, "v3-prior.bin"), ph, {**pa, "sigma_code": code, "sigma_km": sig, "alpha": alp})
    lab = []
    for u in range(C):
        r_ = {"name": names[u], "genus": genus[u], "family": genus[u] + "aceae", "native": True, "photos": photos[u],
              "inat": 1000 + u}
        if ship_of[u] >= 0:
            r_["ship"] = ship_of[u]
        if u == 1:
            r_["common"] = "second alpha"
        if u == 8:
            r_["merged_into"] = 0
        lab.append(r_)
    json.dump({"version": 1, "count": C, "labels": lab}, open(os.path.join(md, "v2-labels.json"), "w"), indent=0)
    sh = V3Ship(md)
    E = rng.normal(size=(14, D)).astype(np.float32)
    Bn = unit(base)
    E[:6] = 3 * Bn[[0, 3, 6, 1, 4, 7]] + 0.3 * E[:6]
    locs = [(-42.88, 147.33), (-33.87, 151.21), (-42.95, 147.2), None, (-37.8, 145.0), (-39.9, 144.0), (-41.4, 146.8)] * 2
    cases = []
    for e, l in zip(E, locs):
        lat, lon = (None, None) if l is None else ([l[0]], [l[1]])
        L, Li, path = sh.logp(e[None], lat, lon)
        L, Li = L[0], Li[0]
        alt = dict(sh.sc["ladder"], image_floor=0.3, congener_ratio=0.5)
        sh.sc["ladder"], keep = alt, sh.sc["ladder"]
        lad_alt = sh.ladder(L, Li)
        sh.sc["ladder"] = keep
        c_ = {"embedding": e.tolist(), "location": list(l) if l else None, "path": str(path[0]),
              "logp": L.tolist(), "image": Li.tolist(), "ladder": sh.ladder(L, Li), "ladder_alt": lad_alt}
        if l is None:   # the switch: no location scored as inside the Tasmania box
            sh.sc["no_location"] = "tasmania"
            Lt, Lit, pt = sh.logp(e[None])
            sh.sc["no_location"] = "australia"
            assert str(pt[0]) == "tasmania"
            c_["logp_as_tasmania"] = Lt[0].tolist()
        cases.append(c_)
    hl = sh.head_logits(unit(unit(E) - sh.mu[None]).astype(np.float32))
    json.dump({"version": 3, "ladder_alt": {"image_floor": 0.3, "congener_ratio": 0.5},
               "head_logits": hl.tolist(), "cases": cases},
              open(os.path.join(FIX, "plantid-v3-mini.json"), "w"), indent=0)
    if not real:
        print(f"v3 fixtures: mini only (no ship/v3-head.bin) → {FIX}")
        return
    # ---- real: Tasmania (A-test), mainland + eucalypts (C report half), some without a location
    sh = V3Ship(SHIP)
    ids, embs = load_parts(os.path.join(SHIP, "eval", "coreml-w8"))
    te = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["photo_id", "lat", "lon"]).to_pydict()
    where = {p: (la, lo) for p, la, lo in zip(te["photo_id"], te["lat"], te["lon"])}
    au_dir = os.path.join(CACHE, "australia")
    cid, cemb = load_parts(os.path.join(au_dir, "emb-w8"))
    C_ = pq.read_table(os.path.join(au_dir, "C.parquet"), columns=["photo_id", "lat", "lon", "subset", "half"]).to_pydict()
    cinfo = {p: (la, lo, s_, h_) for p, la, lo, s_, h_ in zip(C_["photo_id"], C_["lat"], C_["lon"], C_["subset"], C_["half"])}
    r3 = np.random.default_rng(3)
    n_tas, n_euc = n_real * 3 // 10, n_real * 3 // 10
    pick = [("tasmania", embs[i], where[int(ids[i])]) for i in np.sort(r3.permutation(len(ids))[:n_tas])]
    rep = [i for i in range(len(cid)) if cinfo.get(int(cid[i]), (0, 0, "", ""))[3] == "report"]
    euc = [i for i in rep if cinfo[int(cid[i])][2] == "euc"]
    main = [i for i in rep if cinfo[int(cid[i])][2] == "main"]
    pick += [("eucalypt", cemb[i], cinfo[int(cid[i])][:2]) for i in sorted(r3.choice(euc, n_euc, replace=False))]
    pick += [("mainland", cemb[i], cinfo[int(cid[i])][:2])
             for i in sorted(r3.choice(main, n_real - n_tas - n_euc, replace=False))]
    cases = []
    for j, (kind, e, (la, lo)) in enumerate(pick):
        e = np.asarray(e, np.float32)
        loc = None if j % 6 == 5 else (round(float(la), 3), round(float(lo), 3))
        L, Li, path = sh.logp(e[None], None if loc is None else [loc[0]], None if loc is None else [loc[1]])
        L, Li = L[0], Li[0]
        top = np.argsort(-L)[:10]
        cases.append({"set": kind, "embedding": __import__("base64").b64encode(e.astype("<f4").tobytes()).decode(),
                      "location": list(loc) if loc else None, "path": str(path[0]),
                      "top": [[int(t), float(L[t])] for t in top], "image_named": float(Li[top[0]]),
                      "ladder": sh.ladder(L, Li)})
    pj = json.load(open(os.path.join(SHIP, "pipeline.json")))["files"]
    json.dump({"version": 3, "encoder": "w8",
               "note": "embeddings = PlantEncoder-w8 Core ML outputs of test photos (A-test Tasmania, C report half "
                       "eucalypts / mainland; numbers only); expected = build_ship.V3Ship on ship/ (v3-head, "
                       "v3-prior, v2-labels, bank-int8 inside the Tasmania box)",
               "files": {f: pj[f]["sha256"] for f in V3_FILES + ("bank-int8.bin",)},
               "cases": cases}, open(os.path.join(FIX, "plantid-v3-real.json"), "w"), indent=0)
    kinds = collections.Counter((c["set"], c["path"], c["ladder"]["kind"]) for c in cases)
    print(f"v3 fixtures: mini {len(json.load(open(os.path.join(FIX, 'plantid-v3-mini.json')))['cases'])} cases, "
          f"real {len(cases)} cases {dict(kinds)} → {FIX}")


def ladder_named(lp, named, genus, thr=(0.5, 0.5)):
    """The answer ladder when the named class may differ from argmax (hybrid
    margin): species if p[named] ≥ thr[0], else the genus ladder (thr[1])."""
    p = np.exp(lp)
    if p[named] >= thr[0]:
        return {"kind": "species", "label": named, "p": float(p[named])}
    r = ladder_of(lp, genus, *thr)
    return r if r["kind"] != "species" else {"kind": "notSure"}


AU_LADDER_FILE = os.path.join(CACHE, "australia", "train", "ladder.json")


def au_ladder():
    """(species, genus) thresholds of the AU path (outside the Tasmania box)."""
    if os.path.exists(AU_LADDER_FILE):
        c = json.load(open(AU_LADDER_FILE))["chosen"]
        return (float(c["species"]), float(c["genus"]))
    return (0.5, 0.5)


def answer_ladder(lp, named, genus, lat, lon, thr_au):
    """Gated answer's ladder: Tasmanian path (box or no location) 0.5/0.5,
    AU path thr_au."""
    tas = lat is None or bool(in_tas([lat], [lon])[0])
    return ladder_named(lp, named, genus, (0.5, 0.5) if tas else thr_au)


def cmd_benchall(a):
    """Load time (cold = first load after a reboot-free cache clear is not
    possible here: 'first' = first load in this session of a new file,
    'warm' = later loads) + peak memory footprint, each in a fresh process."""
    res = json.load(open(os.path.join(SHIP, "results.json")))
    out = res.setdefault("encoders", {})
    for v in a.variants:
        if not os.path.exists(os.path.join(SHIP, "encoder", ENC[v])):
            continue
        runs = []
        for _ in range(a.repeat):
            p = subprocess.run(["/usr/bin/time", "-l", sys.executable, "-I", __file__, "bench",
                                "--variant", v], capture_output=True, text=True)
            j = json.loads([l for l in p.stdout.splitlines() if l.startswith("{")][-1])
            for l in p.stderr.splitlines():
                if "peak memory footprint" in l:
                    j["peak_footprint_mb"] = round(int(l.split()[0]) / 1e6)
                if "maximum resident set size" in l:
                    j["max_rss_mb"] = round(int(l.split()[0]) / 1e6)
            runs.append(j)
        out[v] = {"bytes": size_of(os.path.join(SHIP, "encoder", ENC[v])), "runs": runs}
        print(v, out[v])
    json.dump(res, open(os.path.join(SHIP, "results.json"), "w"), indent=1, ensure_ascii=False)


def cmd_au(a):
    """After `train_australia.py score` (which writes au-head/au-protos/
    au-prior/au-labels into ship/): credits for the union of the Tasmanian and
    the Australia-wide training photos (credits.json / credits-photos.tsv.gz,
    same format as before), pipeline.json "australia" section + hashes. The
    Tasmanian files it replaces are kept in ship/tas-<date>/ first."""
    for f in ("au-head.bin", "au-protos.bin", "au-prior.bin", "au-labels.json"):
        assert os.path.exists(os.path.join(SHIP, f)), f"{f} missing (train_australia.py score)"
    bak = os.path.join(SHIP, "tas-2026-11-04")
    if not os.path.exists(bak):
        os.makedirs(bak)
        for f in ("credits.json", "credits-photos.tsv.gz", "pipeline.json", "results.json"):
            shutil.copy2(os.path.join(SHIP, f), bak)
    sys.path.insert(0, HERE)
    import train_australia as TA
    # photos the AU head was trained on = train manifest rows with an embedding
    have = []
    for f in sorted(glob.glob(os.path.join(CACHE, "emb", MODEL, "img-*.npz"))) + \
            sorted(glob.glob(os.path.join(TA.TR, "emb", "shard-*.npz"))):
        have.append(np.load(f)["photo_id"])
    have = np.unique(np.concatenate(have))
    au = pq.read_table(os.path.join(TA.AU, "plan", "train.parquet"),
                       columns=["photo_id", "observer_id", "license"]).to_pydict()
    keep = np.isin(np.array(au["photo_id"]), have)
    tas = pq.read_table(os.path.join(CACHE, "sets", "train.parquet"),
                        columns=["photo_id", "observer_id", "license"]).to_pydict()
    rows = {}
    for src in (tas, {k: [v[i] for i in np.nonzero(keep)[0]] for k, v in au.items()}):
        for p, o, lic in zip(src["photo_id"], src["observer_id"], src["license"]):
            rows[int(p)] = (int(o), lic)
    print(f"credits: {len(tas['photo_id']):,} Tasmanian + {int(keep.sum()):,} Australia-wide train "
          f"photos → {len(rows):,} distinct")
    tr = {"photo_id": list(rows), "observer_id": [r[0] for r in rows.values()],
          "license": [r[1] for r in rows.values()]}
    cred = build_credits({"tr": tr}, a.observers)
    pipe = json.load(open(os.path.join(SHIP, "pipeline.json")))
    ph, _ = read_blob(os.path.join(SHIP, "au-protos.bin"))
    pr, _ = read_blob(os.path.join(SHIP, "au-prior.bin"))
    hh, _ = read_blob(os.path.join(SHIP, "au-head.bin"))
    pipe["australia"] = {
        "built": time.strftime("%Y-%m-%d"),
        "labels": "au-labels.json", "head": "au-head.bin", "protos": "au-protos.bin", "text": "au-text.bin",
        "prior": "au-prior.bin", "classes": hh["labels"],
        "steps": [
            "q = normalise(normalise(embedding) − au-head.centre)   (its own centre, not head.bin's)",
            "L_head = log_softmax(au-head.temp · (au-head.weight · q))   (int8: × scale per row)",
            "if omega > 0: kNN over au-protos exactly as the Tasmanian bank step, C = classes; "
            "L_img = log_softmax(blend_temp · (L_head + omega · L_knn)); else L_img = L_head",
            "if zs_omega > 0: L_img = log_softmax(image_weight · L_img + zs_omega · log_softmax(zs_kappa · "
            "(au-text · q)))   (au-text int8 rows × scale; image_weight default 1)",
            "L_au = log_softmax(L_img + lam · log au-prior(lat, lon))   (no location: lam = 0)",
            "standalone: log p = log_softmax(L_au / final_temp)",
            "hybrid (pipeline default): Z = log_softmax(L_au / hybrid.tau − hybrid.b · [class not "
            "Tasmanian]); p_out = Σ exp(Z) over non-Tasmanian classes; the Tasmanian scorer's "
            "final log p L_tas (head.bin ⊕ bank ⊕ prior.bin, the steps above) gives Tasmanian "
            "class u = au label with ship = j: log p[u] = log(1 − p_out) + L_tas[j]; others keep Z",
            "named class: argmax of log p, except when it is non-Tasmanian and beats the best "
            "Tasmanian class by ≤ hybrid.m in log p — then the best Tasmanian class",
            "displayed probabilities: log_softmax(log p / hybrid.final_temp) (ranking unchanged); "
            "answer ladder on these with the thresholds in australia.ladder (Tasmanian path 0.5/0.5, "
            "AU path its own)"],
        "scoring": ph["scoring"], "hybrid": ph["hybrid"],
        "ladder": {"tasmanian_path": {"species": 0.5, "genus": 0.5},
                   "au_path": dict(zip(("species", "genus"), au_ladder())),
                   "note": "answer ladder on the displayed (calibrated) p: species if p[named] ≥ species, else "
                           "the genus with summed p ≥ genus, else 'not sure'. Tasmanian path = inside the "
                           "Tasmania box or no location (unchanged); AU path = everywhere else. Chosen on "
                           "AU-tune per photo + AU-val eucalypts: species stated but wrong ≤ 7 %."},
        "prior_grid": {k: pr[k] for k in ("cell_deg", "lat0", "lon0", "ny", "nx", "sigma_km", "alpha")}}
    files = pipe["files"]
    for f in ("au-head.bin", "au-protos.bin", "au-prior.bin", "au-text.bin", "au-labels.json", "credits.json",
              "credits-photos.tsv.gz"):
        p = os.path.join(SHIP, f)
        files[f] = {"bytes": size_of(p), "sha256": sha256(p)}
    pipe["built"] = time.strftime("%Y-%m-%d")
    json.dump(pipe, open(os.path.join(SHIP, "pipeline.json"), "w"), indent=1, ensure_ascii=False)
    print(f"pipeline.json: australia section + {len(files)} files; credits {cred}")

def tas_named_labels(au_labels, tas_labels):
    """The label table the app shows (decision 2026-11-05): a row that IS a
    Tasmanian label (`ship` = its labels.json row) takes that label's name,
    genus and family — the Understorey Network guide she opens is the
    reference, so the APC spelling (Bossiaea cinerea for UN's B. cordifolia,
    Callistemon pallidus for Melaleuca pallida, …) must not appear beside
    it, and genus sums inside Tasmania stay under today's genera. Its UN
    profile (`un`) comes along; the APC name is kept as `apc_name` when it
    differs. Other rows are unchanged. Returns (new rows, {field: changes})."""
    out, changed = [], {"name": 0, "genus": 0, "family": 0}
    for l in au_labels:
        l = dict(l)
        j = l.get("ship", -1)
        if j is not None and j >= 0:
            t = tas_labels[j]
            for k in ("name", "genus", "family"):
                if t.get(k) and t[k] != l.get(k):
                    changed[k] += 1
                    if k == "name":
                        l["apc_name"] = l.get("name")
                    l[k] = t[k]
            if t.get("un"):
                l["un"] = t["un"]
        out.append(l)
    return out, changed


def cmd_au_labels(a):
    """ship/au-labels.json + labels.json → the display table with the
    Tasmanian names on ship rows (`tas_named_labels`), written to --out
    (default cache/plantid/australia/au-labels-named.json; NOT into ship/:
    the staged pack and the Swift fixtures still use au-labels.json as is)."""
    j = json.load(open(os.path.join(SHIP, "au-labels.json")))
    tas = json.load(open(os.path.join(SHIP, "labels.json")))["labels"]
    j["labels"], changed = tas_named_labels(j["labels"], tas)
    j["note"] = j.get("note", "") + "; ship rows carry the Tasmanian label's name/genus/family (apc_name = the APC name)"
    out = a.out or os.path.join(CACHE, "australia", "au-labels-named.json")
    json.dump(j, open(out + ".part", "w"), ensure_ascii=False, separators=(",", ":"))
    os.replace(out + ".part", out)
    print(f"au labels with Tasmanian names: changed {changed} → {out}")


COMMON = os.path.join(CACHE, "australia", "common")
INAT_TAXA = "https://api.inaturalist.org/v1/taxa/"
AUSTRALIA_PLACE = 6744  # iNaturalist place id: preferred names as used in Australia


def cmd_au_common(a):
    """English common names for the Australia-wide classes that have none from
    the Understorey Network: every non-Tasmanian class, and the Tasmanian
    (ship) rows whose UN profile has no common name or that have no profile
    (Leo, 2026-11-06; a UN name, shown through `un`, always wins in the app):
    iNaturalist's preferred_common_name (locale en, place Australia) of each
    class's taxon ids, first id with a name wins. Facts only — the name
    string, nothing else. GET /v1/taxa/<≤30 ids>, ~1 req/s, one cache file per
    batch (resumable), User-Agent izzymap-plantid-eval/1. Writes `common`
    into ship/au-labels.json and its hash into pipeline.json."""
    import urllib.request
    os.makedirs(COMMON, exist_ok=True)
    path = os.path.join(SHIP, "au-labels.json")
    j = json.load(open(path))
    lab = j["labels"]
    plants = {p["id"]: p for p in json.load(open(os.path.join(HERE, "..", "..", "ios", "IzzyMap", "Resources",
                                                               "Data", "plants.json")))["plants"]}

    def wants(l):
        if l.get("ship", -1) < 0:
            return True
        return not any((plants.get(i) or {}).get("common") for i in (l.get("un") or {}).get("ids") or [])

    ids = sorted({t for l in lab if wants(l) for t in l.get("inat") or []})
    # every id already cached (any batch file) is read, only the rest fetched:
    # batches are named by their first/last id, so a new id list must not
    # re-key — and re-fetch — the whole cache
    names, fetched = {}, 0
    for f in sorted(os.listdir(COMMON)):
        if f.endswith(".json"):
            names.update(json.load(open(os.path.join(COMMON, f))))
    todo = [t for t in ids if str(t) not in names]
    batches = [todo[i:i + 30] for i in range(0, len(todo), 30)]
    t0 = time.time()
    for b in batches:
        f = os.path.join(COMMON, f"{b[0]}-{b[-1]}-{len(b)}.json")
        if not os.path.exists(f):
            url = INAT_TAXA + ",".join(map(str, b)) + f"?locale=en&preferred_place_id={AUSTRALIA_PLACE}&per_page=30"
            for attempt in range(5):
                try:
                    r = urllib.request.urlopen(urllib.request.Request(
                        url, headers={"User-Agent": "izzymap-plantid-eval/1", "Accept": "application/json"}), timeout=60)
                    d = json.load(r)
                    break
                except Exception as e:  # 429 / transient: back off
                    print(f"  {b[0]}…: {e}; retry", flush=True)
                    time.sleep(10 * (attempt + 1))
            else:
                sys.exit(f"iNaturalist taxa batch {b[0]}… failed 5 times (cache keeps the rest; re-run)")
            got = {str(x["id"]): x.get("preferred_common_name") for x in d.get("results", [])}
            json.dump({str(t): got.get(str(t)) for t in b}, open(f + ".part", "w"))
            os.replace(f + ".part", f)
            fetched += 1
            if fetched % 50 == 0:
                print(f"  {fetched} batches fetched ({time.time() - t0:.0f} s)", flush=True)
            time.sleep(1.0)
        names.update(json.load(open(f)))
    n = 0
    n_tas = 0
    for l in lab:
        l.pop("common", None)
        if not wants(l):
            continue
        for t in l.get("inat") or []:
            c = names.get(str(t))
            if c and c.strip():
                l["common"] = " ".join(c.split())
                n += 1
                n_tas += l.get("ship", -1) >= 0
                break
    other = sum(1 for l in lab if wants(l))
    json.dump(j, open(path + ".part", "w"), ensure_ascii=False, separators=(",", ":"))
    os.replace(path + ".part", path)
    pipe = json.load(open(os.path.join(SHIP, "pipeline.json")))
    pipe["files"]["au-labels.json"] = {"bytes": size_of(path), "sha256": sha256(path)}
    json.dump(pipe, open(os.path.join(SHIP, "pipeline.json"), "w"), indent=1, ensure_ascii=False)
    print(f"common names: {n:,} of {other:,} classes without a UN name ({n_tas:,} Tasmanian rows; "
          f"{len(ids):,} taxon ids, {len(batches)} batches, "
          f"{fetched} fetched now) → {path}")



# ------------------------------------------- single model v2 (train_v2.py)
#
# README "Single model (v2)": ONE trained head over the 22,122 classes
# (Tasmanian labels ∪ Australian natives; 19 twins merged), the location prior
# from iNat + ALA, and inside the Tasmania box the Tasmanian bank's kNN term
# with a re-tuned prior (tas_gap.py F5). Every parameter comes from the
# evaluation outputs of the chosen run (eval.json, ladder_v3.json,
# tas_gap.json); `v2` asserts they agree with each other and with V2_RUN.

V2DIR = os.path.join(CACHE, "australia", "v2")
V2_RUN = "final-cb50-s1"            # provenance "v2 K choice on the re-weighted val"
V2_TAU_NORM = 0.5                   # scale-kept τ-normalisation (eval_v2 / ladder_v3 env TAUNORM)
V2_PRIOR_SHIP = os.path.join(V2DIR, "prior-ship-inatall+ala-noinat.bin")   # built from ALL data (shipped)
V2_PRIOR_EVAL = os.path.join(V2DIR, "prior-eval-inatpool+ala-noinat.bin")  # leak-free (measuring only)
# tas_gap.py F5's prior term is its `Lv_pri[5.0]`: √counts, σ 5 km, α 16 (fixed in
# that script); ω and λ were chosen on A-val (tas_gap.json "F5 …" prm)
V2_TAS_PRIOR = {"transform": "sqrt", "sigma_km": 5.0, "alpha": 16.0}
V2_KNN_FLOOR = -30.0                # tas_gap F4/F5: ω · max(L_knn, −30)
V2_FILES = ("v2-head.bin", "v2-prior.bin", "v2-labels.json")
BUCKET_EDGES = (0, 10, 50)          # ladder_v3: 0 | 1–9 | 10–49 | 50+ training photos


def v2_bucket(n):
    n = np.asarray(n)
    return np.select([n == 0, n < 10, n < 50], [0, 1, 2], 3)


def v2_params():
    """The chosen run's parameters from the evaluation outputs (asserted
    consistent): prior + temperature (eval.json), ladder (ladder_v3.json),
    Tasmania-box add-on (tas_gap.json F5)."""
    ev = json.load(open(os.path.join(V2DIR, "eval.json")))
    lad = json.load(open(os.path.join(V2DIR, "ladder_v3.json")))
    tg = json.load(open(os.path.join(V2DIR, "tas_gap.json")))
    assert ev["final_run"] == V2_RUN and lad["run"] == V2_RUN and tg["run"] == V2_RUN, \
        (ev["final_run"], lad["run"], tg["run"])
    f5 = [v for k, v in tg.items() if k.startswith("F5")]
    assert len(f5) == 1, "tas_gap.json: one F5 row expected"
    steps = [json.loads(l) for l in open(os.path.join(V2DIR, "provenance-steps.jsonl"))]
    ladder_steps = [s for s in steps if s["step"] == "v2 ladder" and s["argv"][-1] == V2_RUN]
    assert ladder_steps and float(ladder_steps[-1]["env"].get("TAUNORM", 0)) == V2_TAU_NORM, "TAUNORM of the ladder step"
    pr, ch = ev["prior"], lad["chosen"]
    return {
        "temperature": float(ev["temperature"]),
        "lam": float(pr["lam"]),
        "prior": {"transform": pr["kind"], "sigma_km": float(pr["sigma"]), "alpha": float(pr["alpha"])},
        "tasmania": {"box": list(TAS_BOX), "omega": float(f5[0]["prm"]["om"]), "knn_floor": V2_KNN_FLOOR,
                     "lam": float(f5[0]["prm"]["lam"]), "prior": dict(V2_TAS_PRIOR), "bank": "bank-int8.bin",
                     "centre": "tas_centre (head.bin's centre: the bank's query space)"},
        "ladder": {"species": [float(x) for x in ch["s"]], "bucket_edges": list(BUCKET_EDGES),
                   "genus": float(ch["g"]), "image_floor": float(ch["f"]), "congener_ratio": float(ch["r"])},
    }


class V2Prior:
    """v2-prior.bin: DegPrior's grid + raw counts, plus the frequency vector of
    each count transform (f = (Σ_cells t(count) + 1) / Σ(…), computed over ALL
    22,122 classes as eval_v2 / ladder_v3 do)."""
    T = {"count": lambda c: c, "sqrt": np.sqrt, "log1p": np.log1p, "presence": np.ones_like}

    def __init__(self, path):
        self.h, a = read_blob(path)
        self.rowptr, self.sp = a["rowptr"], a["species"]
        self.raw = a["count"].astype(np.float64)
        self.freqs = {k[5:]: a[k].astype(np.float64) for k in a if k.startswith("freq_")}
        if not self.freqs:  # an eval prior (prior_v2.py output): compute them
            C = len(a["species_total"])
            for t in ("log1p", "sqrt"):
                tot = np.bincount(self.sp.astype(np.int64), self.T[t](self.raw), minlength=C) + 1.0
                self.freqs[t] = tot / tot.sum()

    def log_prior(self, lat, lon, transform, sigma, alpha):
        """log((K + α f) / (ΣK + α)); K = 0 (→ log f) without a location."""
        f = self.freqs[transform]
        if lat is None:
            return np.log(f)[None, :]
        P = DegPrior.__new__(DegPrior)
        P.h, P.rowptr, P.sp, P.cnt, P.freq = self.h, self.rowptr, self.sp, self.T[transform](self.raw), f
        K = P.density(lat, lon, sigma)
        return np.log((K + alpha * f[None]) / (K.sum(1, keepdims=True) + alpha))


class V2Ship:
    """The single model, from the shipped files only (the spec for the Swift
    side, IzzyKit PlantIDModel). emb = raw encoder output; lat/lon = None for
    no location. Returns (log p displayed, image-only log p, path)."""

    def __init__(self, d, prior=None):
        self.h, a = read_blob(os.path.join(d, "v2-head.bin"))
        self.sc = self.h["scoring"]
        self.W = a["weight"].astype(np.float32) * a["scale"].astype(np.float32)[:, None]
        self.b, self.mu = a["bias"].astype(np.float32), a["centre"].astype(np.float32)
        self.tmu, self.tcls = a["tas_centre"].astype(np.float32), a["tas_classes"].astype(np.int64)
        self.prior = V2Prior(prior or os.path.join(d, "v2-prior.bin"))
        self.bh, ba = read_blob(os.path.join(d, self.sc["tasmania"]["bank"]))
        self.B, self.bl, self.bs = ba["vectors"], ba["labels"], ba["scale"].astype(np.float32)
        lab = json.load(open(os.path.join(d, "v2-labels.json")))["labels"]
        gn = {}
        self.genus = np.array([gn.setdefault(l["genus"], len(gn)) for l in lab])
        self.gnames = list(gn)
        self.photos = np.array([l["photos"] for l in lab])
        self.C = len(lab)

    def logp(self, emb, lat=None, lon=None, box=True):
        """box=False: the Australia-wide path everywhere (as eval_v2 measured it)."""
        e = np.asarray(emb, np.float32)
        q = unit(unit(e) - self.mu[None]).astype(np.float32)
        Lh = log_softmax(q @ self.W.T + self.b[None])
        T, s = self.sc["temperature"], self.sc
        if lat is None or not box:
            tas = np.zeros(len(e), bool)
        else:
            tas = in_tas(lat, lon)
        pm = s["prior"]
        Lp = self.prior.log_prior(lat, lon, pm["transform"], pm["sigma_km"], pm["alpha"])
        L = log_softmax(log_softmax(Lh + s["lam"] * Lp) / T)
        Limg = log_softmax(Lh / T)
        if tas.any():
            t = s["tasmania"]
            i = np.nonzero(tas)[0]
            qs = unit(unit(e[i]) - self.tmu[None]).astype(np.float32)
            p = self.bh["scoring"]
            sims, idx = knn_neighbours(qs, self.B, self.bs, p["k"])
            nb = len(self.tcls)
            Lk = np.full((len(i), self.C), -1e4, np.float32)
            Lk[:, self.tcls] = log_softmax(p["knn_temp"] * knn_vote(sims, idx, self.bl, nb, p["k"], p["tau"]))
            Li = log_softmax(Lh[i] + t["omega"] * np.maximum(Lk, t["knn_floor"]))
            tp = t["prior"]
            Lpt = self.prior.log_prior(np.asarray(lat)[i], np.asarray(lon)[i], tp["transform"], tp["sigma_km"], tp["alpha"])
            L[i] = log_softmax(log_softmax(Li + t["lam"] * Lpt) / T)
            Limg[i] = log_softmax(Li / T)
        return L, Limg, np.where(tas, "tasmania", "australia")

    def ladder(self, lp, lpi):
        """ladder_v3 on one photo's displayed log p (lp) and image-only log p (lpi)."""
        lad = self.sc["ladder"]
        p = np.exp(lp)
        o = np.argsort(-p)
        n1, n2 = int(o[0]), int(o[1])
        thr = lad["species"][int(v2_bucket(self.photos[n1]))]
        close = lad["congener_ratio"] < 1 and self.genus[n1] == self.genus[n2] and p[n2] >= lad["congener_ratio"] * p[n1]
        if p[n1] >= thr and np.exp(lpi[n1]) >= lad["image_floor"] and not close:
            return {"kind": "species", "label": n1, "p": float(p[n1]), "threshold": thr}
        gp = np.bincount(self.genus, p, minlength=len(self.gnames))
        g = int(gp.argmax())
        if gp[g] >= lad["genus"]:
            top = [int(u) for u in o if self.genus[u] == g][:3]
            return {"kind": "genus", "genus": self.gnames[g], "p": float(gp[g]), "top": top}
        return {"kind": "notSure"}


def v2_labels(run_photos, merge):
    """The display table (22,122 rows, the head's order): ship/au-labels.json
    (names, families, iNat ids, common names from `au-common`, UN profiles)
    with the Tasmanian names on Tasmanian rows (tas_named_labels), the run's
    training-photo counts after merges (the ladder's buckets), merged twins
    marked `merged_into`."""
    j = json.load(open(os.path.join(SHIP, "au-labels.json")))
    tas = json.load(open(os.path.join(SHIP, "labels.json")))["labels"]
    rows, changed = tas_named_labels(j["labels"], tas)
    U = pq.read_table(os.path.join(CACHE, "australia", "labels.parquet"), columns=["name", "genus", "native"]).to_pydict()
    assert len(rows) == len(U["name"]) == len(run_photos)
    out = []
    for u, l in enumerate(rows):
        assert (l.get("apc_name") or l["name"]) == U["name"][u], (u, l["name"], U["name"][u])
        r = {"name": l["name"], "genus": l["genus"], "family": l.get("family")}
        for k in ("common", "apc_name", "un"):
            if l.get(k):
                r[k] = l[k]
        if l.get("inat"):
            r["inat"] = int(l["inat"][0])
        if l.get("ship", -1) >= 0:
            r["ship"] = int(l["ship"])
        r["native"] = bool(l.get("native"))
        r["photos"] = int(run_photos[u])
        if u in merge:
            r["merged_into"] = int(merge[u])
        out.append(r)
    return out, changed


def v2_credits(pid, src, observers, sheets=False):
    """credits.json (old shape + `sources`) and credits-photos.tsv.gz for EVERY
    training photo of the run's data (data-final.npz pid/src): the iNat
    open-data photos (plan train ∪ the Tasmanian run's; logins from the
    observers table), the extras (iNat incl. SA/ND: their own login column;
    ALA incl. APII and Wikimedia Commons: creator + provider)."""
    import re
    tags = re.compile(r"<[^>]+>")
    rows = []  # (source, id, login, name, licence, attribution)
    base = set(int(p) for p in pid[src == 0])
    seen = set()
    obs = {}
    for f, cols in ((os.path.join(CACHE, "australia", "plan", "train.parquet"), ["photo_id", "observer_id", "license"]),
                    (os.path.join(CACHE, "sets", "train.parquet"), ["photo_id", "observer_id", "license"])):
        t = pq.read_table(f, columns=cols).to_pydict()
        for p, o, lic in zip(t["photo_id"], t["observer_id"], t["license"]):
            p = int(p)
            if p in base and p not in seen:
                seen.add(p)
                obs[p] = (int(o), lic)
    assert len(obs) == len(base), f"credits: {len(base) - len(obs)} base photos without an observer"
    # r2: the rare species' held-out photos (rare_heldout.py; iNat open data, observer ids → logins)
    rare = {}
    rp = os.path.join(CACHE, "rare_heldout", "extras.parquet")
    if os.path.exists(rp):
        t = pq.read_table(rp, columns=["photo_id", "observer_id", "licence"]).to_pydict()
        rare = {int(p): (int(o), lic) for p, o, lic in zip(t["photo_id"], t["observer_id"], t["licence"])}
    want = {o for o, _ in obs.values()} | {o for o, _ in rare.values()}
    logins = {}
    with gzip.open(observers, "rt") as f:
        next(f)
        for line in f:
            i, login, *name = line.rstrip("\n").split("\t")
            if int(i) in want:
                logins[int(i)] = (login, name[0] if name else "")
    for p, (o, lic) in obs.items():
        lg, nm = logins.get(o, ("?", ""))
        rows.append(("inat", str(p), lg, nm, lic, ""))
    extra = set(int(p) for p in pid[src == 1])
    k = pq.read_table(os.path.join(CACHE, "extra", "extra_photos_k1000.parquet"),
                      columns=["photo_id", "login", "observer_name", "licence", "source"]).to_pydict()
    for p, lg, nm, lic, s in zip(k["photo_id"], k["login"], k["observer_name"], k["licence"], k["source"]):
        if int(p) in extra:
            extra.discard(int(p))
            rows.append(("inat", str(p), lg or "?", nm or "", lic, ""))
    for p, (o, lic) in rare.items():
        if p in extra:
            extra.discard(p)
            lg, nm = logins.get(o, ("?", ""))
            rows.append(("inat", str(p), lg, nm, lic, ""))
    s = pq.read_table(os.path.join(CACHE, "extra", "extra_photos_src.parquet"),
                      columns=["photo_id", "image_id", "source", "login", "licence", "attribution", "dr_name"]).to_pydict()
    for p, iid, so, lg, lic, att, dr in zip(s["photo_id"], s["image_id"], s["source"], s["login"], s["licence"],
                                            s["attribution"], s["dr_name"]):
        if int(p) in extra:
            extra.discard(int(p))
            who = " ".join(tags.sub("", lg or "").split())
            rows.append(("commons" if so == "commons" else "ala", str(iid), who or dr, dr, lic,
                         " ".join(tags.sub("", att or "").split())))
    assert not extra, f"credits: {len(extra)} extra photos without a source row"
    assert len(rows) == len(pid), (len(rows), len(pid))
    n_photos = len(rows)
    if sheets:  # herbarium sheets behind the photo-less classes' rows (sheet_rows.py; not training photos)
        hb = os.path.join(CACHE, "herbarium")
        emb_ids = set(np.load(os.path.join(hb, "emb-gbif.npz"))["image_id"].tolist())
        for f in sorted(glob.glob(os.path.join(hb, "recs-gbif", "*.json"))):
            d_ = json.load(open(f))
            if not isinstance(sheets, bool) and d_["u"] not in sheets:
                continue  # only the classes whose rows the sheets actually set
            for im in d_["images"]:
                if im["image_id"] in emb_ids:
                    inst = im.get("inst") or "?"
                    rows.append(("herbarium", f"gbif:{im['occ']}", inst, im.get("dataset") or inst,
                                 im["license"], f"GBIF occurrence {im['occ']} ({im.get('dataset') or inst})"))
    with gzip.open(os.path.join(SHIP, "credits-photos.tsv.gz"), "wt") as f:
        f.write("photo_id\tobserver_login\tlicense\tsource\tattribution\n")
        for so, i, lg, _, lic, att in sorted(rows, key=lambda r: (r[0], r[1])):
            f.write(f"{i}\t{lg}\t{lic}\t{so}\t{att}\n")
    per, names, lic_tot, by_src = {}, {}, {}, {}
    for so, _, lg, nm, lic, _ in rows:
        key = (so if so != "inat" else "inat", lg)
        d = per.setdefault(key, {})
        d[lic] = d.get(lic, 0) + 1
        names[key] = nm
        lic_tot[lic] = lic_tot.get(lic, 0) + 1
        b = by_src.setdefault(so, {"photos": 0, "licences": {}})
        b["photos"] += 1
        b["licences"][lic] = b["licences"].get(lic, 0) + 1
    for so in by_src:
        by_src[so]["credited"] = sum(1 for k_ in per if k_[0] == so)
    obs_rows = sorted(([k_[1], names[k_] if k_[0] == "inat" else (names[k_] if names[k_] != k_[1] else None),
                        sum(d.values()), d, k_[0]] for k_, d in per.items()), key=lambda r: (-r[2], r[0].lower()))
    json.dump({"version": 1,
               "about": "The plant-ID model was trained on these photos: the iNaturalist Open Dataset (2026-10 "
                        "snapshot, research grade and more photos of the same observations, incl. CC BY-SA / "
                        "BY-ND / BY-NC-SA / BY-NC-ND), field photos from the Atlas of Living Australia (incl. "
                        "the Australian Plant Image Index, Australian National Botanic Gardens) and Wikimedia "
                        "Commons. Each photo © its creator, under the licence listed. CC BY-NC binds IzzyMap to "
                        "non-commercial use. Per-photo list: credits-photos.tsv.gz (iNat photo page "
                        "https://www.inaturalist.org/photos/<id>; ALA image https://images.ala.org.au/image/<id>; "
                        "Commons page id)." + (" Rows of species without training photos also use herbarium "
                        "specimen images via GBIF (source \"herbarium\"; CC/PD media, one per specimen; "
                        "https://www.gbif.org/occurrence/<id>)." if sheets else ""),
               "photos": n_photos, "licences": lic_tot, "sources": by_src,
               "observers": [{"login": r[0], **({"name": r[1]} if r[1] else {}), "photos": r[2], "licences": r[3],
                              **({"source": r[4]} if r[4] != "inat" else {})} for r in obs_rows]},
              open(os.path.join(SHIP, "credits.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    return {"photos": len(rows), "credited": len(per), "missing_logins": len(want - logins.keys()),
            "sources": {k_: {"photos": v["photos"], "credited": v["credited"]} for k_, v in by_src.items()},
            "licences": lic_tot}


def cmd_v2(a):
    """The single model's pack files (V2_RUN) → ship/: v2-head.bin (int8 rows ×
    per-row scale, bias, centres, the Tasmanian bank's class map, every scoring
    parameter + the ladder in its header), v2-prior.bin, v2-labels.json, the
    credits of every training photo, pipeline.json "v2" + provenance. Then
    checks the WRITTEN files (V2Ship) against the evaluation's numbers with
    the leak-free eval prior. Env: the eval env (train_v2/eval_v2's;
    V2DATA=…/data-final.npz)."""
    sys.path.insert(0, HERE)
    import train_v2 as V
    assert os.path.abspath(V.DATA) == os.path.abspath(os.path.join(V2DIR, "data-final.npz")), \
        f"V2DATA must be data-final.npz (is {V.DATA})"
    prm = v2_params()
    z = np.load(os.path.join(V2DIR, "runs", V2_RUN + ".npz"))
    W, b, n_c = z["W"].astype(np.float32), z["b"].astype(np.float32), z["n_c"].astype(np.int64)
    nr = np.linalg.norm(W, axis=1, keepdims=True).clip(1e-6)
    W = W * (nr.mean() / nr) ** V2_TAU_NORM  # baked in (scale kept: mean norm unchanged)
    D = np.load(V.DATA, mmap_mode="r")
    mf, mt = D["merge_from"].astype(np.int64), D["merge_to"].astype(np.int64)
    if a.check_only:
        b = b.copy()
        b[mf] = -1e4
        return v2_check(W, b)
    ev = json.load(open(os.path.join(V2DIR, "eval.json")))
    merge = dict(zip(mf.tolist(), mt.tolist()))
    assert merge == {int(k): int(v) for k, v in ev["merged_classes"].items()}, "merges differ from eval.json"
    for f_, t_ in merge.items():
        n_c[t_] += n_c[f_]
        n_c[f_] = 0
    b = b.copy()
    b[mf] = -1e4  # eval's column mask, baked into the bias
    C = len(W)
    q8, sc8 = int8_rows(W)
    labels, changed = v2_labels(n_c, merge)
    ship_h, ship_a = read_blob(os.path.join(SHIP, "head.bin"))
    tas_lab = json.load(open(os.path.join(SHIP, "labels.json")))["labels"]
    mapv = np.arange(C)
    mapv[mf] = mt
    s2u = np.full(len(tas_lab), -1, np.int64)
    for u, l in enumerate(json.load(open(os.path.join(SHIP, "au-labels.json")))["labels"]):
        if l.get("ship", -1) >= 0:
            assert s2u[l["ship"]] < 0
            s2u[l["ship"]] = mapv[u]
    assert (s2u >= 0).all(), "every Tasmanian label maps to a class"
    hdr = {"kind": "plantid-head-v2", "version": 1, "labels": C, "run": V2_RUN,
           "variant": "int8 per-row (scale = max|w|/127)", "tau_norm": V2_TAU_NORM,
           "scoring": prm,
           "recipe": [
               "q = normalise(normalise(embedding) − centre)",
               "L_head = log_softmax(scale ⊙ (weight · q) + bias)   (merged twins: bias −1e4)",
               "prior(t, σ, α) = log((K + α f_t) / (ΣK + α)), K[c] = Σ_cells t(count)·exp(−d²/2σ²) (v2-prior.bin, "
               "DegPrior's grid; f_t = v2-prior freq_<t>); no location: K = 0 → log f_t",
               "outside the Tasmania box or without a location: L = log_softmax(log_softmax(L_head + lam · "
               "prior(prior.transform, prior.sigma_km, prior.alpha)) / temperature)",
               "inside the box [W, S, E, N]: q_t = normalise(normalise(embedding) − tas_centre); L_knn over "
               "bank-int8.bin exactly as the Tasmanian scorer (k, tau, knn_temp from its header; C = its 2,675 "
               "labels), placed at columns tas_classes (others −1e4; repeated column: the last wins); L_img = "
               "log_softmax(L_head + omega · max(L_knn, knn_floor)); L = log_softmax(log_softmax(L_img + "
               "tasmania.lam · prior(tasmania.prior…)) / temperature)",
               "image-only (the ladder's floor): log_softmax(L_head or L_img / temperature)",
               "ladder (ladder_v3): named = argmax L; species if p[named] ≥ species[bucket(photos[named])] "
               "(bucket edges 0 | 1–9 | 10–49 | 50+), image-only p[named] ≥ image_floor and not close congeners "
               "(congener_ratio < 1: top-2 share a genus and p2 ≥ ratio · p1); else genus (v2-labels genus) "
               "with summed p ≥ genus → that genus + its top 3; else not sure"]}
    write_blob(os.path.join(SHIP, "v2-head.bin"), hdr,
               {"weight": q8, "scale": sc8.astype(np.float32), "bias": b.astype(np.float32),
                "centre": np.asarray(D["mu"], np.float32), "tas_centre": ship_a["centre"].astype(np.float32),
                "tas_classes": s2u.astype(np.int32)})
    # prior: the shipped (all-data) counts + each transform's frequency over all classes
    ph, pa = read_blob(V2_PRIOR_SHIP)
    assert len(pa["species_total"]) == C
    raw = pa["count"].astype(np.float64)
    freqs = {}
    for t in ("log1p", "sqrt"):
        tot = np.bincount(pa["species"].astype(np.int64), V2Prior.T[t](raw), minlength=C) + 1.0
        freqs["freq_" + t] = tot / tot.sum()
    ph2 = {k: v for k, v in ph.items() if k != "arrays"}
    ph2.update({"sigma_km": prm["prior"]["sigma_km"], "alpha": prm["prior"]["alpha"],
                "source_file": os.path.basename(V2_PRIOR_SHIP), "transforms": ["log1p", "sqrt"],
                "freq": "freq_<t> = (bincount(species, t(count)) + 1) / Σ, over all classes (float64)"})
    write_blob(os.path.join(SHIP, "v2-prior.bin"), ph2,
               {"rowptr": pa["rowptr"], "species": pa["species"], "count": pa["count"],
                "species_total": pa["species_total"], **freqs})
    lj = {"version": 1, "model": HF, "run": V2_RUN, "count": C,
          "note": "index = row of v2-head.bin / class id of v2-prior.bin; ship = row of the Tasmanian labels.json "
                  "(un = its Understorey Network profile); photos = training photos after merges (the ladder's "
                  "bucket); merged_into = a twin merged at training (never shown); apc_name = the APC name "
                  "where the Tasmanian label's spelling is shown instead",
          "labels": labels}
    json.dump(lj, open(os.path.join(SHIP, "v2-labels.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    print(f"v2: head {C:,} × {W.shape[1]} int8, prior {len(pa['species']):,} pairs, labels (Tasmanian names: "
          f"{changed}), {int((n_c > 0).sum()):,} classes with photos")
    cred = v2_credits(np.asarray(D["pid"]), np.asarray(D["src"]), a.observers)
    print(f"credits: {cred}")
    # pipeline.json: the single model only (the Tasmanian scorer's tables are gone from the pack;
    # its bank stays: the Tasmania-box term)
    pp = os.path.join(SHIP, "pipeline.json")
    pipe = json.load(open(pp))
    for k in ("australia", "labels", "head", "prior", "bank_default", "banks", "steps", "ladder"):
        pipe.pop(k, None)
    if isinstance(pipe.get("model"), str):
        pipe["encoder_model"] = pipe.pop("model")
    pipe["v2"] = {"built": time.strftime("%Y-%m-%d"), "run": V2_RUN, "files": list(V2_FILES),
                  "classes": C, "classes_with_photos": int((n_c > 0).sum()), "merged": len(merge),
                  "scoring": prm, "recipe": hdr["recipe"], "credits": cred,
                  "note": "v2-head/v2-prior/v2-labels + bank-int8.bin (Tasmania box) + the encoder; "
                          "build_ship.V2Ship is the reference scorer"}
    keep = set(V2_FILES) | {"bank-int8.bin", "credits.json", "credits-photos.tsv.gz"}
    pipe["files"] = {f: v for f, v in pipe["files"].items() if f in keep}
    for f in V2_FILES + ("credits.json", "credits-photos.tsv.gz"):
        p = os.path.join(SHIP, f)
        pipe["files"][f] = {"bytes": size_of(p), "sha256": sha256(p)}
    pipe["built"] = time.strftime("%Y-%m-%d")
    json.dump(pipe, open(pp, "w"), indent=1, ensure_ascii=False)
    import provenance as PV
    PV.record("v2 ship", inputs=[os.path.join(V2DIR, "runs", V2_RUN + ".npz"), V2_PRIOR_SHIP, V.DATA,
                                 os.path.join(V2DIR, "eval.json"), os.path.join(V2DIR, "ladder_v3.json"),
                                 os.path.join(V2DIR, "tas_gap.json"), os.path.join(SHIP, "au-labels.json"),
                                 os.path.join(SHIP, "labels.json"), os.path.join(SHIP, "head.bin")],
              outputs=[os.path.join(SHIP, f) for f in V2_FILES + ("credits.json", "credits-photos.tsv.gz")],
              extra={"run": V2_RUN, "scoring": prm})
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "provenance.py"), "section"], check=True)
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "provenance.py"), "ship"], check=True)
    # the compact identity the app shows (Diagnostics, Model & training photos)
    pipe = json.load(open(pp))
    g = pipe["provenance"]["git"]
    lad = prm["ladder"]
    pipe["model"] = {"id": V2_RUN, "git": g["commit"][:10], "git_clean": bool(g.get("plantid_clean")),
                     "built": pipe["built"], "classes": C, "classes_with_photos": int((n_c > 0).sum()),
                     "encoder": "BioCLIP 2.5 ViT-H/14, 8-bit (w8)",
                     "summary": f"T {prm['temperature']:.2f} · prior {prm['prior']['transform']} σ "
                                f"{prm['prior']['sigma_km']:g} km λ {prm['lam']:g} · ladder species "
                                f"{'/'.join(f'{x:g}' for x in lad['species'])} genus {lad['genus']:g} · "
                                f"Tasmania kNN ω {prm['tasmania']['omega']:g}"}
    json.dump(pipe, open(pp, "w"), indent=1, ensure_ascii=False)
    print(f"model: {pipe['model']}")
    if not a.no_check:
        v2_check(W, b)


def v2_check(W_fp32, b):
    """The written files against the evaluation (leak-free eval prior): A-test
    natural top-1 of tas_gap F5 (Tasmania-box path), the main path's top-1
    and ladder_v3's species rate on AU-test; int8 vs fp32 head agreement."""
    import eval_v2 as E2
    import train_v2 as V
    D, U, genus, euc, sets, ship, ash = E2.load_sets()
    sh = V2Ship(SHIP, prior=V2_PRIOR_EVAL)
    mapv = np.arange(sh.C)
    mf = np.asarray(np.load(V.DATA, mmap_mode="r")["merge_from"], np.int64)
    mapv[mf] = np.asarray(np.load(V.DATA, mmap_mode="r")["merge_to"], np.int64)
    res = {}
    rep = json.load(open(os.path.join(V2DIR, "eval.json")))["report"]["final"]
    for nm, n_max in (("A-test", None), ("AU-test", 12000)):
        S = sets[nm]
        n = S.n if n_max is None else min(S.n, n_max)
        y = np.where(S.y[:n] >= 0, mapv[np.maximum(S.y[:n], 0)], -1)
        w = S.w[:n]
        inl = y >= 0
        for box in (False, True):
            pred, kinds, path = [], [], []
            for i in range(0, n, 1024):
                j = slice(i, min(i + 1024, n))
                l_, li_, p_ = sh.logp(S.emb[j].astype(np.float32), S.lat[j], S.lon[j], box=box)
                pred.append(l_.argmax(1))
                path.append(p_)
                kinds += [sh.ladder(l_[k], li_[k])["kind"] for k in range(len(l_))]
            pred, path, kinds = np.concatenate(pred), np.concatenate(path), np.array(kinds)
            hit = (pred == y) & inl
            res[f"{nm} {'box' if box else 'main'}"] = {
                "n": int(n), "top1_nat": round(float((hit * w)[inl].sum() / w[inl].sum()), 4),
                "in_box": int((path == "tasmania").sum()),
                "species_answers": round(float((kinds == "species").mean()), 4),
                "species_wrong_nat": round(float((((kinds == "species") & ~hit) * w)[inl].sum() / w[inl].sum()), 4)}
    res["expect"] = {"A-test main top1_nat (eval.json final)": round(rep["A-test"]["top1_w"], 4),
                     "A-test box top1_nat (tas_gap F5)": 0.9479,
                     "AU-test main top1_nat (eval.json final, all photos)": round(rep.get("AU-test", {}).get("top1_w", float("nan")), 4)}
    # int8 vs fp32 head on AU-test embeddings (head + bias only)
    e = sets["AU-test"].emb[:4000].astype(np.float32)
    q = unit(unit(e) - sh.mu[None])
    a8, a32 = q @ sh.W.T + sh.b, q @ W_fp32.T + b
    res["int8_vs_fp32"] = {"top1_agree": round(float((a8.argmax(1) == a32.argmax(1)).mean()), 5),
                           "max_abs_logit_diff": round(float(np.abs(a8 - a32).max()), 4)}
    print("v2 check:", json.dumps(res, indent=1))
    json.dump(res, open(os.path.join(SHIP, "v2-check.json"), "w"), indent=1)


# ------------------------------------------- final configuration v3 (final_sweep.py)
#
# README "Final configuration (v3): shipping": the final sweep's choice
# `mpA01|adaptive|box` — the MEAN of two multi-prototype heads (head_capacity.py
# mproto "mpAc", seeds 0 and 1: adaptive K per class, logsumexp pooling with the
# log K correction), the adaptive-bandwidth prior (prior_adaptive.py F2) everywhere
# (no separate Tasmania-box prior), and inside the Tasmania box the Tasmanian
# bank's kNN at ω 3 with a SOFT floor. Every number is read from the sweep's
# outputs: refine.json (cfg), calib.json (T, ladder); test.json holds the report
# numbers the check of the written files must reproduce. Same 22,122 classes,
# merges and training photos as v2 (asserted) → v2-labels.json and the credits stay.

V3_CFG = "mpA01|adaptive|box"
V3_ID = os.environ.get("V3_ID", "final-mpA01-adaptive")
# Release r2 (2026-11-07/08): heads retrained on data-final2.npz (+ the rare species' held-out
# photos, rare_heldout.py) with herbarium-sheet rows for photo-less classes (sheet_rows.py).
# V3_R2=1 → data-final2.npz, counts/labels/credits rebuilt from it, sweep caches from
# BA_WORK / FS_WORK / FS_HCR (bank_analysis2, final_sweep3, hc_sheets_r2).
V3_R2 = bool(os.environ.get("V3_R2"))
V3_FILES = ("v3-head.bin", "v3-prior.bin", "v2-labels.json")
# THE no-location switch: "australia" = no bank, prior K = 0 (the country-wide
# frequency; as v2); "tasmania" = a photo without a location is scored as inside
# the Tasmania box (bank term on, prior still K = 0). Read by the app from
# scoring.no_location — flip here and rebuild the pack.
V3_NO_LOCATION = "australia"
V3_HEADS_GCS = os.environ.get("V3_HEADS_GCS", "gs://leo-superresolution-izzy-plantid/au/hc/runs/")


def v3_sweep():
    """(final_sweep module, cfg, calib row, test row) of V3_CFG, asserted consistent."""
    sys.path.insert(0, HERE)
    import final_sweep as FSW
    ref = json.load(open(os.path.join(FSW.FS, "refine.json")))[V3_CFG]
    cal = json.load(open(os.path.join(FSW.FS, "calib.json")))[V3_CFG]
    te = json.load(open(os.path.join(FSW.FS, "test.json")))[V3_CFG]
    c = ref["cfg"]
    assert FSW.cfg_name(c) == V3_CFG and c["ens"] == "mpA01" and c["prior"] == "adaptive" and not c["nat"], c
    assert te["cfg"] == c and te["T"] == cal["T"] and te["ladder"] == cal["ladder"], "test.json ≠ refine.json / calib.json"
    return FSW, c, cal, te


def v3_params():
    """The scoring block (v3-head.bin header `scoring`, pipeline.json v3.scoring)."""
    import ladder_v3 as L3
    import prior_adaptive as PA
    FSW, c, cal, _ = v3_sweep()
    probe = np.array([0, 1, 9, 10, 49, 50, 4000])
    assert (L3.bucket(probe) == v2_bucket(probe)).all(), "ladder_v3 buckets ≠ BUCKET_EDGES"
    lad = cal["ladder"]
    F2 = dict(FSW.F2)
    return {
        "temperature": float(cal["T"]),
        "image_temperature": float(c["t"]),
        "combine": "mean of the heads' logits",
        "tau_norm": float(c["tn"]),
        "lam": float(c["lam"]),
        "prior": {"kind": "adaptive", "transform": F2["t"], "file": "v3-prior.bin",
                  "fit": {**F2, "steps_per_octave": PA.STEPS}},
        "tasmania": {"box": list(TAS_BOX), "omega": float(c["om_b"]), "knn_floor": float(c["fl_b"]),
                     "bank": "bank-int8.bin", "centre": "tas_centre (head.bin's centre: the bank's query space)"},
        "no_location": V3_NO_LOCATION,
        "ladder": {"species": [float(x) for x in lad["s"]], "bucket_edges": list(BUCKET_EDGES),
                   "genus": float(lad["g"]), "image_floor": float(lad["f"]), "congener_ratio": float(lad["r"])},
    }


def v3_row0(Kc):
    """First prototype row of every class in head_capacity.mp_blocks' layout (rows
    grouped by K, then class ascending, then slot: a class's K rows are contiguous)."""
    Kc = np.asarray(Kc, np.int64)
    row0, a = np.zeros(len(Kc), np.int64), 0
    for K in sorted(np.unique(Kc)):
        cls = np.nonzero(Kc == K)[0]
        row0[cls] = a + K * np.arange(len(cls))
        a += K * len(cls)
    return row0


def v3_load_head(path, tn):
    """A head_capacity mproto run → (W fp32 with mp_taunorm baked (R × D), b, Kc, row0, pool T, n_c, cfg)."""
    z = np.load(path)
    assert "Kc" in z.files and not int(z["tn_applied"]), f"{path}: not an un-normed mproto head"
    Kc = z["Kc"].astype(np.int64)
    row0 = v3_row0(Kc)
    W = z["W"].astype(np.float32)
    assert len(W) == int(Kc.sum())
    slot = np.arange(len(W)) - np.repeat(np.cumsum(Kc) - Kc, Kc)       # 0 … K_c − 1 within each class
    row_cls = np.empty(len(W), np.int64)
    row_cls[np.repeat(row0, Kc) + slot] = np.repeat(np.arange(len(Kc)), Kc)
    assert np.array_equal(np.sort(np.repeat(row0, Kc) + slot), np.arange(len(W))), "layout isn't a partition of the rows"
    # head_capacity.mp_taunorm (scale-kept τ-norm on the per-class mean prototype norm), in numpy
    nr = np.linalg.norm(W, axis=1)
    cn = np.maximum(np.bincount(row_cls, nr, minlength=len(Kc)) / Kc, 1e-6)
    W = W * ((cn.mean() / cn) ** tn)[row_cls][:, None].astype(np.float32)
    cfg = json.loads(str(z["meta"]))["cfg"]
    return W, z["b"].astype(np.float32), Kc, row0, float(z["T"]), z["n_c"].astype(np.int64), cfg


def int8_rows32(X):
    """Per-row symmetric int8 with a float32 scale (max|x|/127)."""
    X = np.asarray(X, np.float32)
    scale = (np.maximum(np.abs(X).max(1), 1e-12) / np.float32(127.0)).astype(np.float32)
    return np.clip(np.round(X / scale[:, None]), -127, 127).astype(np.int8), scale


def v3_sigma_codes(prior_path, fit):
    """prior_adaptive's balloon σ per grid cell, as codes k: σ = smin · 2^(k/STEPS)."""
    import prior_adaptive as PA
    P = PA.AdaptivePrior(prior_path)
    sm = P.sigma_map(fit)
    code = np.round(np.log2(sm / fit["smin"]) * PA.STEPS).astype(np.int64)
    assert np.allclose(fit["smin"] * 2.0 ** (code / PA.STEPS), sm) and code.min() >= 0 and code.max() < 256
    rho0 = float(np.median(P.rho(fit["srho"])[P.tot > 0]))
    return code.astype(np.uint8), rho0


class V3Prior(V2Prior):
    """v3-prior.bin: v2-prior.bin's arrays (the same counts and freq_<t>) plus the
    adaptive kernel per grid cell — sigma_code (ny × nx uint8; row iy, column ix as
    the counts) indexing sigma_km / alpha (float64 per code). At a point: its cell
    (iy, ix clipped to the grid) → (σ, α), then V2Prior's kernel sum and
    shrinkage. `sigma` = (code, sigma_km, alpha) overrides the file's (the check
    scores the leak-free eval counts with their own raster)."""

    def __init__(self, path, sigma=None):
        super().__init__(path)
        if sigma is None:
            a = read_blob(path)[1]
            sigma = (a["sigma_code"], a["sigma_km"], a["alpha"])
        self.code = np.asarray(sigma[0])
        self.sig, self.alp = np.asarray(sigma[1], np.float64), np.asarray(sigma[2], np.float64)
        assert self.code.shape == (self.h["ny"], self.h["nx"]) and int(self.code.max()) < len(self.sig)
        self.tcnt = {}

    def kernel(self, lat, lon):
        h = self.h
        lat, lon = np.asarray(lat, float), np.asarray(lon, float)
        iy = np.clip(np.floor((lat - h["lat0"]) / h["cell_deg"]).astype(np.int64), 0, h["ny"] - 1)
        ix = np.clip(np.floor((lon - h["lon0"]) / h["cell_deg"]).astype(np.int64), 0, h["nx"] - 1)
        return self.code[iy, ix].astype(np.int64)

    def log_prior(self, lat, lon, transform):
        f = self.freqs[transform]
        if lat is None:
            return np.log(f)[None, :]
        lat, lon = np.asarray(lat, float), np.asarray(lon, float)
        if transform not in self.tcnt:
            self.tcnt[transform] = self.T[transform](self.raw)
        P = DegPrior.__new__(DegPrior)
        P.h, P.rowptr, P.sp, P.cnt, P.freq = self.h, self.rowptr, self.sp, self.tcnt[transform], f
        k = self.kernel(lat, lon)
        out = np.zeros((len(lat), len(f)), np.float32)
        for c in np.unique(k):
            i = np.nonzero(k == c)[0]
            s, a = float(self.sig[c]), float(self.alp[c])
            K = P.density(lat[i], lon[i], s)
            out[i] = np.log((K + a * f[None]) / (K.sum(1, keepdims=True) + a))
        return out


class V3Ship:
    """The final configuration from the shipped files only (the spec for the
    Swift side, IzzyKit PlantIDModel). emb = raw encoder output; lat/lon = None
    for no location. Returns (log p displayed, image-only log p, path)."""

    def __init__(self, d, prior=None):
        self.h, a = read_blob(os.path.join(d, "v3-head.bin"))
        self.sc = self.h["scoring"]
        self.mu, self.tmu = a["centre"].astype(np.float32), a["tas_centre"].astype(np.float32)
        self.tcls = a["tas_classes"].astype(np.int64)
        self.heads = []
        for j, hh in enumerate(self.h["heads"]):
            r0, r1 = hh["rows"]
            W = a["weight"][r0:r1].astype(np.float32) * a["scale"][r0:r1].astype(np.float32)[:, None]
            kc, row0 = a["kc"][j].astype(np.int64), a["row0"][j].astype(np.int64) - r0
            groups = [(int(K), np.nonzero(kc == K)[0]) for K in np.unique(kc)]
            groups = [(K, cls, row0[cls][:, None] + np.arange(K)[None]) for K, cls in groups]
            self.heads.append((W, a["bias"][j].astype(np.float32), groups, float(hh["pool_temperature"])))
        self.prior = prior or V3Prior(os.path.join(d, self.sc["prior"]["file"]))
        self.bh, ba = read_blob(os.path.join(d, self.sc["tasmania"]["bank"]))
        self.B, self.bl, self.bs = ba["vectors"], ba["labels"], ba["scale"].astype(np.float32)
        lab = json.load(open(os.path.join(d, "v2-labels.json")))["labels"]
        gn = {}
        self.genus = np.array([gn.setdefault(l["genus"], len(gn)) for l in lab])
        self.gnames = list(gn)
        self.photos = np.array([l["photos"] for l in lab])
        self.C = len(lab)

    def head_logits(self, q):
        """Ensemble-mean logits: per head, class c's K_c prototype logits z pooled as
        T·(logsumexp(z/T) − log K_c) (= z for K_c = 1) + bias."""
        out = np.zeros((len(q), self.C), np.float32)
        for W, b, groups, T in self.heads:
            Z = q @ W.T
            for K, cls, idx in groups:
                if K == 1:
                    out[:, cls] += Z[:, idx[:, 0]] + b[cls]
                    continue
                zz = Z[:, idx]
                m = zz.max(-1)
                out[:, cls] += m + T * (np.log(np.exp((zz - m[..., None]) / T).sum(-1)) - np.log(K)) + b[cls]
        return out / len(self.heads)

    def knn(self, e):
        qs = unit(unit(e) - self.tmu[None]).astype(np.float32)
        p = self.bh["scoring"]
        sims, idx = knn_neighbours(qs, self.B, self.bs, p["k"])
        Lk = np.full((len(e), self.C), -1e4, np.float32)
        Lk[:, self.tcls] = log_softmax(p["knn_temp"] * knn_vote(sims, idx, self.bl, len(self.tcls), p["k"], p["tau"]))
        return Lk

    def logp(self, emb, lat=None, lon=None):
        e = np.asarray(emb, np.float32)
        s = self.sc
        q = unit(unit(e) - self.mu[None]).astype(np.float32)
        Lh = log_softmax(self.head_logits(q) / s["image_temperature"])
        tas = np.full(len(e), s["no_location"] == "tasmania") if lat is None else in_tas(lat, lon)
        Li = Lh
        if tas.any():
            i = np.nonzero(tas)[0]
            t = s["tasmania"]
            Li = Lh.copy()
            Li[i] = log_softmax(Lh[i] + t["omega"] * np.maximum(self.knn(e[i]), t["knn_floor"]))
        P = s["lam"] * self.prior.log_prior(lat, lon, s["prior"]["transform"])
        T = s["temperature"]
        return log_softmax(log_softmax(Li + P) / T), log_softmax(Li / T), np.where(tas, "tasmania", "australia")

    ladder = V2Ship.ladder


def v3_tas_classes(C, mf, mt):
    """Per Tasmanian label (labels.json row): its class (as cmd_v2)."""
    tas_lab = json.load(open(os.path.join(SHIP, "labels.json")))["labels"]
    mapv = np.arange(C)
    mapv[mf] = mt
    s2u = np.full(len(tas_lab), -1, np.int64)
    for u, l in enumerate(json.load(open(os.path.join(SHIP, "au-labels.json")))["labels"]):
        if l.get("ship", -1) >= 0:
            assert s2u[l["ship"]] < 0
            s2u[l["ship"]] = mapv[u]
    assert (s2u >= 0).all(), "every Tasmanian label maps to a class"
    return s2u


def cmd_v3(a):
    """The final configuration's pack files → ship/: v3-head.bin (both heads' int8
    prototype rows × per-row scale, per head bias / K_c / first row per class,
    centres, the Tasmanian bank's class map, every scoring parameter + the
    ladder in its header), v3-prior.bin (v2's counts + the σ-code raster),
    pipeline.json "v3" + provenance + `model`. v2-labels.json, bank-int8.bin and
    the credits are kept (same classes and training photos, asserted). Then
    checks the WRITTEN files (V3Ship, leak-free eval counts) against the sweep's
    test.json. Env: the eval env (V2DATA=…/data-final.npz)."""
    sys.path.insert(0, HERE)
    import train_v2 as V
    want_data = "data-final2.npz" if V3_R2 else "data-final.npz"
    assert os.path.abspath(V.DATA) == os.path.abspath(os.path.join(V2DIR, want_data)), \
        f"V2DATA must be {want_data} (is {V.DATA})"
    assert not os.environ.get("HC_T"), "HC_T would rescale the reference heads"
    FSW, cfg, cal, te = v3_sweep()
    prm = v3_params()
    heads = [(h, FSW.HEADS[h]) for h in FSW.ENS[cfg["ens"]]]
    if a.check_only:
        return v3_check(a.check_n)
    D = np.load(V.DATA, mmap_mode="r")
    mf, mt = D["merge_from"].astype(np.int64), D["merge_to"].astype(np.int64)
    if V3_R2:  # training counts of the data in use (= every head's n_c, asserted below)
        n_v2 = np.bincount(np.asarray(D["ytr"]).astype(np.int64), minlength=len(D["T"])).astype(np.int64)
    else:
        n_v2 = np.load(os.path.join(V2DIR, "runs", V2_RUN + ".npz"))["n_c"].astype(np.int64)
    C = len(n_v2)
    W8, S8, B, KC, R0, hh = [], [], [], [], [], []
    r = 0
    for name, path in heads:
        W, b, Kc, row0, T, n_c, hcfg = v3_load_head(path, prm["tau_norm"])
        assert len(b) == C and (n_c == n_v2).all(), f"{name}: classes / training counts differ from {V2_RUN}"
        assert int(Kc.max()) < 256 and int(Kc.min()) >= 1
        q8, s8 = int8_rows32(W)
        b = b.copy()
        b[mf] = -1e4  # the sweep's column mask (merged twins), baked into each head's bias
        W8.append(q8), S8.append(s8), B.append(b), KC.append(Kc.astype(np.uint8)), R0.append((row0 + r).astype(np.int32))
        hh.append({"run": name, "file": os.path.basename(path), "sha256": sha256(path), "rows": [r, r + len(W)],
                   "pool_temperature": T, "kbreaks": hcfg["kbreaks"], "seed": hcfg["seed"],
                   "k_histogram": {int(k): int((Kc == k).sum()) for k in np.unique(Kc)},
                   "gcs": V3_HEADS_GCS + os.path.basename(path)})
        r += len(W)
    D_ = W8[0].shape[1]
    mu = np.asarray(D["mu"], np.float32)
    import bank_analysis as BA_
    Z_mu = np.load(os.path.join(BA_.WORK, "sets.npz"))["mu"]
    assert np.allclose(Z_mu, mu, atol=1e-6), "the sweep's query centre ≠ data-final mu"
    ship_h, ship_a = read_blob(os.path.join(SHIP, "head.bin"))
    s2u = v3_tas_classes(C, mf, mt)
    # labels: v2-labels.json as shipped — its photos ARE the merged training counts the ladder buckets
    lab = json.load(open(os.path.join(SHIP, "v2-labels.json")))
    n_m = n_v2.copy()
    for f_, t_ in zip(mf, mt):
        n_m[t_] += n_m[f_]
        n_m[f_] = 0
    if V3_R2:  # same 22,122 labels, new photo counts (the ladder buckets) → rewrite v2-labels.json
        merge = dict(zip(mf.tolist(), mt.tolist()))
        new_rows, _ = v2_labels(n_m, merge)
        assert [(r["name"], r.get("merged_into")) for r in new_rows] == \
            [(l["name"], l.get("merged_into")) for l in lab["labels"]], "r2: label list changed"
        lab["labels"] = new_rows
        json.dump(lab, open(os.path.join(SHIP, "v2-labels.json"), "w"), ensure_ascii=False, separators=(",", ":"))
        cred = v2_credits(np.asarray(D["pid"]), np.asarray(D["src"]), a.observers,
                          sheets={int(c) for c in np.nonzero(n_m == 0)[0]})
        print(f"r2 credits: {cred}")
    assert lab["count"] == C and [l["photos"] for l in lab["labels"]] == n_m.tolist(), "v2-labels.json photos ≠ merged n_c"
    hdr = {"kind": "plantid-head-v3", "version": 1, "labels": C, "id": V3_ID, "sweep": V3_CFG,
           "variant": "int8 per prototype row (float32 scale = max|w|/127)", "heads": hh, "scoring": prm,
           "recipe": [
               "q = normalise(normalise(embedding) − centre)",
               "per head h: z = scale ⊙ (weight[rows_h] · q); class c's prototypes are rows row0[h][c] … + kc[h][c] − 1; "
               "s_c = T_h·(logsumexp(z/T_h) − log kc) (= z when kc = 1), T_h = heads[h].pool_temperature; "
               "logit_h = s + bias[h] (merged twins: −1e4)",
               "L_head = log_softmax(mean_h logit_h / image_temperature)",
               "prior = lam · log((K + α f) / (ΣK + α)), K[c] = Σ_cells t(count)·exp(−d²/2σ²) over cells within "
               "radius_sigmas·σ (v3-prior.bin; t = prior.transform; f = freq_<t>); (σ, α) = (sigma_km, alpha)"
               "[sigma_code[iy][ix]] of the photo's grid cell (iy, ix clipped to the grid); no location: K = 0 → lam · log f",
               "inside the Tasmania box [W, S, E, N] (no location: only when no_location = \"tasmania\"): q_t = "
               "normalise(normalise(embedding) − tas_centre); L_knn over bank-int8.bin as the Tasmanian scorer "
               "(k, tau, knn_temp from its header; C = its labels) at columns tas_classes (others −1e4; repeated "
               "column: the last wins); L_img = log_softmax(L_head + omega · max(L_knn, knn_floor)); else L_img = L_head",
               "L = log_softmax(log_softmax(L_img + prior) / temperature); image-only = log_softmax(L_img / temperature)",
               "ladder (ladder_v3): named = argmax L; species if p[named] ≥ species[bucket(photos[named])] "
               "(bucket edges 0 | 1–9 | 10–49 | 50+), image-only p[named] ≥ image_floor and not close congeners "
               "(congener_ratio < 1: top-2 share a genus and p2 ≥ ratio · p1); else genus (v2-labels genus) "
               "with summed p ≥ genus → that genus + its top 3; else not sure"]}
    write_blob(os.path.join(SHIP, "v3-head.bin"), hdr,
               {"weight": np.concatenate(W8), "scale": np.concatenate(S8), "bias": np.stack(B),
                "kc": np.stack(KC), "row0": np.stack(R0), "centre": mu,
                "tas_centre": ship_a["centre"].astype(np.float32), "tas_classes": s2u.astype(np.int32)})
    # prior: the shipped (all-data) counts + freq_<t> (as v2-prior.bin) + the σ-code raster from the same counts
    fit = prm["prior"]["fit"]
    code, rho0 = v3_sigma_codes(V2_PRIOR_SHIP, fit)
    code_e, rho0_e = v3_sigma_codes(V2_PRIOR_EVAL, fit)
    nlev = int(round(np.log2(fit["smax"] / fit["smin"]) * fit["steps_per_octave"])) + 1
    sig = fit["smin"] * 2.0 ** (np.arange(nlev) / fit["steps_per_octave"])
    alp = fit["a0"] * (sig / fit["s0"]) ** fit["delta"]
    assert int(code.max()) < nlev
    ph, pa = read_blob(V2_PRIOR_SHIP)
    assert len(pa["species_total"]) == C
    raw = pa["count"].astype(np.float64)
    freqs = {}
    for t in ("log1p", "sqrt"):
        tot = np.bincount(pa["species"].astype(np.int64), V2Prior.T[t](raw), minlength=C) + 1.0
        freqs["freq_" + t] = tot / tot.sum()
    old = os.path.join(SHIP, "v2-prior.bin")
    if os.path.exists(old):
        _, oa = read_blob(old)
        assert all(np.array_equal(oa[k], v) for k, v in [("rowptr", pa["rowptr"]), ("species", pa["species"]),
                                                          ("count", pa["count"])] + list(freqs.items())), \
            "counts differ from v2-prior.bin"
    ph2 = {k: v for k, v in ph.items() if k != "arrays"}
    ph2.update({"version": 3, "source_file": os.path.basename(V2_PRIOR_SHIP), "transforms": ["log1p", "sqrt"],
                "freq": "freq_<t> = (bincount(species, t(count)) + 1) / Σ, over all classes (float64)",
                "adaptive": {**fit, "rho0": rho0, "levels": nlev,
                             "about": "prior_adaptive.py balloon σ: ρ = Gaussian(σ_ρ)-smoothed records/km² of this "
                                      "file's counts, σ = clip(s0·(ρ0/ρ)^γ, smin, smax) quantised to σ = smin·2^(k/"
                                      "steps_per_octave) → sigma_code k per cell; α = a0·(σ/s0)^δ"}})
    ph2.pop("sigma_km", None), ph2.pop("alpha", None)
    write_blob(os.path.join(SHIP, "v3-prior.bin"), ph2,
               {"rowptr": pa["rowptr"], "species": pa["species"], "count": pa["count"],
                "species_total": pa["species_total"], **freqs,
                "sigma_code": code, "sigma_km": sig.astype(np.float64), "alpha": alp.astype(np.float64)})
    rec = np.bincount(np.repeat(np.arange(ph["ny"] * ph["nx"]), np.diff(pa["rowptr"].astype(np.int64))),
                      minlength=ph["ny"] * ph["nx"]).reshape(code.shape) > 0
    print(f"v3: {len(heads)} heads, {r:,} prototype rows × {D_} int8 ({[h['k_histogram'] for h in hh][0]}), pool T "
          f"{[round(h['pool_temperature'], 3) for h in hh]}; σ raster {code.shape} levels {sorted(set(code.ravel().tolist()))} "
          f"(ρ0 ship {rho0:.4f} / eval {rho0_e:.4f}; record cells with the eval code: {(code == code_e)[rec].mean():.4f})")
    # pipeline.json: v3 replaces v2 (its files leave the pack)
    pp = os.path.join(SHIP, "pipeline.json")
    pipe = json.load(open(pp))
    pipe.pop("v2", None)
    pipe["v3"] = {"built": time.strftime("%Y-%m-%d"), "id": V3_ID, "sweep": V3_CFG, "files": list(V3_FILES),
                  "classes": C, "classes_with_photos": int((n_m > 0).sum()), "merged": len(mf), "heads": hh,
                  "scoring": prm, "recipe": hdr["recipe"],
                  "sweep_test": {k: te["metrics"][k] for k in ("A-test", "AU-test", "C-main", "AU-test-euc")},
                  "note": "v3-head/v3-prior/v2-labels + bank-int8.bin (Tasmania box) + the encoder; "
                          "build_ship.V3Ship is the reference scorer"}
    keep = set(V3_FILES) | {"bank-int8.bin", "credits.json", "credits-photos.tsv.gz"}
    pipe["files"] = {f: v for f, v in pipe["files"].items() if f in keep}
    for f in V3_FILES + (("credits.json", "credits-photos.tsv.gz") if V3_R2 else ()):
        p = os.path.join(SHIP, f)
        pipe["files"][f] = {"bytes": size_of(p), "sha256": sha256(p)}
    assert set(pipe["files"]) == keep, sorted(keep - set(pipe["files"]))
    pipe["built"] = time.strftime("%Y-%m-%d")
    json.dump(pipe, open(pp, "w"), indent=1, ensure_ascii=False)
    import provenance as PV
    PV.record("v3 ship", inputs=[p for _, p in heads] + [V2_PRIOR_SHIP, V2_PRIOR_EVAL, V.DATA,
                                                          os.path.join(V2DIR, "runs", V2_RUN + ".npz"),
                                                          os.path.join(FSW.FS, "refine.json"), os.path.join(FSW.FS, "calib.json"),
                                                          os.path.join(FSW.FS, "test.json"), os.path.join(SHIP, "au-labels.json"),
                                                          os.path.join(SHIP, "labels.json"), os.path.join(SHIP, "head.bin"),
                                                          os.path.join(SHIP, "v2-labels.json")],
              outputs=[os.path.join(SHIP, f) for f in ("v3-head.bin", "v3-prior.bin")],
              extra={"id": V3_ID, "sweep": V3_CFG, "scoring": prm,
                     "heads": [{k: h[k] for k in ("run", "file", "sha256", "gcs", "seed")} for h in hh],
                     "heads_trained": "head_capacity.py vm (cfg in each npz `meta`)"})
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "provenance.py"), "section"], check=True)
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "provenance.py"), "ship"], check=True)
    pipe = json.load(open(pp))
    g = pipe["provenance"]["git"]
    lad, pr = prm["ladder"], prm["prior"]["fit"]
    pipe["model"] = {"id": V3_ID, "git": g["commit"][:10], "git_clean": bool(g.get("plantid_clean")),
                     "built": pipe["built"], "classes": C, "classes_with_photos": int((n_m > 0).sum()),
                     "encoder": "BioCLIP 2.5 ViT-H/14, 8-bit (w8)",
                     "summary": f"{len(hh)} multi-prototype heads (t {prm['image_temperature']:g}) · T "
                                f"{prm['temperature']:.2f} · adaptive prior {pr['t']} σ {pr['smin']:g}–{pr['smax']:g} km "
                                f"λ {prm['lam']:g} · ladder species {'/'.join(f'{x:g}' for x in lad['species'])} genus "
                                f"{lad['genus']:g} · Tasmania kNN ω {prm['tasmania']['omega']:g} floor "
                                f"{prm['tasmania']['knn_floor']:g}"}
    json.dump(pipe, open(pp, "w"), indent=1, ensure_ascii=False)
    print(f"model: {pipe['model']}")
    if not a.no_check:
        v3_check(a.check_n)


def v3_check(n_max=None):
    """The WRITTEN files against the sweep's test.json: V3Ship on the sweep's sets
    (bank_analysis cache) with the leak-free eval counts and THEIR σ raster (what
    the sweep scored) → top-1/5 per species, natural, re-weighted and the ladder
    rates on A-test and AU-test; int8 vs the fp32 heads (head_capacity's own
    scorer); V3Ship.ladder vs the sweep's vectorised rule. → ship/v3-check.json."""
    import bank_analysis as BA
    import head_capacity as HC
    import torch
    FSW, cfg, cal, te = v3_sweep()
    t0 = time.time()
    Z = BA.load()
    shp = V3Prior(os.path.join(SHIP, "v3-prior.bin"))
    fit = read_blob(os.path.join(SHIP, "v3-prior.bin"))[0]["adaptive"]
    code_e, _ = v3_sigma_codes(V2_PRIOR_EVAL, fit)
    sh = V3Ship(SHIP, prior=V3Prior(V2_PRIOR_EVAL, sigma=(code_e, shp.sig, shp.alp)))
    assert sh.C == len(Z["mapv"]) and (sh.photos == Z["n_tr"]).all(), "v2-labels photos ≠ the sweep's n_tr"
    # the sweep groups genera by its own table (bank_analysis: 2,610 genera, e.g. Callistemon in Melaleuca);
    # the app (V3Ship.ladder) by v2-labels' genus names (2,614) — as v2 shipped; reported, not changed
    pairs = np.unique(np.stack([sh.genus, Z["genus"]], 1), axis=0)
    sc = BA.Scorer(Z, dev="cpu")
    lad = cal["ladder"]
    res = {"files": {f: sha256(os.path.join(SHIP, f)) for f in ("v3-head.bin", "v3-prior.bin")}}
    G = int(Z["genus"].max()) + 1
    ladder_agree = []
    for nm in ("A-test", "AU-test"):
        y, w = Z[nm + "/y"], Z[nm + "/w"]
        n = len(y) if not n_max else min(len(y), n_max)
        top5 = np.full((len(y), 5), -1, np.int64)
        F = {k: np.zeros(len(y)) for k in ("p1", "p2", "pimg", "gp")}
        F.update({k: np.zeros(len(y), np.int64) for k in ("named", "second", "gtop")})
        for i in range(0, n, 1024):
            j = np.arange(i, min(n, i + 1024))
            L, Li, _ = sh.logp(Z[nm + "/emb"][j].astype(np.float32), Z[nm + "/lat"][j], Z[nm + "/lon"][j])
            o = np.argpartition(-L, 5, axis=1)[:, :5]
            o = np.take_along_axis(o, np.argsort(-np.take_along_axis(L, o, 1), 1), 1)
            top5[j] = o
            ar = np.arange(len(j))
            p = np.exp(L)
            F["named"][j], F["second"][j] = o[:, 0], o[:, 1]
            F["p1"][j], F["p2"][j] = p[ar, o[:, 0]], p[ar, o[:, 1]]
            F["pimg"][j] = np.exp(Li[ar, o[:, 0]])
            pg = np.bincount((ar[:, None] * G + Z["genus"][None, :]).ravel(), p.ravel(), minlength=len(j) * G).reshape(len(j), G)
            F["gtop"][j], F["gp"][j] = pg.argmax(1), pg.max(1)
            if i == 0:   # the per-photo ladder (V3Ship.ladder) vs the sweep's vectorised rule (same genus table)
                for k in range(0, len(j), 4):
                    gs = np.bincount(sh.genus, p[k]).max()
                    ladder_agree.append((sh.ladder(L[k], Li[k])["kind"], j[k], nm, gs))
        mask = np.arange(len(y)) < n
        got = sc.metrics(nm, top5, mask)
        F = FSW.add_feats(F, Z)
        lr = FSW.ladder_rates(y, w, F, lad, Z["genus"], mask=mask)
        want, wl = te["metrics"][nm], te["ladder_test"][nm]["chosen"]
        res[nm] = {"n": got["n"],
                   **{k: {"files": round(got[k], 5), "sweep": round(want[k], 5), "diff_pp": round(100 * (got[k] - want[k]), 3)}
                      for k in ("top1_sp", "top5_sp", "top1_nat", "top1_sp_rw")},
                   **{"ladder_" + k: {"files": round(lr[k], 5), "sweep": round(wl[k], 5), "diff_pp": round(100 * (lr[k] - wl[k]), 3)}
                      for k in ("species", "species_wrong", "genus", "not_sure")}}
        for kind, r_, s_, gs in [x for x in ladder_agree if x[2] == nm]:
            s_thr = np.array(lad["s"])[F["bucket"][r_]]
            vk = "species" if F["p1"][r_] >= s_thr and F["pimg"][r_] >= lad["f"] else \
                "genus" if gs >= lad["g"] else "notSure"
            if vk != kind:
                res.setdefault("ladder_rule_mismatch", []).append([nm, int(r_), kind, vk])
        print(f"  {nm}: {time.time() - t0:.0f} s", flush=True)
    res["ladder_rule_checked"] = len(ladder_agree)
    res["genus_tables"] = {"v2_labels": int(len(np.unique(sh.genus))), "sweep": int(len(np.unique(Z["genus"]))),
                           "pairs": int(len(pairs))}
    # int8 vs the fp32 heads through head_capacity's scorer (τ-norm + pooling as the sweep), on AU-test embeddings
    e = Z["AU-test/emb"][:2000].astype(np.float32)
    q = unit(unit(e) - Z["mu"][None].astype(np.float32)).astype(np.float32)
    with torch.no_grad():
        qt = torch.from_numpy(q)
        ref = sum(HC.hc_head_fn(FSW.HEADS[h], tn=cfg["tn"], dev="cpu")(qt) for h in FSW.ENS[cfg["ens"]]).numpy() / 2
    mine = sh.head_logits(q)
    live = Z["mapv"] == np.arange(len(Z["mapv"]))
    res["int8_vs_fp32"] = {"top1_agree": round(float((mine[:, live].argmax(1) == ref[:, live].argmax(1)).mean()), 5),
                           "max_abs_logit_diff": round(float(np.abs(mine[:, live] - ref[:, live]).max()), 4),
                           "mean_abs_logit_diff": round(float(np.abs(mine[:, live] - ref[:, live]).mean()), 5)}
    res["seconds"] = round(time.time() - t0)
    print("v3 check:", json.dumps(res, indent=1))
    worst = max(abs(v["diff_pp"]) for nm in ("A-test", "AU-test") for v in res[nm].values() if isinstance(v, dict))
    res["worst_diff_pp"] = worst
    json.dump(res, open(os.path.join(SHIP, "v3-check.json"), "w"), indent=1)
    if not n_max:
        assert worst <= 0.3 and not res.get("ladder_rule_mismatch"), f"v3 check: off by {worst} pp"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("data")
    p.add_argument("--protos", nargs="+", type=int, default=[1, 2, 4])
    p.add_argument("--default-bank", default="int8")
    p.add_argument("--device")
    p.add_argument("--observers", default=os.path.join(CACHE, "meta", "observers.csv.gz"),
                   help="iNat Open Dataset observers table (s3://inaturalist-open-data/"
                        "observers.csv.gz, ~18 MB; fetch_meta.sh does not pull it)")
    p = sub.add_parser("encoders")
    p.add_argument("--variants", nargs="+", default=["w8", "p4"], choices=["w8", "p4", "p6"])
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--force", action="store_true")
    p = sub.add_parser("embed")
    p.add_argument("--variant", required=True, choices=ENC)
    p.add_argument("--subset", type=int, help="seeded random subset of the test photos")
    p.add_argument("--compute-units", default="ALL")
    p = sub.add_parser("fp32ref")
    p.add_argument("--n", type=int, default=500)
    p = sub.add_parser("bench")
    p.add_argument("--variant", required=True, choices=ENC)
    p = sub.add_parser("fixture")
    p.add_argument("--n", type=int, default=50)
    p.add_argument("--out", help="fixture directory (default ios/IzzyKit/Tests/Fixtures)")
    p = sub.add_parser("benchall")
    p.add_argument("--variants", nargs="+", default=list(ENC))
    p.add_argument("--repeat", type=int, default=2)
    p = sub.add_parser("report")
    p.add_argument("--bank", default="bank-fp16.bin")
    p = sub.add_parser("au-common")
    p = sub.add_parser("au-labels")
    p.add_argument("--out")
    p = sub.add_parser("au")
    p.add_argument("--observers", default=os.path.join(CACHE, "meta", "observers.csv.gz"))
    p = sub.add_parser("v2")
    p.add_argument("--observers", default=os.path.join(CACHE, "meta", "observers.csv.gz"))
    p.add_argument("--no-check", action="store_true", help="skip the check against the evaluation (~2 min)")
    p.add_argument("--check-only", action="store_true", help="only the check, on the files already in ship/")
    p = sub.add_parser("v3")
    p.add_argument("--observers", default=os.path.join(CACHE, "meta", "observers.csv.gz"))
    p.add_argument("--no-check", action="store_true", help="skip the check against the sweep (~minutes)")
    p.add_argument("--check-only", action="store_true", help="only the check, on the files already in ship/")
    p.add_argument("--check-n", type=int, help="check on the first N photos per set only (a quick look; no assert)")
    a = ap.parse_args()
    {"data": cmd_data, "encoders": cmd_encoders, "embed": cmd_embed, "fp32ref": cmd_fp32ref,
     "bench": cmd_bench, "benchall": cmd_benchall, "report": cmd_report, "fixture": cmd_fixture,
     "au": cmd_au, "au-common": cmd_au_common, "au-labels": cmd_au_labels, "v2": cmd_v2,
     "v3": cmd_v3}[a.cmd](a)


if __name__ == "__main__":
    main()

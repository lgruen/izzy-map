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

    def gather(tab):
        keep = [i for i, p in enumerate(tab["photo_id"]) if p in idx]
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


def ladder_of(lp, genus):
    """The answer ladder on one log p vector (evaluate.score's rule)."""
    p = np.exp(lp)
    i = int(p.argmax())
    if p[i] >= 0.5:
        return {"kind": "species", "label": i, "p": float(p[i])}
    tot = {}
    for j, g in enumerate(genus):
        tot[g] = tot.get(g, 0.0) + float(p[j])
    g = max(tot, key=tot.get)
    if tot[g] >= 0.5:
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

    - plantid-mini/ + plantid-mini.json: a tiny synthetic model (6 labels,
      8 dims; int8, fp16-with-weights and head-only banks; a prior near
      Hobart) and Ship's log p for 12 embeddings — runs in CI.
    - plantid-real.json: N test-photo embeddings from the shipped w8 Core ML
      encoder (ship/eval/coreml-w8), location rounded to 3 dp (some
      without), and Ship's top 10 + ladder with bank-int8 — the Swift test
      reads the real files from ship/ and skips when they're absent.
    - plantid-preprocess.{json,bin}: Pillow's resize + centre crop of a
      synthetic image (whole, and a square crop), uint8 224×224×3 each."""
    from PIL import Image
    os.makedirs(FIXTURES, exist_ok=True)
    rng = np.random.default_rng(7)

    # ---- mini model
    md = os.path.join(FIXTURES, "plantid-mini")
    os.makedirs(md, exist_ok=True)
    C, D = 6, 8
    genus = ["Alpha", "Alpha", "Alpha", "Beta", "Beta", "Gamma"]
    names = ["Alpha prima", "Alpha secunda", "Alpha tertia", "Beta una", "Beta duo", "Gamma sola"]
    W = rng.normal(size=(C, D)).astype(np.float16)
    mu = (0.1 * rng.normal(size=D)).astype(np.float32)
    write_blob(os.path.join(md, "head.bin"), {"kind": "plantid-head", "version": 1, "labels": C,
                                              "temp": 7.5, "bias": None},
               {"weight": W, "centre": mu})
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
    write_blob(os.path.join(md, "bank-fp16w.bin"),
               {"kind": "plantid-bank", "variant": "proto", "rows": len(X),
                "scoring": {**sc, "k": 7, "rho": 0.5, "omega": 1.0}},
               {"vectors": X.astype(np.float16), "labels": labs,
                "weight": rng.integers(1, 9, len(X)).astype(np.uint16)})
    write_blob(os.path.join(md, "bank-none.bin"),
               {"kind": "plantid-bank", "variant": "none", "rows": 0,
                "scoring": {"head_only": True, "lam": 0.5}},
               {"vectors": np.zeros((0, D), np.float16), "labels": np.zeros(0, np.uint16)})
    # prior: records scattered around Hobart (and none of "Gamma sola")
    plat = -42.88 + 0.15 * rng.normal(size=60)
    plon = 147.33 + 0.15 * rng.normal(size=60)
    pcls = rng.integers(0, C - 1, 60)
    write_prior(os.path.join(md, "prior.bin"), plat, plon, pcls, C, "synthetic test records")
    json.dump({"version": 1, "count": C, "labels": [
        {"name": n, "genus": g, "family": g + "aceae", "tas_records": 1,
         **({"un": {"key": n, "ids": [i + 1]}} if i < 4 else {})}
        for i, (n, g) in enumerate(zip(names, genus))]},
        open(os.path.join(md, "labels.json"), "w"), indent=0)
    E = rng.normal(size=(12, D)).astype(np.float32)
    E[:4] = 3 * protos[[0, 3, 5, 1]] + 0.3 * E[:4]  # some confident ones
    locs = [(-42.88, 147.33), (-42.95, 147.2), (-41.4, 146.8), None] * 3
    mini = {"version": 1, "embeddings": E.tolist(), "locations": [list(l) if l else None for l in locs],
            "banks": {}}
    for bank in ("bank-int8.bin", "bank-fp16w.bin", "bank-none.bin"):
        sh = Ship(md, bank)
        out = []
        for e, l in zip(E, locs):
            if l is None:  # no location: lam = 0
                lp = log_softmax(sh.image_logp(sh.query(e[None])))[0]
            else:
                lp = sh.logp(e[None], [l[0]], [l[1]])[0]
            out.append({"logp": lp.tolist(), "ladder": ladder_of(lp, genus)})
        mini["banks"][bank] = out
    json.dump(mini, open(os.path.join(FIXTURES, "plantid-mini.json"), "w"), indent=0)
    print(f"mini model → {md}")

    # ---- real embeddings (w8 Core ML) with the shipped files
    ids, embs = load_parts(os.path.join(SHIP, "eval", "coreml-w8"))
    te = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"),
                       columns=["photo_id", "lat", "lon"]).to_pydict()
    where = {p: (la, lo) for p, la, lo in zip(te["photo_id"], te["lat"], te["lon"])}
    pick = np.sort(np.random.default_rng(3).permutation(len(ids))[:a.n])
    sh = Ship(SHIP, "bank-int8.bin")
    labels = json.load(open(os.path.join(SHIP, "labels.json")))["labels"]
    rgen = [l["genus"] for l in labels]
    cases = []
    for j, i in enumerate(pick):
        e = embs[i].astype(np.float32)
        la, lo = where[int(ids[i])]
        loc = None if j % 5 == 4 else (round(float(la), 3), round(float(lo), 3))
        if loc is None:
            lp = log_softmax(sh.image_logp(sh.query(e[None])))[0]
        else:
            lp = sh.logp(e[None], [loc[0]], [loc[1]])[0]
        top = np.argsort(-lp)[:10]
        cases.append({"embedding": __import__("base64").b64encode(e.astype("<f4").tobytes()).decode(),
                      "location": list(loc) if loc else None,
                      "top": [[int(t), float(lp[t])] for t in top],
                      "ladder": ladder_of(lp, rgen)})
    json.dump({"version": 1, "bank": "bank-int8.bin", "encoder": "w8",
               "note": "embeddings = PlantEncoder-w8 Core ML outputs of test photos (numbers only); "
                       "expected = build_ship.Ship on ship/ (head, bank-int8, prior)",
               "files": {f: json.load(open(os.path.join(SHIP, "pipeline.json")))["files"][f]["sha256"]
                         for f in ("head.bin", "bank-int8.bin", "prior.bin", "labels.json")},
               "cases": cases}, open(os.path.join(FIXTURES, "plantid-real.json"), "w"), indent=0)
    print(f"real: {len(cases)} cases, ladders "
          f"{ {k: sum(c['ladder']['kind'] == k for c in cases) for k in ('species', 'genus', 'notSure')} }")

    # ---- preprocessing
    src = synthetic_rgb(317, 241)
    im = Image.fromarray(src, "RGB")
    crop = (40, 10, 220, 190)
    outs = [resize_crop(im), resize_crop(im.crop(crop))]
    with open(os.path.join(FIXTURES, "plantid-preprocess.bin"), "wb") as f:
        for o in outs:
            f.write(o.tobytes())
    x = (outs[0].astype(np.float32) / 255.0 - np.array(MEAN, np.float32)) / np.array(STD, np.float32)
    json.dump({"version": 1, "source": [317, 241], "formula": "synthetic_rgb in build_ship.py",
               "cases": [{"crop": None}, {"crop": list(crop)}],
               "bytes_per_case": 224 * 224 * 3, "layout": "uint8 HWC RGB, row-major",
               "tensor_samples": [[c, yy, xx, float(x[yy, xx, c])]
                                  for c, yy, xx in [(0, 0, 0), (1, 100, 37), (2, 223, 223), (0, 57, 201)]]},
              open(os.path.join(FIXTURES, "plantid-preprocess.json"), "w"), indent=1)
    print(f"fixtures → {FIXTURES}")


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
    p = sub.add_parser("benchall")
    p.add_argument("--variants", nargs="+", default=list(ENC))
    p.add_argument("--repeat", type=int, default=2)
    p = sub.add_parser("report")
    p.add_argument("--bank", default="bank-fp16.bin")
    a = ap.parse_args()
    {"data": cmd_data, "encoders": cmd_encoders, "embed": cmd_embed, "fp32ref": cmd_fp32ref,
     "bench": cmd_bench, "benchall": cmd_benchall, "report": cmd_report, "fixture": cmd_fixture}[a.cmd](a)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Herbarium-sheet rows for species WITHOUT training photos, written into a
shipped multi-prototype head (head_capacity mproto npz) — the rule
herbarium_test.py chose on its simulated set (notes/herbarium_test.md):

  row_c = s0 · ‖t_c + g‖ · unit(0.75 · unit(t_c + g) + 0.25 · p_c),  bias 0
  t_c = the class's centred text vector (its current row / s0), g = mean move
  Δ = (class-mean prototype / s0 − t) of the head's TRAINED classes (≥ 10
  photos) in the same genus (fallback: all trained), p_c = the unit mean of the
  class's centred sheet embeddings (shipped w8 encoder, GBIF sheets).

Only classes with Kc = 1, no training photo, not merged, and ≥ 1 sheet are
touched; every other row is copied bit for bit (asserted).

  python3 sheet_rows.py IN.npz OUT.npz [--data data.npz] [--gamma 0.25]
Env: uv run --with 'numpy<2.3' --with pyarrow python3 -I pipeline/plantid/sheet_rows.py …
"""
import argparse
import glob
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
V2 = os.path.join(CACHE, "australia", "v2")
HB = os.path.join(CACHE, "herbarium")


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True).clip(1e-9)


def blocks_of(Kc):
    out, a = {}, 0
    for K in sorted(np.unique(Kc)):
        cls = np.nonzero(Kc == K)[0]
        out[int(K)] = (cls, a)
        a += K * len(cls)
    return out, a


def sheet_protos(mu, C):
    E = np.load(os.path.join(HB, "emb-gbif.npz"))
    emb = dict(zip(E["image_id"].tolist(), unit(unit(E["emb"].astype(np.float32)) - mu)))
    P, n = np.zeros((C, len(mu)), np.float32), np.zeros(C, np.int64)
    for f in glob.glob(os.path.join(HB, "recs-gbif", "*.json")):
        d = json.load(open(f))
        v = [emb[im["image_id"]] for im in d["images"] if im["image_id"] in emb]
        if v:
            P[d["u"]], n[d["u"]] = unit(np.mean(v, 0)), len(v)
    return P, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--data", default=os.environ.get("V2DATA", os.path.join(V2, "data-final2.npz")))
    ap.add_argument("--gamma", type=float, default=0.25)
    a = ap.parse_args()
    z = dict(np.load(a.inp))
    D = np.load(a.data, mmap_mode="r")
    T, s0, genus, mu = D["T"].astype(np.float32), float(D["s0"]), D["genus"], D["mu"].astype(np.float32)
    Tc = unit(T - T.mean(0))                       # the text init the heads start from (train_v2 / head_capacity)
    W, Kc, n = z["W"].astype(np.float32), z["Kc"].astype(np.int64), z["n_c"].astype(np.int64)
    C = len(Kc)
    merged = np.zeros(C, bool)
    merged[D["merge_from"]] = True
    blk, R = blocks_of(Kc)
    assert R == len(W)
    row = np.zeros(C, np.int64)       # first prototype row of each class
    mean = np.zeros((C, W.shape[1]), np.float32)
    for K, (cls, a0) in blk.items():
        rows = a0 + np.arange(len(cls))[:, None] * K + np.arange(K)[None]
        row[cls] = rows[:, 0]
        mean[cls] = W[rows].mean(1)
    Delta = mean / s0 - Tc
    tr = (n >= 10) & ~merged
    G = int(genus.max()) + 1
    gs, gc = np.zeros((G, W.shape[1]), np.float32), np.zeros(G)
    np.add.at(gs, genus[tr], Delta[tr])
    np.add.at(gc, genus[tr], 1)
    gm = np.where(gc[:, None] > 0, gs / np.maximum(gc, 1)[:, None], Delta[tr].mean(0))
    P, nsh = sheet_protos(mu, C)
    tgt = np.nonzero((Kc == 1) & (n == 0) & ~merged & (nsh > 0))[0]
    # sanity: these rows are still the text init (s0 · t_c), nothing trained them
    cos0 = (unit(W[row[tgt]]) * Tc[tgt]).sum(1)
    assert np.median(cos0) > 0.99, f"photo-less rows are not at the text init (median cos {np.median(cos0):.3f})"
    g = gm[genus[tgt]]
    base = Tc[tgt] + g
    new = s0 * np.linalg.norm(base, axis=1, keepdims=True) * unit((1 - a.gamma) * unit(base) + a.gamma * P[tgt])
    W2 = W.copy()
    W2[row[tgt]] = new
    b2 = z["b"].astype(np.float32).copy()
    b2[tgt] = 0.0
    keep = np.ones(len(W), bool)
    keep[row[tgt]] = False
    assert (W2[keep] == W[keep]).all()
    z["W"], z["b"] = W2.astype(z["W"].dtype), b2
    meta = json.loads(str(z["meta"]))
    meta["sheet_rows"] = {"classes": int(len(tgt)), "gamma": a.gamma, "sheets_median": int(np.median(nsh[tgt])),
                          "source": "GBIF PRESERVED_SPECIMEN CC/PD media, herbarium_test.py recs-gbif",
                          "rule": "s0·‖t+g‖·unit((1−γ)·unit(t+g) + γ·p), bias 0"}
    z["meta"] = np.array(json.dumps(meta))
    np.savez(a.out, **z)
    print(f"{a.inp} → {a.out}: {len(tgt)} photo-less classes got sheet rows "
          f"(of {int(((Kc == 1) & (n == 0) & ~merged).sum())} photo-less; median {int(np.median(nsh[tgt]))} sheets)")


if __name__ == "__main__":
    main()

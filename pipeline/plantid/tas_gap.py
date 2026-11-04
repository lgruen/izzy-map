#!/usr/bin/env python3
"""Why does the single model (v2) lose ~1 pt in Tasmania (A-test) against the
shipped Tasmanian scorer, and can it be closed inside the model? Decomposes
head vs prior vs label space on A-test, and tries in-model fixes — every
weight tuned on A-val only (Tasmanian val observers), reported on A-test,
paired against the shipped scorer (= the gated hybrid in Tasmania).
→ australia/v2/tas_gap.json. Reads the read-only ALA grid the app bundles
(ios/…/Data/nearby.bin: ALA records as distinct ~100 m cells per 0.01° cell
for the 1,729 Understorey Network species) for the ALA-prior test.

Env: eval_v2.py's.  Usage: tas_gap.py [run name]"""
import json
import os
import struct
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402
import eval_v2 as E2  # noqa: E402
import train_australia as TA  # noqa: E402
import train_v2 as V  # noqa: E402

DEV = "mps"
DATA = os.path.normpath(os.path.join(HERE, "..", "..", "ios", "IzzyMap", "Resources", "Data"))


def ala_grid(names_to_u):
    """nearby.bin → (cell lat, cell lon, class u, count) for UN species mapped to U."""
    raw = open(os.path.join(DATA, "nearby.bin"), "rb").read()
    magic, n = struct.unpack("<II", raw[:8])
    assert magic == 0x4E425931
    cells = np.frombuffer(raw, "<u4", n, 8)
    offs = np.frombuffer(raw, "<u4", n + 1, 8 + 4 * n)
    rec = np.frombuffer(raw, [("s", "<u2"), ("n", "<u2")], offs[-1], 8 + 4 * n + 4 * (n + 1))
    sp = json.load(open(os.path.join(DATA, "records.json")))["species"]
    nlon = 551
    cid = np.repeat(cells, np.diff(offs))
    row, col = cid // nlon, cid % nlon
    u = np.array([names_to_u.get(sp[s], -1) for s in rec["s"]])
    k = u >= 0
    print(f"ALA grid: {len(rec):,} (cell, species) pairs, {len(set(rec['s'][k])):,} of {len(sp)} species mapped to U")
    return -44.0 + row[k] * 0.01, 143.5 + col[k] * 0.01, u[k], rec["n"][k].astype(np.float64)


def ala_density(lat, lon, glat, glon, gu, gn, C, sigma):
    """Gaussian kernel (σ km, cut 3σ) over the 0.01° ALA cells → n × C."""
    import scipy.sparse as sp
    from scipy.spatial import cKDTree
    kx = 111.32 * np.cos(np.radians(-42.0))
    pts = np.c_[glon * kx, glat * 110.57]
    cell_key, inv = np.unique(pts, axis=0, return_inverse=True)
    Cm = sp.csr_matrix((gn, (inv.ravel(), gu)), shape=(len(cell_key), C))
    tree = cKDTree(cell_key)
    q = np.c_[np.asarray(lon) * kx, np.asarray(lat) * 110.57]
    nb = tree.query_ball_point(q, 3 * sigma)
    rows = np.repeat(np.arange(len(q)), [len(x) for x in nb])
    cols = np.concatenate([np.array(x, np.int64) for x in nb]) if len(rows) else np.zeros(0, np.int64)
    d2 = ((cell_key[cols] - q[rows]) ** 2).sum(1)
    W = sp.csr_matrix((np.exp(-d2 / (2 * sigma ** 2)), (rows, cols)), shape=(len(q), len(cell_key)))
    return (W @ Cm).toarray().astype(np.float32), np.asarray(Cm.sum(0)).ravel()


def main():
    import pyarrow.parquet as pq
    import torch
    run = sys.argv[1] if len(sys.argv) > 1 else "v2fix-e12"
    t0 = time.time()
    D, U, genus, euc, sets, ship, ash = E2.load_sets()
    C = D["T"].shape[0]
    z = np.load(os.path.join(V.V2, "runs", run + ".npz"))
    W, b, n_tr = z["W"].astype(np.float32), z["b"].astype(np.float32), z["n_c"].copy()
    L_ = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name", "inat_ids", "aliases"]).to_pydict()
    merge = V.class_merges(L_["name"], L_["inat_ids"], n_tr, V.name_map_pairs(L_["inat_ids"]))
    mapv = np.arange(C)
    for a_, b_ in merge.items():
        mapv[a_] = b_
    mask = np.zeros(C, np.float32)
    mask[list(merge)] = -1e4
    s2u = mapv[ash.ship2u]
    in2675 = np.full(C, -1e4, np.float32)
    in2675[s2u] = 0
    # sqrt-count AU prior (v2's), from the eval
    base_prior = BS.DegPrior(os.environ.get("V2PRIOR") or os.path.join(BS.SHIP, "au-prior.bin"))
    P = BS.DegPrior.__new__(BS.DegPrior)
    P.h, P.rowptr, P.sp, P.cnt = base_prior.h, base_prior.rowptr, base_prior.sp, np.sqrt(base_prior.cnt.astype(np.float64))
    tot = np.bincount(P.sp.astype(np.int64), P.cnt, minlength=C) + 1.0
    P.freq = tot / tot.sum()
    n2u = {}
    for u, (nm, al) in enumerate(zip(L_["name"], L_["aliases"])):
        for k in [nm] + [x for x in (al or "").split("|") if x]:
            n2u.setdefault(k, mapv[u])
    G = ala_grid(n2u)
    comp = {}
    for nm in ("A-val", "A-test"):
        S = sets[nm]
        S.y = np.where(S.y >= 0, mapv[np.maximum(S.y, 0)], -1)
        e = S.emb.astype(np.float32)
        q = BS.unit(BS.unit(e) - D["mu"])
        Lh = BS.log_softmax(q @ W.T + b + mask).astype(np.float32)
        qs = ship.query(e)
        Ls_img = ship.image_logp(qs)                       # Tasmanian head ⊕ bank, 2,675
        Ls_pri = ship.prior.log_prior(S.lat, S.lon)        # Tasmanian prior (iNat pool, 2.5 km cells, σ 5)
        Lv_pri = {}
        for s in (5.0, 10.0):
            K = P.density(S.lat, S.lon, s)
            Lv_pri[s] = np.log((K + 16 * P.freq[None]) / (K.sum(1, keepdims=True) + 16)).astype(np.float32)
            del K
        Ka, tot_a = ala_density(S.lat, S.lon, *G, C, 5.0)
        fa = (tot_a + 1) / (tot_a + 1).sum()
        cov = tot_a > 0
        La = np.where(cov[None], np.log((Ka + 16 * fa[None]) / (Ka.sum(1, keepdims=True) + 16)) - np.log(fa)[None],
                      0).astype(np.float32)
        # Tasmanian bank kNN in U space (the dense 82k-photo bank, Tasmania only)
        Lk = np.full((S.n, C), -1e4, np.float32)
        p_ = ship.bh["scoring"]
        sims, idx = BS.knn_neighbours(qs, ship.B, ship.bscale, p_["k"])
        Lk[:, s2u] = BS.log_softmax(p_["knn_temp"] * BS.knn_vote(sims, idx, ship.blabels, ship.C, p_["k"], p_["tau"]))
        comp[nm] = dict(S=S, Lh=Lh, Ls_img=Ls_img, Ls_pri=Ls_pri, Lv_pri=Lv_pri, La=La, Lk=Lk)
        print(f"{nm} components ({time.time() - t0:.0f} s)", flush=True)

    def to_u(Ls):  # 2,675 → U columns (others −1e4)
        out = np.full((Ls.shape[0], C), -1e4, np.float32)
        out[:, s2u] = Ls
        return out

    def score(nm, L):
        S = comp[nm]["S"]
        pred = L.argmax(1)
        inl = S.y >= 0
        hit = (pred == S.y) & inl
        w = S.w
        nat = float((hit * w)[inl].sum() / w[inl].sum())
        _, inv = np.unique(S.y[inl], return_inverse=True)
        sp_ = float((np.bincount(inv, hit[inl]) / np.bincount(inv)).mean())
        return nat, sp_, hit

    ref_hit = {nm: score(nm, to_u(ship.logp(comp[nm]["S"].emb.astype(np.float32), comp[nm]["S"].lat,
                                            comp[nm]["S"].lon)))[2] for nm in comp}

    def variant(fn, grid=None):
        """fn(c, prm) → log p; prm tuned on A-val (natural top-1), reported on A-test."""
        best = None
        for prm in (grid or [{}]):
            v = score("A-val", fn(comp["A-val"], prm))[0]
            if best is None or v > best[0]:
                best = (v, prm)
        nat, sp_, hit = score("A-test", fn(comp["A-test"], best[1]))
        r0 = ref_hit["A-test"]
        return {"prm": best[1], "A-val": round(best[0], 4), "A-test_nat": round(nat, 4), "A-test_sp": round(sp_, 4),
                "lost": int((r0 & ~hit).sum()), "gained": int((~r0 & hit).sum())}
    lams = [{"lam": l} for l in (0.25, 0.5, 0.75, 1.0, 1.5)]
    res = {"run": run, "merges": len(merge)}
    V_ = {
        "D1 Tasmanian scorer (shipped: head ⊕ bank + Tas prior)": (lambda c, p: to_u(ship.logp(c["S"].emb.astype(np.float32), c["S"].lat, c["S"].lon)), None),
        "D2 Tasmanian head ⊕ bank, no prior": (lambda c, p: to_u(c["Ls_img"]), None),
        "D3 v2 head, no prior (22,122)": (lambda c, p: c["Lh"], None),
        "D4 v2 head, no prior, only the 2,675": (lambda c, p: c["Lh"] + in2675, None),
        "D5 v2 head + v2 prior σ10 λ.75 (= v2)": (lambda c, p: c["Lh"] + 0.75 * c["Lv_pri"][10.0], None),
        "D6 v2 head + v2 prior, only the 2,675": (lambda c, p: c["Lh"] + 0.75 * c["Lv_pri"][10.0] + in2675, None),
        "D7 v2 head + Tasmanian prior, only the 2,675": (lambda c, p: c["Lh"] + in2675 + p["lam"] * to_u(c["Ls_pri"]), lams),
        "D8 Tasmanian head ⊕ bank + v2 prior": (lambda c, p: to_u(c["Ls_img"]) + p["lam"] * c["Lv_pri"][10.0], lams),
        "F1 v2 + prior strength re-tuned in Tasmania (≙ regional temperature)": (lambda c, p: c["Lh"] + p["lam"] * c["Lv_pri"][10.0], lams),
        "F2 v2 + v2 prior σ 5 km in Tasmania": (lambda c, p: c["Lh"] + p["lam"] * c["Lv_pri"][5.0], lams),
        "F3 v2 + ALA lift (UN species, σ 5 km)": (lambda c, p: c["Lh"] + 0.75 * c["Lv_pri"][10.0] + p["lam"] * c["La"], lams),
        "F4 v2 + Tasmanian bank kNN (ω), Tasmania only": (
            lambda c, p: BS.log_softmax(c["Lh"] + p["om"] * np.maximum(c["Lk"], -30)) + 0.75 * c["Lv_pri"][10.0],
            [{"om": o} for o in (0.25, 0.5, 1.0, 2.0)]),
        "F5 v2 + bank kNN + prior σ5 re-tuned": (
            lambda c, p: BS.log_softmax(c["Lh"] + p["om"] * np.maximum(c["Lk"], -30)) + p["lam"] * c["Lv_pri"][5.0],
            [{"om": o, "lam": l} for o in (0.5, 1.0, 2.0) for l in (0.5, 0.75, 1.0)]),
    }
    for k, (fn, grid) in V_.items():
        res[k] = variant(fn, grid)
        print(k, res[k], flush=True)
    json.dump(res, open(os.path.join(V.V2, "tas_gap.json"), "w"), indent=1)


if __name__ == "__main__":
    main()

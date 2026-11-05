#!/usr/bin/env python3
"""Answer ladder v3 for the single model (README "Single model (v2)"):
  species  if p(named) ≥ s[bucket of the NAMED class's training photos]
           AND image-only p(named) ≥ f   (the prior alone can't create confidence)
           AND NOT close congeners (top-2 same genus with p2 ≥ r · p1)
  genus    else if the genus' summed p ≥ g  (close congeners: genus + top-3 shown)
  not sure otherwise.
Chosen on AU-val with per-class weights re-weighted to the label-free
training-count mix of all species with an Australian record (as eval_v2's
robust ladder): stated-but-wrong per species ≤ 7 % overall, maximum species
answers right; genus rung no less reliable than the species rung. Reported on
A-test, C-main, C-euc, AU-test, AU-test eucalypts vs the 0.80 / 0.55 ladder.
→ australia/v2/ladder_v3.json.   Usage: ladder_v3.py [run]"""
import itertools
import json
import os
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
BUCKET_EDGES = (0, 10, 50)  # 0 | 1–9 | 10–49 | 50+


def bucket(n):
    n = np.asarray(n)
    return np.select([n == 0, n < 10, n < 50], [0, 1, 2], 3)


def main():
    import pyarrow.parquet as pq
    import torch
    run = sys.argv[1] if len(sys.argv) > 1 else "v2fix-e12"
    t0 = time.time()
    D, U, genus, euc, sets, ship, ash = E2.load_sets()
    C = D["T"].shape[0]
    z = np.load(os.path.join(V.V2, "runs", run + ".npz"))
    W, b, n_tr = (torch.from_numpy(z["W"].astype(np.float32)).to(DEV), torch.from_numpy(z["b"].astype(np.float32)).to(DEV),
                  z["n_c"].copy())
    L_ = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name", "inat_ids", "rg_au"]).to_pydict()
    merge = V.class_merges(L_["name"], L_["inat_ids"], n_tr, V.name_map_pairs(L_["inat_ids"]))
    mapv = np.arange(C)
    for a_, b_ in merge.items():
        mapv[a_] = b_
        n_tr[b_] += n_tr[a_]
        n_tr[a_] = 0
    mask = torch.zeros(C, device=DEV)
    mask[list(merge)] = -1e4
    ev = json.load(open(os.path.join(V.V2, "eval.json")))
    pr, T = ev["prior"], ev["temperature"]
    base = BS.DegPrior(os.environ.get("V2PRIOR") or os.path.join(BS.SHIP, "au-prior.bin"))
    P = BS.DegPrior.__new__(BS.DegPrior)
    P.h, P.rowptr, P.sp = base.h, base.rowptr, base.sp
    P.cnt = {"count": base.cnt.astype(np.float64), "sqrt": np.sqrt(base.cnt.astype(np.float64)),
             "log1p": np.log1p(base.cnt.astype(np.float64)), "presence": np.ones(len(base.cnt))}[pr["kind"]]
    tot = np.bincount(P.sp.astype(np.int64), P.cnt, minlength=C) + 1.0
    P.freq = tot / tot.sum()
    gt = torch.from_numpy(genus).to(DEV)
    G = int(genus.max()) + 1
    feats = {}
    for nm in ("AU-val", "A-test", "C-report", "AU-test"):
        S = sets[nm]
        S.y = np.where(S.y >= 0, mapv[np.maximum(S.y, 0)], -1)
        out = collections_def()
        for a in range(0, S.n, 2048):
            e = S.emb[a:a + 2048].astype(np.float32)
            q = torch.from_numpy(BS.unit(BS.unit(e) - D["mu"])).to(DEV)
            Li = torch.log_softmax(q @ W.T + b + mask, 1)
            K = torch.from_numpy(P.density(S.lat[a:a + 2048], S.lon[a:a + 2048], pr["sigma"]).astype(np.float32)).to(DEV)
            f = torch.from_numpy(P.freq.astype(np.float32)).to(DEV)
            Lp = torch.log((K + pr["alpha"] * f[None]) / (K.sum(1, keepdim=True) + pr["alpha"]))
            L = torch.log_softmax(torch.log_softmax(Li + pr["lam"] * Lp, 1) / T, 1)
            Li_c = torch.log_softmax(Li / T, 1)  # image-only, same temperature
            o = L.topk(3, dim=1)
            named = o.indices[:, 0]
            pg = torch.zeros(L.shape[0], G, device=DEV).index_add_(1, gt, L.exp())
            gp, gtop = pg.max(1)
            ar = torch.arange(len(named), device=DEV)
            out["named"].append(named.cpu().numpy())
            out["p1"].append(o.values[:, 0].exp().cpu().numpy())
            out["p2"].append(o.values[:, 1].exp().cpu().numpy())
            out["second"].append(o.indices[:, 1].cpu().numpy())
            out["pimg"].append(Li_c[ar, named].exp().cpu().numpy())
            out["gp"].append(gp.cpu().numpy())
            out["gtop"].append(gtop.cpu().numpy())
        F = {k: np.concatenate(v) for k, v in out.items()}
        F["same_genus"] = genus[F["named"]] == genus[F["second"]]
        F["bucket"] = bucket(n_tr[F["named"]])
        feats[nm] = (S, F)
        print(f"{nm}: {S.n:,} photos ({time.time() - t0:.0f} s)", flush=True)

    # class weights on val: label-free mix of all (unmerged) classes with an AU record
    rg = np.array(L_["rg_au"])
    act = (rg > 0) & (mapv == np.arange(C))
    tgt = np.bincount(bucket(n_tr[act]), minlength=4) / act.sum()
    Sv, Fv = feats["AU-val"]
    cls_v = np.unique(Sv.y)
    vmix = np.bincount(bucket(n_tr[cls_v]), minlength=4) / len(cls_v)
    wcls = (tgt / np.maximum(vmix, 1e-9))[bucket(n_tr)]  # per true class

    def ladder(S, F, prm):
        s_thr = np.array(prm["s"])[F["bucket"]]
        close = F["same_genus"] & (F["p2"] >= prm["r"] * F["p1"]) if prm["r"] < 1 else np.zeros(S.n, bool)
        sp_ = (F["p1"] >= s_thr) & (F["pimg"] >= prm["f"]) & ~close
        ge = ~sp_ & (F["gp"] >= prm["g"])
        return sp_, ge

    def rates(S, F, prm, cw=None, mask=None):
        m = np.ones(S.n, bool) if mask is None else mask
        sp_, ge = ladder(S, F, prm)
        y = S.y[m]
        ok_s = (F["named"] == S.y)[m]
        ok_g = ((S.y >= 0) & (F["gtop"] == genus[np.maximum(S.y, 0)]))[m]
        sp_, ge = sp_[m], ge[m]
        key = np.where(y >= 0, y, -1 - np.arange(len(y)))
        cl, inv = np.unique(key, return_inverse=True)
        cnt = np.bincount(inv)
        wc = np.ones(len(cl)) if cw is None else np.where(cl >= 0, cw[np.maximum(cl, 0)], 1.0)

        def per(h):
            return float(((np.bincount(inv, h.astype(float)) / cnt) * wc).sum() / wc.sum())
        nat_w = S.w[m] / S.w[m].sum()
        r = {"species": per(sp_), "species_right": per(sp_ & ok_s), "species_wrong": per(sp_ & ~ok_s),
             "genus": per(ge), "genus_wrong": per(ge & ~ok_g), "not_sure": per(~sp_ & ~ge),
             "species_w": float((sp_ * nat_w).sum()), "species_wrong_w": float(((sp_ & ~ok_s) * nat_w).sum())}
        return r
    # search: (f, r, g) grid; per-bucket thresholds by greedy raising until ≤ 7 % stated-wrong
    grid_s = [round(x, 2) for x in np.arange(0.5, 0.99, 0.05)]
    best = None
    for f_, r_ in itertools.product((0.0, 0.1, 0.2, 0.3, 0.4), (1.0, 0.7, 0.5, 0.3)):
        s = [0.5] * 4
        while True:
            prm = {"s": s, "f": f_, "r": r_, "g": 0.5}
            rr = rates(Sv, Fv, prm, wcls)
            if rr["species_wrong"] <= 0.07:
                break
            opts = []
            for k in range(4):
                i = grid_s.index(s[k]) if s[k] in grid_s else 0
                if i + 1 < len(grid_s):
                    s2 = list(s)
                    s2[k] = grid_s[i + 1]
                    r2 = rates(Sv, Fv, dict(prm, s=s2), wcls)
                    gain = rr["species_wrong"] - r2["species_wrong"]
                    loss = rr["species_right"] - r2["species_right"]
                    opts.append((gain / max(loss, 1e-6), s2))
            if not opts:
                break
            s = max(opts, key=lambda o: o[0])[1]
        rr = rates(Sv, Fv, {"s": s, "f": f_, "r": r_, "g": 0.5}, wcls)
        if rr["species_wrong"] <= 0.07 and (best is None or rr["species_right"] > best[0]["species_right"]):
            best = (rr, {"s": s, "f": f_, "r": r_})
    prm = dict(best[1])
    for g_ in [round(x, 2) for x in np.arange(0.5, 0.96, 0.05)]:
        rr = rates(Sv, Fv, dict(prm, g=g_), wcls)
        if rr["genus_wrong"] / max(rr["genus"], 1e-9) <= rr["species_wrong"] / max(rr["species"], 1e-9):
            prm["g"] = g_
            break
    else:
        prm["g"] = 0.95
    old = {"s": [0.8] * 4, "f": 0.0, "r": 1.0, "g": 0.55}
    res = {"run": run, "chosen": prm, "val_reweighted": {"v3": rates(Sv, Fv, prm, wcls), "old": rates(Sv, Fv, old, wcls)},
           "target_mix": tgt.tolist(), "val_mix": vmix.tolist(), "report": {}}
    for nm, sub in (("A-test", None), ("C-main", "main"), ("C-euc", "euc"), ("AU-test", None), ("AU-test-euc", "euc_y")):
        S, F = feats["C-report" if nm.startswith("C-") else ("AU-test" if nm.startswith("AU-test") else nm)]
        m = None if sub is None else (S.sub == sub if sub != "euc_y" else euc[np.maximum(S.y, 0)] & (S.y >= 0))
        res["report"][nm] = {"v3": rates(S, F, prm, mask=m), "old 0.80/0.55": rates(S, F, old, mask=m)}
    json.dump(res, open(os.path.join(V.V2, "ladder_v3.json"), "w"), indent=1)
    import provenance as PV
    PV.record("v2 ladder", inputs=[V.DATA, os.path.join(V.V2, "runs", run + ".npz"), os.path.join(V.V2, "eval.json")],
              outputs=[os.path.join(V.V2, "ladder_v3.json")], extra={"chosen": {k: (list(map(float, v)) if isinstance(v, list) else float(v)) for k, v in prm.items()}})
    P_ = lambda x: f"{100 * x:.1f}"  # noqa: E731
    print("chosen", prm)
    print("| set | ladder | species | species right | stated wrong | genus (wrong) | not sure | natural: species / stated wrong |")
    for nm, d in res["report"].items():
        for k, r in d.items():
            print(f"| {nm} | {k} | {P_(r['species'])} | {P_(r['species_right'])} | {P_(r['species_wrong'])} | "
                  f"{P_(r['genus'])} ({P_(r['genus_wrong'])}) | {P_(r['not_sure'])} | {P_(r['species_w'])} / {P_(r['species_wrong_w'])} |")


def collections_def():
    import collections
    return collections.defaultdict(list)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Evaluation of the single model (train_v2.py runs): run selection, location
prior (abundance vs range variants), temperature, answer ladder — all chosen
on the CLASS-BALANCED (per-species) val objective — then the report sets
(A-test, C-main, C-euc, AU-test, AU-test eucalypts), ablations, diagnostics
and plots → australia/v2/{eval.json, eval.md, *.png}.

Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'numpy<2.3' --with scipy
     --with pyarrow --with pillow --with duckdb --with matplotlib
     python3 -I pipeline/plantid/eval_v2.py
"""
import collections
import glob
import hashlib
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402
import eval_australia as EA  # noqa: E402
import train_australia as TA  # noqa: E402
import train_v2 as V  # noqa: E402

DEV = "mps"
V2 = V.V2
SIGMAS = (5.0, 10.0, 25.0)
ALPHAS = (4.0, 16.0, 64.0)
LAMS = (0.25, 0.5, 0.75, 1.0, 1.5)
KINDS = ("count", "log1p", "sqrt", "presence")
BUCKETS = ((0, 0, "0"), (1, 9, "1-9"), (10, 49, "10-49"), (50, 10 ** 9, "50-100"))


def h01(s):
    return int.from_bytes(hashlib.sha256(s.encode()).digest()[:4], "big") / 2 ** 32


class NS:
    def __init__(self, **k):
        self.__dict__.update(k)


# ------------------------------------------------------------ metrics

def mets(S, top, p1, genus, mask=None, thr=None):
    """Per-species (class-balanced: every species weighs the same) AND natural-
    mix (photo weights w) metrics; truth −1 (not in label set) counts wrong."""
    m = np.ones(S.n, bool) if mask is None else mask
    y, w = S.y[m], S.w[m]
    t, p = top[m], p1[m]
    yy = np.maximum(y, 0)
    inl = y >= 0
    r1 = (t[:, 0] == y) & inl
    r5 = (t == y[:, None]).any(1) & inl
    g1 = inl & (genus[t[:, 0]] == genus[yy])
    cw = (p >= 0.5) & ~r1
    key = np.where(inl, y, -1 - np.arange(len(y)))  # unanswerable photos: their own "species"
    _, inv = np.unique(key, return_inverse=True)
    cnt = np.bincount(inv)

    def sp(h):
        return float((np.bincount(inv, h) / cnt).mean()) if len(h) else None

    def nat(h):
        return float((h * w).sum() / w.sum()) if len(h) else None
    out = {"n": int(m.sum()), "species": int(len(set(y[inl])))}
    # accuracies over in-label photos (as the earlier tables); conf. wrong over ALL photos
    _, inv_i = np.unique(y[inl], return_inverse=True)
    cnt_i = np.bincount(inv_i)
    for nm, h in (("top1", r1), ("top5", r5), ("genus", g1)):
        h = h[inl].astype(float)
        out[nm + "_sp"] = float((np.bincount(inv_i, h) / cnt_i).mean()) if len(h) else None
        out[nm + "_w"] = float((h * w[inl]).sum() / w[inl].sum()) if len(h) else None
    out["conf_wrong_sp"], out["conf_wrong_w"] = sp(cw.astype(float)), nat(cw.astype(float))
    if thr is not None:  # answer ladder at (species, genus) thresholds
        out["ladder"] = ladder_rates(S, m, t, p1[m], thr, genus, inv, cnt, w)
    return out


def ladder_rates(S, m, t, p, thr, genus, inv, cnt, w):
    y = S.y[m]
    pg = S.pgen[m] if hasattr(S, "pgen") else None
    sp_ = p >= thr[0]
    gtop, gp = S.gtop[m], S.gp[m]
    ge = ~sp_ & (gp >= thr[1])
    ok_s = t[:, 0] == y
    ok_g = (y >= 0) & (gtop == genus[np.maximum(y, 0)])
    r = {}
    for nm, h in (("species", sp_), ("species_wrong", sp_ & ~ok_s), ("genus", ge), ("genus_wrong", ge & ~ok_g),
                  ("not_sure", ~sp_ & ~ge)):
        r[nm + "_sp"] = float((np.bincount(inv, h.astype(float)) / cnt).mean())
        r[nm + "_w"] = float((h * w).sum() / w.sum())
    return r


def preds(L, genus_t, G):
    """top-5, p(top-1), genus argmax + its p from a (n × C) log p tensor (chunked by caller)."""
    import torch
    o = L.topk(5, dim=1)
    P = L.exp()
    pg = torch.zeros(L.shape[0], G, device=L.device).index_add_(1, genus_t, P)
    gp, gt = pg.max(1)
    return o.indices.cpu().numpy(), o.values[:, 0].exp().cpu().numpy(), gt.cpu().numpy(), gp.cpu().numpy()


def ece(conf, correct, weight, bins=15):
    edges = np.linspace(0, 1, bins + 1)
    b = np.clip(np.digitize(conf, edges) - 1, 0, bins - 1)
    W = weight / weight.sum()
    e, rows = 0.0, []
    for k in range(bins):
        mk = b == k
        if mk.any():
            acc, cf, wt = (correct[mk] * W[mk]).sum() / W[mk].sum(), (conf[mk] * W[mk]).sum() / W[mk].sum(), W[mk].sum()
            e += wt * abs(acc - cf)
            rows.append((float(edges[k]), float(cf), float(acc), float(wt)))
    return float(e), rows


# ------------------------------------------------------------ data

def load_sets():
    import pyarrow.parquet as pq
    D = np.load(V.DATA)
    U = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["genus", "euc", "ship", "native"]).to_pydict()
    gn = {g: i for i, g in enumerate(sorted(set(U["genus"])))}
    genus = np.array([gn[g] for g in U["genus"]])
    euc = np.array(U["euc"])
    sets = {}

    def mk(nm, emb, lat, lon, y, w, sub=None, obs=None, pid=None, ext=None):
        sets[nm] = NS(name=nm, n=len(y), emb=np.asarray(emb, np.float16), lat=np.asarray(lat, float),
                      lon=np.asarray(lon, float), y=np.asarray(y, np.int64), w=np.asarray(w, float), sub=sub, obs=obs,
                      pid=None if pid is None else np.asarray(pid), ext=None if ext is None else np.asarray(ext))
    mk("AU-val", D["Xv"], D["latv"], D["lonv"], D["yv"], D["wv"], obs=D["obsv"])
    mk("A-val", D["Xa"], D["lata"], D["lona"], D["ya"], D["wa"])
    SS = BS.load_sets()
    ev = SS["ev"]["test"]
    ship = BS.Ship(BS.SHIP, "bank-int8.bin")
    ash = BS.AuShip(BS.SHIP, ship)
    iw, Ew = BS.load_parts(os.path.join(BS.SHIP, "eval", "coreml-w8"))
    pw = {int(p): i for i, p in enumerate(iw)}
    mk("A-test", Ew[[pw[int(p)] for p in ev["photo_id"]]], ev["lat"], ev["lon"],
       np.where(ev["y"] >= 0, ash.ship2u[np.maximum(ev["y"], 0)], -1), ev["w"], pid=ev["photo_id"], ext=ev["ext"])
    crows = EA.c_rows()
    ic, Ec = BS.load_parts(os.path.join(TA.AU, "emb-w8"))
    cp = {int(p): i for i, p in enumerate(ic)}
    rr = [r for r in crows if r["half"] == "report" and r["photo_id"] in cp]
    mk("C-report", Ec[[cp[r["photo_id"]] for r in rr]], [r["lat"] for r in rr], [r["lon"] for r in rr],
       [r["u"] for r in rr], [r["w"] for r in rr], sub=np.array([r["subset"] for r in rr]),
       pid=[r["photo_id"] for r in rr], ext=[r["ext"] for r in rr])
    ids, E = TA.all_embeddings()
    pe = {k: np.array(v) for k, v in pq.read_table(os.path.join(TA.AU, "plan", "eval.parquet"), columns=[
        "lat", "lon", "role", "u", "photo_id", "n_split", "ext"]).to_pydict().items()}
    i_e, ok = TA.lookup(ids, pe["photo_id"])
    m = ok & (pe["role"] == "test")
    u = pe["u"][m]
    cnt = collections.Counter(u.tolist())
    mk("AU-test", E[i_e[m]], pe["lat"][m], pe["lon"][m], u, pe["n_split"][m] / np.array([cnt[x] for x in u]),
       pid=pe["photo_id"][m], ext=pe["ext"][m])
    # val tuning subset (observer hash; prior sweeps hold n × C arrays)
    S = sets["AU-val"]
    keep = np.array([h01(f"{o}v2tune") < 8000 / S.n for o in S.obs])
    cnt = collections.Counter(S.y[keep].tolist())
    full = collections.Counter(S.y.tolist())
    mk("AU-vtune", S.emb[keep], S.lat[keep], S.lon[keep], S.y[keep],
       S.w[keep] * np.array([full[x] / cnt[x] for x in S.y[keep]]))
    return D, U, genus, euc, sets, ship, ash


# ------------------------------------------------------------ main

def main():
    import torch
    t0 = time.time()
    D, U, genus, euc, sets, ship, ash = load_sets()
    C = D["T"].shape[0]
    G = int(genus.max()) + 1
    gt = torch.from_numpy(genus).to(DEV)
    mu = D["mu"]
    print({k: v.n for k, v in sets.items()}, f"({time.time() - t0:.0f} s)", flush=True)
    runs = {}
    for f in sorted(glob.glob(os.path.join(V2, "runs", "*.npz"))):
        z = np.load(f)
        runs[os.path.basename(f)[:-4]] = {"W": z["W"], "b": z["b"], "n_c": z["n_c"], **json.loads(str(z["meta"]))}
    stage1 = [k for k in runs if k.startswith("tau")]  # incl. stage 3 (schedule / wd follow-ups)
    final = os.environ.get("FINAL") or max(stage1, key=lambda k: runs[k]["info"]["best_val_top1_sp"])
    print("runs:", {k: (round(r["info"]["best_val_top1_sp"], 4), r["info"]["best_epoch"]) for k, r in runs.items()},
          "final:", final, flush=True)
    n_tr = runs[final]["n_c"].copy()
    import pyarrow.parquet as pq
    L_ = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name", "inat_ids"]).to_pydict()
    merge = V.class_merges(L_["name"], L_["inat_ids"], n_tr, V.name_map_pairs(L_["inat_ids"]))
    mapv = np.arange(C)
    for a_, b_ in merge.items():
        mapv[a_] = b_
        n_tr[b_] += n_tr[a_]
        n_tr[a_] = 0
    for S in sets.values():
        S.y = np.where(S.y >= 0, mapv[np.maximum(S.y, 0)], -1)
    colmask = torch.zeros(C, device=DEV)
    colmask[torch.tensor(list(merge), dtype=torch.long, device=DEV)] = -1e4
    print(f"merged classes: {merge}", flush=True)
    for S in sets.values():
        S.q = torch.from_numpy(BS.unit(BS.unit(S.emb.astype(np.float32)) - mu).astype(np.float16))

    def logits(run, S, rows=slice(None)):
        W = torch.from_numpy(runs[run]["W"].astype(np.float32)).to(DEV)
        b = torch.from_numpy(runs[run]["b"].astype(np.float32)).to(DEV)
        L = S.q[rows].to(DEV).float() @ W.T + b + colmask
        pt = float(os.environ.get("POSTHOC_TAU", 0))  # post-hoc logit adjustment (plain-CE heads)
        if pt:
            n = torch.from_numpy(runs[run]["n_c"].astype(np.float32)).to(DEV)
            L = L - pt * torch.where(n > 0, torch.log(n), torch.zeros_like(n))[None]
        return L

    # ---- location prior variants (abundance vs range), on AU-vtune per species
    pc = TA.prior_counts()
    base_prior = BS.DegPrior(os.environ.get("V2PRIOR") or os.path.join(BS.SHIP, "au-prior.bin"))  # same records, 0.05° cells

    def variant(kind):
        P = BS.DegPrior.__new__(BS.DegPrior)
        P.h, P.rowptr, P.sp = base_prior.h, base_prior.rowptr, base_prior.sp
        c = base_prior.cnt.astype(np.float64)
        P.cnt = {"count": c, "log1p": np.log1p(c), "sqrt": np.sqrt(c), "presence": np.ones_like(c)}[kind]
        tot = np.bincount(P.sp.astype(np.int64), P.cnt, minlength=C) + 1.0
        P.freq = tot / tot.sum()
        return P
    priors = {k: variant(k) for k in KINDS}
    TUNE = ("AU-vtune", "A-val")
    for nm in TUNE:
        S = sets[nm]
        S.L = torch.log_softmax(logits(final, S), 1).cpu()
        S.K = {(k, s): torch.from_numpy(priors[k].density(S.lat, S.lon, s).astype(np.float16)) for k in KINDS
               for s in SIGMAS}
    print(f"prior densities ({time.time() - t0:.0f} s)", flush=True)

    def lp(S, k, s, al, rows=slice(None)):
        K = S.K[(k, s)][rows].to(DEV).float()
        f = torch.from_numpy(priors[k].freq.astype(np.float32)).to(DEV)
        return torch.log((K + al * f[None]) / (K.sum(1, keepdim=True) + al))

    def quick(S, L):  # per-species and natural top-1 from log p
        p = L.argmax(1).cpu().numpy()
        hit = p == S.y
        _, inv = np.unique(S.y, return_inverse=True)
        return float((np.bincount(inv, hit) / np.bincount(inv)).mean()), float((hit * S.w).sum() / S.w.sum())
    S = sets["AU-vtune"]
    sweep = [{"kind": "none", "sp": quick(S, S.L.to(DEV))[0], "w": quick(S, S.L.to(DEV))[1]}]
    for k in KINDS:
        for s in SIGMAS:
            for al in ALPHAS:
                P_ = lp(S, k, s, al)
                for lam in LAMS:
                    sp_, w_ = quick(S, S.L.to(DEV) + lam * P_)
                    sweep.append({"kind": k, "sigma": s, "alpha": al, "lam": lam, "sp": sp_, "w": w_})
    best_by_kind = {k: max([r for r in sweep if r["kind"] == k], key=lambda r: r["sp"]) for k in KINDS}
    bp = max(best_by_kind.values(), key=lambda r: r["sp"])
    print("prior sweep best per kind:", best_by_kind, "\nchosen:", bp, flush=True)

    # ---- temperature (class-balanced NLL on AU-val subset) and ladder (per species)
    pcache = {}

    def prior_lp(S, prior):
        key = (S.name, prior["kind"], prior["sigma"], prior["alpha"])
        if key not in pcache:
            f = torch.from_numpy(priors[prior["kind"]].freq.astype(np.float32))
            parts = []
            for a in range(0, S.n, 2048):
                K = torch.from_numpy(priors[prior["kind"]].density(S.lat[a:a + 2048], S.lon[a:a + 2048],
                                                                   prior["sigma"]).astype(np.float32))
                parts.append(torch.log((K + prior["alpha"] * f[None]) / (K.sum(1, keepdim=True) + prior["alpha"])).half())
            pcache[key] = torch.cat(parts)
        return pcache[key]

    def drop_cache(kind):
        for k in [k for k in pcache if k[1] == kind]:
            del pcache[k]

    def final_logp(S, rows, run=final, prior=bp, T=1.0, post_tau=0.0):
        L = torch.log_softmax(logits(run, S, rows), 1)
        if post_tau:
            n = torch.from_numpy(runs[run]["n_c"].astype(np.float32)).to(DEV)
            L = torch.log_softmax(L - post_tau * torch.where(n > 0, torch.log(n), torch.zeros_like(n))[None], 1)
        if prior and prior["kind"] != "none":
            if hasattr(S, "K") and (prior["kind"], prior["sigma"]) in S.K:
                P_ = lp(S, prior["kind"], prior["sigma"], prior["alpha"], rows)
            else:
                P_ = prior_lp(S, prior)[rows].to(DEV).float()
            L = torch.log_softmax(L + prior["lam"] * P_, 1)
        return torch.log_softmax(L / T, 1)
    S = sets["AU-vtune"]
    Lt = final_logp(S, slice(None))
    yt = torch.from_numpy(S.y).to(DEV)
    _, inv = np.unique(S.y, return_inverse=True)
    wb = torch.from_numpy((1.0 / np.bincount(inv)[inv]).astype(np.float32)).to(DEV)  # class-balanced weights
    nll = {}
    for T in np.exp(np.linspace(np.log(0.5), np.log(3.0), 25)):
        Lc = torch.log_softmax(Lt / float(T), 1)
        nll[float(T)] = float(-(Lc.gather(1, yt[:, None])[:, 0] * wb).sum() / wb.sum())
    Tf = min(nll, key=nll.get)
    print(f"temperature T = {Tf:.3f} (class-balanced val NLL)", flush=True)

    def run_set(S, **kw):
        tops, p1s, gts, gps = [], [], [], []
        for a in range(0, S.n, 2048):
            L = final_logp(S, slice(a, a + 2048), **kw)
            t, p, g, q = preds(L, gt, G)
            tops.append(t), p1s.append(p), gts.append(g), gps.append(q)
        S.gtop, S.gp = np.concatenate(gts), np.concatenate(gps)
        return np.concatenate(tops), np.concatenate(p1s)
    # ladder thresholds on AU-val (per species): species-stated-but-wrong ≤ 7 %
    S = sets["AU-val"]
    top, p1 = run_set(S, T=Tf)
    grid = [round(float(x), 2) for x in np.arange(0.3, 0.96, 0.05)]
    lad = {}
    for s_ in grid:
        for g_ in grid:
            lad[(s_, g_)] = mets(S, top, p1, genus, thr=(s_, g_))["ladder"]
    s_thr = min([s_ for s_ in grid if lad[(s_, 0.5)]["species_wrong_sp"] <= 0.07] or [0.95])
    g_ok = [g_ for g_ in grid if lad[(s_thr, g_)]["genus_wrong_sp"] / max(lad[(s_thr, g_)]["genus_sp"], 1e-9) <=
            lad[(s_thr, g_)]["species_wrong_sp"] / max(lad[(s_thr, g_)]["species_sp"], 1e-9)]
    g_thr = min(g_ok or [0.95])
    thr_plain = (s_thr, g_thr)
    # robust ladder: per-species rates on val re-weighted to the training-count mix of
    # ALL classes a user can meet (U classes with ≥ 1 AU research-grade record; label-free)
    # — val over-represents well-photographed classes, where confident errors are rare
    rg = np.array(pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["rg_au"]).to_pydict()["rg_au"])
    def bucket(n):
        return np.select([n == 0, n < 10, n < 50], [0, 1, 2], 3)
    tgt = np.bincount(bucket(n_tr[(rg > 0) & (mapv == np.arange(C))]), minlength=4) / ((rg > 0) & (mapv == np.arange(C))).sum()
    cls_v = np.unique(S.y)
    valmix = np.bincount(bucket(n_tr[cls_v]), minlength=4) / len(cls_v)
    tst = sets["AU-test"]
    testmix = np.bincount(bucket(n_tr[np.unique(tst.y)]), minlength=4) / len(np.unique(tst.y))
    wb_ = tgt / np.maximum(valmix, 1e-9)
    cw = {int(c): float(wb_[bucket(n_tr[c])]) for c in cls_v}

    def lad_w(s_, g_):
        sp_ = p1 >= s_
        ge = ~sp_ & (S.gp >= g_)
        ok_s = top[:, 0] == S.y
        ok_g = S.gtop == genus[S.y]
        per = {}
        for nm_, h in (("species", sp_), ("species_wrong", sp_ & ~ok_s), ("genus", ge), ("genus_wrong", ge & ~ok_g),
                       ("not_sure", ~sp_ & ~ge)):
            _, inv = np.unique(S.y, return_inverse=True)
            m_ = np.bincount(inv, h.astype(float)) / np.bincount(inv)
            wts = np.array([cw[int(c)] for c in np.unique(S.y)])
            per[nm_ + "_sp"] = float((m_ * wts).sum() / wts.sum())
        return per
    ladw = {(s_, g_): lad_w(s_, g_) for s_ in grid for g_ in grid}
    s_thr = min([s_ for s_ in grid if ladw[(s_, 0.5)]["species_wrong_sp"] <= 0.07] or [0.95])
    g_ok = [g_ for g_ in grid if ladw[(s_thr, g_)]["genus_wrong_sp"] / max(ladw[(s_thr, g_)]["genus_sp"], 1e-9) <=
            ladw[(s_thr, g_)]["species_wrong_sp"] / max(ladw[(s_thr, g_)]["species_sp"], 1e-9)]
    thr = (s_thr, min(g_ok or [0.95]))
    per_bucket = {}
    for k in range(4):
        m_ = np.array([bucket(n_tr[c]) == k for c in S.y])
        if m_.any():
            per_bucket[["0", "1-9", "10-49", "50-100"][k]] = mets(S, top, p1, genus, m_, thr_plain)["ladder"]["species_wrong_sp"]
    ladder_diag = {"val_class_mix": valmix.tolist(), "AU-test_class_mix": testmix.tolist(), "target_mix": tgt.tolist(),
                   "val_stated_wrong_by_bucket_at_plain": per_bucket, "plain": thr_plain, "robust": thr,
                   "val_reweighted_at_plain": ladw[thr_plain], "val_reweighted_at_robust": ladw[thr]}
    print(f"ladder: plain {thr_plain}, robust (val re-weighted to the class mix) {thr}; {ladder_diag}", flush=True)

    res = {"final_run": final, "merged_classes": {int(k): int(v) for k, v in merge.items()}, "runs": {k: {"cfg": r["cfg"], "info": r["info"]} for k, r in runs.items()},
           "prior_sweep": sweep, "prior_best_by_kind": best_by_kind, "prior": bp, "temperature": Tf,
           "temperature_nll": nll, "ladder": {"species": thr[0], "genus": thr[1], "at_val": lad[thr],
                                              "diagnostics": ladder_diag}}

    # ---- report sets for one variant
    def report(tag, **kw):
        out = {}
        for nm in ("A-test", "C-report", "AU-test"):
            S = sets[nm]
            top, p1 = run_set(S, **kw)
            S.__dict__["top_" + tag] = top
            if nm == "C-report":
                out["C-main"] = mets(S, top, p1, genus, S.sub == "main", thr)
                out["C-euc"] = mets(S, top, p1, genus, S.sub == "euc", thr)
            elif nm == "AU-test":
                out["AU-test"] = mets(S, top, p1, genus, None, thr)
                out["AU-test-euc"] = mets(S, top, p1, genus, euc[S.y], thr)
                ntr = n_tr[S.y]
                out["buckets"] = {bn: mets(S, top, p1, genus, (ntr >= lo) & (ntr <= hi)) for lo, hi, bn in BUCKETS}
                S.__dict__["p1_" + tag] = p1
            else:
                out["A-test"] = mets(S, top, p1, genus, None, thr)
        return out
    rep = {"final": report("final", T=Tf)}
    if os.environ.get("EVAL_LIGHT"):  # prior comparisons: tuning + the final row only
        res["report"] = {"final": rep["final"]}
        S = sets["AU-test"]
        top, p1 = run_set(S, T=Tf)
        corr = (top[:, 0] == S.y).astype(float)
        _, inv = np.unique(S.y, return_inverse=True)
        res["ece_AU-test"] = {"natural": ece(p1, corr, S.w)[0], "per_species": ece(p1, corr, 1.0 / np.bincount(inv)[inv])[0]}
        res["n_train_buckets"] = {bn: int(((n_tr >= lo) & (n_tr <= hi)).sum()) for lo, hi, bn in BUCKETS}
        out = os.environ.get("EVAL_OUT") or os.path.join(V2, "eval-light.json")
        json.dump(res, open(out, "w"), indent=1, default=float)
        print(f"light eval → {out} ({time.time() - t0:.0f} s)")
        return
    thr_keep = thr
    thr = thr_plain
    rep["final_plain_ladder"] = report("final_pl", T=Tf)
    thr = thr_keep
    print(f"final reported ({time.time() - t0:.0f} s)", flush=True)
    rep["no_prior"] = report("noprior", prior=None, T=Tf)
    rep["uncalibrated"] = report("uncal", T=1.0)
    # per-photo dump for the error analysis (final + no-prior predictions)
    for nm in ("A-test", "C-report", "AU-test"):
        S = sets[nm]
        top, p1 = run_set(S, T=Tf)
        tn, pn = run_set(S, T=Tf, prior=None)
        np.savez(os.path.join(V2, f"pred-{nm}.npz"), pid=S.pid, ext=S.ext, y=S.y, lat=S.lat, lon=S.lon, w=S.w,
                 sub=S.sub if S.sub is not None else np.array([]), top=top, p1=p1, top_noprior=tn, p1_noprior=pn,
                 thr=np.array(thr))
    for k in KINDS:
        if k != bp["kind"]:
            rep[f"prior_{k}"] = report(f"pk_{k}", prior=best_by_kind[k], T=Tf)
            drop_cache(k)
            print(f"prior {k} reported ({time.time() - t0:.0f} s)", flush=True)
    base30 = "tau1-wd0.01"  # the ablations' base (30-epoch cosine); final = its 12-epoch follow-up
    for r in (base30, "abl-random-init", "abl-no-l2sp", "abl-genus-share", "abl-plain-ce", "size-25", "size-50"):
        if r in runs:
            rep[r] = report(r, run=r, T=Tf)
    if "abl-plain-ce" in runs:  # post-hoc logit adjustment on the plain-CE head, τ' on val
        best = None
        for pt in (0.25, 0.5, 0.75, 1.0, 1.5):
            S = sets["AU-vtune"]
            L = final_logp(S, slice(None), run="abl-plain-ce", post_tau=pt)
            v = quick(S, L)[0]
            if best is None or v > best[1]:
                best = (pt, v)
        rep["abl-posthoc-la"] = report("posthoc", run="abl-plain-ce", post_tau=best[0], T=Tf)
        res["posthoc_tau"] = best[0]
    # z1 and the current gated hybrid (shipped files)
    z1 = {}
    Tsh = BS.unit(D["T"].astype(np.float32) - D["T"].astype(np.float32).mean(0))
    z1p = EA.AuPrior(C)
    cur = {}
    for nm in ("A-test", "C-report", "AU-test"):
        S = sets[nm]
        tz, pz, gz, gpz, tc, pc_, gc, gpc = [], [], [], [], [], [], [], []
        for a in range(0, S.n, 1024):
            e = S.emb[a:a + 1024].astype(np.float32)
            la, lo = S.lat[a:a + 1024], S.lon[a:a + 1024]
            qs = BS.unit(BS.unit(e) - ship.mu[None])
            K = z1p.density(la, lo, 25.0)
            Z = 70.0 * (qs @ Tsh.T) + np.log((K + 16 * z1p.freq[None]) / (K.sum(1, keepdims=True) + 16))
            r_ = preds(torch.log_softmax(torch.from_numpy(Z.astype(np.float32)).to(DEV), 1), gt, G)
            tz.append(r_[0]), pz.append(r_[1]), gz.append(r_[2]), gpz.append(r_[3])
            Lh, named = ash.answer(e, la, lo)
            Lt_ = torch.from_numpy(Lh.astype(np.float32)).to(DEV)
            t5, p_, g_, gp_ = preds(Lt_, gt, G)
            for j in np.nonzero(named != t5[:, 0])[0]:
                rest = [x for x in t5[j] if x != named[j]]
                t5[j] = [named[j]] + rest[:4]
            p_ = np.exp(Lh[np.arange(len(named)), named])
            tc.append(t5), pc_.append(p_), gc.append(g_), gpc.append(gp_)
        for tag, (T_, P_, G_, GP_) in (("z1", (tz, pz, gz, gpz)), ("gated_hybrid", (tc, pc_, gc, gpc))):
            S.gtop, S.gp = np.concatenate(G_), np.concatenate(GP_)
            top, p1 = mapv[np.concatenate(T_)], np.concatenate(P_)  # a twin's answer = its merged class
            S.__dict__["top_" + tag] = top
            d = (z1 if tag == "z1" else cur)
            th = thr if tag == "z1" else (0.7, 0.7)  # (gated hybrid: its AU ladder; Tas path 0.5 — approx.)
            if nm == "C-report":
                d["C-main"] = mets(S, top, p1, genus, S.sub == "main", th)
                d["C-euc"] = mets(S, top, p1, genus, S.sub == "euc", th)
            elif nm == "AU-test":
                d["AU-test"] = mets(S, top, p1, genus, None, th)
                d["AU-test-euc"] = mets(S, top, p1, genus, euc[S.y], th)
                ntr = n_tr[S.y]
                d["buckets"] = {bn: mets(S, top, p1, genus, (ntr >= lo) & (ntr <= hi)) for lo, hi, bn in BUCKETS}
            else:
                d["A-test"] = mets(S, top, p1, genus, None, th)
    rep["z1"], rep["gated_hybrid"] = z1, cur
    A = sets["A-test"]
    inl = A.y >= 0
    r0 = inl & (A.top_gated_hybrid[:, 0] == A.y)
    rf = inl & (A.top_final[:, 0] == A.y)
    res["A_paired_final_vs_gated"] = {"lost": int((r0 & ~rf).sum()), "gained": int((~r0 & rf).sum()),
                                      "photos": int(inl.sum())}
    v0 = inl & (ash.ship2u[np.argmax(ship.logp(A.emb.astype(np.float32), A.lat, A.lon), 1)] == A.y)
    res["A_paired_final_vs_v0"] = {"lost": int((v0 & ~rf).sum()), "gained": int((~v0 & rf).sum())}
    np.savez(os.path.join(V2, "pred-A-test-hybrid.npz"), pid=A.pid, top=A.top_gated_hybrid)
    print(f"comparisons ({time.time() - t0:.0f} s)", flush=True)
    # ---- prototype kNN term: does it earn its 16 MB? (protos = class means of the train photos)
    Xc = torch.cat([torch.nn.functional.normalize(torch.nn.functional.normalize(
        torch.from_numpy(D["Xtr"][i:i + 65536].astype(np.float32)), dim=-1) - torch.from_numpy(mu), dim=-1)
        for i in range(0, len(D["ytr"]), 65536)])
    Pm = torch.zeros(C, 1024).index_add_(0, torch.from_numpy(D["ytr"].astype(np.int64)), Xc)
    has = torch.from_numpy(n_tr > 0)
    Pm = torch.nn.functional.normalize(Pm[has], dim=-1).to(DEV)
    plab = torch.nonzero(has)[:, 0].to(DEV)
    del Xc

    def knn_L(S, rows, k=10, tau=0.05):
        s = S.q[rows].to(DEV).float() @ Pm.T
        v, i = s.topk(k, dim=1)
        wv = torch.exp((v - v[:, :1]) / tau)
        P = torch.zeros(s.shape[0], C, device=DEV).scatter_add_(1, plab[i], wv)
        return torch.log(P / P.sum(1, keepdim=True) + 1e-6 / C)
    S = sets["AU-vtune"]
    om_res = {}
    for om in (0.0, 0.25, 0.5, 1.0):
        L = torch.log_softmax(torch.log_softmax(logits(final, S), 1) + om * torch.log_softmax(knn_L(S, slice(None)), 1), 1)
        L = torch.log_softmax(L + bp["lam"] * lp(S, bp["kind"], bp["sigma"], bp["alpha"]), 1)
        om_res[om] = quick(S, L)[0]
    res["knn_omega_val_sp"] = om_res
    print("kNN blend on val (per-species top-1):", om_res, flush=True)
    res["report"] = rep
    # ---- diagnostics: calibration (AU-test, natural and balanced), per-class acc vs n, curves
    S = sets["AU-test"]
    _, inv = np.unique(S.y, return_inverse=True)
    bal = 1.0 / np.bincount(inv)[inv]
    cal = {}
    for tag, T_ in (("uncal", 1.0), ("final", Tf)):
        top, p1 = run_set(S, T=T_)
        corr = (top[:, 0] == S.y).astype(float)
        cal[tag] = {"ece_w": ece(p1, corr, S.w), "ece_sp": ece(p1, corr, bal)}
    res["calibration_AU-test"] = {k: {"ece_w": v["ece_w"][0], "ece_sp": v["ece_sp"][0]} for k, v in cal.items()}
    top = S.top_final
    hit = (top[:, 0] == S.y).astype(float)
    per_acc = np.bincount(inv, hit) / np.bincount(inv)
    cls = np.unique(S.y)
    per_n = n_tr[cls]
    msk = per_n > 0
    A_ = np.c_[np.ones(msk.sum()), np.log10(per_n[msk])]
    coef = np.linalg.lstsq(A_, per_acc[msk], rcond=None)[0]
    res["per_class_fit"] = {"acc ≈ a + b·log10(n)": {"a": float(coef[0]), "b": float(coef[1])},
                            "classes": int(msk.sum()), "zero_photo_classes_acc": float(per_acc[~msk].mean())
                            if (~msk).any() else None}
    json.dump(res, open(os.path.join(V2, "eval.json"), "w"), indent=1, default=float)
    import provenance as PV
    PV.record("v2 eval", inputs=[V.DATA, os.path.join(V2, "runs", final + ".npz"),
                                 os.environ.get("V2PRIOR") or os.path.join(BS.SHIP, "au-prior.bin")],
              outputs=[os.path.join(V2, "eval.json")],
              extra={"chosen": {"run": final, "prior": bp, "temperature": Tf, "ladder": list(thr)}})
    plots(res, runs, final, cal, per_n, per_acc, coef)
    write_md(res, os.path.join(V2, "eval.md"))
    print(open(os.path.join(V2, "eval.md")).read())
    print(f"total {time.time() - t0:.0f} s")


def plots(res, runs, final, cal, per_n, per_acc, coef):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 3, figsize=(16, 4.5))
    for k, r in sorted(runs.items()):
        c = r["curve"]
        ep = [x["epoch"] for x in c]
        lw, al = (2.5, 1) if k == final else (0.8, 0.5)
        ax[0].plot(ep, [x["train_loss"] for x in c], lw=lw, alpha=al, label=k if k == final else None)
        ax[1].plot(ep, [x["val_loss"] for x in c], lw=lw, alpha=al, label=k)
        ax[2].plot(ep, [x["val_top1_sp"] for x in c], lw=lw, alpha=al, label=k)
    ax[0].set_title("train loss (logit-adjusted CE)"); ax[0].set_yscale("log")
    ax[1].set_title("val loss (plain CE, uniform prior)")
    ax[2].set_title("val top-1 per species (no prior)")
    for a in ax:
        a.set_xlabel("epoch")
    ax[2].legend(fontsize=6, ncol=2)
    fig.tight_layout(); fig.savefig(os.path.join(V2, "curves.png"), dpi=120); plt.close(fig)
    fig, ax = plt.subplots(1, 2, figsize=(10, 4.5))
    for i, key in enumerate(("ece_w", "ece_sp")):
        for tag, st in (("uncal", "--"), ("final", "-")):
            e, rows = cal[tag][key]
            ax[i].plot([r[1] for r in rows], [r[2] for r in rows], st, marker="o", label=f"{tag} ECE {e:.3f}")
        ax[i].plot([0, 1], [0, 1], ":", c="grey")
        ax[i].set_title("reliability, AU-test, " + ("natural mix" if key == "ece_w" else "per species"))
        ax[i].set_xlabel("confidence"); ax[i].set_ylabel("accuracy"); ax[i].legend()
    fig.tight_layout(); fig.savefig(os.path.join(V2, "reliability.png"), dpi=120); plt.close(fig)
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.5))
    m = per_n > 0
    jit = np.random.default_rng(0).uniform(-0.02, 0.02, m.sum())
    ax[0].scatter(per_n[m], per_acc[m] + jit, s=3, alpha=0.25)
    xs = np.logspace(0, 2, 50)
    ax[0].plot(xs, coef[0] + coef[1] * np.log10(xs), c="r", label=f"{coef[0]:.2f} + {coef[1]:.2f}·log10(n)")
    ax[0].set_xscale("log"); ax[0].set_xlabel("training photos of the class"); ax[0].set_ylabel("AU-test top-1 of the class")
    ax[0].legend(); ax[0].set_title("per-class accuracy vs training photos")
    rep = res["report"]
    sz = [(25, "size-25"), (50, "size-50"), (100, "final")]
    for key, lab in (("AU-test", "AU-test"), ("AU-test-euc", "AU-test eucalypts"), ("C-euc", "C-euc")):
        pts = [(p, rep[r][key]["top1_sp"]) for p, r in sz if r in rep]
        ax[1].plot([p for p, _ in pts], [v for _, v in pts], marker="o", label=lab + " per species")
    ax[1].set_xlabel("% of each class's photos used"); ax[1].set_ylabel("top-1 per species"); ax[1].legend()
    ax[1].set_title("data-size curve")
    fig.tight_layout(); fig.savefig(os.path.join(V2, "data_size.png"), dpi=120); plt.close(fig)


def write_md(res, path):
    P = lambda x: "–" if x is None else f"{100 * x:.1f}"  # noqa: E731
    rep = res["report"]
    cols = ("A-test", "C-main", "C-euc", "AU-test", "AU-test-euc")
    out = ["Per species (primary) / natural mix. top-1, top-5, genus, conf. wrong (p ≥ .5 and wrong):", "",
           "| variant | " + " | ".join(f"{c} top-1 sp/w | {c} top-5 sp/w | {c} genus sp | {c} c.wrong sp" for c in cols) + " |",
           "|" + "---|" * (1 + 4 * len(cols))]
    for v, r in rep.items():
        cells = []
        for c in cols:
            m = r.get(c)
            if m is None:
                cells += ["–"] * 4
                continue
            cells += [f"{P(m['top1_sp'])} / {P(m['top1_w'])}", f"{P(m['top5_sp'])} / {P(m['top5_w'])}",
                      P(m["genus_sp"]), P(m["conf_wrong_sp"])]
        out.append(f"| {v} | " + " | ".join(cells) + " |")
    out += ["", "AU-test by training photos (top-1 per species / natural):"]
    for v in ("final", "gated_hybrid", "z1", "abl-genus-share", "abl-no-l2sp", "abl-random-init"):
        if v in rep and "buckets" in rep[v]:
            out.append(f"- {v}: " + ", ".join(f"{b} {P(m['top1_sp'])}/{P(m['top1_w'])} (n {m['n']})"
                                               for b, m in rep[v]["buckets"].items()))
    f = rep["final"]
    out += ["", "Ladder (final, per species / natural): " + "; ".join(
        f"{c}: species {P(f[c]['ladder']['species_sp'])}/{P(f[c]['ladder']['species_w'])}, stated wrong "
        f"{P(f[c]['ladder']['species_wrong_sp'])}/{P(f[c]['ladder']['species_wrong_w'])}, genus "
        f"{P(f[c]['ladder']['genus_sp'])} (wrong {P(f[c]['ladder']['genus_wrong_sp'])}), not sure "
        f"{P(f[c]['ladder']['not_sure_sp'])}" for c in cols)]
    out += ["", f"final run {res['final_run']}, prior {res['prior']}, T {res['temperature']:.3f}, ladder "
            f"{res['ladder']['species']}/{res['ladder']['genus']}, post-hoc τ' {res.get('posthoc_tau')}",
            f"prior best per kind (val per species): " + json.dumps(res["prior_best_by_kind"]),
            f"kNN ω (val per species): {res['knn_omega_val_sp']}",
            f"A paired: final vs gated {res['A_paired_final_vs_gated']}, final vs v0 {res['A_paired_final_vs_v0']}",
            f"calibration: {res['calibration_AU-test']}", f"per-class fit: {res['per_class_fit']}"]
    open(path, "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()

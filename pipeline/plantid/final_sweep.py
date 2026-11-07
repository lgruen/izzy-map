#!/usr/bin/env python3
"""Final plant-ID configuration: the COMBINATIONS of the components tested one at
a time (head × location prior × kNN banks), plus head ensembles, every weight
chosen on val J = ½ (AU-val top-1 per species re-weighted to the all-AU-species
training-count mix + A-val natural top-1) — bank_analysis.py's objective; the
report sets are read once, for the final candidates only. Analysis only:
bank_analysis / bank_prune / prior_adaptive / head_capacity / ladder_v3 loaders
and protocol are imported, never edited; the shipped files are untouched.

Score of a photo (all terms in log space, as build_ship.V2Ship):
  z      = mean over the ensemble's heads of the head logits (scale-kept τ-norm tn
           per head; merged twin columns masked), Lh = log_softmax(z / t)
  inside the Tasmania box:  Li = log_softmax(Lh + ω_b · max(L_tasbank, fl_b))
  outside:  Li = Lh, or with the national bank (bank_prune cov-c50-85000, k 50,
           τ 0.05, β 0.5, votes only among the top-10 of Lh + λP):
           Li = log_softmax(Lh + ω_n · max(L_nat, fl_n))
  prior  "shipped": main (log1p σ 10 α 64) × λ outside, box (√ σ 5 α 16) × λ_b inside;
         "adaptive": prior_adaptive F2 (log1p, s0 14, γ .25, σ 2–20, σ_ρ 5, α0 32) × λ everywhere
  S = Li + prior;  displayed log p = log_softmax(log_softmax(S) / T), image-only log_softmax(Li / T)
T = calibration temperature (½ AU-val class-balanced NLL + ½ A-val natural NLL);
the ladder (ladder_v3's rule and greedy search) is re-chosen on AU-val per config.

Subcommands (eval_v2.py's env; FINAL/TAUNORM/V2DATA/V2PRIOR as bank_analysis.py):
  prep              adaptive-F2 prior per set → FS/prior-adF2-<set>.npy (fp16, n × C)
  fit [cfg …]       coordinate descent on val J per configuration → FS/fit.json
  calib [cfg …]     T + ladder on val for fitted configs → FS/calib.json
  test cfg …        report sets ONCE per config (+ ECE, ladder, size/time) → FS/test.json
  boot cfg …        paired bootstrap (photos resampled) vs "shipped" on A-test / AU-test → FS/boot.json
FS = env FS_WORK (default australia/v2/final_sweep).
"""
import itertools
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bank_analysis as BA  # noqa: E402
import build_ship as BS  # noqa: E402
import head_capacity as HC  # noqa: E402

V2 = BA.V.V2
FS = os.environ.get("FS_WORK") or os.path.join(V2, "final_sweep")
HCR = os.environ.get("FS_HCR") or os.path.join(V2, "head_capacity", "runs")  # e.g. head_capacity2/runs (retrained heads)
DEV = "mps"
os.makedirs(FS, exist_ok=True)

HEADS = {  # name: path (linear v2 runs: W, b; head_capacity runs: hc_head_fn)
    "lin0": os.path.join(V2, "runs", "final-cb50-s0.npz"),
    "lin1": os.path.join(V2, "runs", "final-cb50-s1.npz"),
    "lin2": os.path.join(FS, "heads", "hc-lin-e12-s2.npz"),
    "mpA0": os.path.join(HCR, "hc-mpAc-s0.npz"),
    "mpA1": os.path.join(HCR, "hc-mpAc-s1.npz"),
    "mpB1": os.path.join(FS, "heads", "hc-mpBc-s1.npz"),
    "mpC1": os.path.join(FS, "heads", "hc-mpCc-s1.npz"),
    "mpAg1": os.path.join(FS, "heads", "hc-mpAc-g0.3-s1.npz"),
}
ENS = {"lin1": ["lin1"], "lin01": ["lin0", "lin1"], "lin012": ["lin0", "lin1", "lin2"],
       "mpA1": ["mpA1"], "mpA01": ["mpA0", "mpA1"], "mpB1": ["mpB1"], "mpC1": ["mpC1"], "mpAg1": ["mpAg1"],
       "mix11": ["lin1", "mpA1"], "mix0101": ["lin0", "lin1", "mpA0", "mpA1"]}
NAT = "cov-c50-85000"
NATP = {"k": 50, "tau": 0.05, "beta": 0.5, "rerank": 10}
F2 = {"t": "log1p", "s0": 14.0, "gamma": 0.25, "smin": 2.0, "smax": 20.0, "srho": 5.0, "a0": 32.0, "delta": 0.0}
GRID = {"t": [0.8, 1.0, 1.25, 1.5], "tn": [0.25, 0.5, 0.75], "lam": [0.75, 1.0, 1.25, 1.5, 2.0],
        "lam_b": [0.75, 1.0, 1.25, 1.5, 2.0, 2.5], "om_b": [0.0, 0.25, 0.5, 1.0, 2.0, 3.0], "fl_b": [-1.5, -3.0, -5.0, -10.0, -30.0],
        "om_n": [0.25, 0.5, 1.0, 2.0, 4.0], "fl_n": [-1.5, -3.0, -10.0]}
SHIPPED = {"ens": "lin1", "prior": "shipped", "nat": False, "t": 1.0, "tn": 0.5, "lam": 1.0, "lam_b": 1.0,
           "om_b": 2.0, "fl_b": -30.0, "om_n": 1.0, "fl_n": -3.0}
OUT_KEYS = ("ens", "tn", "t", "prior", "lam", "nat", "om_n", "fl_n")
IN_KEYS = ("ens", "tn", "t", "prior", "lam", "lam_b", "om_b", "fl_b")


def log(*a):
    print(*a, flush=True)


def cfg_name(c):
    return f"{c['ens']}|{c['prior']}|{'nat' if c['nat'] else 'box'}"


def all_cfgs():
    out = []
    for e in ("lin1", "lin01", "lin012", "mpA1", "mpA01", "mix11", "mix0101"):
        for pr in ("shipped", "adaptive"):
            for nat in (False, True):
                out.append({**SHIPPED, "ens": e, "prior": pr, "nat": nat,
                            **({"om_b": 1.0, "fl_b": -30.0} if pr == "adaptive" else {})})
    return out


# ------------------------------------------------------------ prep

def cmd_prep():
    import prior_adaptive as PA
    Z = BA.load()
    P = PA.AdaptivePrior(BS.V2_PRIOR_EVAL)
    C = len(Z["mapv"])
    for nm in BA.SETS:
        f = os.path.join(FS, f"prior-adF2-{nm}.npy")
        if os.path.exists(f):
            continue
        t0 = time.time()
        lat, lon = Z[nm + "/lat"], Z[nm + "/lon"]
        arr = np.lib.format.open_memmap(f + ".part.npy", "w+", np.float16, (len(lat), C))
        for i in range(0, len(lat), 2048):
            arr[i:i + 2048] = P.log_prior(lat[i:i + 2048], lon[i:i + 2048], {**F2, "lam": 1.0})
        arr.flush()
        del arr
        os.replace(f + ".part.npy", f)
        log(f"adaptive prior {nm}: {len(lat):,} rows ({time.time() - t0:.0f} s)")


# ------------------------------------------------------------ scorer

class Sweep:
    def __init__(self):
        import torch
        self.torch = torch
        self.Z = BA.load()
        self.sc = BA.Scorer(self.Z)
        self.C = self.sc.C
        self.cm = torch.from_numpy(BA.colmask(self.Z)).to(DEV)
        self.mu = self.Z["mu"].astype(np.float32)
        self.q = {}
        self.boxes, self.natfn, self.lcache, self.memo = {}, {}, {}, {}
        self.hfn = {}
        y = self.Z["mapv"][np.asarray(BA.npz_memmap(BA.V.DATA, "ytr")).astype(np.int64)]
        r = np.load(os.path.join(BA.WORK, "prune", f"rows-{NAT}.npy"))
        self.nat_rows = len(r)
        self.nat_lab = torch.from_numpy(y[r]).to(DEV)
        self.nat_cnt = torch.bincount(self.nat_lab, minlength=self.C).float()
        self.nb = dict(np.load(os.path.join(BA.WORK, "prune", f"nb-{NAT}.npz")))

    # -- inputs
    def Q(self, nm):
        if nm not in self.q:
            e = self.Z[nm + "/emb"].astype(np.float32)
            self.q[nm] = self.torch.from_numpy(BS.unit(BS.unit(e) - self.mu[None]).astype(np.float32)).to(DEV)
        return self.q[nm]

    def head(self, h, tn):
        torch = self.torch
        k = (h, tn)
        if k not in self.hfn:
            while len(self.hfn) >= 4:   # bounded: mproto weights are ~0.25 GB fp32 each on the device
                self.hfn.pop(next(iter(self.hfn)))
                torch.mps.empty_cache()
            p = HEADS[h]
            z = np.load(p)
            if "Kc" in z.files or "tn_applied" in z.files:
                self.hfn[k] = HC.hc_head_fn(p, tn=tn, dev=DEV)
            else:
                W = HC.taunorm(z["W"].astype(np.float32), tn)
                Wt, bt = torch.from_numpy(W).to(DEV), torch.from_numpy(z["b"].astype(np.float32)).to(DEV)
                self.hfn[k] = lambda q, Wt=Wt, bt=bt: q @ Wt.T + bt
        return self.hfn[k]

    def logits(self, nm, rows, ens, tn):
        """Ensemble-mean logits (rows: np int array) → torch float32."""
        torch = self.torch
        key = (nm, ens, tn)
        if nm.endswith("val"):   # val: cache the whole set (fp16) — the coordinate descent re-reads it
            if key not in self.lcache:
                while len(self.lcache) >= 3:
                    self.lcache.pop(next(iter(self.lcache)))
                    torch.mps.empty_cache()
                q = self.Q(nm)
                out = torch.empty(len(q), self.C, dtype=torch.float16, device=DEV)
                for a in range(0, len(q), 2048):
                    z = self._ens(q[a:a + 2048], ens, tn)
                    out[a:a + 2048] = (z - z.max(1, keepdim=True).values).half()   # shift-invariant; fp16 is exact near the top
                self.lcache[key] = out
            return self.lcache[key][torch.from_numpy(rows).to(DEV)].float()
        return self._ens(self.Q(nm)[torch.from_numpy(rows).to(DEV)], ens, tn)

    def _ens(self, q, ens, tn):
        hs = ENS[ens]
        with self.torch.no_grad():
            z = sum(self.head(h, tn)(q) for h in hs) / len(hs)
        return z

    def box(self, nm):
        if nm not in self.boxes:
            self.boxes[nm] = BA.box_knn_rows(self.Z, nm)
        return self.boxes[nm]

    def prior_rows(self, nm, rows, kind):
        f = {"main": os.path.join(BA.WORK, f"prior-main-{nm}.npy"), "box": os.path.join(BA.WORK, f"prior-box-{nm}.npy"),
             "ad": os.path.join(FS, f"prior-adF2-{nm}.npy")}[kind]
        if kind == "box" and not os.path.exists(f):
            P2 = getattr(self, "P2", None) or BS.V2Prior(BA.PRIOR)
            self.P2 = P2
            return self.torch.from_numpy(P2.log_prior(self.Z[nm + "/lat"][rows], self.Z[nm + "/lon"][rows], *BA.BOX[:3])
                                         .astype(np.float32)).to(DEV)
        return self.torch.from_numpy(np.asarray(np.load(f, mmap_mode="r")[rows], np.float32)).to(DEV)

    # -- the score
    def score_rows(self, nm, rows, c, inbox):
        """→ (S, Li) torch float32 for rows (all inside or all outside the box)."""
        torch = self.torch
        Lh = torch.log_softmax(self.logits(nm, rows, c["ens"], c["tn"]) / c["t"] + self.cm, 1)
        if inbox:
            _, bf = self.box(nm)
            Li = torch.log_softmax(Lh + c["om_b"] * bf(rows).clamp(min=c["fl_b"]), 1)
            P = c["lam_b"] * self.prior_rows(nm, rows, "box") if c["prior"] == "shipped" else \
                c["lam"] * self.prior_rows(nm, rows, "ad")
            return Li + P, Li
        P = c["lam"] * self.prior_rows(nm, rows, "main" if c["prior"] == "shipped" else "ad")
        Li = Lh
        if c["nat"]:
            v = torch.from_numpy(self.nb[nm + "/v"][rows, :NATP["k"]].astype(np.float32)).to(DEV)
            j = torch.from_numpy(self.nb[nm + "/i"][rows, :NATP["k"]].astype(np.int64)).to(DEV)
            w = torch.exp((v - v[:, :1]) / NATP["tau"])
            lab = self.nat_lab[j]
            w = w * self.nat_cnt.clamp(min=1)[lab] ** -NATP["beta"]
            Pk = torch.zeros(len(rows), self.C, device=DEV).scatter_add_(1, lab, w)
            Lk = torch.log(Pk / Pk.sum(1, keepdim=True) + 1e-6 / self.C)
            t = (Lh + P).topk(NATP["rerank"], dim=1).indices
            keep = torch.zeros_like(Lk, dtype=torch.bool).scatter_(1, t, True)
            Lk = torch.where(keep, Lk, torch.full_like(Lk, -1e4))
            Li = torch.log_softmax(Lh + c["om_n"] * Lk.clamp(min=c["fl_n"]), 1)
        return Li + P, Li

    def parts(self, nm):
        bx, _ = self.box(nm)
        return {True: np.nonzero(bx)[0], False: np.nonzero(~bx)[0]}

    def top5(self, nm, c, chunk=2048):
        torch = self.torch
        n = len(self.Z[nm + "/y"])
        out = np.zeros((n, 5), np.int64)
        for inbox, rows in self.parts(nm).items():
            if not len(rows):
                continue
            key = (nm, inbox) + tuple(c[k] for k in (IN_KEYS if inbox else OUT_KEYS))
            if key not in self.memo:
                res = np.zeros((len(rows), 5), np.int64)
                with torch.no_grad():
                    for a in range(0, len(rows), chunk):
                        S, _ = self.score_rows(nm, rows[a:a + chunk], c, inbox)
                        res[a:a + chunk] = S.topk(5, dim=1).indices.cpu().numpy()
                if nm.endswith("val"):
                    self.memo[key] = res
                else:
                    out[rows] = res
                    continue
            out[rows] = self.memo[key]
        return out

    def J(self, c):
        r = {nm: self.sc.metrics(nm, self.top5(nm, c)) for nm in ("AU-val", "A-val")}
        return 0.5 * (r["AU-val"]["top1_sp_rw"] + r["A-val"]["top1_nat"]), r

    def feats(self, nm, c, T, genus, chunk=2048):
        """Calibrated ladder features + log p of the truth, for every photo of nm."""
        torch = self.torch
        n = len(self.Z[nm + "/y"])
        y = self.Z[nm + "/y"]
        gt = torch.from_numpy(genus).to(DEV)
        G = int(genus.max()) + 1
        F = {k: np.zeros(n, np.float64) for k in ("p1", "p2", "pimg", "gp", "lpy")}
        F.update({k: np.zeros(n, np.int64) for k in ("named", "second", "gtop")})
        F["top5"] = np.zeros((n, 5), np.int64)
        for inbox, rows in self.parts(nm).items():
            for a in range(0, len(rows), chunk):
                r = rows[a:a + chunk]
                with torch.no_grad():
                    S, Li = self.score_rows(nm, r, c, inbox)
                    L = torch.log_softmax(torch.log_softmax(S, 1) / T, 1)
                    Lic = torch.log_softmax(Li / T, 1)
                    o = L.topk(5, dim=1)
                    named = o.indices[:, 0]
                    pg = torch.zeros(len(r), G, device=DEV).index_add_(1, gt, L.exp())
                    gp, gtop = pg.max(1)
                    ar = torch.arange(len(r), device=DEV)
                    yt = torch.from_numpy(np.maximum(y[r], 0)).to(DEV)
                    F["top5"][r] = o.indices.cpu().numpy()
                    F["named"][r] = named.cpu().numpy()
                    F["second"][r] = o.indices[:, 1].cpu().numpy()
                    F["p1"][r] = o.values[:, 0].exp().cpu().numpy()
                    F["p2"][r] = o.values[:, 1].exp().cpu().numpy()
                    F["pimg"][r] = Lic[ar, named].exp().cpu().numpy()
                    F["gp"][r], F["gtop"][r] = gp.cpu().numpy(), gtop.cpu().numpy()
                    F["lpy"][r] = L[ar, yt].cpu().numpy()
        return F

    def tlogits_val(self, c, Ts):
        """NLL(T) on val: ½ AU-val class-balanced + ½ A-val natural."""
        torch = self.torch
        res = {}
        for nm in ("AU-val", "A-val"):
            y = self.Z[nm + "/y"]
            m = y >= 0
            _, inv = np.unique(y[m], return_inverse=True)
            wts = np.zeros(len(y))
            wts[m] = (1.0 / np.bincount(inv)[inv]) if nm == "AU-val" else self.Z[nm + "/w"][m]
            nll = {T: 0.0 for T in Ts}
            for inbox, rows in self.parts(nm).items():
                for a in range(0, len(rows), 2048):
                    r = rows[a:a + 2048]
                    with torch.no_grad():
                        S, _ = self.score_rows(nm, r, c, inbox)
                        S = torch.log_softmax(S, 1)
                        yt = torch.from_numpy(np.maximum(y[r], 0)).to(DEV)
                        for T in Ts:
                            lp = torch.log_softmax(S / T, 1).gather(1, yt[:, None])[:, 0].cpu().numpy()
                            nll[T] += float(-(lp * wts[r]).sum())
            res[nm] = {T: v / wts.sum() for T, v in nll.items()}
        return {T: 0.5 * (res["AU-val"][T] + res["A-val"][T]) for T in Ts}


# ------------------------------------------------------------ fit

def cmd_fit(names):
    sw = Sweep()
    path = os.path.join(FS, "fit.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    t0 = time.time()
    j0, r0 = sw.J(SHIPPED)
    log(f"shipped val J {j0:.4f} (AU-val rw {r0['AU-val']['top1_sp_rw']:.4f}, A-val nat {r0['A-val']['top1_nat']:.4f}) "
        f"({time.time() - t0:.0f} s)")
    res["shipped"] = {"cfg": SHIPPED, "J": j0, "AU-val_rw": r0["AU-val"]["top1_sp_rw"], "A-val_nat": r0["A-val"]["top1_nat"]}
    for c0 in all_cfgs():
        nm = cfg_name(c0)
        if (names and nm not in names and c0["ens"] not in names) or nm in res:
            continue
        if any(not os.path.exists(HEADS[h]) for h in ENS[c0["ens"]]):
            log("skip (missing head)", nm)
            continue
        cfg, cur = dict(c0), sw.J(c0)[0]
        free = ["t", "lam"] + (["lam_b"] if cfg["prior"] == "shipped" else []) + ["om_b", "fl_b"] + \
            (["om_n", "fl_n"] if cfg["nat"] else []) + (["tn"] if len(ENS[cfg["ens"]]) > 1 else [])
        n_ev = 0
        for rnd in range(3):
            changed = False
            for p in free:
                for v in GRID[p]:
                    if v == cfg[p]:
                        continue
                    c2 = {**cfg, p: v}
                    j = sw.J(c2)[0]
                    n_ev += 1
                    if j > cur + 1e-5:
                        cur, cfg, changed = j, c2, True
            if not changed:
                break
        jb, rb = sw.J(cfg)
        res[nm] = {"cfg": cfg, "J": jb, "AU-val_rw": rb["AU-val"]["top1_sp_rw"], "A-val_nat": rb["A-val"]["top1_nat"],
                   "AU-val_sp": rb["AU-val"]["top1_sp"], "A-val_sp": rb["A-val"]["top1_sp"], "evals": n_ev}
        log(f"{nm:28s} J {jb:.4f} (AU-val rw {rb['AU-val']['top1_sp_rw']:.4f}, A-val nat {rb['A-val']['top1_nat']:.4f}) "
            f"{ {k: cfg[k] for k in free} } [{n_ev} evals, {time.time() - t0:.0f} s]")
        json.dump(res, open(path, "w"), indent=1)
        sw.memo.clear()


GROUPS = (("t",), ("lam",), ("lam_b",), ("om_b", "fl_b"), ("om_n", "fl_n"), ("tn",))


def cmd_refine(names):
    """Second pass from each fitted cfg: coupled parameters searched JOINTLY (product grids of the
    GROUPS), rounds until no change — coordinate descent alone can stick (ω_b → 0 at floor −30
    makes the floor irrelevant)."""
    sw = Sweep()
    path = os.path.join(FS, "refine.json")   # separate file: may run while `fit` still writes fit.json
    res = json.load(open(path)) if os.path.exists(path) else {}
    fit = json.load(open(os.path.join(FS, "fit.json")))
    t0 = time.time()
    for nm in [n for n in fit if n != "shipped" and (not names or n in names or n.split("|")[0] in names)]:
        if nm in res:
            continue
        res[nm] = fit[nm]
        cfg = dict(res[nm]["cfg"])
        cur = sw.J(cfg)[0]
        groups = [g for g in GROUPS if not ((g == ("lam_b",) and cfg["prior"] != "shipped") or
                                            (g == ("om_n", "fl_n") and not cfg["nat"]) or
                                            (g == ("tn",) and len(ENS[cfg["ens"]]) == 1))]
        n_ev = 0
        for rnd in range(3):
            changed = False
            for g in groups:
                for vals in itertools.product(*(GRID[p] for p in g)):
                    c2 = {**cfg, **dict(zip(g, vals))}
                    if c2 == cfg or (g == ("om_b", "fl_b") and vals[0] == 0.0 and vals[1] != -30.0):
                        continue
                    j = sw.J(c2)[0]
                    n_ev += 1
                    if j > cur + 1e-5:
                        cur, cfg, changed = j, c2, True
            if not changed:
                break
        jb, rb = sw.J(cfg)
        old = res[nm]["J"]
        res[nm] = {"cfg": cfg, "J": jb, "AU-val_rw": rb["AU-val"]["top1_sp_rw"], "A-val_nat": rb["A-val"]["top1_nat"],
                   "AU-val_sp": rb["AU-val"]["top1_sp"], "A-val_sp": rb["A-val"]["top1_sp"],
                   "evals": res[nm]["evals"] + n_ev, "refined": True, "J_coord": old}
        log(f"{nm:28s} J {old:.4f} → {jb:.4f} (AU-val rw {rb['AU-val']['top1_sp_rw']:.4f}, A-val nat "
            f"{rb['A-val']['top1_nat']:.4f}) { {k: cfg[k] for g in groups for k in g} } [{n_ev} evals, {time.time() - t0:.0f} s]")
        json.dump(res, open(path, "w"), indent=1)
        sw.memo.clear()


# ------------------------------------------------------------ calibration + ladder

def ladder_rates(y, w, F, prm, genus, cw=None, mask=None):
    """ladder_v3's rule and per-species / natural rates (copied logic; ladder_v3.main is monolithic)."""
    n = len(y)
    m = np.ones(n, bool) if mask is None else mask
    s_thr = np.array(prm["s"])[F["bucket"]]
    close = F["same_genus"] & (F["p2"] >= prm["r"] * F["p1"]) if prm["r"] < 1 else np.zeros(n, bool)
    sp_ = (F["p1"] >= s_thr) & (F["pimg"] >= prm["f"]) & ~close
    ge = ~sp_ & (F["gp"] >= prm["g"])
    yy = y[m]
    ok_s = (F["named"] == y)[m]
    ok_g = ((y >= 0) & (F["gtop"] == genus[np.maximum(y, 0)]))[m]
    sp_, ge = sp_[m], ge[m]
    key = np.where(yy >= 0, yy, -1 - np.arange(len(yy)))
    cl, inv = np.unique(key, return_inverse=True)
    cnt = np.bincount(inv)
    wc = np.ones(len(cl)) if cw is None else np.where(cl >= 0, cw[np.maximum(cl, 0)], 1.0)

    def per(h):
        return float(((np.bincount(inv, h.astype(float)) / cnt) * wc).sum() / wc.sum())
    nw = w[m] / w[m].sum()
    return {"species": per(sp_), "species_right": per(sp_ & ok_s), "species_wrong": per(sp_ & ~ok_s),
            "genus": per(ge), "genus_wrong": per(ge & ~ok_g), "not_sure": per(~sp_ & ~ge),
            "species_w": float((sp_ * nw).sum()), "species_wrong_w": float(((sp_ & ~ok_s) * nw).sum())}


def ladder_search(y, w, F, genus, wcls):
    """ladder_v3's search: per-bucket species thresholds raised greedily to ≤ 7 % stated-wrong per
    species (re-weighted), over image floors f and congener ratios r; then the genus threshold."""
    grid_s = [round(x, 2) for x in np.arange(0.5, 0.99, 0.05)]
    best = None
    for f_, r_ in itertools.product((0.0, 0.1, 0.2, 0.3, 0.4), (1.0, 0.7, 0.5, 0.3)):
        s = [0.5] * 4
        while True:
            prm = {"s": s, "f": f_, "r": r_, "g": 0.5}
            rr = ladder_rates(y, w, F, prm, genus, wcls)
            if rr["species_wrong"] <= 0.07:
                break
            opts = []
            for k in range(4):
                i = grid_s.index(s[k]) if s[k] in grid_s else 0
                if i + 1 < len(grid_s):
                    s2 = list(s)
                    s2[k] = grid_s[i + 1]
                    r2 = ladder_rates(y, w, F, dict(prm, s=s2), genus, wcls)
                    opts.append(((rr["species_wrong"] - r2["species_wrong"]) / max(rr["species_right"] - r2["species_right"], 1e-6), s2))
            if not opts:
                break
            s = max(opts, key=lambda o: o[0])[1]
        rr = ladder_rates(y, w, F, {"s": s, "f": f_, "r": r_, "g": 0.5}, genus, wcls)
        if rr["species_wrong"] <= 0.07 and (best is None or rr["species_right"] > best[0]["species_right"]):
            best = (rr, {"s": s, "f": f_, "r": r_})
    prm = dict(best[1])
    for g_ in [round(x, 2) for x in np.arange(0.5, 0.96, 0.05)]:
        rr = ladder_rates(y, w, F, dict(prm, g=g_), genus, wcls)
        if rr["genus_wrong"] / max(rr["genus"], 1e-9) <= rr["species_wrong"] / max(rr["species"], 1e-9):
            prm["g"] = g_
            break
    else:
        prm["g"] = 0.95
    return prm


SHIPPED_T = 1.532196746540708   # v2-head.bin scoring.temperature
SHIPPED_LADDER = {"s": [0.6, 0.5, 0.5, 0.75], "f": 0.0, "r": 1.0, "g": 0.55}


def add_feats(F, Z):
    import ladder_v3 as L3
    F["same_genus"] = Z["genus"][F["named"]] == Z["genus"][F["second"]]
    F["bucket"] = L3.bucket(Z["n_tr"][F["named"]])
    return F


def val_wcls(Z):
    import ladder_v3 as L3
    n_tr = Z["n_tr"]
    act = (Z["rg_au"] > 0) & (Z["mapv"] == np.arange(len(n_tr)))
    tgt = np.bincount(L3.bucket(n_tr[act]), minlength=4) / act.sum()
    cls_v = np.unique(Z["AU-val/y"][Z["AU-val/y"] >= 0])
    vmix = np.bincount(L3.bucket(n_tr[cls_v]), minlength=4) / len(cls_v)
    return (tgt / np.maximum(vmix, 1e-9))[L3.bucket(n_tr)]


def load_fit():
    fit = json.load(open(os.path.join(FS, "fit.json")))
    p = os.path.join(FS, "refine.json")
    if os.path.exists(p):
        fit.update(json.load(open(p)))
    return fit


def cmd_calib(names):
    sw = Sweep()
    Z = sw.Z
    fit = load_fit()
    path = os.path.join(FS, "calib.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    Ts = [float(x) for x in np.exp(np.linspace(np.log(0.7), np.log(3.0), 30))]
    for nm in names:
        c = fit[nm]["cfg"]
        t0 = time.time()
        nll = sw.tlogits_val(c, Ts + ([SHIPPED_T] if nm == "shipped" else []))
        T = SHIPPED_T if nm == "shipped" else min(nll, key=nll.get)   # shipped: its own T and ladder, as on the device
        F = add_feats(sw.feats("AU-val", c, T, Z["genus"]), Z)
        prm = SHIPPED_LADDER if nm == "shipped" else ladder_search(Z["AU-val/y"], Z["AU-val/w"], F, Z["genus"], val_wcls(Z))
        rv = ladder_rates(Z["AU-val/y"], Z["AU-val/w"], F, prm, Z["genus"], val_wcls(Z))
        res[nm] = {"T": T, "nll": nll[T], "ladder": prm, "val_ladder": rv}
        log(f"{nm}: T {T:.3f} (val NLL {nll[T]:.4f}), ladder {prm}, val rw species {rv['species']:.3f} "
            f"wrong {rv['species_wrong']:.3f} ({time.time() - t0:.0f} s)")
        json.dump(res, open(path, "w"), indent=1)


# ------------------------------------------------------------ tests (read once)

def sizes(c):
    hs = ENS[c["ens"]]
    rows = sum(np.load(HEADS[h], mmap_mode="r")["W"].shape[0] for h in hs)
    head_mb = sum(BA.bank_bytes(np.load(HEADS[h], mmap_mode="r")["W"].shape[0]) for h in hs) / 1e6
    tas_mb = BA.bank_bytes(82649) / 1e6
    nat_rows = len(np.load(os.path.join(BA.WORK, "prune", f"rows-{NAT}.npy"))) if c["nat"] else 0
    nat_mb = BA.bank_bytes(nat_rows) / 1e6
    prior_mb = os.path.getsize(os.path.join(BS.SHIP, "v2-prior.bin")) / 1e6 + (0.03 if c["prior"] == "adaptive" else 0)
    ms_out = 1e3 * BA.time_scan(rows + nat_rows)
    ms_in = 1e3 * BA.time_scan(rows + 82649)
    return {"head_MB": round(head_mb, 1), "tasbank_MB": round(tas_mb, 1), "natbank_MB": round(nat_mb, 1),
            "prior_MB": round(prior_mb, 1), "total_MB": round(head_mb + tas_mb + nat_mb + prior_mb, 1),
            "head_rows": int(rows), "scan_ms_M4cpu_outside": round(ms_out, 1), "scan_ms_M4cpu_inside": round(ms_in, 1)}


def cmd_test(names):
    import eval_v2 as E2
    sw = Sweep()
    Z = sw.Z
    fit = load_fit()
    cal = json.load(open(os.path.join(FS, "calib.json")))
    path = os.path.join(FS, "test.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    hits_p = os.path.join(FS, "hits.npz")
    hits = dict(np.load(hits_p)) if os.path.exists(hits_p) else {}
    for nm in names:
        if nm in res:
            log("already read:", nm)
            continue
        t0 = time.time()
        c, T, lad = fit[nm]["cfg"], cal[nm]["T"], cal[nm]["ladder"]
        out = {"cfg": c, "valJ": fit[nm]["J"], "T": T, "ladder": lad, "size": sizes(c)}
        top5s, feats = {}, {}
        for s in ("AU-test", "A-test", "C-report"):
            F = add_feats(sw.feats(s, c, T, Z["genus"]), Z)
            feats[s], top5s[s] = F, F["top5"]
            hits[f"{nm}::{s}"] = (F["top5"][:, 0] == Z[s + "/y"])
        rep = sw.sc.report(top5s)
        ntr = sw.sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
        rep["AU-test 1-9"] = sw.sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
        rep["A-test strict 0.2 km"] = sw.sc.metrics("A-test", top5s["A-test"], BA.strict_mask(Z, "A-test", 0.2))
        out["metrics"] = rep
        lr = {}
        for s, sub, key in (("A-test", None, "A-test"), ("AU-test", None, "AU-test"), ("C-report", "main", "C-main"),
                            ("C-report", "euc", "C-euc"), ("AU-test", "euc_y", "AU-test-euc")):
            y, w, F = Z[s + "/y"], Z[s + "/w"], feats[s]
            m = None if sub is None else (Z[s + "/sub"] == sub if sub != "euc_y" else Z["euc"][np.maximum(y, 0)] & (y >= 0))
            lr[key] = {"chosen": ladder_rates(y, w, F, lad, Z["genus"], mask=m),
                       "shipped-ladder": ladder_rates(y, w, F, SHIPPED_LADDER, Z["genus"], mask=m)}
        out["ladder_test"] = lr
        ec = {}
        for s in ("AU-test", "A-test"):
            y, F = Z[s + "/y"], feats[s]
            m = y >= 0
            _, inv = np.unique(y[m], return_inverse=True)
            corr = (F["named"] == y)[m].astype(float)
            ec[s] = {"natural": E2.ece(F["p1"][m], corr, Z[s + "/w"][m])[0],
                     "per_species": E2.ece(F["p1"][m], corr, 1.0 / np.bincount(inv)[inv])[0],
                     "nll_nat": float(-(F["lpy"][m] * Z[s + "/w"][m]).sum() / Z[s + "/w"][m].sum())}
        out["ece"] = ec
        res[nm] = out
        json.dump(res, open(path, "w"), indent=1)
        np.savez(hits_p, **hits)
        log(nm, json.dumps({k: (round(x["top1_sp"] * 100, 1), round(x["top1_nat"] * 100, 1)) for k, x in rep.items()}),
            "ECE", {s: (round(100 * e["per_species"], 1), round(100 * e["natural"], 1)) for s, e in ec.items()},
            "stated-wrong sp/nat", {k: (round(100 * v["chosen"]["species_wrong"], 1), round(100 * v["chosen"]["species_wrong_w"], 1))
                                    for k, v in lr.items()}, out["size"], f"({time.time() - t0:.0f} s)")


def cmd_boot(names, B=2000):
    Z = BA.load()
    hits = dict(np.load(os.path.join(FS, "hits.npz")))
    rng = np.random.default_rng(0)
    path = os.path.join(FS, "boot.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    for s in ("A-test", "AU-test"):
        y, w = Z[s + "/y"], Z[s + "/w"]
        m = y >= 0
        cls, inv = np.unique(y[m], return_inverse=True)
        n = int(m.sum())
        ref = hits[f"shipped::{s}"][m].astype(float)
        draws = [np.bincount(rng.integers(0, n, n), minlength=n).astype(float) for _ in range(B)]
        for nm in names:
            h = hits[f"{nm}::{s}"][m].astype(float)
            d_sp, d_nat = [], []
            for k in draws:
                cnt = np.bincount(inv, k, minlength=len(cls))
                ok = cnt > 0
                a = np.bincount(inv, k * h, minlength=len(cls))[ok] / cnt[ok]
                b = np.bincount(inv, k * ref, minlength=len(cls))[ok] / cnt[ok]
                d_sp.append(a.mean() - b.mean())
                kw = k * w[m]
                d_nat.append(((h - ref) * kw).sum() / kw.sum())
            p0 = lambda v: float(min(1.0, 2 * min((np.array(v) <= 0).mean(), (np.array(v) >= 0).mean())))  # noqa: E731
            pt_sp = float(np.bincount(inv, h).__truediv__(np.bincount(inv)).mean() - np.bincount(inv, ref).__truediv__(np.bincount(inv)).mean())
            pt_nat = float(((h - ref) * w[m]).sum() / w[m].sum())
            res[f"{nm}::{s}"] = {"per_species": [100 * pt_sp, *(100 * np.percentile(d_sp, [2.5, 97.5])).tolist(), p0(d_sp)],
                                 "natural": [100 * pt_nat, *(100 * np.percentile(d_nat, [2.5, 97.5])).tolist(), p0(d_nat)],
                                 "gained_lost": [int(((h > ref) & True).sum()), int((h < ref).sum())]}
            log(s, nm, {k: [round(x, 2) for x in v] for k, v in res[f"{nm}::{s}"].items()})
    json.dump(res, open(path, "w"), indent=1)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "prep":
        cmd_prep()
    elif cmd == "fit":
        cmd_fit(args)
    elif cmd == "refine":
        cmd_refine(args)
    elif cmd == "calib":
        cmd_calib(args)
    elif cmd == "test":
        cmd_test(args)
    elif cmd == "boot":
        cmd_boot(args)
    else:
        raise SystemExit(__doc__)

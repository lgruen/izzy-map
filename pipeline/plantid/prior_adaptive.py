#!/usr/bin/env python3
"""Adaptive-bandwidth location prior (experiment): ONE prior for all of Australia whose kernel
σ and smoothing α follow the local record density, instead of a Tasmania-box re-tuned prior.
Imports the data layout from build_ship.py; changes no existing file.

  ρ(cell)  = Gaussian-smoothed (σ_ρ km) total record count of ALL classes per km², from the
             same raw 0.05° count table the prior uses (prior-*.bin).
  balloon  σ(x) = clip(σ0 · (ρ0/ρ(x))^γ, σmin, σmax),  α(x) = α0 · (σ(x)/σ0)^δ
           ρ0 = median of ρ over cells holding records; γ = 0 reproduces the fixed prior.
  K(x) = Σ_cells t(count) · exp(−d²/2σ(x)²);  log p = log((K + α f)/(ΣK + α)), t = log1p | sqrt.
  σ(x), α(x) depend on the CELL of x only (a lookup of one byte per 0.05° cell) and are quantised
  to a geometric ladder (STEPS per octave), so the device keeps the shipped count table and its
  kernel sum; the only addition is the σ-code raster (`bake` reports its size).

  prior_adaptive.py facts [--prior P.bin]     record density per region (task 1)
  prior_adaptive.py fit                       coordinate descent on val (needs the bank_analysis cache)
  prior_adaptive.py test                      read tests once for the chosen cfgs
  prior_adaptive.py bake CFG_NAME             σ-code raster size

Env as bank_analysis.py: FINAL=final-cb50-s1 TAUNORM=0.5 V2DATA=…/data-final.npz
V2PRIOR=…/prior-eval-inatpool+ala-noinat.bin (default)."""
import argparse
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402

STEPS = 3  # σ ladder steps per octave


class AdaptivePrior(BS.V2Prior):
    def __init__(self, path, sigma_rho=10.0):
        super().__init__(path)
        h = self.h
        ny, nx = h["ny"], h["nx"]
        self.ny, self.nx = ny, nx
        cell = np.repeat(np.arange(ny * nx), np.diff(self.rowptr.astype(np.int64)))
        self.cell_of_row = cell
        self.tot = np.bincount(cell, self.raw, minlength=ny * nx).reshape(ny, nx)   # records per cell
        lat_c = h["lat0"] + (np.arange(ny) + 0.5) * h["cell_deg"]
        self.area = ((h["km_per_deg_lat"] * h["cell_deg"]) * (h["km_per_deg_lon"] * h["cell_deg"]
                                                              * np.cos(np.radians(lat_c)))[:, None]
                     * np.ones((1, nx)))
        self.rho_cache = {}
        self.sigma_rho = sigma_rho

    def rho(self, sigma_rho=None):
        """records / km² smoothed with a Gaussian (σ_rho km), on the cell grid."""
        from scipy.ndimage import gaussian_filter
        s = sigma_rho or self.sigma_rho
        if s not in self.rho_cache:
            h = self.h
            sy = s / (h["km_per_deg_lat"] * h["cell_deg"])
            lat_mid = h["lat0"] + 0.5 * self.ny * h["cell_deg"]
            sx = s / (h["km_per_deg_lon"] * h["cell_deg"] * np.cos(np.radians(lat_mid)))
            num = gaussian_filter(self.tot, (sy, sx), mode="constant", truncate=3)
            den = gaussian_filter(np.ones_like(self.tot), (sy, sx), mode="constant", truncate=3)
            self.rho_cache[s] = (num / np.maximum(den, 1e-9)) / self.area
        return self.rho_cache[s]

    def sigma_map(self, c):
        """σ (km) per cell for config c: {s0, gamma, smin, smax, srho}; ρ0 = median ρ over record cells."""
        rho = self.rho(c.get("srho", 10.0))
        rho0 = c.get("rho0") or float(np.median(rho[self.tot > 0]))
        s = c["s0"] * (rho0 / np.maximum(rho, 1e-6)) ** c["gamma"]
        s = np.clip(s, c["smin"], c["smax"])
        k = np.round(np.log2(s / c["smin"]) * STEPS)
        return c["smin"] * 2.0 ** (k / STEPS)

    def log_prior(self, lat, lon, cfg):
        """Adaptive prior for points (n × C float32). cfg: t, s0, gamma, smin, smax, srho, a0, delta."""
        lat, lon = np.asarray(lat, float), np.asarray(lon, float)
        h = self.h
        f = self.freqs[cfg["t"]]
        iy = np.clip(np.floor((lat - h["lat0"]) / h["cell_deg"]).astype(np.int64), 0, self.ny - 1)
        ix = np.clip(np.floor((lon - h["lon0"]) / h["cell_deg"]).astype(np.int64), 0, self.nx - 1)
        sq = self.sigma_map(cfg)[iy, ix]
        out = np.zeros((len(lat), len(f)), np.float32)
        P = BS.DegPrior.__new__(BS.DegPrior)
        P.h, P.rowptr, P.sp, P.cnt, P.freq = h, self.rowptr, self.sp, self.T[cfg["t"]](self.raw), f
        for s in np.unique(sq):
            idx = np.nonzero(sq == s)[0]
            a = cfg["a0"] * (s / cfg["s0"]) ** cfg["delta"]
            for i in range(0, len(idx), 512):
                j = idx[i:i + 512]
                K = P.density(lat[j], lon[j], float(s))
                out[j] = np.log((K + a * f[None]) / (K.sum(1, keepdims=True) + a))
        return out


REGIONS = {  # name: (W, S, E, N), rough boxes
    "Tasmania": BS.TAS_BOX, "Greater Hobart": (147.0, -43.1, 147.7, -42.6), "Tas west/NW": (144.0, -43.0, 146.0, -41.0),
    "Sydney basin": (150.5, -34.5, 151.5, -33.3), "Melbourne": (144.5, -38.3, 145.7, -37.4),
    "Vic rest": (141.0, -39.0, 150.0, -34.0), "SE Qld": (152.5, -28.3, 153.6, -26.5),
    "Perth/SW WA": (115.0, -35.2, 116.5, -31.5), "Adelaide": (138.2, -35.3, 139.2, -34.4),
    "Canberra": (148.8, -35.8, 149.5, -35.1), "NSW rest": (141.0, -37.5, 153.6, -28.2),
    "NT": (129.0, -26.0, 138.0, -11.0), "WA outback": (113.0, -35.0, 129.0, -14.0),
    "Qld north/west": (138.0, -29.0, 153.6, -10.5), "SA outback": (129.0, -38.0, 141.0, -26.0)}


def cmd_facts(a):
    P = AdaptivePrior(a.prior)
    h = P.h
    lat = h["lat0"] + (np.arange(P.ny) + 0.5) * h["cell_deg"]
    lon = h["lon0"] + (np.arange(P.nx) + 0.5) * h["cell_deg"]
    LA, LO = np.meshgrid(lat, lon, indexing="ij")
    rho = P.rho(10.0)
    tot = P.tot
    rec = tot > 0
    cc = np.bincount(P.cell_of_row, minlength=P.ny * P.nx).reshape(P.ny, P.nx)
    print(f"grid {P.ny}x{P.nx} cells of {h['cell_deg']} deg, records {tot.sum():,.0f}, cells with records {rec.sum():,}; "
          f"records per record-cell median/p10/p90 {np.median(tot[rec]):.0f}/{np.percentile(tot[rec], 10):.0f}/"
          f"{np.percentile(tot[rec], 90):.0f}; rho10 median over record cells {np.median(rho[rec]):.3f} rec/km2")
    print(f"{'region':16s} {'rec cells':>9s} {'rec/cell med':>12s} {'rec/km2 med':>11s} {'rho10 med':>9s} {'rho10 p90':>9s} {'classes/cell':>12s}")
    for nm, (w, s, e, n) in REGIONS.items():
        m = (LO >= w) & (LO <= e) & (LA >= s) & (LA <= n) & rec
        if not m.any():
            continue
        print(f"{nm:16s} {m.sum():9d} {np.median(tot[m]):12.0f} {np.median(tot[m] / P.area[m]):11.2f} "
              f"{np.median(rho[m]):9.3f} {np.percentile(rho[m], 90):9.3f} {np.median(cc[m]):12.0f}")
    tas, main = rec & BS.in_tas(LA, LO), rec & ~BS.in_tas(LA, LO)
    print("rho10 pct 10/50/90 mainland", np.percentile(rho[main], [10, 50, 90]).round(3), "Tasmania",
          np.percentile(rho[tas], [10, 50, 90]).round(3))
    print("share of mainland record cells with rho10 above Tasmania's median:",
          round(float((rho[main] > np.median(rho[tas])).mean()), 3),
          "| share of mainland RECORDS in such cells:",
          round(float(tot[main & (rho > np.median(rho[tas]))].sum() / tot[main].sum()), 3))


# ------------------------------------------------------------------ evaluation (bank_analysis protocol)

WORKJ = None
START = {"t": "log1p", "s0": 10.0, "gamma": 0.5, "smin": 3.0, "smax": 20.0, "srho": 10.0, "a0": 64.0, "delta": 2.0,
         "lam": 1.0, "om": 2.0}
FIXED = {**START, "gamma": 0.0, "delta": 0.0}
GRID = {"t": ["log1p", "sqrt"], "s0": [5.0, 7.0, 10.0, 14.0], "gamma": [0.0, 0.25, 0.5, 0.75, 1.0],
        "smin": [2.0, 3.0, 5.0], "smax": [14.0, 20.0, 30.0], "srho": [5.0, 10.0, 20.0],
        "a0": [16.0, 32.0, 64.0, 128.0], "delta": [0.0, 1.0, 2.0], "lam": [0.75, 1.0, 1.25], "om": [1.0, 2.0, 3.0]}


class Ev:
    def __init__(self):
        import bank_analysis as BA
        self.BA = BA
        self.Z = BA.load()
        self.sc = BA.Scorer(self.Z)
        self.P = AdaptivePrior(BS.V2_PRIOR_EVAL)
        self.cacheL, self.cacheB = {}, {}

    def Lh(self, nm):
        import torch
        if nm not in self.cacheL:
            for k in [k for k in self.cacheL if k not in ("AU-val", "A-val")]:
                del self.cacheL[k]
            self.cacheL[nm] = torch.from_numpy(self.BA.head_logp(self.Z, nm, self.sc.W, self.sc.b)).half().to("mps")
        return self.cacheL[nm]

    def box(self, nm):
        if nm not in self.cacheB:
            self.cacheB[nm] = self.BA.box_knn_rows(self.Z, nm)
        return self.cacheB[nm]

    def top5(self, nm, cfg, bank, chunk=4096):
        """Adaptive prior (cfg) everywhere; bank=True: Tasmanian-box bank kNN (ω cfg['om'], floor −30) inside the box."""
        import torch
        Lh = self.Lh(nm)
        lat, lon = self.Z[nm + "/lat"], self.Z[nm + "/lon"]
        bx, bf = self.box(nm) if bank else (np.zeros(len(lat), bool), None)
        out = np.zeros((len(lat), 5), np.int64)
        for a in range(0, len(lat), chunk):
            b = min(len(lat), a + chunk)
            L = Lh[a:b].float()
            r = np.arange(a, b)
            if bf is not None and bx[r].any():
                rb = r[bx[r]]
                tb = torch.from_numpy(rb - a).to("mps")
                L[tb] = torch.log_softmax(L[tb] + cfg["om"] * bf(rb).clamp(min=-30.0), 1)
            Pn = torch.from_numpy(self.P.log_prior(lat[a:b], lon[a:b], cfg)).to("mps")
            out[a:b] = (L + cfg["lam"] * Pn).topk(5, dim=1).indices.cpu().numpy()
        return out

    def J(self, cfg, bank):
        r = {nm: self.sc.metrics(nm, self.top5(nm, cfg, bank)) for nm in ("AU-val", "A-val")}
        return 0.5 * (r["AU-val"]["top1_sp_rw"] + r["A-val"]["top1_nat"]), r


def key(cfg, bank):
    return json.dumps({**cfg, "bank": bank}, sort_keys=True)


def cmd_fit(a):
    ev = Ev()
    path = os.path.join(ev.BA.WORK, f"adaptive_fit-{a.name}.json")   # one file per fit (parallel runs)
    res = json.load(open(path)) if os.path.exists(path) else {"evals": {}, "best": {}}
    t0 = time.time()

    def score(cfg, bank):
        k = key(cfg, bank)
        if k not in res["evals"]:
            j, r = ev.J(cfg, bank)
            res["evals"][k] = {"J": j, "AU-val_rw": r["AU-val"]["top1_sp_rw"], "A-val_nat": r["A-val"]["top1_nat"],
                               "AU-val_sp": r["AU-val"]["top1_sp"], "A-val_sp": r["A-val"]["top1_sp"]}
            json.dump(res, open(path, "w"))
        return res["evals"][k]["J"]

    name, bank = a.name, a.bank
    cfg = dict(FIXED if a.fixed else START)
    if a.init:
        cfg.update(json.loads(a.init))
    free = [p for p in a.params.split(",")]
    if a.fixed:
        free = [p for p in free if p not in ("gamma", "smin", "smax", "srho", "delta")]
    if not bank:
        free = [p for p in free if p != "om"]
    cur = score(cfg, bank)
    print(name, "start", round(cur, 4), cfg, f"({time.time() - t0:.0f} s)", flush=True)
    for rnd in range(a.rounds):
        changed = False
        for p in free:
            for v in GRID[p]:
                if v == cfg[p] or (cfg["gamma"] == 0 and p in ("smin", "smax", "srho", "delta") and not a.fixed):
                    continue
                c2 = {**cfg, p: v}
                j = score(c2, bank)
                if j > cur + 1e-5:
                    cur, cfg, changed = j, c2, True
            print(f"  {name} round {rnd} {p} -> {cfg[p]}  J {cur:.4f} ({time.time() - t0:.0f} s)", flush=True)
        if not changed:
            break
    res["best"][name] = {"cfg": cfg, "bank": bank, "J": cur, **{k: v for k, v in res["evals"][key(cfg, bank)].items() if k != "J"}}
    json.dump(res, open(path, "w"), indent=1)
    print(name, "BEST", json.dumps(res["best"][name]), flush=True)


def cmd_test(a):
    ev = Ev()
    BA, sc, Z = ev.BA, ev.sc, ev.Z
    path = os.path.join(BA.WORK, "adaptive_test.json")
    res = {"best": {}}
    for f_ in os.listdir(BA.WORK):
        if f_.startswith("adaptive_fit-"):
            res["best"].update(json.load(open(os.path.join(BA.WORK, f_)))["best"])
    out = json.load(open(path)) if os.path.exists(path) else {}
    todo = a.names.split(",")
    for nm in todo:
        if nm == "shipped":      # main prior outside the box, box prior + Tasmanian bank inside (bank_prune's "+box" with no outside bank)
            def run(s):
                bx, bf = BA.box_knn_rows(Z, s)
                return sc.run(s, None, rows_box=bx, box_fn=bf)
        elif nm == "main":       # shipped main prior everywhere, no bank
            def run(s):
                return sc.run(s)
        else:
            b = dict(res["best"][nm[:-2] if nm.endswith("nb") else nm])
            if nm.endswith("nb"):    # the same cfg without the bank
                b["bank"] = False

            def run(s, b=b):
                return ev.top5(s, b["cfg"], b["bank"])
        t0 = time.time()
        va = {s: sc.metrics(s, run(s)) for s in ("AU-val", "A-val")}
        valJ = 0.5 * (va["AU-val"]["top1_sp_rw"] + va["A-val"]["top1_nat"])
        print(nm, f"val J {valJ:.4f} (AU-val rw {va['AU-val']['top1_sp_rw']:.4f}, A-val nat {va['A-val']['top1_nat']:.4f})", flush=True)
        top5s = {s: run(s) for s in ("AU-test", "A-test", "C-report")}
        rep = sc.report(top5s)
        ntr = sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
        rep["AU-test 1-9"] = sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
        rep["A-test strict 0.2 km"] = sc.metrics("A-test", top5s["A-test"], BA.strict_mask(Z, "A-test", 0.2))
        bx = BS.in_tas(Z["AU-test/lat"], Z["AU-test/lon"])
        rep["AU-test in-box"] = sc.metrics("AU-test", top5s["AU-test"], bx)
        rep["AU-test mainland"] = sc.metrics("AU-test", top5s["AU-test"], ~bx)
        rep["valJ"] = valJ
        out[nm] = rep
        print(nm, json.dumps({k: (round(x["top1_sp"] * 100, 1), round(x["top1_nat"] * 100, 1)) for k, x in rep.items() if isinstance(x, dict)}),
              f"({time.time() - t0:.0f} s)", flush=True)
        json.dump(out, open(path, "w"), indent=1)


def cmd_bake(a):
    import zlib
    import bank_analysis as BA
    cfg = json.load(open(os.path.join(BA.WORK, f"adaptive_fit-{a.name}.json")))["best"][a.name]["cfg"]
    P = AdaptivePrior(BS.V2_PRIOR_EVAL)
    sm = P.sigma_map(cfg)
    code = np.round(np.log2(sm / cfg["smin"]) * STEPS).astype(np.uint8)
    lv = np.unique(code)
    print(a.name, "sigma levels (km):", (cfg["smin"] * 2.0 ** (lv / STEPS)).round(2).tolist(), "cells per level:",
          [int((code == l).sum()) for l in lv])
    rec = P.tot > 0
    h = P.h
    print(f"sigma-code raster {code.shape}: raw u8 {code.size / 1e3:.0f} KB, zlib {len(zlib.compress(code.tobytes(), 9)) / 1e3:.1f} KB, "
          f"4-bit {code.size / 2e3:.0f} KB; counts file unchanged ({os.path.getsize(BS.V2_PRIOR_EVAL) / 1e6:.1f} MB eval build)")
    tas = BS.in_tas(*np.meshgrid(h["lat0"] + (np.arange(P.ny) + .5) * h["cell_deg"], h["lon0"] + (np.arange(P.nx) + .5) * h["cell_deg"], indexing="ij"))
    for nm, m in (("Tasmania", tas & rec), ("mainland", ~tas & rec)):
        q = np.percentile(sm[m], [10, 50, 90]).round(1)
        print(f"  sigma km pct 10/50/90 in {nm} record cells: {q.tolist()}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("facts")
    p.add_argument("--prior", default=BS.V2_PRIOR_EVAL)
    p = sub.add_parser("fit")
    p.add_argument("name")
    p.add_argument("--bank", action="store_true")
    p.add_argument("--fixed", action="store_true", help="gamma 0 (a refit fixed-σ prior)")
    p.add_argument("--init", default="")
    p.add_argument("--params", default="t,s0,gamma,smin,smax,srho,a0,delta,lam,om")
    p.add_argument("--rounds", type=int, default=2)
    p = sub.add_parser("test")
    p.add_argument("names")
    p = sub.add_parser("bake")
    p.add_argument("name")
    a = ap.parse_args()
    {"facts": cmd_facts, "fit": cmd_fit, "test": cmd_test, "bake": cmd_bake}[a.cmd](a)

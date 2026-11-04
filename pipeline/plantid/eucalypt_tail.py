#!/usr/bin/env python3
"""Long-tail fixes for the Australia-wide model, aimed at eucalypts (README
"Eucalypt round"). Loads the shipped au-* files, precomputes per set the
image log p (head ⊕ prototypes), the centred text cosines and the AU prior,
then sweeps on AU-tune + the AU-val eucalypt photos only:
  (a) logit adjustment: − τ · log(train photos + 1) per class;
  (b) per-class zero-shot weight w0 + w1 / (1 + n / n0) on log_softmax(κ · cos);
  (c) both, with λ / σ of the prior re-tuned.
Reports on A-test, C-report and AU-test (eucalypts + a 6,000-photo sample).
  `exp`   the sweep → australia/train/euc_tail.json
  `ship`  rewrite au-text.bin / au-protos.bin with the chosen variant
Env: train_australia.py's laptop env."""
import collections, json, os, sys, time
import numpy as np, pyarrow.parquet as pq, torch
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import build_ship as BS, eval_australia as EA, train_australia as TA  # noqa: E402

DEV = "mps"
OUT = os.path.join(TA.TR, "euc_tail2.json" if sys.argv[2:3] == ["grid2"] else "euc_tail.json")


def load():
    t0 = time.time()
    Ut = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["genus", "ship", "euc"]).to_pydict()
    nU = len(Ut["genus"])
    ship = BS.Ship(BS.SHIP, "bank-int8.bin")
    ash = BS.AuShip(BS.SHIP, ship)
    euc = np.array(Ut["euc"])
    gn = {g: i for i, g in enumerate(sorted(set(Ut["genus"])))}
    ctx = {"genus": np.array([gn[g] for g in Ut["genus"]])}
    ntr = np.array([l["train_photos"] for l in json.load(open(os.path.join(BS.SHIP, "au-labels.json")))["labels"]])
    ids, E = TA.all_embeddings()
    sets = {}

    def mk(nm, emb, lat, lon, y, w, sub=None, sp=None):
        sets[nm] = TA.NS(name=nm, n=len(y), emb=np.asarray(emb, np.float32), lat=np.asarray(lat, float),
                         lon=np.asarray(lon, float), y=np.asarray(y), w=np.asarray(w, float), sub=sub,
                         sp=np.asarray(y if sp is None else sp))
    SS = BS.load_sets(); ev = SS["ev"]
    lj = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    s2u = ash.ship2u
    iw, Ew = BS.load_parts(os.path.join(BS.SHIP, "eval", "coreml-w8")); pw = {int(p): i for i, p in enumerate(iw)}
    for nm, X, e in (("A-test", Ew[[pw[int(p)] for p in ev["test"]["photo_id"]]], ev["test"]),):
        mk(nm, X, e["lat"], e["lon"], np.where(e["y"] >= 0, s2u[np.maximum(e["y"], 0)], -1), e["w"], sp=e["sp"])
    crows = EA.c_rows(); ic, Ec = BS.load_parts(os.path.join(TA.AU, "emb-w8")); cp = {int(p): i for i, p in enumerate(ic)}
    rr = [r for r in crows if r["half"] == "report" and r["photo_id"] in cp]
    mk("C-report", Ec[[cp[r["photo_id"]] for r in rr]], [r["lat"] for r in rr], [r["lon"] for r in rr],
       [r["u"] for r in rr], [r["w"] for r in rr], sub=np.array([r["subset"] for r in rr]))
    te = pq.read_table(os.path.join(TA.CACHE, "sets", "test.parquet"), columns=["observer_id", "split"]).to_pydict()
    excl = {r["observer_id"] for r in crows if r["half"] == "report"} | {o for o, s in zip(te["observer_id"], te["split"]) if s == "test"}
    pe = {k: np.array(v) for k, v in pq.read_table(os.path.join(TA.AU, "plan", "eval.parquet"),
          columns=["observer_id", "lat", "lon", "role", "u", "photo_id", "n_split"]).to_pydict().items()}
    i_e, ok = TA.lookup(ids, pe["photo_id"])
    rng = np.random.default_rng(0)
    for role in ("val", "test"):
        m = ok & (pe["role"] == role)
        if role == "val":
            m &= ~np.isin(pe["observer_id"], list(excl))
        u = pe["u"][m]; cnt = collections.Counter(u.tolist()); w = pe["n_split"][m] / np.array([cnt[x] for x in u])
        idx = np.nonzero(m)[0]
        if role == "val":
            hv = np.array([int.from_bytes(__import__("hashlib").sha256(f"{o}tune".encode()).digest()[:4], "big") / 2 ** 32
                           for o in pe["observer_id"][m]])
            tune = hv < 12000 / m.sum()
            tu = u[tune]; ct = collections.Counter(tu.tolist()); full = collections.Counter(u.tolist())
            mk("AU-tune", E[i_e[idx[tune]]], pe["lat"][idx[tune]], pe["lon"][idx[tune]], tu,
               w[tune] * np.array([full[x] / ct[x] for x in tu]))
            e_ = euc[u]
            mk("AU-val-euc", E[i_e[idx[e_]]], pe["lat"][idx[e_]], pe["lon"][idx[e_]], u[e_], w[e_])
        else:
            e_ = euc[u]
            mk("AU-test-euc", E[i_e[idx[e_]]], pe["lat"][idx[e_]], pe["lon"][idx[e_]], u[e_], w[e_])
            smp = np.sort(rng.permutation(len(idx))[:6000])
            mk("AU-test-6k", E[i_e[idx[smp]]], pe["lat"][idx[smp]], pe["lon"][idx[smp]], u[smp], w[smp])
    print({k: v.n for k, v in sets.items()}, f"({time.time() - t0:.0f} s)", flush=True)
    return Ut, nU, ship, ash, euc, ctx, ntr, sets


def components(S, ash, ship, z1prior, Tsh):
    """float16 CPU tensors: image log p (head ⊕ protos), centred cos, priors; Ship log p."""
    Li, Cc, P10, P25, Z1c, Z1p = [], [], [], [], [], []
    sc = ash.ph["scoring"]
    for a in range(0, S.n, 1024):
        e, la, lo = S.emb[a:a + 1024], S.lat[a:a + 1024], S.lon[a:a + 1024]
        q = ash.query(e)
        Lh = BS.log_softmax(ash.hh["temp"] * (q @ ash.W.T))
        sims, idx = BS.knn_neighbours(q, ash.P, ash.pscale, sc["k"])
        Lk = BS.log_softmax(sc["knn_temp"] * BS.knn_vote(sims, idx, ash.plabels, ash.C, sc["k"], sc["tau"], ash.pweight, sc["rho"]))
        Li.append(BS.log_softmax(sc["blend_temp"] * (Lh + sc["omega"] * Lk)).astype(np.float16))
        Cc.append((q @ ash.T.T).astype(np.float16))
        P10.append(ash.prior.log_prior(la, lo, 10.0, 4.0).astype(np.float16))
        P25.append(ash.prior.log_prior(la, lo, 25.0, 16.0).astype(np.float16))
        # z1 exactly as eval_australia (ship.mu centring, 0.1° prior, κ 70, σ 25, α 16, λ 1)
        qs = BS.unit(BS.unit(e) - ship.mu[None, :])
        Z1c.append((qs @ Tsh.T).astype(np.float16))
        K = z1prior.density(la, lo, 25.0)
        Z1p.append(np.log((K + 16 * z1prior.freq[None]) / (K.sum(1, keepdims=True) + 16)).astype(np.float16))
    S.Li, S.Cc, S.P = torch.from_numpy(np.concatenate(Li)), torch.from_numpy(np.concatenate(Cc)), \
        {10: torch.from_numpy(np.concatenate(P10)), 25: torch.from_numpy(np.concatenate(P25))}
    S.Z1 = torch.from_numpy((70.0 * np.concatenate(Z1c).astype(np.float32) + np.concatenate(Z1p).astype(np.float32)).astype(np.float16))
    if S.name.startswith("A-"):
        S.Ls = torch.from_numpy(ship.logp(S.emb, S.lat, S.lon).astype(np.float32))


def La_of(S, prm, ntr_t, rows=slice(None)):
    """Uncalibrated AU log p of a variant (torch, on DEV)."""
    Li = S.Li[rows].to(DEV).float()
    cache = getattr(S, "lz", None)
    if cache is not None and prm["kappa"] in cache:
        Lz = cache[prm["kappa"]]
    else:
        Lz = torch.log_softmax(prm["kappa"] * S.Cc[rows].to(DEV).float(), 1)
    n = ntr_t
    wz = prm["w0"] + prm["w1"] / (1.0 + n / prm["n0"])
    L = prm.get("alpha", 1.0) * Li - prm["tau"] * torch.log1p(n)[None, :] + wz[None, :] * Lz
    L = torch.log_softmax(L, 1) + prm["lam"] * S.P[prm["sigma"]][rows].to(DEV).float()
    return torch.log_softmax(L, 1)


def top5(L):
    o = L.topk(5, dim=1)
    return o.indices.cpu().numpy(), o.values[:, 0].exp().cpu().numpy()


def obj(S, top):
    hit = top[:, 0] == S.y
    inl = S.y >= 0
    micro = (hit * S.w)[inl].sum() / S.w[inl].sum()
    _, inv = np.unique(S.y[inl], return_inverse=True)
    return 0.5 * (micro + (np.bincount(inv, hit[inl]) / np.bincount(inv)).mean())


def tg_pred(S, La, prm_h, ash, T):
    """Gate: hybrid in Tasmania (all A photos are), else La/T."""
    nl = torch.from_numpy(ash.nonlocal_).to(DEV); s2u = torch.from_numpy(ash.ship2u).to(DEV)
    Z = torch.log_softmax(La / prm_h["tau"] - prm_h["b"] * nl[None].float(), 1)
    p_out = Z[:, nl].exp().sum(1, keepdim=True).clamp(0, 1)
    Lf = Z.clone(); Ls = S.Ls.to(DEV)
    Lf[:, s2u] = torch.log((1 - p_out).clamp_min(1e-30)) + Ls
    top = Lf.argmax(1); bl = s2u[Ls.argmax(1)]; ar = torch.arange(len(top), device=DEV)
    sw = nl[top] & (Lf[ar, top] - Lf[ar, bl] <= prm_h["m"])
    named = torch.where(sw, bl, top).cpu().numpy()
    Lc = torch.log_softmax(Lf / prm_h["final_temp"], 1)
    t5, _ = top5(Lc)
    for j in np.nonzero(named != t5[:, 0])[0]:
        rest = [x for x in t5[j] if x != named[j]]; t5[j] = [named[j]] + rest[:4]
    p1 = Lc[torch.arange(len(named)), torch.from_numpy(named).to(DEV)].exp().cpu().numpy()
    return t5, p1


def ship_variant():
    """Write the chosen grid2 variant into au-protos.bin / au-prior.bin headers
    (arrays unchanged; old files kept in ship/au-v1/), then score from the files."""
    import shutil
    r = json.load(open(os.path.join(TA.TR, "euc_tail2.json")))
    prm, Tf = r["chosen"]["prm"], r["report"]["new"]["final_temp"]
    assert prm["tau"] == 0 and prm["w1"] == 0  # no per-class vector needed for this one
    bak = os.path.join(BS.SHIP, "au-v1")
    os.makedirs(bak, exist_ok=True)
    for f in ("au-protos.bin", "au-prior.bin"):
        if not os.path.exists(os.path.join(bak, f)):
            shutil.copy2(os.path.join(BS.SHIP, f), bak)
    h, a = BS.read_blob(os.path.join(bak, "au-protos.bin"))
    h["scoring"].update({"zs_kappa": prm["kappa"], "zs_omega": prm["w0"], "image_weight": prm["alpha"],
                         "lam": prm["lam"], "final_temp": Tf})
    h["tuned"] = "eucalypt round (eucalypt_tail.py grid2): ½ AU-tune objective + ¼ AU-val eucalypt top-1 + ¼ top-5"
    BS.write_blob(os.path.join(BS.SHIP, "au-protos.bin"), h, {k: np.array(v) for k, v in a.items()})
    h, a = BS.read_blob(os.path.join(bak, "au-prior.bin"))
    h.update({"sigma_km": float(prm["sigma"]), "alpha": 16.0})
    BS.write_blob(os.path.join(BS.SHIP, "au-prior.bin"), h, {k: np.array(v) for k, v in a.items()})
    Ut, nU, ship, ash, euc, ctx, ntr, sets = load()
    ash = BS.AuShip(BS.SHIP, ship)
    for nm in ("A-test", "C-report", "AU-test-euc"):
        S = sets[nm]
        tops, p1s = [], []
        for a_ in range(0, S.n, 1024):
            L, named = ash.answer(S.emb[a_:a_ + 1024], S.lat[a_:a_ + 1024], S.lon[a_:a_ + 1024])
            t5 = np.argsort(-L, 1)[:, :5]
            for j in np.nonzero(named != t5[:, 0])[0]:
                rest = [x for x in t5[j] if x != named[j]]; t5[j] = [named[j]] + rest[:4]
            tops.append(t5); p1s.append(np.exp(L[np.arange(len(named)), named]))
        tp, p1 = np.concatenate(tops), np.concatenate(p1s)
        if nm == "C-report":
            for sub in ("main", "euc"):
                m = EA.metrics(S, tp, p1, ctx, S.sub == sub)
                print(nm, sub, {k: round(100 * m[k], 1) for k in ("top1", "top1_sp", "top5", "genus1", "conf_wrong")})
        else:
            m = EA.metrics(S, tp, p1, ctx)
            print(nm, {k: round(100 * m[k], 2) for k in ("top1", "top1_w", "top5", "top5_w", "conf_wrong_w")})


def rungs(L, named, genus_idx, y, w, s_thr, g_thr):
    """Answer ladder at (species, genus) thresholds → shares and per-rung error (weighted)."""
    p = np.exp(L)
    pn = p[np.arange(len(named)), named]
    G = genus_idx.max() + 1
    pg = np.zeros((len(named), G))
    for j in range(len(named)):
        pg[j] = np.bincount(genus_idx, p[j], minlength=G)
    sp = pn >= s_thr
    gt = pg.argmax(1)
    ge = ~sp & (pg.max(1) >= g_thr)
    ns = ~sp & ~ge
    ok_s = named == y
    ok_g = gt == genus_idx[np.maximum(y, 0)]
    W = w / w.sum()
    f = lambda m: float(W[m].sum())  # noqa: E731
    return {"species": f(sp), "species_err": f(sp & ~ok_s) / max(f(sp), 1e-12), "species_wrong_all": f(sp & ~ok_s),
            "genus": f(ge), "genus_err": f(ge & ~ok_g) / max(f(ge), 1e-12), "not_sure": f(ns),
            "wrong_all": f(sp & ~ok_s) + f(ge & ~ok_g)}


def ladder():
    """Ladder thresholds for the AU path (outside the Tasmania box) on AU-tune's
    mainland photos (natural-mix weights); the Tasmanian path keeps 0.5/0.5."""
    Ut, nU, ship, ash, euc, ctx, ntr, sets = load()
    gi = ctx["genus"]
    out = {}
    for nm in ("AU-tune", "AU-val-euc", "C-report", "AU-test-euc"):
        S = sets[nm]
        keep = ~BS.in_tas(S.lat, S.lon)
        Ls, ns = [], []
        for a in range(0, S.n, 1024):
            L, named = ash.answer(S.emb[a:a + 1024], S.lat[a:a + 1024], S.lon[a:a + 1024])
            Ls.append(L[keep[a:a + 1024]].astype(np.float32)); ns.append(named[keep[a:a + 1024]])
        S.L, S.nm, S.yk, S.wk = np.concatenate(Ls), np.concatenate(ns), S.y[keep], S.w[keep]
        S.subk = S.sub[keep] if S.sub is not None else None
    TU, EV = sets["AU-tune"], sets["AU-val-euc"]
    grid = [round(float(x), 2) for x in np.arange(0.5, 0.96, 0.05)]
    # natural mix (weighted) already ≤ 7 % at 0.5 (4.2 %); the long tail is where
    # the confident errors are → constrain AU-tune PER PHOTO (≤ 8 per class) and the
    # AU-val eucalypts in their natural mix
    sweep = {(s_, g_): rungs(TU.L, TU.nm, gi, TU.yk, np.ones(len(TU.yk)), s_, g_) for s_ in grid for g_ in grid}
    ev = {(s_, g_): rungs(EV.L, EV.nm, gi, EV.yk, EV.wk, s_, g_) for s_ in grid for g_ in grid}
    s_thr = min([s_ for s_ in grid if max(sweep[(s_, 0.5)]["species_wrong_all"], ev[(s_, 0.5)]["species_wrong_all"])
                 <= 0.07] or [0.95])
    # genus rung no less trustworthy than the species rung
    g_thr = min([g_ for g_ in grid if max(sweep[(s_thr, g_)]["genus_err"], ev[(s_thr, g_)]["genus_err"]) <=
                 min(sweep[(s_thr, g_)]["species_err"], ev[(s_thr, g_)]["species_err"])] or [0.95])
    out["chosen"] = {"species": s_thr, "genus": g_thr}
    out["AU-tune (per photo)"] = {f"{k[0]}/{k[1]}": v for k, v in sweep.items() if k in ((0.5, 0.5), (s_thr, g_thr))}
    out["AU-val-euc"] = {f"{k[0]}/{k[1]}": v for k, v in ev.items() if k in ((0.5, 0.5), (s_thr, g_thr))}
    out["AU-tune (natural mix)"] = {f"{a}/{b}": rungs(TU.L, TU.nm, gi, TU.yk, TU.wk, a, b)
                                    for a, b in ((0.5, 0.5), (s_thr, g_thr))}
    C = sets["C-report"]
    for tag, m in (("C-main", C.subk == "main"), ("C-euc", C.subk == "euc")):
        out[tag] = {f"{a}/{b}": rungs(C.L[m], C.nm[m], gi, C.yk[m], np.ones(m.sum()), a, b)
                    for a, b in ((0.5, 0.5), (s_thr, g_thr))}
    T = sets["AU-test-euc"]
    out["AU-test-euc (mainland)"] = {f"{a}/{b}": rungs(T.L, T.nm, gi, T.yk, T.wk, a, b)
                                     for a, b in ((0.5, 0.5), (s_thr, g_thr))}
    json.dump(out, open(os.path.join(TA.TR, "ladder.json"), "w"), indent=1)
    P = lambda x: f"{100 * x:.1f}"  # noqa: E731
    print("chosen", out["chosen"])
    for k, v in out.items():
        if k == "chosen":
            continue
        for th, r in v.items():
            print(f"{k:24s} {th:9s} species {P(r['species'])} (err {P(r['species_err'])}, wrong/all "
                  f"{P(r['species_wrong_all'])}) genus {P(r['genus'])} (err {P(r['genus_err'])}) "
                  f"not sure {P(r['not_sure'])}")


def main():
    cmd = sys.argv[1]
    if cmd == "ship":
        return ship_variant()
    if cmd == "ladder":
        return ladder()
    Ut, nU, ship, ash, euc, ctx, ntr, sets = load()
    T = np.load(os.path.join(TA.AU, "text.npz"))["emb"].astype(np.float32)
    Tsh = BS.unit(T - T.mean(0)).astype(np.float32)
    z1prior = EA.AuPrior(nU)
    t0 = time.time()
    for S in sets.values():
        components(S, ash, ship, z1prior, Tsh)
    print(f"components {time.time() - t0:.0f} s", flush=True)
    ntr_t = torch.from_numpy(ntr.astype(np.float32)).to(DEV)
    sc = ash.ph["scoring"]
    cur = {"tau": 0.0, "w0": sc["zs_omega"], "w1": 0.0, "n0": 1.0, "kappa": sc["zs_kappa"], "lam": sc["lam"], "sigma": 10}
    for S in sets.values():
        S.lz = None
    res = {"current": cur, "sweep": []}
    TU, EV = sets["AU-tune"], sets["AU-val-euc"]
    for S in (TU, EV):  # resident on the GPU for the sweep
        S.Li = S.Li.to(DEV); S.P = {k: v.to(DEV) for k, v in S.P.items()}
        S.lz = {k: torch.log_softmax(k * S.Cc.to(DEV).float(), 1).half() for k in (30.0, 70.0)}
    best = None
    t1 = time.time()
    G2 = len(sys.argv) > 2 and sys.argv[2] == "grid2"
    grid = [(tau, w0, w1, n0, kappa, lam, sig, 1.0) for tau in (0.0, 0.25, 0.5, 1.0) for w0 in (0.0, 0.25, 0.5)
            for w1 in (0.0, 1.0, 2.0, 4.0) for n0 in ((5.0, 20.0) if w1 else (1.0,)) for kappa in (30.0, 70.0)
            for lam, sig in ((0.25, 10), (0.5, 10), (1.0, 25))]
    if G2:  # stronger zero-shot / prior ensemble (z1-like), image weight alpha
        grid = [(tau, w0, w1, 20.0, 70.0, lam, 25, al) for tau in (0.0, 0.5, 1.0) for w0 in (0.5, 1.0, 2.0)
                for w1 in (0.0, 2.0) for lam in (0.5, 1.0) for al in (0.5, 1.0)]
    for tau, w0, w1, n0, kappa, lam, sig, al in grid:
                            if len(res["sweep"]) == 3:
                                print(f"  ~{(time.time() - t1) / 3:.2f} s per setting", flush=True)
                            if len(res["sweep"]) == 3:
                                print(f"  ~{(time.time() - t1) / 3:.2f} s per setting", flush=True)
                            prm = {"tau": tau, "w0": w0, "w1": w1, "n0": n0, "kappa": kappa, "lam": lam, "sigma": sig,
                                   "alpha": al}
                            a, _ = top5(La_of(TU, prm, ntr_t)); b, _ = top5(La_of(EV, prm, ntr_t))
                            r = {"prm": prm, "tune": obj(TU, a), "euc_val": float((b[:, 0] == EV.y).mean()),
                                 "euc_val5": float((b == EV.y[:, None]).any(1).mean())}
                            r["score"] = 0.5 * r["tune"] + (0.25 * r["euc_val"] + 0.25 * r["euc_val5"] if G2 else
                                                            0.5 * r["euc_val"])
                            res["sweep"].append(r)
                            if best is None or r["score"] > best["score"]:
                                best = r
                                print(f"  best so far {r}", flush=True)
    print(f"sweep {len(res['sweep'])} settings, {time.time() - t0:.0f} s", flush=True)
    res["chosen"] = best
    # also: the best by AU-tune alone (no eucalypt emphasis) for reference
    res["best_tune_only"] = max(res["sweep"], key=lambda r: r["tune"])
    # temperature of each candidate on AU-tune, then report
    out = {}
    for tag, prm in (("current", cur), ("new", best["prm"]), ("new_tune_only", res["best_tune_only"]["prm"])):
        TU.lz = None
        La = La_of(TU, prm, ntr_t); yt = torch.from_numpy(TU.y).to(DEV)
        t = TA.fit_temp(La, yt); Tf = 1.0 / t
        rep = {"final_temp": Tf}
        for nm in ("A-test", "C-report", "AU-test-euc", "AU-test-6k"):
            S = sets[nm]
            parts = []
            for a in range(0, S.n, 2048):
                rows = slice(a, a + 2048)
                L = La_of(S, prm, ntr_t, rows)
                if nm.startswith("A-"):
                    Sx = TA.NS(Ls=S.Ls[rows])
                    parts.append(tg_pred(Sx, L, ash.ph["hybrid"], ash, Tf))
                else:
                    parts.append(top5(torch.log_softmax(L / Tf, 1)))
            tp, p1 = np.concatenate([p[0] for p in parts]), np.concatenate([p[1] for p in parts])
            S.last = tp
            if nm == "C-report":
                rep[nm] = {"main": EA.metrics(S, tp, p1, ctx, S.sub == "main"), "euc": EA.metrics(S, tp, p1, ctx, S.sub == "euc")}
            else:
                rep[nm] = EA.metrics(S, tp, p1, ctx)
            if nm == "A-test":
                S.__dict__["tops_" + tag] = tp[:, 0].copy()
        out[tag] = rep
    # z1 rows on the same sets
    z1 = {}
    for nm in ("C-report", "AU-test-euc", "AU-test-6k"):
        S = sets[nm]
        tp, p1 = top5(torch.log_softmax(S.Z1.to(DEV).float(), 1))
        z1[nm] = ({"main": EA.metrics(S, tp, p1, ctx, S.sub == "main"), "euc": EA.metrics(S, tp, p1, ctx, S.sub == "euc")}
                  if nm == "C-report" else EA.metrics(S, tp, p1, ctx))
    out["z1"] = z1
    A = sets["A-test"]; inl = A.y >= 0
    tv0 = A.Ls.argmax(1).numpy(); r0 = inl & (ash.ship2u[tv0] == A.y)
    for tag in ("current", "new", "new_tune_only"):
        rh = inl & (A.__dict__["tops_" + tag] == A.y)
        out[tag]["A_paired_vs_v0"] = {"lost": int((r0 & ~rh).sum()), "gained": int((~r0 & rh).sum())}
    res["report"] = out
    json.dump(res, open(OUT, "w"), indent=1, default=float)
    P = lambda x: f"{100 * x:.1f}"  # noqa: E731
    for tag in ("z1", "current", "new", "new_tune_only"):
        r = out[tag]
        A_ = f"{P(r['A-test']['top1_w'])} (−{r['A_paired_vs_v0']['lost']}/+{r['A_paired_vs_v0']['gained']})" if "A-test" in r else "–"
        M, Eu, Te, T6 = r["C-report"]["main"], r["C-report"]["euc"], r["AU-test-euc"], r["AU-test-6k"]
        print(f"| {tag} | {A_} | {P(M['top1_sp'])} / {P(M['top1_w'])} | {P(M['top5'])} | {P(M['conf_wrong'])} | "
              f"{P(Eu['top1'])} | {P(Eu['top5'])} | {P(Eu['genus1'])} | {P(Eu['conf_wrong'])} | "
              f"{P(Te['top1'])} | {P(Te['top5'])} | {P(T6['top1_w'])} / {P(T6['top1_sp'])} |")
    print("chosen", best, "\ntune-only", res["best_tune_only"]["prm"])


if __name__ == "__main__":
    main()

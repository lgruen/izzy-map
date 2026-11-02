#!/usr/bin/env python3
"""Plant-ID evaluation, step 4: compare classifiers and location priors.

For each model with embeddings (embed.py), these classifiers:
  zero-shot   cosine to the taxonomic text prompt (no photos used);
              "centred" = both modalities centred (uses the mean train photo)
  prototype   per species: normalise(sum of its train embeddings + γ·text) —
              the text vector acts as γ "virtual photos", so species with
              few photos lean on their name, well-photographed ones on data
  linear      a trained linear head initialised at the text vectors and
              pulled back towards them (L2 weight μ); class-balanced loss;
              rows of species without train photos stay frozen at their text
              vector (otherwise they only ever receive "not this" gradients).
              μ AND the number of passes over the data (epochs) are chosen on
              val from a learning curve, reported in the report.
  kNN         vote of the k most similar individual train photos
  blends      linear ⊕ plain zero-shot, linear ⊕ kNN: log p = log p_a + ω·log p_b
each optionally with a CSLS hub correction (β), × three priors:
  none        image only
  frequency   × how common the species is in Tasmania (pool records)
  local       × a kernel density of pool records around the photo's location,
              shrunk towards the statewide frequency: (K + α·f) / (ΣK + α)
Combination: log p(image) + λ · log p(species | place). Each classifier's
temperature is first fitted on val (negative log-likelihood), so λ = 1 is
the Bayes-correct weight for a calibrated model and λ is comparable across
classifiers. All classifiers have a ~uniform built-in class prior (text
prompts; balanced loss), so multiplying in the location prior doesn't count
species frequency twice.

All choices are made on VAL (observers disjoint from TEST and from all
training data) by the mean of photo-weighted and per-species top-1; numbers
are reported on TEST. Accuracy two ways:
  photos   re-weighted to the natural mix of species in the split (what share
           of the photos people actually take gets the right name)
  species  mean over species (the long tail counts as much as Banksia)
plus tiers by train photos available, plant groups, genus-level accuracy,
"not in label set", how often the top answer has p ≥ 0.5 and is then right
(over ALL photos — unanswerable ones are where confident errors live), a
species → genus → "not sure" answer ladder, accuracy by observation date
(a pretraining-leakage check: a model that saw some test photos in training
leads by more on the older ones), and an error analysis of the best method.
"""
import argparse
import glob
import json
import os
import time

import numpy as np
import pyarrow.parquet as pq
import scipy.sparse as sp
import torch
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")
TIERS = [(0, 0, "0"), (1, 4, "1-4"), (5, 19, "5-19"), (20, 10**9, "20+")]
GROUPS = {  # family / class → reporting group
    "Myrtaceae": "Myrtaceae (eucalypts, tea-trees)", "Ericaceae": "Ericaceae (heaths)",
    "Proteaceae": "Proteaceae", "Fabaceae": "Fabaceae (peas, wattles)",
    "Asteraceae": "Asteraceae (daisies)", "Orchidaceae": "Orchidaceae",
    "Poaceae": "Poaceae (grasses)", "Cyperaceae": "Cyperaceae (sedges)",
    "Polypodiopsida": "ferns",
}
TEMPS = np.exp(np.linspace(np.log(0.02), np.log(50), 41))


def load_table(path, cols=None):
    return pq.read_table(path, columns=cols).to_pydict()


def load_emb(d):
    ids, embs = [], []
    for f in sorted(glob.glob(os.path.join(d, "img-*.npz"))):
        z = np.load(f)
        ids.append(z["photo_id"])
        embs.append(z["emb"].astype(np.float32))
    if not ids:
        return {}, None
    ids = np.concatenate(ids)
    return {int(p): i for i, p in enumerate(ids)}, np.concatenate(embs)


def log_softmax(z):
    z = z - z.max(1, keepdims=True)
    return z - np.log(np.exp(z).sum(1, keepdims=True))


def unit(Z):
    return Z / np.linalg.norm(Z, axis=1, keepdims=True)


def period_of(d):
    """Half-year bucket of an observation date (leakage check)."""
    if d is None:
        return "?"
    h = 1 if d.month <= 6 else 2
    return f"{d.year}-H{h}"


# ---------------------------------------------------------------- classifiers

def prototype(Xtr, ytr, T, gamma):
    S = np.zeros_like(T)
    np.add.at(S, ytr, Xtr)
    return unit(S + gamma * T)


def hub_offsets(W, Xref, yref, k=10):
    """CSLS-style hub score per class (Conneau et al. 2018): mean of its k
    highest similarities to reference photos of OTHER species. Subtracting
    it stops a class that is close to everything from winning everything."""
    S = Xref @ W.T
    S[np.arange(len(yref)), yref] = -np.inf  # a photo never counts for its own class
    k = max(1, min(k, len(Xref) - 1))
    return -np.partition(-S, k - 1, axis=0)[:k].mean(0)


def linear(Xtr, ytr, T, mu, checkpoints=(20,), device="cpu", seed=0, lr=1e-3):
    """Train the head; return {epochs: W} at each checkpoint (learning curve)."""
    torch.manual_seed(seed)
    X = torch.from_numpy(Xtr).to(device)
    y = torch.from_numpy(ytr).long().to(device)
    T0 = torch.from_numpy(T).to(device)
    counts = torch.bincount(y, minlength=T.shape[0]).float()
    mask = (counts > 0).float()[:, None]  # species without photos stay frozen
    D = torch.nn.Parameter(torch.zeros_like(T0))
    ls = torch.nn.Parameter(torch.tensor(float(np.log(30.0)), device=device))
    w = (1.0 / counts.clamp(min=1))[y]  # class-balanced: each species weighs the same
    opt = torch.optim.Adam([D, ls], lr=lr)
    n, out = len(y), {}
    for ep in range(1, max(checkpoints) + 1):
        perm = torch.randperm(n).to(device)
        for i in range(0, n, 2048):
            b = perm[i:i + 2048]
            W = T0 + mask * D
            ce = torch.nn.functional.cross_entropy(ls.exp() * X[b] @ W.T, y[b],
                                                   reduction="none")
            loss = (ce * w[b]).sum() / w[b].sum() + mu * ((mask * D) ** 2).sum()
            opt.zero_grad()
            loss.backward()
            opt.step()
        if ep in checkpoints:
            out[ep] = (T0 + mask * D).detach().cpu().numpy()
    return out


def knn_logp(Xq, Xtr, ytr, C, k, tau, chunk=1024):
    """log p from a softmax-weighted vote of the k nearest train photos,
    smoothed with a tiny uniform floor so absent classes stay finite."""
    P = np.zeros((len(Xq), C), np.float64)
    for i in range(0, len(Xq), chunk):
        S = Xq[i:i + chunk] @ Xtr.T
        nb = np.argpartition(-S, k - 1, axis=1)[:, :k]
        s = np.take_along_axis(S, nb, 1)
        wts = np.exp((s - s.max(1, keepdims=True)) / tau)
        rows = np.repeat(np.arange(len(nb)), k)
        np.add.at(P[i:i + chunk], (rows, ytr[nb].ravel()), wts.ravel())
    P /= P.sum(1, keepdims=True)
    return np.log(P + 1e-6 / C)


# --------------------------------------------------------------------- priors

def project(lat, lon):
    lat, lon = np.asarray(lat, float), np.asarray(lon, float)
    return np.stack([lon * 111.32 * np.cos(np.radians(-42.0)), lat * 110.57], 1)


class GeoPrior:
    """Kernel density of pool records per species around a point."""

    def __init__(self, rec_xy, rec_cls, n_cls):
        self.xy, self.cls, self.C = rec_xy, rec_cls, n_cls
        self.freq = (np.bincount(rec_cls, minlength=n_cls) + 1.0)
        self.freq /= self.freq.sum()
        self.cache = {}

    def density(self, key, q_xy, sigma):
        if (key, sigma) in self.cache:
            return self.cache[(key, sigma)]
        g = sigma / 2.0  # grid records into cells of σ/2 first (bounded cost)
        cell = np.floor(self.xy / g).astype(np.int64)
        uniq, inv = np.unique(cell, axis=0, return_inverse=True)
        inv = inv.ravel()
        cnt = sp.coo_matrix((np.ones(len(inv), np.float32), (inv, self.cls)),
                            shape=(len(uniq), self.C)).tocsr()
        centres = (uniq + 0.5) * g
        tree = cKDTree(centres)
        rows, cols, vals = [], [], []
        for i, nb in enumerate(tree.query_ball_point(q_xy, r=3 * sigma)):
            if nb:
                d2 = ((centres[nb] - q_xy[i]) ** 2).sum(1)
                rows += [i] * len(nb)
                cols += nb
                vals.append(np.exp(-d2 / (2 * sigma ** 2)))
        vals = np.concatenate(vals) if vals else np.zeros(0)
        K = sp.csr_matrix((vals.astype(np.float32), (rows, cols)),
                          shape=(len(q_xy), len(uniq))) @ cnt
        K = np.asarray(K.todense())
        self.cache[(key, sigma)] = K
        return K

    def log_prior(self, key, q_xy, kind, sigma=None, alpha=None):
        if kind == "none":
            return 0.0
        if kind == "frequency":
            return np.log(self.freq)[None, :]
        K = self.density(key, q_xy, sigma)
        tot = K.sum(1, keepdims=True)
        return np.log((K + alpha * self.freq[None, :]) / (tot + alpha))


# -------------------------------------------------------------------- metrics

def objective(logp, ev):
    """Fast tuning objective: mean of photo-weighted and per-species top-1."""
    y, w, sp_of = ev["y"], ev["w"], ev["sp"]
    inl = y >= 0
    hit = (logp.argmax(1) == y) & inl
    micro = (hit[inl] * w[inl]).sum() / w[inl].sum()
    ids, hh = sp_of[inl], hit[inl].astype(float)
    uniq, inv = np.unique(ids, return_inverse=True)
    macro = (np.bincount(inv, hh) / np.bincount(inv)).mean()
    return 0.5 * (micro + macro)


def score(logp, ev, ctx, n_tr):
    """logp: (E × C) log-probabilities; ev["y"]: class index or −1."""
    genus_of, gidx, Gm, group_of = ctx["genus_of"], ctx["gidx"], ctx["Gm"], ctx["group_of"]
    y, w, sp_of = ev["y"], ev["w"], ev["sp"]
    top = np.argpartition(-logp, 5, axis=1)[:, :5]  # top 5, then order them
    top = np.take_along_axis(top, np.argsort(-np.take_along_axis(logp, top, 1), 1), 1)
    inl = y >= 0
    yy = np.maximum(y, 0)
    hit1 = (top[:, 0] == y) & inl
    hit5 = (top == y[:, None]).any(1) & inl
    gen1 = inl & (genus_of[top[:, 0]] == genus_of[yy])
    p = np.exp(logp)
    conf = p.max(1)
    pg = np.asarray(Gm.T.dot(p.T).T)  # genus probabilities
    gconf, gtop = pg.max(1), pg.argmax(1)
    every = np.ones_like(inl)

    def acc(mask, h):
        return float((h[mask] * w[mask]).sum() / w[mask].sum()) if mask.any() else None

    def macro(mask, h):
        if not mask.any():
            return None
        ids, hh = sp_of[mask], h[mask]
        return float(np.mean([hh[ids == s].mean() for s in np.unique(ids)]))

    sure = conf >= 0.5
    r = {"top1": acc(inl, hit1), "top5": acc(inl, hit5), "genus1": acc(inl, gen1),
         "top1_species": macro(inl, hit1), "top1_all_photos": acc(every, hit1),
         "confident_share": acc(every, sure), "confident_top1": acc(sure, hit1),
         "n": int(inl.sum()), "n_all": int(len(y))}
    r["objective"] = 0.5 * ((r["top1"] or 0) + (r["top1_species"] or 0))
    # answer ladder: species if p ≥ .5, else genus if its summed p ≥ .5, else "not sure"
    g_ans = ~sure & (gconf >= 0.5)
    g_ok = g_ans & inl & (gtop == gidx[yy])
    r["ladder"] = {"species": acc(every, sure), "species_right": acc(sure, hit1),
                   "genus": acc(every, g_ans), "genus_right": acc(g_ans, g_ok),
                   "not_sure": acc(every, ~sure & ~g_ans),
                   "wrong_answer": acc(every, (sure & ~hit1) | (g_ans & ~g_ok))}
    tiers = {}
    for lo, hi, name in TIERS:
        m = inl & (n_tr[yy] >= lo) & (n_tr[yy] <= hi)
        tiers[name] = {"top1": acc(m, hit1), "top1_species": macro(m, hit1), "n": int(m.sum())}
    r["tiers"] = tiers
    groups = {}
    for gname in sorted(set(GROUPS.values())):
        m = inl & np.array([c >= 0 and group_of[c] == gname for c in y])
        groups[gname] = {"top1": acc(m, hit1), "n": int(m.sum())}
    r["groups"] = groups
    if "period" in ev:
        r["periods"] = {per: {"top1": acc(inl & (ev["period"] == per), hit1),
                              "n": int((inl & (ev["period"] == per)).sum())}
                        for per in sorted(set(ev["period"]))}
    r["_pred"] = top[:, 0]
    return r


def nll(logp, ev):
    m = ev["y"] >= 0
    return -float((logp[m, ev["y"][m]] * ev["w"][m]).sum() / ev["w"][m].sum())


def calibrate(raw, ev):
    """Fit one temperature on val NLL; return calibrated log-probs + T."""
    t = min(TEMPS, key=lambda t: nll(log_softmax(t * raw["val"]), ev["val"]))
    return {s: log_softmax(t * raw[s]) for s in raw}, float(t)


# ----------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sets", default=os.path.join(CACHE, "sets"))
    ap.add_argument("--emb", default=os.path.join(CACHE, "emb"))
    ap.add_argument("--out", default=os.path.join(CACHE, "report"))
    ap.add_argument("--models", nargs="+", default=["bioclip", "bioclip2", "bioclip25"])
    ap.add_argument("--shots", nargs="+", type=int, default=[1, 5],
                    help="also re-train prototype/linear with ≤ k photos per species")
    ap.add_argument("--quick", action="store_true", help="tiny grids (smoke test)")
    ap.add_argument("--min-coverage", type=float, default=0.98,
                    help="abort if fewer of the set photos have embeddings")
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    t0 = time.time()

    L = load_table(os.path.join(a.sets, "labels.parquet"))
    cls_of = {s: i for i, s in enumerate(L["species_id"])}
    C = len(cls_of)
    genus_of = np.array(L["genus"], dtype=object)
    gnames = {g: i for i, g in enumerate(sorted({str(g) for g in genus_of}))}
    gidx = np.array([gnames[str(g)] for g in genus_of])
    ctx = {"genus_of": genus_of, "gidx": gidx,
           "Gm": sp.csr_matrix((np.ones(C), (np.arange(C), gidx)), shape=(C, len(gnames))),
           "group_of": [GROUPS.get(f) or GROUPS.get(c) for f, c in zip(L["family"], L["cls"])],
           "name_of": L["name"]}
    tr = load_table(os.path.join(a.sets, "train.parquet"), ["photo_id", "species_id"])
    te = load_table(os.path.join(a.sets, "test.parquet"),
                    ["photo_id", "species_id", "taxon_id", "lat", "lon", "split", "n_split",
                     "observed_on"])
    pr = load_table(os.path.join(a.sets, "prior.parquet"))
    rec_cls = np.array([cls_of[s] for s in pr["species_id"]], dtype=np.int64)

    q = a.quick
    grids = {
        "gamma": [1, 4] if q else [0.5, 1, 2, 4, 8, 16, 32],
        "mu": [1e-4] if q else [0, 1e-5, 1e-4, 1e-3, 1e-2],
        "epochs": [5, 10] if q else [5, 10, 20, 40, 80],
        "sigma": [5] if q else [1, 2, 5, 15, 40],
        "alpha": [8] if q else [2, 8, 32, 128, 512],
        "lam": [0, 0.5, 1] if q else [0, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0],
        "omega": [0, 0.5] if q else [0, 0.25, 0.5, 1.0, 2.0],
        "knn_tau": [0.05] if q else [0.01, 0.02, 0.05, 0.1],
        "knn_k": 50,
    }
    results = {"generated": time.strftime("%Y-%m-%d %H:%M"), "models": {}, "grids": grids}
    eval_ids = None
    for model in a.models:
        d = os.path.join(a.emb, model)
        if not os.path.exists(os.path.join(d, "text.npz")):
            print(f"{model}: no embeddings, skipped")
            continue
        info = json.load(open(os.path.join(d, "info.json")))
        z = np.load(os.path.join(d, "text.npz"))
        if sorted(int(s) for s in z["species_id"]) != sorted(cls_of):
            raise SystemExit(f"{model}: text.npz species ≠ label set — re-run embed.py")
        T = np.zeros((C, z["emb"].shape[1]), np.float32)
        for s, e in zip(z["species_id"], z["emb"]):
            T[cls_of[int(s)]] = e
        idx, E = load_emb(d)
        if E is None:
            print(f"{model}: no image embeddings, skipped")
            continue
        want = set(tr["photo_id"]) | set(te["photo_id"])
        cov = len(want & idx.keys()) / max(len(want), 1)
        if cov < a.min_coverage:
            raise SystemExit(f"{model}: only {cov:.1%} of set photos embedded "
                             f"(--min-coverage {a.min_coverage})")

        def gather(tab):
            keep = [i for i, p in enumerate(tab["photo_id"]) if p in idx]
            X = E[[idx[tab["photo_id"][i]] for i in keep]]
            y = np.array([cls_of.get(tab["species_id"][i], -1) for i in keep], dtype=np.int64)
            return keep, X, y

        _, Xtr_all, ytr_all = gather(tr)
        ev = {}
        for split in ("val", "test"):
            rows = [i for i, s in enumerate(te["split"]) if s == split]
            sub = {k: [te[k][i] for i in rows] for k in te}
            keep, X, y = gather(sub)
            # natural-mix weight: photos of this species in the split / sampled
            # (genus-level / hybrid photos have no species: key = −taxon_id,
            # matching the partition pick_sets.py counted n_split over)
            keys = np.array([sub["species_id"][i] if sub["species_id"][i] is not None
                             else -sub["taxon_id"][i] for i in keep])
            sampled = dict(zip(*np.unique(keys, return_counts=True)))
            w = np.array([sub["n_split"][i] / sampled[k] for i, k in zip(keep, keys)])
            xy = project([sub["lat"][i] for i in keep], [sub["lon"][i] for i in keep])
            ev[split] = dict(X=X, y=y, w=w, sp=keys, xy=xy,
                             period=np.array([period_of(sub["observed_on"][i]) for i in keep]),
                             ids=sorted(sub["photo_id"][i] for i in keep))
        ids_now = (ev["val"]["ids"], ev["test"]["ids"])
        if eval_ids is not None and ids_now != eval_ids:
            raise SystemExit(f"{model}: different val/test photos than the previous model")
        eval_ids = ids_now
        geo = GeoPrior(project(pr["lat"], pr["lon"]), rec_cls, C)  # cache per model
        n_all = np.bincount(ytr_all, minlength=C)
        print(f"{model}: {len(ytr_all):,} train photos over {int((n_all > 0).sum()):,} species; "
              f"val {len(ev['val']['y']):,}, test {len(ev['test']['y']):,} photos", flush=True)
        out = {"info": info, "train_photos": int(len(ytr_all)), "methods": {}, "curve": {}}
        preds = {}

        def finish(name, Lp, n_tr, extra):
            """Tune the prior on val (coordinate search), report test."""
            for pk in ("none", "frequency", "local"):
                def val_of(o):
                    lp = geo.log_prior("val", ev["val"]["xy"], pk, o.get("sigma"), o.get("alpha"))
                    return objective(Lp["val"] + o["lam"] * lp, ev["val"])
                if pk == "none":
                    o = {"lam": 0}
                elif pk == "frequency":
                    o = max(({"lam": l} for l in grids["lam"]), key=val_of)
                else:  # λ at a middle kernel, then (σ, α) at that λ, then λ again
                    mid = {"sigma": grids["sigma"][len(grids["sigma"]) // 2],
                           "alpha": grids["alpha"][len(grids["alpha"]) // 2]}
                    o = max(({**mid, "lam": l} for l in grids["lam"]), key=val_of)
                    o = max(({"lam": o["lam"], "sigma": s, "alpha": al} for s in grids["sigma"]
                             for al in grids["alpha"]), key=val_of)
                    o = max(({**o, "lam": l} for l in grids["lam"]), key=val_of)
                lp = geo.log_prior("test", ev["test"]["xy"], pk, o.get("sigma"), o.get("alpha"))
                r = score(log_softmax(Lp["test"] + o["lam"] * lp), ev["test"], ctx, n_tr)
                preds[f"{name} + {pk}"] = r.pop("_pred")
                r["params"] = {**extra, **o}
                r["val_objective"] = float(val_of(o))
                out["methods"][f"{name} + {pk}"] = r
                print(f"  {name:28s} {pk:9s} top1 {r['top1']:.3f}  top5 {r['top5']:.3f}  "
                      f"genus {r['genus1']:.3f}  per-species {r['top1_species']:.3f}  "
                      f"(val {r['val_objective']:.3f})", flush=True)

        def raw_of(W, beta, Xtr, ytr):
            mu_i = Xtr.mean(0)
            r_hub = 0.0
            if beta:
                ref = np.random.default_rng(0).permutation(len(ytr))[:5000]
                r_hub = hub_offsets(W, unit(Xtr[ref] - mu_i), ytr[ref])
            return {s: unit(ev[s]["X"] - mu_i) @ W.T - beta * r_hub for s in ev}

        def pick(cands, Xtr, ytr):
            """cands: [(extra, W)] → best (val, extra, W, β), no prior."""
            best = None
            for extra, W in cands:
                for beta in (0.0, 1.0):
                    v = objective(raw_of(W, beta, Xtr, ytr)["val"], ev["val"])
                    if best is None or v > best[0]:
                        best = (v, extra, W, beta)
            return best

        def run(name, W, beta, Xtr, ytr, extra):
            Lp, t = calibrate(raw_of(W, beta, Xtr, ytr), ev)
            finish(name, Lp, np.bincount(ytr, minlength=C), {**extra, "hub": beta,
                                                              "temp": round(t, 3)})
            return Lp

        # zero-shot, as BioCLIP ships it (no centring, no photos at all)
        Lzs, t = calibrate({s: ev[s]["X"] @ T.T for s in ev}, ev)
        finish("zero-shot (plain)", Lzs, n_all, {"temp": round(t, 3)})
        Tc = unit(T - T.mean(0))  # text centred on its own mean (modality gap)
        _, extra, W, beta = pick([({}, Tc)], Xtr_all, ytr_all)
        run("zero-shot (centred)", W, beta, Xtr_all, ytr_all, extra)

        shot_sets = [("all", np.arange(len(ytr_all)))]
        for k in a.shots:  # first k per species (train order is a random rank)
            seen, sel = {}, []
            for i, c in enumerate(ytr_all):
                if seen.get(c, 0) < k:
                    seen[c] = seen.get(c, 0) + 1
                    sel.append(i)
            shot_sets.append((f"≤{k}", np.array(sel)))
        Llin_all = None
        for tag, sel in shot_sets:
            Xs, ys = Xtr_all[sel], ytr_all[sel]
            Xc = unit(Xs - Xs.mean(0))  # centred on THIS subset's photo mean
            _, extra, W, beta = pick([({"gamma": g}, prototype(Xc, ys, Tc, g))
                                      for g in grids["gamma"]], Xs, ys)
            run(f"prototype ({tag})", W, beta, Xs, ys, extra)
            # learning curve: val objective per (μ, epochs), β = 0 (hub never won)
            cands, curve, tl = [], {}, time.time()
            for m in grids["mu"]:
                for ep, Wm in linear(Xc, ys, Tc, m, checkpoints=grids["epochs"],
                                     device=a.device).items():
                    cands.append(({"mu": m, "epochs": ep}, Wm))
                    curve[f"{m:g}/{ep}"] = float(objective(raw_of(Wm, 0.0, Xs, ys)["val"],
                                                           ev["val"]))
            out["curve"][tag] = curve
            print(f"  linear ({tag}) curve in {time.time() - tl:.0f} s: " +
                  ", ".join(f"{k} {v:.3f}" for k, v in curve.items()), flush=True)
            _, extra, W, beta = pick(cands, Xs, ys)
            Lp = run(f"linear ({tag})", W, beta, Xs, ys, extra)
            if tag == "all":
                Llin_all, lin_extra = Lp, extra

        # kNN over individual train photos (centred), then blends with the head
        Xc_all = unit(Xtr_all - Xtr_all.mean(0))
        Q = {s: unit(ev[s]["X"] - Xtr_all.mean(0)) for s in ev}
        best = None
        for tau in grids["knn_tau"]:
            Lk = {s: knn_logp(Q[s], Xc_all, ytr_all, C, grids["knn_k"], tau) for s in ev}
            v = objective(Lk["val"], ev["val"])
            if best is None or v > best[0]:
                best = (v, tau, Lk)
        Lknn, t = calibrate(best[2], ev)
        finish("kNN", Lknn, n_all, {"k": grids["knn_k"], "tau": best[1], "temp": round(t, 3)})
        for bname, Lb in (("zero-shot", Lzs), ("kNN", Lknn)):
            om = max(grids["omega"], key=lambda o: objective(Llin_all["val"] + o * Lb["val"],
                                                             ev["val"]))
            Lbl, t = calibrate({s: Llin_all[s] + om * Lb[s] for s in ev}, ev)
            finish(f"linear (all) ⊕ {bname}", Lbl, n_all,
                   {**lin_extra, "omega": om, "temp": round(t, 3)})

        # error analysis of the best method on val (test predictions)
        name, best_r = max(out["methods"].items(), key=lambda kv: kv[1]["val_objective"])
        pred, y, w = preds[name], ev["test"]["y"], ev["test"]["w"]
        wrong = (y >= 0) & (pred != y)
        pairs = {}
        for i in np.where(wrong)[0]:
            key = (int(y[i]), int(pred[i]))
            pairs[key] = pairs.get(key, 0.0) + w[i]
        same_genus = float(sum(w[i] for i in np.where(wrong)[0]
                               if genus_of[y[i]] == genus_of[pred[i]]) / max(w[wrong].sum(), 1e-9))
        out["errors"] = {
            "method": name, "same_genus_share": same_genus,
            "not_in_labels_share": float(w[y < 0].sum() / w.sum()),
            "top_pairs": [{"true": ctx["name_of"][a_], "predicted": ctx["name_of"][b_],
                           "weight": round(float(v), 1), "same_genus": bool(genus_of[a_] == genus_of[b_])}
                          for (a_, b_), v in sorted(pairs.items(), key=lambda kv: -kv[1])[:30]]}
        results["models"][model] = out

    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=1)
    write_report(results, os.path.join(a.out, "report.md"))
    print(f"report: {os.path.join(a.out, 'report.md')}  ({time.time() - t0:.0f} s)")


def pct(x):
    return "–" if x is None else f"{100 * x:.1f}"


def write_report(res, path):
    lines = [f"# Plant-ID evaluation ({res['generated']})", "",
             "Test-set numbers; every choice made on val. top-1/top-5/genus are "
             "photo-weighted over photos whose species is in the label set; "
             "'all photos' also counts unanswerable ones as wrong.", ""]
    for model, m in res["models"].items():
        lines += [f"## {model} — {m['info']['model']}, {m['train_photos']:,} train photos", "",
                  "| method + prior | top-1 | top-5 | genus | per-species | all photos | "
                  "confident share / right | params |", "|---|---|---|---|---|---|---|---|"]
        for name, r in m["methods"].items():
            lines.append(f"| {name} | {pct(r['top1'])} | {pct(r['top5'])} | {pct(r['genus1'])} | "
                         f"{pct(r['top1_species'])} | {pct(r['top1_all_photos'])} | "
                         f"{pct(r['confident_share'])} / {pct(r['confident_top1'])} | "
                         f"{r['params']} |")
        for tag, curve in m.get("curve", {}).items():
            mus = sorted({k.split("/")[0] for k in curve}, key=float)
            eps = sorted({int(k.split("/")[1]) for k in curve})
            lines += ["", f"Learning curve, linear ({tag}): val objective by L2 weight μ "
                          f"(rows) and passes over the data (columns)", "",
                      "| μ | " + " | ".join(str(e) for e in eps) + " |",
                      "|---|" + "---|" * len(eps)]
            for mu in mus:
                lines.append(f"| {mu} | " + " | ".join(pct(curve.get(f"{mu}/{e}")) for e in eps)
                             + " |")
        name, best = max(m["methods"].items(), key=lambda kv: kv[1]["val_objective"] or 0)
        lad = best["ladder"]
        lines += ["", f"Best on VAL: **{name}**.", "",
                  f"Answer ladder (all test photos): species named {pct(lad['species'])} % "
                  f"(right {pct(lad['species_right'])} %), genus only {pct(lad['genus'])} % "
                  f"(right {pct(lad['genus_right'])} %), 'not sure' {pct(lad['not_sure'])} %, "
                  f"wrong answer given {pct(lad['wrong_answer'])} %.", "",
                  "| tier (train photos) | photos | top-1 | per-species |", "|---|---|---|---|"]
        for t, r in best["tiers"].items():
            lines.append(f"| {t} | {r['n']} | {pct(r['top1'])} | {pct(r['top1_species'])} |")
        lines += ["", "| group | photos | top-1 |", "|---|---|---|"]
        for g, r in best["groups"].items():
            lines.append(f"| {g} | {r['n']} | {pct(r['top1'])} |")
        zs = m["methods"].get("zero-shot (plain) + none", {})
        lines += ["", "By observation date (zero-shot plain / best):", "",
                  "| period | photos | zero-shot | best |", "|---|---|---|---|"]
        for per, r in best.get("periods", {}).items():
            lines.append(f"| {per} | {r['n']} | {pct(zs.get('periods', {}).get(per, {}).get('top1'))} "
                         f"| {pct(r['top1'])} |")
        er = m.get("errors")
        if er:
            lines += ["", f"Errors of {er['method']}: {pct(er['same_genus_share'])} % of mistakes "
                          f"stay within the right genus; photos outside the label set "
                          f"{pct(er['not_in_labels_share'])} %.", "",
                      "| true | predicted | weight | same genus |", "|---|---|---|---|"]
            for p_ in er["top_pairs"][:20]:
                lines.append(f"| {p_['true']} | {p_['predicted']} | {p_['weight']} | "
                             f"{'yes' if p_['same_genus'] else ''} |")
        lines.append("")
    open(path, "w").write("\n".join(lines))


if __name__ == "__main__":
    main()

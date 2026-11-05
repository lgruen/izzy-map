#!/usr/bin/env python3
"""ONE trained classifier on the frozen BioCLIP 2.5 encoder over the 22,122
classes (Tasmanian shipped labels ∪ Australian natives) — README "Single
model (v2)". Replaces the patchwork (Tasmanian head + bank, AU head +
prototypes + zero-shot term, gate, post-hoc ensemble) with:

  head    logits = q · Wᵀ + b, q = normalise(normalise(x) − μ) (μ = train mean),
          W initialised at s0 · (centred text vectors) (the zero-shot classifier,
          s0 = its NLL-fitted scale on val), b = 0.
  loss    logit-adjusted cross-entropy (Menon et al. 2021):
          CE(logits + τ · log π_y), π = training class frequencies; classes with
          no photo have log π = −∞, so they never enter the training softmax
          and keep their text row exactly (the principled zero-shot fallback).
  reg     L2-SP: AdamW on Δ = W − W0 with decoupled weight decay wd (pulls W
          back to the text classifier, not to 0).
  sched   AdamW, linear warmup 1 epoch, cosine to 0; best epoch by per-species
          (class-balanced) val top-1 (early stopping, patience 6).
  test    p_bal(y | x) = softmax(logits) (uniform class prior); with a place:
          log p ∝ log p_bal + λ · log p(y | loc) (one Australia-wide prior),
          then ONE temperature; one answer ladder.

Subcommands
  data     (laptop) train/val arrays → australia/v2/data.npz (+ upload with
           cloud/run_au.sh v2-upload)
  bench    (laptop) one epoch on a 5 % sample on MPS → time per epoch, extrapolated
  vm       (GPU VM) every run of RUNS not yet in GCS → v2/runs/<name>.npz
  local    (laptop) the same, here (for short runs)
  eval     (laptop) prior, temperature, ladder, report sets, ablations, plots

Env (laptop): train_australia.py's; VM: torch + numpy only.
"""
import argparse
import collections
import glob
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
V2 = os.path.join(CACHE, "australia", "v2")
DATA = os.environ.get("V2DATA", os.path.join(V2, "data.npz"))  # the training/val arrays in use

BASE = {"init": "text", "tau": 1.0, "wd": 0.1, "lr": 1e-3, "epochs": 30, "bs": 2048, "frac": 1.0,
        "patience": 6, "seed": 0}
# the sweep: τ × wd for the final recipe, then one-change ablations of it (filled
# in with the chosen τ/wd by `vm --stage 2`)
STAGE1 = [dict(BASE, name=f"tau{t:g}-wd{w:g}", tau=t, wd=w) for t in (0.5, 1.0, 1.5) for w in (0.01, 0.1, 1.0)]


def stage2(best):
    b = dict(BASE, tau=best["tau"], wd=best["wd"])
    return [dict(b, name="abl-random-init", init="random"),
            dict(b, name="abl-plain-ce", tau=0.0),
            dict(b, name="abl-no-l2sp", wd=0.0),
            dict(b, name="size-25", frac=0.25),
            dict(b, name="size-50", frac=0.5),
            dict(b, name="abl-genus-share", genus_gamma=0.5)]


NAME_MAP = os.path.join(CACHE, "names", "apc_inat_map.json")


def name_map_pairs(inat_ids):
    """resolve_names.py's `photo_flow: merge` entries (an APC native that is the
    same iNat taxon as a shipped Tasmanian extra class) → [(apc class, owner class)]."""
    if not os.path.exists(NAME_MAP):
        return []
    owner = {}
    for u, ids in enumerate(inat_ids):
        for i in ids or []:
            owner.setdefault(int(i), u)
    out = []
    for e in json.load(open(NAME_MAP)).values():
        if e.get("photo_flow") == "merge":
            for t in e.get("inat_taxon_ids") or [e.get("inat_taxon_id")]:
                if t is not None and int(t) in owner and owner[int(t)] != e["index"]:
                    out.append((e["index"], owner[int(t)]))
    return out


def class_merges(names, inat_ids, n_photos, extra_pairs=()):
    """Classes that share an iNat taxon id (APC vs Tasmanian names, synonym
    pairs) → {twin: kept}: one class per taxon, the one with the most training
    photos kept (display name = build_ship.tas_named_labels' rule). Asserts that
    after merging no two classes share a taxon id or a display name."""
    by = collections.defaultdict(set)
    for u, ids in enumerate(inat_ids):
        for i in ids or []:
            by[int(i)].add(u)
    parent = list(range(len(names)))

    def find(u):
        while parent[u] != u:
            parent[u] = parent[parent[u]]
            u = parent[u]
        return u
    for g in list(by.values()) + [set(p) for p in extra_pairs]:
        g = sorted(g)
        for u in g[1:]:
            parent[find(u)] = find(g[0])
    groups = collections.defaultdict(list)
    for u in range(len(names)):
        groups[find(u)].append(u)
    merge = {}
    for g in groups.values():
        if len(g) > 1:
            keep = max(g, key=lambda u: (n_photos[u], -u))
            merge.update({u: keep for u in g if u != keep})
    active = [u for u in range(len(names)) if u not in merge]
    # (a kept class answers for its twins: its display name follows tas_named_labels)
    nm = collections.Counter(names[u] for u in active)
    assert all(v == 1 for v in nm.values()), [k for k, v in nm.items() if v > 1]
    seen = collections.Counter(int(i) for u in active for i in (inat_ids[u] or []))
    assert all(v == 1 for v in seen.values())
    return merge


def stage3(best):
    b = dict(BASE, tau=best["tau"], wd=best["wd"])
    return [dict(b, name=f"tau{best['tau']:g}-wd{best['wd']:g}-e12", epochs=12),
            dict(b, name=f"tau{best['tau']:g}-wd0.001", wd=0.001),
            dict(b, name=f"tau{best['tau']:g}-wd0.001-e12", wd=0.001, epochs=12)]


def unit(x):
    return x / np.linalg.norm(x, axis=1, keepdims=True)


# --------------------------------------------------------------------- data

def cmd_data(a):
    sys.path.insert(0, HERE)
    import pyarrow.parquet as pq
    import build_ship as BS
    import train_australia as TA
    os.makedirs(V2, exist_ok=True)
    Ut = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["ship", "genus"]).to_pydict()
    U = Ut["ship"]
    gnames = {g: i for i, g in enumerate(sorted(set(Ut["genus"])))}
    genus = np.array([gnames[g] for g in Ut["genus"]], np.int32)
    nU = len(U)
    ship2u = np.full(2675, -1)
    for u, s in enumerate(U):
        if s >= 0:
            ship2u[s] = u
    ids, E = TA.all_embeddings()
    # train = plan train (AU, cap 100) ∪ the Tasmanian run's train photos
    tr = pq.read_table(os.path.join(TA.AU, "plan", "train.parquet"), columns=["photo_id", "u", "lat", "lon"]).to_pydict()
    ttr = pq.read_table(os.path.join(CACHE, "sets", "train.parquet"), columns=["photo_id", "lat", "lon"]).to_pydict()
    loc = {int(p): (la, lo) for p, la, lo in zip(tr["photo_id"] + ttr["photo_id"], tr["lat"] + ttr["lat"], tr["lon"] + ttr["lon"])}
    SS = BS.load_sets()
    tas_p = np.array(SS["tr"]["photo_id"], np.int64)
    tas_y = ship2u[SS["ytr"]]
    pid = np.r_[np.array(tr["photo_id"], np.int64), tas_p]
    y = np.r_[np.array(tr["u"], np.int64), tas_y]
    _, first = np.unique(pid, return_index=True)
    pid, y = pid[np.sort(first)], y[np.sort(first)]
    i, ok = TA.lookup(ids, pid)
    X, y, pid = E[i[ok]], y[ok], pid[ok]
    src = np.zeros(len(y), np.int8)  # 0 = iNat open data (CC0/BY/BY-NC), 1 = --extra
    ll = np.array([loc.get(int(p), (np.nan, np.nan)) for p in pid], float)
    tas = BS.in_tas(ll[:, 0], ll[:, 1])
    if a.reassign:
        y = apply_reassign(a.reassign, y, pid)
    if a.extra:
        X, y, pid, src, tas = add_extra(a.extra, X, y, pid, src, nU, a.extra_emb, tas)
    L = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name", "inat_ids"]).to_pydict()
    merge = class_merges(L["name"], L["inat_ids"], np.bincount(y, minlength=nU), name_map_pairs(L["inat_ids"]))
    print(f"class merges (shared iNat taxon): {merge}")
    for a_, b_ in merge.items():
        y[y == a_] = b_
    print(f"train: {tas.sum():,} photos taken in the Tasmania box")
    print(f"train: {len(y):,} photos ({len(tas_p):,} Tasmanian-run photos, union), "
          f"{len(np.unique(y)):,} classes")
    # val: AU-val (plan val observers minus C-report / A-test observers) + A-val
    import eval_australia as EA
    crows = EA.c_rows()
    te = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["observer_id", "split"]).to_pydict()
    excl = {r["observer_id"] for r in crows if r["half"] == "report"} | {
        o for o, s in zip(te["observer_id"], te["split"]) if s == "test"}
    pe = {k: np.array(v) for k, v in pq.read_table(os.path.join(TA.AU, "plan", "eval.parquet"), columns=[
        "observer_id", "lat", "lon", "role", "u", "photo_id", "n_split"]).to_pydict().items()}
    ie, oke = TA.lookup(ids, pe["photo_id"])
    m = oke & (pe["role"] == "val") & ~np.isin(pe["observer_id"], list(excl))
    uv = pe["u"][m].copy()
    cnt = collections.Counter(uv.tolist())
    wv = pe["n_split"][m] / np.array([cnt[x] for x in uv])
    ev = SS["ev"]["val"]
    ya = np.where(ev["y"] >= 0, ship2u[np.maximum(ev["y"], 0)], -1)
    for a_, b_ in merge.items():
        uv[uv == a_] = b_
        ya[ya == a_] = b_
    T = np.load(os.path.join(TA.AU, "text.npz"))["emb"].astype(np.float32)
    mu = unit(X.astype(np.float32)).mean(0)
    # zero-shot scale s0: NLL of the centred cosine classifier on AU-val
    import torch
    Tc = torch.from_numpy(unit(T - T.mean(0)))
    q = torch.from_numpy(unit(unit(E[ie[m]].astype(np.float32)) - mu))
    cos = q @ Tc.T
    yv = torch.from_numpy(uv)
    nll = {s: float(-torch.log_softmax(s * cos, 1).gather(1, yv[:, None]).mean()) for s in (20, 30, 40, 50, 70, 100)}
    s0 = min(nll, key=nll.get)
    print(f"zero-shot scale s0 = {s0} (val NLL {nll})")
    out = a.out or DATA
    np.savez(out, Xtr=X.astype(np.float16), ytr=y.astype(np.int32), mu=mu.astype(np.float32),
             src=src, pid=pid, tas=tas, merge_from=np.array(list(merge), np.int32), merge_to=np.array(list(merge.values()), np.int32),
             T=T.astype(np.float16), s0=np.float32(s0), genus=genus,
             Xv=E[ie[m]].astype(np.float16), yv=uv.astype(np.int32), wv=wv.astype(np.float32),
             latv=pe["lat"][m], lonv=pe["lon"][m], obsv=pe["observer_id"][m],
             Xa=ev["X"].astype(np.float16), ya=ya.astype(np.int32), wa=ev["w"].astype(np.float32),
             spa=ev["sp"], lata=ev["lat"], lona=ev["lon"])
    import provenance as PV
    PV.record("v2 data", inputs=[os.path.join(TA.AU, "plan", "train.parquet"), os.path.join(TA.AU, "plan", "eval.parquet"),
                                 os.path.join(CACHE, "sets", "train.parquet"), os.path.join(TA.AU, "labels.parquet"),
                                 os.path.join(TA.AU, "text.npz"), NAME_MAP, a.extra, a.reassign], outputs=[out],
              extra={"extra_emb": a.extra_emb})
    print(f"val: AU-val {m.sum():,} photos, A-val {len(ya):,}; → {out} "
          f"({os.path.getsize(out) / 1e9:.2f} GB)")


def add_extra(path, X, y, pid, src, nU, emb_dir=None, tas=None):
    """Extra training photos (other sources / licences) without code changes.
    `path` = parquet with columns
      u        class index (row of au-labels / labels.parquet) — or `species`
               (binomial, matched against labels.parquet `name` and `aliases`)
      photo_id photo key (int64; iNat sources share iNat's photo-id space and are
               de-duplicated against the training photos)
      source   e.g. "inat-extra-photo", "inat-sa-nd", "ala", "wikimedia"
      licence | license   any CC licence or PD (never all-rights-reserved)
      shard    (optional) path of an .npz with `photo_id` + `emb`; without it (or
               with an integer shard number) the embedding is looked up by
               photo_id in every *.npz under `emb_dir`
      lat, lon (optional) → the Tasmania flag for the photo weighting
    Embeddings: BioCLIP 2.5 cloud fp16 with the same preprocessing. The caller
    guarantees observer-disjointness from val/test (expand_inat.py asserts it);
    this function rejects ARR licences, unknown classes, duplicate photo ids and
    photos already in training."""
    import pyarrow.parquet as pq
    t = pq.read_table(path).to_pydict()
    n = len(t["photo_id"])
    if "u" not in t:
        L = pq.read_table(os.path.join(CACHE, "australia", "labels.parquet"), columns=["name", "aliases"]).to_pydict()
        key = {}
        for u, (nm, al) in enumerate(zip(L["name"], L["aliases"])):
            for k in [nm] + [x for x in (al or "").split("|") if x]:
                key.setdefault(k, u)
        t["u"] = [key.get(sp, -1) for sp in t["species"]]
    lic = [str(x).upper() for x in (t.get("licence") or t.get("license"))]
    have = set(int(p) for p in pid)
    bad = {i for i in range(n) if not lic[i].startswith(("CC", "PD")) or t["u"][i] is None
           or not 0 <= t["u"][i] < nU}
    seen, keep, dup = set(), [], 0
    for i in range(n):
        k = int(t["photo_id"][i])
        if i in bad:
            continue
        if k in seen or k in have:
            dup += 1
            continue
        seen.add(k)
        keep.append(i)
    # embeddings: explicit npz path per row, else an index over emb_dir
    index = {}
    if emb_dir:
        for f in sorted(glob.glob(os.path.join(emb_dir, "**", "*.npz"), recursive=True)):
            z = np.load(f)
            if "photo_id" in z and "emb" in z:
                for j, p in enumerate(z["photo_id"].tolist()):
                    index[int(p)] = (f, j)
    cache = {}
    xs, ys, ps, ts = [], [], [], []
    for i in keep:
        sh = t.get("shard", [None] * n)[i]
        loc = (sh, None) if isinstance(sh, str) and sh.endswith(".npz") else index.get(int(t["photo_id"][i]))
        if not loc:
            continue
        f, j = loc
        if f not in cache:
            z = np.load(f)
            cache = {f: (z["photo_id"], z["emb"])}
        ids, emb = cache[f]
        if j is None:
            hit = np.nonzero(ids == int(t["photo_id"][i]))[0]
            if not len(hit):
                continue
            j = int(hit[0])
        xs.append(emb[j]); ys.append(int(t["u"][i])); ps.append(int(t["photo_id"][i]))
        la, lo = (t.get("lat") or [None] * n)[i], (t.get("lon") or [None] * n)[i]
        ts.append(bool(la is not None and lo is not None and BS_in_tas(la, lo)))
    print(f"extra: {n:,} rows, {len(bad):,} rejected (licence/class), {dup:,} duplicates, {len(xs):,} added "
          f"(embedding found); sources {collections.Counter(t['source'][i] for i in keep)}")
    if not xs:
        return X, y, pid, src, tas
    return (np.concatenate([X, np.stack(xs).astype(X.dtype)]), np.r_[y, ys], np.r_[pid, ps],
            np.r_[src, np.ones(len(xs), np.int8)], None if tas is None else np.r_[tas, np.array(ts, bool)])


def BS_in_tas(lat, lon):
    return 143.5 <= lon <= 149.0 and -44.0 <= lat <= -39.2


def apply_reassign(path, y, pid):
    """expand_inat.py's reassign_train.parquet: training photos the name map moves
    to another label (photo_id, u_old, u_new)."""
    import pyarrow.parquet as pq
    t = pq.read_table(path, columns=["photo_id", "u_old", "u_new"]).to_pydict()
    pos = {int(p): i for i, p in enumerate(pid)}
    moved = 0
    for p, a_, b_ in zip(t["photo_id"], t["u_old"], t["u_new"]):
        i = pos.get(int(p))
        if i is not None and y[i] == a_:
            y[i] = b_
            moved += 1
    print(f"reassign: {moved} of {len(t['photo_id'])} training photos moved to their new label")
    return y


# --------------------------------------------------------------------- train

def objective(pred, y, w):
    hit = pred == y
    inl = y >= 0
    micro = (hit * w)[inl].sum() / w[inl].sum()
    _, inv = np.unique(y[inl], return_inverse=True)
    macro = (np.bincount(inv, hit[inl]) / np.bincount(inv)).mean()
    return float(micro), float(macro), float(0.5 * (micro + macro))


def train(c, D, dev, log=print, max_steps=None):
    """→ (curve, W, b, info). D = np.load(data.npz)."""
    import torch
    torch.manual_seed(c["seed"])
    rng = np.random.default_rng(c["seed"])
    C = D["T"].shape[0]
    mu = torch.from_numpy(D["mu"]).to(dev)

    def centre(X):
        out = []
        for i in range(0, len(X), 65536):
            x = torch.from_numpy(X[i:i + 65536].astype(np.float32)).to(dev)
            x = torch.nn.functional.normalize(x, dim=-1) - mu
            out.append(torch.nn.functional.normalize(x, dim=-1).half())
        return torch.cat(out)
    y = D["ytr"].astype(np.int64)
    idx = np.arange(len(y))
    if c["frac"] < 1:  # per class: the first ⌈frac · n⌉ photos of a seeded permutation
        perm = rng.permutation(len(y))
        order = perm[np.argsort(y[perm], kind="stable")]
        starts = np.r_[0, np.cumsum(np.bincount(y, minlength=C))]
        keep = []
        for k in range(C):
            n = starts[k + 1] - starts[k]
            if n:
                keep.append(order[starts[k]:starts[k] + max(1, math.ceil(c["frac"] * n))])
        idx = np.sort(np.concatenate(keep))
    Xc = centre(D["Xtr"][idx])
    yt = torch.from_numpy(y[idx]).to(dev)
    n_c = torch.bincount(yt, minlength=C).float()
    logpi = torch.where(n_c > 0, torch.log(n_c / n_c.sum()), torch.full_like(n_c, -1e4))
    Tc = torch.from_numpy(unit(D["T"].astype(np.float32) - D["T"].astype(np.float32).mean(0))).to(dev)
    # parametrised at unit scale: W = s0 · (W0 + Δ), b = s0 · β, so Adam's step size is
    # relative to unit-norm rows (as in the Tasmanian head) whatever s0 is
    s0 = float(D["s0"])
    if c["init"] == "text":
        W0 = Tc
        if c.get("genus_gamma"):  # hierarchical sharing: anchor = blend of text and genus mean
            g = torch.from_numpy(D["genus"].astype(np.int64)).to(dev)
            G = int(g.max()) + 1
            # genus mean from data: Σ centred train photos of the genus' classes, + its text rows
            gs = torch.zeros(G, Tc.shape[1], device=dev)
            gs.index_add_(0, g[yt], Xc.float())
            gs = torch.nn.functional.normalize(gs, dim=-1)
            gt = torch.nn.functional.normalize(torch.zeros(G, Tc.shape[1], device=dev).index_add_(0, g, Tc), dim=-1)
            gm = torch.nn.functional.normalize(gs + gt, dim=-1)
            W0 = torch.nn.functional.normalize((1 - c["genus_gamma"]) * Tc + c["genus_gamma"] * gm[g], dim=-1)
        Dw = torch.nn.Parameter(torch.zeros_like(W0))
    else:
        W0 = torch.zeros_like(Tc)
        Dw = torch.nn.Parameter(torch.nn.functional.normalize(torch.randn_like(Tc), dim=-1))
    beta = torch.nn.Parameter(torch.zeros(C, device=dev))
    opt = torch.optim.AdamW([Dw, beta], lr=c["lr"], weight_decay=c["wd"], betas=(0.9, 0.999))
    n = len(yt)
    spe = -(-n // c["bs"])
    total = spe * c["epochs"]
    warm = spe

    def lr_at(s):
        return (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm)))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)
    Xv, yv, wv = centre(D["Xv"]), D["yv"].astype(np.int64), D["wv"]
    Xa, ya, wa = centre(D["Xa"]), D["ya"].astype(np.int64), D["wa"]
    yvt = torch.from_numpy(yv).to(dev)
    tau = c["tau"]
    # sample weights: Tasmanian photos × tas_weight (default 1)
    sw = torch.ones(n, device=dev)
    if c.get("tas_weight", 1.0) != 1.0:
        sw[torch.from_numpy(D["tas"][idx]).to(dev)] = c["tas_weight"]
    curve, best, bad, step, t0 = [], None, 0, 0, time.time()
    for ep in range(1, c["epochs"] + 1):
        perm = torch.randperm(n, device=dev)
        tl, tn = 0.0, 0
        for i in range(0, n, c["bs"]):
            bi = perm[i:i + c["bs"]]
            W = s0 * (W0 + Dw)
            logits = Xc[bi].float() @ W.T + s0 * beta
            ce = torch.nn.functional.cross_entropy(logits + tau * logpi, yt[bi], reduction="none")
            loss = (ce * sw[bi]).sum() / sw[bi].sum()
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            tl += float(loss) * len(bi)
            tn += len(bi)
            step += 1
            if max_steps and step >= max_steps:
                break
        with torch.no_grad():
            W = s0 * (W0 + Dw)
            b = s0 * beta
            Lv = Xv.float() @ W.T + b
            vloss = float(torch.nn.functional.cross_entropy(Lv, yvt))
            pv = Lv.argmax(1).cpu().numpy()
            pa = (Xa.float() @ W.T + b).argmax(1).cpu().numpy()
        mi, ma, ob = objective(pv, yv, wv)
        a_mi = float(((pa == ya) * wa)[ya >= 0].sum() / wa[ya >= 0].sum())
        drift = float(((Dw.detach() if c["init"] == "text" else Dw.detach() - 0) ** 2).sum(1).sqrt().mean())
        r = {"epoch": ep, "train_loss": tl / tn, "val_loss": vloss, "val_top1_w": mi, "val_top1_sp": ma,
             "val_obj": ob, "aval_top1_w": a_mi, "lr": float(sched.get_last_lr()[0]), "row_drift": drift,
             "s": round(time.time() - t0, 1)}
        curve.append(r)
        log(f"  {c['name']} ep {ep}: train {r['train_loss']:.4f} val {vloss:.4f} top1 w {mi:.4f} sp {ma:.4f} "
            f"A-val {a_mi:.4f} ({r['s']} s)")
        sel = ma  # selection = class-balanced (per-species) val top-1 (Leo, 2026-11-05)
        if best is None or sel > best[0]:
            best = (sel, ep, W.detach().cpu().numpy().astype(np.float16), b.detach().cpu().numpy())
            bad = 0
        else:
            bad += 1
            if bad >= c["patience"]:
                break
        if max_steps and step >= max_steps:
            break
    info = {"best_epoch": best[1], "best_val_top1_sp": best[0], "photos": int(n),
            "classes_with_photos": int((n_c > 0).sum()), "seconds": round(time.time() - t0, 1)}
    return curve, best[2], best[3], info, n_c.cpu().numpy()


def run_all(runs, D, dev, have, put, log=print):
    for c in runs:
        if c["name"] in have:
            log(f"{c['name']}: done already")
            continue
        curve, W, b, info, n_c = train(c, D, dev, log)
        put(c["name"], {"W": W, "b": b, "n_c": n_c.astype(np.int32),
                        "meta": np.array(json.dumps({"cfg": c, "info": info, "curve": curve}))})
        log(f"{c['name']}: {info}")


def cmd_bench(a):
    """One epoch on a 5 % sample (MPS) → s/epoch, extrapolated to the full set."""
    import torch
    D = dict(np.load(DATA))
    full = len(D["ytr"])
    rng = np.random.default_rng(0)
    s = np.sort(rng.permutation(full)[:full // 20])
    D5 = dict(D, Xtr=D["Xtr"][s], ytr=D["ytr"][s])
    c = dict(BASE, name="bench5", epochs=int(os.environ.get("EP", 2)), patience=99)
    t = time.time()
    curve, *_ = train(c, D5, "mps" if torch.backends.mps.is_available() else "cpu")
    ep = (curve[-1]["s"] - curve[0]["s"]) / max(1, len(curve) - 1)  # epochs after the 1st
    out = {"sample_photos": len(s), "s_per_epoch_5pct": round(ep, 1),
           "extrapolated_s_per_epoch_full": round(ep * 20, 0),
           "extrapolated_min_per_30_epoch_run": round(ep * 20 * 30 / 60, 1), "total_s": round(time.time() - t, 1)}
    print(json.dumps(out))
    json.dump(out, open(os.path.join(V2, "bench.json"), "w"), indent=1)


def cmd_local(a):
    """Short local runs (MPS) → australia/v2/runs/<name>.npz (same format as the VM's)."""
    import torch
    D = dict(np.load(DATA))
    od = os.path.join(V2, "runs")
    os.makedirs(od, exist_ok=True)
    for spec in a.runs:
        c = dict(BASE, **json.loads(spec))
        curve, W, b, info, n_c = train(c, D, "mps" if torch.backends.mps.is_available() else "cpu")
        np.savez(os.path.join(od, c["name"] + ".npz"), W=W, b=b, n_c=n_c.astype(np.int32),
                 meta=np.array(json.dumps({"cfg": c, "info": info, "curve": curve})))
        print(f"{c['name']}: {info}", flush=True)
        import provenance as PV
        PV.record("v2 train", inputs=[DATA], outputs=[os.path.join(od, c["name"] + ".npz")],
                  extra={"cfg": c, "info": info, "device": "mps" if torch.backends.mps.is_available() else "cpu"})


def cmd_vm(a):
    import torch
    bucket = a.bucket.rstrip("/")
    D = dict(np.load(os.path.join(a.work, "data.npz")))
    od = os.path.join(a.work, "runs")
    os.makedirs(od, exist_ok=True)

    def have():
        r = subprocess.run(["gcloud", "storage", "ls", f"{bucket}/v2/runs/"], capture_output=True, text=True)
        return {os.path.basename(l)[:-4] for l in r.stdout.split() if l.endswith(".npz")}

    def put(name, arrs):
        p = os.path.join(od, name + ".npz")
        np.savez(p, **arrs)
        subprocess.run(["gcloud", "storage", "cp", p, f"{bucket}/v2/runs/", "--quiet"], check=True)
    run_all(STAGE1, D, "cuda", have(), put, log=lambda s: print(s, flush=True))
    # stage 2: ablations of the stage-1 winner (by per-species val top-1)
    res = []
    for c in STAGE1:
        z = np.load(os.path.join(od, c["name"] + ".npz")) if os.path.exists(os.path.join(od, c["name"] + ".npz")) \
            else None
        if z is None:
            subprocess.run(["gcloud", "storage", "cp", f"{bucket}/v2/runs/{c['name']}.npz", od, "--quiet"], check=True)
            z = np.load(os.path.join(od, c["name"] + ".npz"))
        res.append((json.loads(str(z["meta"]))["info"]["best_val_top1_sp"], c))
    best = max(res, key=lambda r: r[0])[1]
    print(f"stage 1 winner: {best['name']}", flush=True)
    run_all(stage2(best), D, "cuda", have(), put, log=lambda s: print(s, flush=True))
    # stage 3 (after the curves showed val loss bottoming at epoch ~10 of 30 and the
    # smallest wd winning): a schedule that ends where early stopping did, and wd → 0.001
    run_all(stage3(best), D, "cuda", have(), put, log=lambda s: print(s, flush=True))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("data")
    p.add_argument("--extra", help="parquet of extra training photos (see add_extra)")
    p.add_argument("--extra-emb", help="directory of *.npz embedding shards holding the extras")
    p.add_argument("--reassign", help="expand_inat.py's reassign_train.parquet")
    p.add_argument("--out", help="data file (default australia/v2/data.npz)")
    sub.add_parser("bench")
    p = sub.add_parser("vm")
    p.add_argument("--bucket", required=True)
    p.add_argument("--work", required=True)
    p = sub.add_parser("local")
    p.add_argument("runs", nargs="+", help='JSON configs over BASE, e.g. {"name": "x", "epochs": 12}')
    a = ap.parse_args()
    {"data": cmd_data, "bench": cmd_bench, "vm": cmd_vm, "local": cmd_local}[a.cmd](a)


if __name__ == "__main__":
    main()

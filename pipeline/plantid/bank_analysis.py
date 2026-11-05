#!/usr/bin/env python3
"""Why does the Tasmania-box kNN bank help the single model (v2), and is there
a general (Australia-wide) mechanism that does the same? Analysis only — the
shipped files and the training/eval scripts are untouched.

Subcommands (eval_v2.py's env; V2DATA=…/data-final.npz):
  cache       sets (A-val, A-test, AU-val, AU-test, C-report) → WORK/sets.npz
              (raw embeddings, lat/lon, merged truths, weights) + the two
              priors per set (fp16 log p, n × C) → WORK/prior-*.npy
  decompose   part 1: kNN term vs the box's re-tuned prior (A-val tunes,
              A-test once) + per-photo neighbour dumps for part 2
  flips       part 2: error analysis of the photos the bank flips
  natknn      part 3 (i): national kNN bank / per-class prototypes in v2 space
  strict      part 4: A re-scored without test photos near a same-class
              training photo

WORK = env BA_WORK (default pipeline/cache/plantid/australia/v2/bank_analysis).
Run (as eval_v2): FINAL=final-cb50-s1 TAUNORM=0.5
  V2PRIOR=…/prior-eval-inatpool+ala-noinat.bin python3 -I bank_analysis.py <cmd>
"""
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402
import train_v2 as V  # noqa: E402

RUN = os.environ.get("FINAL", "final-cb50-s1")
TN = float(os.environ.get("TAUNORM", 0.5))
WORK = os.environ.get("BA_WORK") or os.path.join(V.V2, "bank_analysis")
PRIOR = os.environ.get("V2PRIOR") or BS.V2_PRIOR_EVAL
MAIN = ("log1p", 10.0, 64.0, 1.0)   # eval.json final prior (transform, σ, α, λ)
BOX = ("sqrt", 5.0, 16.0, 1.0)      # tas_gap F5 prior inside the box
SETS = ("A-val", "A-test", "AU-val", "AU-test", "C-report")
os.makedirs(WORK, exist_ok=True)


def log(*a):
    print(*a, flush=True)


# ------------------------------------------------------------ cache

def cmd_cache():
    import eval_v2 as E2
    import pyarrow.parquet as pq
    import train_australia as TA
    t0 = time.time()
    D, U, genus, euc, sets, ship, ash = E2.load_sets()
    C = D["T"].shape[0]
    z = np.load(os.path.join(V.V2, "runs", RUN + ".npz"))
    n_tr = z["n_c"].astype(np.int64).copy()
    L_ = pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name", "inat_ids", "rg_au"]).to_pydict()
    merge = V.class_merges(L_["name"], L_["inat_ids"], n_tr, V.name_map_pairs(L_["inat_ids"]))
    mapv = np.arange(C)
    for a_, b_ in merge.items():
        mapv[a_] = b_
        n_tr[b_] += n_tr[a_]
        n_tr[a_] = 0
    SS = BS.load_sets()
    out = {"mapv": mapv, "n_tr": n_tr, "genus": genus, "euc": np.asarray(euc, bool), "rg_au": np.array(L_["rg_au"]),
           "s2u": mapv[ash.ship2u], "mu": D["mu"]}
    pid = {"A-val": SS["ev"]["val"]["photo_id"], "A-test": SS["ev"]["test"]["photo_id"]}
    for nm in SETS:
        S = sets[nm]
        y = np.where(S.y >= 0, mapv[np.maximum(S.y, 0)], -1)
        out[nm + "/emb"], out[nm + "/lat"], out[nm + "/lon"] = S.emb, S.lat, S.lon
        out[nm + "/y"], out[nm + "/w"] = y, S.w
        p_ = pid.get(nm, S.pid)
        if p_ is not None:
            out[nm + "/pid"] = np.asarray(p_, np.int64)
        if S.sub is not None:
            out[nm + "/sub"] = S.sub
        if S.obs is not None:
            out[nm + "/obs"] = S.obs
    assert len(out["A-val/pid"]) == len(out["A-val/y"])
    np.savez(os.path.join(WORK, "sets.npz"), **out)
    log(f"sets cached ({time.time() - t0:.0f} s)", {nm: len(out[nm + '/y']) for nm in SETS})
    P = BS.V2Prior(PRIOR)
    for tag, (tr, sg, al, _) in (("main", MAIN), ("box", BOX)):
        for nm in SETS:
            if tag == "box" and nm not in ("A-val", "A-test", "AU-val", "AU-test"):
                continue
            lat, lon = out[nm + "/lat"], out[nm + "/lon"]
            arr = np.lib.format.open_memmap(os.path.join(WORK, f"prior-{tag}-{nm}.npy"), "w+", np.float16,
                                            (len(lat), C))
            for i in range(0, len(lat), 1024):
                arr[i:i + 1024] = P.log_prior(lat[i:i + 1024], lon[i:i + 1024], tr, sg, al)
            arr.flush()
            log(f"prior {tag} {nm} ({time.time() - t0:.0f} s)")


def load():
    z = np.load(os.path.join(WORK, "sets.npz"), allow_pickle=True)
    return {k: z[k] for k in z.files}


def head():
    z = np.load(os.path.join(V.V2, "runs", RUN + ".npz"))
    W, b = z["W"].astype(np.float32), z["b"].astype(np.float32)
    if TN:
        nr = np.linalg.norm(W, axis=1, keepdims=True).clip(1e-6)
        W = W * (nr.mean() / nr) ** TN
    return W, b


def prior(tag, nm):
    return np.load(os.path.join(WORK, f"prior-{tag}-{nm}.npy"), mmap_mode="r")


def colmask(Z):
    m = np.zeros(len(Z["mapv"]), np.float32)
    m[Z["mapv"] != np.arange(len(Z["mapv"]))] = -1e4
    return m


def head_fn(path, tn=None, dev="mps"):
    """bank_heads.py run → f(q: torch n × d centred) → logits (n × C); τ-norm (scale kept)
    on the per-class norm (mean over a class's K vectors)."""
    import torch
    tn = TN if tn is None else tn
    z = np.load(path)
    W = z["W"].astype(np.float32)
    if W.ndim == 2:
        W = W[:, None]
    if tn:
        nr = np.linalg.norm(W, axis=2).mean(1, keepdims=True).clip(1e-6)
        W = W * ((nr.mean() / nr) ** tn)[..., None]
    Wt = torch.from_numpy(W).to(dev)
    bt = torch.from_numpy(z["b"].astype(np.float32)).to(dev)
    K = W.shape[1]
    ad = None
    if "A" in z.files:
        ad = [torch.from_numpy(z[k].astype(np.float32)).to(dev) for k in ("A", "a", "U")]

    def f(q):
        if ad is not None:
            q = torch.nn.functional.normalize(q + torch.nn.functional.gelu(q @ ad[0].T + ad[1]) @ ad[2].T, dim=-1)
        if K == 1:
            return q @ Wt[:, 0].T + bt
        return torch.logsumexp(torch.einsum("nd,ckd->nck", q, Wt), 2) - np.log(K) + bt
    return f


def head_logp(Z, nm, W, b, dev="mps"):
    import torch
    if os.environ.get("HEAD"):
        f = head_fn(os.environ["HEAD"])
        mu = Z["mu"].astype(np.float32)
        q = BS.unit(BS.unit(Z[nm + "/emb"].astype(np.float32)) - mu[None]).astype(np.float32)
        cm = torch.from_numpy(colmask(Z)).to(dev)
        out = np.empty((len(q), len(Z["mapv"])), np.float32)
        for i in range(0, len(q), 1024):
            out[i:i + 1024] = torch.log_softmax(f(torch.from_numpy(q[i:i + 1024]).to(dev)) + cm, 1).cpu().numpy()
        return out
    mu = Z["mu"].astype(np.float32)
    e = Z[nm + "/emb"].astype(np.float32)
    q = BS.unit(BS.unit(e) - mu[None]).astype(np.float32)
    Wt = torch.from_numpy(W).to(dev)
    bt = torch.from_numpy(b + colmask(Z)).to(dev)
    out = np.empty((len(q), W.shape[0]), np.float32)
    for i in range(0, len(q), 2048):
        L = torch.from_numpy(q[i:i + 2048]).to(dev) @ Wt.T + bt
        out[i:i + 2048] = torch.log_softmax(L, 1).cpu().numpy()
    return out


def score(Z, nm, pred, mask=None):
    y, w = Z[nm + "/y"], Z[nm + "/w"]
    m = (y >= 0) if mask is None else (mask & (y >= 0))
    hit = (pred == y)
    nat = float((hit * w)[m].sum() / w[m].sum())
    _, inv = np.unique(y[m], return_inverse=True)
    sp = float((np.bincount(inv, hit[m]) / np.bincount(inv)).mean())
    return nat, sp


def tas_knn(Z, nm, ship_k=None):
    """Tasmanian bank kNN log p in U space (as build_ship.V2Ship inside the box) +
    the raw neighbours (bank rows, sims) for the error analysis."""
    import torch
    hh, ha = BS.read_blob(os.path.join(BS.SHIP, "head.bin"))
    tmu = ha["centre"].astype(np.float32)
    bh, ba = BS.read_blob(os.path.join(BS.SHIP, "bank-int8.bin"))
    p = bh["scoring"]
    B, bl, bs = ba["vectors"], ba["labels"].astype(np.int64), ba["scale"].astype(np.float32)
    e = Z[nm + "/emb"].astype(np.float32)
    qs = BS.unit(BS.unit(e) - tmu[None]).astype(np.float32)
    Bt = torch.from_numpy(B.astype(np.float16)).to("mps")
    st = torch.from_numpy(bs.astype(np.float16)).to("mps")
    sims, idx = [], []
    for i in range(0, len(qs), 1024):
        S_ = (torch.from_numpy(qs[i:i + 1024]).half().to("mps") @ Bt.T) * st[None]
        v, j = S_.float().topk(p["k"], dim=1)
        sims.append(v.cpu().numpy()), idx.append(j.cpu().numpy())
    sims, idx = np.concatenate(sims), np.concatenate(idx)
    nb = int(bl.max()) + 1
    C = len(Z["mapv"])
    Lk = np.full((len(e), C), -1e4, np.float32)
    s2u = Z["s2u"]
    Lk[:, s2u] = BS.log_softmax(p["knn_temp"] * BS.knn_vote(sims, idx, bl, len(s2u), p["k"], p["tau"]))
    return Lk, sims, idx, qs


# ------------------------------------------------------------ part 1

def cmd_decompose():
    t0 = time.time()
    Z = load()
    W, b = head()
    res, dump = {}, {}
    OMS = (0.25, 0.5, 1.0, 2.0, 3.0, 4.0)
    for nm in ("A-val", "A-test"):
        Lh = head_logp(Z, nm, W, b)
        Pm = np.asarray(prior("main", nm), np.float32)
        Pb = np.asarray(prior("box", nm), np.float32)
        Lk, sims, idx, qs = tas_knn(Z, nm)
        lk = np.maximum(Lk, -30)
        V_ = {"M main path (shipped outside the box)": Lh + MAIN[3] * Pm,
              "P box prior only": Lh + BOX[3] * Pb,
              "H head only (no prior)": Lh}
        for om in OMS:
            Li = BS.log_softmax(Lh + om * lk)
            V_[f"K kNN ω{om} + main prior"] = Li + MAIN[3] * Pm
            V_[f"F kNN ω{om} + box prior"] = Li + BOX[3] * Pb
            V_[f"I kNN ω{om}, no prior"] = Li
            del Li
        preds = {k: v.argmax(1) for k, v in V_.items()}
        res[nm] = {k: score(Z, nm, p) for k, p in preds.items()}
        dump[nm] = dict(preds=preds, sims=sims, idx=idx, top5_M=np.argsort(-V_["M main path (shipped outside the box)"], 1)[:, :5])
        log(nm, f"({time.time() - t0:.0f} s)")
        for k, v in res[nm].items():
            log(f"  {k}: nat {v[0]:.4f} sp {v[1]:.4f}")
        del V_, Lh, Pm, Pb, Lk
    # ω chosen on A-val (natural top-1, as tas_gap) per family, A-test read at that ω
    summ = {}
    for fam in ("K", "F", "I"):
        ks = [k for k in res["A-val"] if k.startswith(fam + " ")]
        kb = max(ks, key=lambda k: res["A-val"][k][0])
        summ[fam] = {"chosen": kb, "A-val": res["A-val"][kb], "A-test": res["A-test"][kb]}
    for k in ("M main path (shipped outside the box)", "P box prior only", "H head only (no prior)",
              "F kNN ω2.0 + box prior", "K kNN ω2.0 + main prior"):
        summ[k] = {"A-val": res["A-val"][k], "A-test": res["A-test"][k]}
    # paired flips vs M for the shipped F5 (ω 2, box prior) and the kNN-only change
    for nm in ("A-val", "A-test"):
        y = Z[nm + "/y"]
        pm = dump[nm]["preds"]["M main path (shipped outside the box)"] == y
        for k in ("F kNN ω2.0 + box prior", "K kNN ω2.0 + main prior", "P box prior only"):
            pf = dump[nm]["preds"][k] == y
            summ.setdefault("flips", {}).setdefault(nm, {})[k] = {"gained": int((~pm & pf).sum()), "lost": int((pm & ~pf).sum())}
    json.dump({"all": res, "summary": summ}, open(os.path.join(WORK, "decompose.json"), "w"), indent=1)
    np.savez(os.path.join(WORK, "flipdump.npz"),
             **{f"{nm}/{k}": v for nm in dump for k, v in
                {"M": dump[nm]["preds"]["M main path (shipped outside the box)"],
                 "F": dump[nm]["preds"]["F kNN ω2.0 + box prior"],
                 "K": dump[nm]["preds"]["K kNN ω2.0 + main prior"],
                 "P": dump[nm]["preds"]["P box prior only"],
                 "sims": dump[nm]["sims"], "idx": dump[nm]["idx"]}.items()})
    log(json.dumps(summ, indent=1))


# ------------------------------------------------------------ part 2

def npz_memmap(path, key):
    """Memory-map one array of an UNCOMPRESSED .npz (data-final.npz is 8 GB)."""
    import zipfile
    zf = zipfile.ZipFile(path)
    info = zf.getinfo(key + ".npy")
    assert info.compress_type == 0, "compressed npz"
    with open(path, "rb") as f:
        f.seek(info.header_offset)
        h = f.read(30)
        n_name, n_extra = int.from_bytes(h[26:28], "little"), int.from_bytes(h[28:30], "little")
        start = info.header_offset + 30 + n_name + n_extra
        f.seek(start)
        ver = np.lib.format.read_magic(f)
        shape, fortran, dtype = (np.lib.format.read_array_header_1_0(f) if ver == (1, 0)
                                 else np.lib.format.read_array_header_2_0(f))
        off = f.tell()
    return np.memmap(path, dtype=dtype, mode="r", offset=off, shape=shape, order="F" if fortran else "C")


def bank_meta():
    """Bank rows (= the Tasmanian run's train photos, BS.load_sets order) → lat, lon, date, observer."""
    import pyarrow.parquet as pq
    S = BS.load_sets()
    _, ba = BS.read_blob(os.path.join(BS.SHIP, "bank-int8.bin"))
    assert np.array_equal(ba["labels"].astype(np.int64), S["ytr"]), "bank rows ≠ train order"
    t = pq.read_table(os.path.join(BS.CACHE, "sets", "train.parquet"),
                      columns=["photo_id", "lat", "lon", "observed_on", "observer_id", "uuid"]).to_pydict()
    r = {p: i for i, p in enumerate(t["photo_id"])}
    j = np.array([r[p] for p in S["tr"]["photo_id"]])
    te = pq.read_table(os.path.join(BS.CACHE, "sets", "test.parquet"),
                       columns=["photo_id", "observed_on", "observer_id", "pacc", "uuid"]).to_pydict()
    rt = {p: i for i, p in enumerate(te["photo_id"])}
    day = lambda d: np.array([(x - __import__("datetime").date(2000, 1, 1)).days if x else -99999 for x in d])  # noqa
    bm = dict(lat=np.array(t["lat"])[j], lon=np.array(t["lon"])[j], day=day([t["observed_on"][i] for i in j]),
              obs=np.array(t["observer_id"])[j], pid=np.array(S["tr"]["photo_id"]))
    return bm, te, rt, day


def geo_km(lat1, lon1, lat2, lon2):
    """Equirectangular distance (km), fine at ≤ 100 km scales; broadcasts (torch or numpy)."""
    import torch
    kx = 111.32 * torch.cos(torch.deg2rad((lat1 + lat2) / 2))
    return torch.sqrt(((lon1 - lon2) * kx) ** 2 + ((lat1 - lat2) * 110.57) ** 2)


VIEWS = {"flower": "a close-up photo of the flowers of a plant",
         "leaf": "a close-up photo of the leaves of a plant",
         "fruit": "a close-up photo of the fruit or seeds of a plant",
         "bark": "a close-up photo of the bark or trunk of a tree",
         "habit": "a photo of a whole plant growing in its habitat"}


def view_text():
    import open_clip
    import torch
    p = os.path.join(WORK, "views.npy")
    if not os.path.exists(p):
        model, _, _ = open_clip.create_model_and_transforms(BS.HF)
        tok = open_clip.get_tokenizer(BS.HF)
        with torch.no_grad():
            t = model.encode_text(tok(list(VIEWS.values()))).float().numpy()
        np.save(p, BS.unit(t))
    return np.load(p)


def cmd_flips():
    import torch
    t0 = time.time()
    Z = load()
    FD = np.load(os.path.join(WORK, "flipdump.npz"))
    bm, te, rt, day = bank_meta()
    W, b = head()
    hh, ha = BS.read_blob(os.path.join(BS.SHIP, "head.bin"))
    tmu = ha["centre"].astype(np.float32)
    bh, ba = BS.read_blob(os.path.join(BS.SHIP, "bank-int8.bin"))
    p = bh["scoring"]
    dev = "mps"
    Bt = torch.from_numpy(ba["vectors"].astype(np.float16)).to(dev)
    st = torch.from_numpy(ba["scale"].astype(np.float16)).to(dev)
    bl = ba["labels"].astype(np.int64)
    blt = torch.from_numpy(bl).to(dev)
    blat = torch.from_numpy(bm["lat"]).float().to(dev)
    blon = torch.from_numpy(bm["lon"]).float().to(dev)
    bday = torch.from_numpy(bm["day"]).to(dev)
    s2u = Z["s2u"]
    u2s = np.full(len(Z["mapv"]), -1)
    u2s[s2u] = np.arange(len(s2u))
    C = len(Z["mapv"])
    VT = view_text()
    # v2 training data, memory-mapped; per-class rows for the classes in A
    Xtr = npz_memmap(V.DATA, "Xtr")
    ytr = npz_memmap(V.DATA, "ytr")
    tasf = npz_memmap(V.DATA, "tas")
    ytr = Z["mapv"][np.asarray(ytr)]
    order = np.argsort(ytr, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(ytr, minlength=C))]
    mu = Z["mu"].astype(np.float32)
    Wn = W / np.linalg.norm(W, axis=1, keepdims=True)
    cls_stats = {}

    def class_stats(c):
        """v2-space stats of class c's training photos: head cos distribution, view mix,
        Tasmanian vs mainland centroid offset (effect size) and Tasmanian share."""
        if c in cls_stats:
            return cls_stats[c]
        rows = np.sort(order[starts[c]:starts[c + 1]])
        if len(rows) > 3000:
            rows = np.sort(np.random.default_rng(c).choice(rows, 3000, replace=False))
        e = np.asarray(Xtr[rows], np.float32)
        x = BS.unit(BS.unit(e) - mu[None])
        hc = x @ Wn[c]
        v = (BS.unit(e) @ VT.T).argmax(1)
        tf = np.asarray(tasf[rows])
        off = np.nan
        if tf.sum() >= 5 and (~tf).sum() >= 5:
            ct, cm = x[tf].mean(0), x[~tf].mean(0)
            spread = np.sqrt(((x - x.mean(0)) ** 2).sum(1).mean())
            # sampling-noise floor of a random split of the same sizes
            noise = spread * np.sqrt(1 / tf.sum() + 1 / (~tf).sum())
            off = (np.linalg.norm(ct - cm) / spread, np.linalg.norm(ct - cm) / noise)
        cls_stats[c] = dict(x=x, hc=hc, view=np.bincount(v, minlength=len(VIEWS)) / len(v), tas_share=float(tf.mean()),
                            n=int(starts[c + 1] - starts[c]), off=off, tf=tf)
        return cls_stats[c]

    out = {}
    abl_specs = {"none": None, "geo100m": ("geo", 0.1), "geo200m": ("geo", 0.2), "geo1km": ("geo", 1.0),
                 "geo5km": ("geo", 5.0), "sameday5km": ("day", 5.0), "dup95": ("cos", 0.95), "dup90": ("cos", 0.90),
                 "sameclass200m": ("geo_y", 0.2), "sameclass1km": ("geo_y", 1.0)}
    for nm in ("A-val", "A-test"):
        y = Z[nm + "/y"]
        n = len(y)
        e = Z[nm + "/emb"].astype(np.float32)
        qs = BS.unit(BS.unit(e) - tmu[None]).astype(np.float32)
        pid = Z[nm + "/pid"]
        qday = day([te["observed_on"][rt[int(x)]] for x in pid])
        pacc = np.array([te["pacc"][rt[int(x)]] or -1 for x in pid], float)
        qlat, qlon = Z[nm + "/lat"], Z[nm + "/lon"]
        ys = np.where(y >= 0, u2s[np.maximum(y, 0)], -1)
        per = {k: np.zeros(n) for k in ("tc_max", "tc_n95", "tc_n90", "tc_mind_km", "tc_nn_km", "tc_sameday1km",
                                        "tc_n200m", "any_n200m", "tc_bank_n")}
        Lk_abl = {k: np.full((n, C), -1e4, np.float32) for k in abl_specs}
        for i in range(0, n, 256):
            sl = slice(i, min(n, i + 256))
            S_ = (torch.from_numpy(qs[sl]).half().to(dev) @ Bt.T).float() * st[None].float()
            d = geo_km(torch.from_numpy(qlat[sl]).float().to(dev)[:, None], torch.from_numpy(qlon[sl]).float().to(dev)[:, None],
                       blat[None], blon[None])
            yt_ = torch.from_numpy(ys[sl]).to(dev)
            same = blt[None] == yt_[:, None]
            dd = torch.from_numpy(qday[sl]).to(dev)
            sd = (bday[None] - dd[:, None]).abs() == 0
            big = torch.full_like(S_, -9.0)
            tcS = torch.where(same, S_, big)
            per["tc_max"][sl] = tcS.max(1).values.cpu().numpy()
            per["tc_n95"][sl] = (tcS >= 0.95).sum(1).cpu().numpy()
            per["tc_n90"][sl] = (tcS >= 0.90).sum(1).cpu().numpy()
            per["tc_bank_n"][sl] = same.sum(1).cpu().numpy()
            inf = torch.full_like(d, 1e9)
            per["tc_mind_km"][sl] = torch.where(same, d, inf).min(1).values.cpu().numpy()
            j = tcS.argmax(1)
            per["tc_nn_km"][sl] = d.gather(1, j[:, None])[:, 0].cpu().numpy()
            per["tc_sameday1km"][sl] = (same & sd & (d <= 1.0)).sum(1).cpu().numpy()
            per["tc_n200m"][sl] = (same & (d <= 0.2)).sum(1).cpu().numpy()
            per["any_n200m"][sl] = (d <= 0.2).sum(1).cpu().numpy()
            for k, spec in abl_specs.items():
                if spec is None:
                    rm = torch.zeros_like(same)
                elif spec[0] == "geo":
                    rm = d <= spec[1]
                elif spec[0] == "day":
                    rm = sd & (d <= spec[1])
                elif spec[0] == "cos":
                    rm = S_ >= spec[1]
                else:
                    rm = same & (d <= spec[1])
                Sm = torch.where(rm, torch.full_like(S_, -9.0), S_)
                v, jj = Sm.topk(p["k"], dim=1)
                v, jj = v.cpu().numpy(), jj.cpu().numpy()
                lk = BS.log_softmax(p["knn_temp"] * BS.knn_vote(v, jj, bl, len(s2u), p["k"], p["tau"]))
                tmp = np.full((sl.stop - sl.start, C), -1e4, np.float32)
                tmp[:, s2u] = lk
                Lk_abl[k][sl] = tmp
        log(f"{nm}: neighbour stats + {len(abl_specs)} bank ablations ({time.time() - t0:.0f} s)")
        Lh = head_logp(Z, nm, W, b)
        Pm = np.asarray(prior("main", nm), np.float32)
        Pb = np.asarray(prior("box", nm), np.float32)
        M = (Lh + Pm).argmax(1)
        okM = M == y
        abl = {}
        for k in abl_specs:
            F = (BS.log_softmax(Lh + 2.0 * np.maximum(Lk_abl[k], -30)) + Pb).argmax(1)
            okF = F == y
            abl[k] = {"nat_sp": score(Z, nm, F), "gained": int((~okM & okF).sum()), "lost": int((okM & ~okF).sum())}
        del Lk_abl
        F = FD[nm + "/F"]
        okF = F == y
        log("F5 reproduction (gained/lost, ablation 'none' vs decompose):", abl["none"]["gained"], abl["none"]["lost"],
            int((~okM & okF).sum()), int((okM & ~okF).sum()))
        grp = np.select([~okM & okF, okM & ~okF, okM & okF, ~okM & ~okF], ["gain", "loss", "both_right", "both_wrong"], default="x").astype("<U16")
        grp[y < 0] = "not_in_labels"
        # v2-space: head-cos percentile of the query within its class's photos, max cos to them, view share
        q2 = BS.unit(BS.unit(e) - mu[None])
        qv = (BS.unit(e) @ VT.T).argmax(1)
        hpct, mx2, vshare, off_es, off_z, tshare, ntr, mx2_tas, mx2_main = (np.full(n, np.nan) for _ in range(9))
        for r in range(n):
            if y[r] < 0 or grp[r] == "both_right" and r % 4:   # both-right: a 25 % sample is plenty
                continue
            cs = class_stats(int(y[r]))
            if cs["n"] == 0:
                continue
            hq = q2[r] @ Wn[y[r]]
            hpct[r] = (cs["hc"] < hq).mean()
            sims = cs["x"] @ q2[r]
            mx2[r] = sims.max()
            if cs["tf"].any():
                mx2_tas[r] = sims[cs["tf"]].max()
            if (~cs["tf"]).any():
                mx2_main[r] = sims[~cs["tf"]].max()
            vshare[r] = cs["view"][qv[r]]
            tshare[r], ntr[r] = cs["tas_share"], cs["n"]
            if isinstance(cs["off"], tuple):
                off_es[r], off_z[r] = cs["off"]
        log(f"{nm}: class stats for {len(cls_stats)} classes ({time.time() - t0:.0f} s)")
        out[nm] = dict(grp=grp, y=y, ablations=abl, qview=qv, pacc=pacc, hpct=hpct, mx2=mx2, mx2_tas=mx2_tas,
                       mx2_main=mx2_main, vshare=vshare, off_es=off_es, off_z=off_z, tshare=tshare, ntr=ntr, **per)
    np.savez(os.path.join(WORK, "flips.npz"), **{f"{nm}/{k}": v for nm in out for k, v in out[nm].items() if k != "ablations"})
    json.dump({nm: out[nm]["ablations"] for nm in out}, open(os.path.join(WORK, "flips_ablations.json"), "w"), indent=1)
    for nm in out:
        log(nm, json.dumps(out[nm]["ablations"]))


def knn_vote_t(v, j, labels_t, C, tau, temp=1.0, cw=None, rho=0.0, rw=None):
    """Torch kNN vote (as BS.knn_vote): softmax(sim/τ) weights over the given
    neighbours, × cw[label] (class re-weighting) × rw[row]^ρ (prototype mass),
    smoothed with a 1e-6/C floor → log p (n × C) on the device."""
    import torch
    w = torch.exp((v - v[:, :1]) / tau)
    lab = labels_t[j]
    if cw is not None:
        w = w * cw[lab]
    if rw is not None and rho:
        w = w * rw[j] ** rho
    P = torch.zeros(v.shape[0], C, device=v.device).scatter_add_(1, lab, w)
    P = P / P.sum(1, keepdim=True)
    return temp * torch.log(P + 1e-6 / C)


def cmd_mech():
    """Which property of the Tasmanian kNN term carries the gain: the label-space
    restriction to the bank's 2,675 classes, the bank's class frequencies, a
    re-ranking of close candidates — and a usable view (organ) label."""
    import torch
    t0 = time.time()
    Z = load()
    W, b = head()
    hh, ha = BS.read_blob(os.path.join(BS.SHIP, "head.bin"))
    tmu = ha["centre"].astype(np.float32)
    bh, ba = BS.read_blob(os.path.join(BS.SHIP, "bank-int8.bin"))
    p = bh["scoring"]
    dev = "mps"
    Bt = torch.from_numpy(ba["vectors"].astype(np.float16)).to(dev)
    st = torch.from_numpy(ba["scale"].astype(np.float16)).to(dev)
    bl = ba["labels"].astype(np.int64)
    blt = torch.from_numpy(bl).to(dev)
    nb = len(Z["s2u"])
    nbank = torch.bincount(blt, minlength=nb).float().clamp(min=1)
    s2u = Z["s2u"]
    C = len(Z["mapv"])
    res = {}
    for nm in ("A-val", "A-test"):
        y = Z[nm + "/y"]
        e = Z[nm + "/emb"].astype(np.float32)
        qs = torch.from_numpy(BS.unit(BS.unit(e) - tmu[None]).astype(np.float16)).to(dev)
        Lh = head_logp(Z, nm, W, b)
        Pm = np.asarray(prior("main", nm), np.float32)
        Pb = np.asarray(prior("box", nm), np.float32)
        Mlp = Lh + Pm
        okM = Mlp.argmax(1) == y
        top10 = np.argsort(-Mlp, 1)[:, :10]
        V_ = {}
        Lks = {}
        for tag, cw in (("plain", None), ("bal0.5", nbank ** -0.5), ("bal1", nbank ** -1.0)):
            out = np.full((len(e), C), -1e4, np.float32)
            for i in range(0, len(e), 512):
                S_ = (qs[i:i + 512] @ Bt.T) * st[None]
                v, j = S_.float().topk(p["k"], dim=1)
                out[i:i + 512][:, s2u] = knn_vote_t(v, j, blt, nb, p["tau"], p["knn_temp"], cw).cpu().numpy()
            Lks[tag] = out
        mask = np.full(C, -1e4, np.float32)
        mask[s2u] = 0
        V_["F5 (shipped box)"] = BS.log_softmax(Lh + 2.0 * np.maximum(Lks["plain"], -30)) + Pb
        V_["label restriction only (2,675 classes, no vote)"] = Lh + 2.0 * np.maximum(mask, -30)[None] + Pb
        V_["F5 vote ÷ n_bank^0.5"] = BS.log_softmax(Lh + 2.0 * np.maximum(Lks["bal0.5"], -30)) + Pb
        V_["F5 vote ÷ n_bank"] = BS.log_softmax(Lh + 2.0 * np.maximum(Lks["bal1"], -30)) + Pb
        # re-rank only: the kNN term only among the main path's top-10 classes
        rr = np.full_like(Lh, -1e4)
        np.put_along_axis(rr, top10, np.take_along_axis(np.maximum(Lks["plain"], -30), top10, 1), 1)
        V_["kNN only among main top-10, + main prior"] = BS.log_softmax(Lh + 2.0 * np.maximum(rr, -30)) + Pm
        V_["kNN (plain) + main prior"] = BS.log_softmax(Lh + 2.0 * np.maximum(Lks["plain"], -30)) + Pm
        V_["M"] = Mlp
        res[nm] = {}
        for k, L in V_.items():
            pr = L.argmax(1)
            ok = pr == y
            res[nm][k] = {"nat_sp": score(Z, nm, pr), "gained": int((~okM & ok).sum()), "lost": int((okM & ~ok).sum())}
            log(nm, k, res[nm][k])
        del V_, Lks, Lh, Pm, Pb, Mlp, rr
    json.dump(res, open(os.path.join(WORK, "mech.json"), "w"), indent=1)
    # views, z-scored per prompt over a 100k training-photo sample (raw prompts call ~85 % "habit")
    VT = view_text()
    Xtr = npz_memmap(V.DATA, "Xtr")
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr"))]
    rng = np.random.default_rng(0)
    smp = np.sort(rng.choice(len(ytr), 100000, replace=False))
    cs = BS.unit(np.asarray(Xtr[smp], np.float32)) @ VT.T
    m_, s_ = cs.mean(0), cs.std(0)
    vview = lambda E: ((BS.unit(E) @ VT.T - m_) / s_).argmax(1)  # noqa: E731
    order = np.argsort(ytr, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(ytr, minlength=C))]
    FL = np.load(os.path.join(WORK, "flips.npz"))
    vres = {}
    for nm in ("A-val", "A-test"):
        y, g = Z[nm + "/y"], FL[nm + "/grp"]
        qv = vview(Z[nm + "/emb"].astype(np.float32))
        share = np.full(len(y), np.nan)
        mixes = {}
        for c in np.unique(y[y >= 0]):
            rows = np.sort(order[starts[c]:starts[c + 1]])
            if not len(rows):
                continue
            if len(rows) > 1000:
                rows = np.sort(rng.choice(rows, 1000, replace=False))
            mixes[c] = np.bincount(vview(np.asarray(Xtr[rows], np.float32)), minlength=len(VIEWS)) / len(rows)
        for r in range(len(y)):
            if y[r] in mixes:
                share[r] = mixes[y[r]][qv[r]]
        vres[nm] = {}
        for k in ("gain", "loss", "both_right", "both_wrong"):
            m = g == k
            vres[nm][k] = {"n": int(m.sum()), "views": dict(zip(VIEWS, np.round(np.bincount(qv[m], minlength=5) / m.sum(), 3).tolist())),
                           "median_view_share_in_class": float(np.nanmedian(share[m])),
                           "frac_view_share_lt_0.15": float(np.nanmean(share[m] < 0.15))}
        # gain rate (net) by view share tercile: does the bank help more for under-represented views?
        okM = (g == "both_right") | (g == "loss")
        okF = (g == "both_right") | (g == "gain")
        bins = [0, 0.1, 0.2, 0.3, 1.01]
        vres[nm]["net_gain_pct_by_view_share"] = {
            f"{bins[i]}-{bins[i + 1]}": [int(((share >= bins[i]) & (share < bins[i + 1])).sum()),
                                         round(100 * float((okF.astype(int) - okM.astype(int))[(share >= bins[i]) & (share < bins[i + 1])].mean()), 2)]
            for i in range(4)}
        vres[nm]["net_gain_pct_by_view"] = {v: [int((qv == i).sum()), round(100 * float((okF.astype(int) - okM.astype(int))[qv == i].mean()), 2)]
                                            for i, v in enumerate(VIEWS)}
    json.dump(vres, open(os.path.join(WORK, "views.json"), "w"), indent=1)
    log(json.dumps(vres, indent=1), f"({time.time() - t0:.0f} s)")


# ------------------------------------------------------------ part 3 (i): national kNN / prototypes

NB_SETS = ("AU-val", "A-val", "A-test", "AU-test", "C-report")


def v2_bank_chunks(Z, chunk=262144, rows=None):
    """Centred v2-space training photos (unit(unit(x) − μ)) as fp16 MPS chunks."""
    import torch
    Xtr = npz_memmap(V.DATA, "Xtr")
    mu = torch.from_numpy(Z["mu"].astype(np.float32)).to("mps")
    n = len(Xtr) if rows is None else rows
    for a in range(0, n, chunk):
        x = torch.from_numpy(np.asarray(Xtr[a:min(n, a + chunk)], np.float32)).to("mps")
        x = torch.nn.functional.normalize(torch.nn.functional.normalize(x, dim=-1) - mu, dim=-1)
        yield a, x.half()


def cmd_natsearch():
    """Top-K neighbours of every query photo in the national bank (all 3.9M
    training photos, v2 space) + Tasmania-only / non-Tasmania top-50 for A.
    BA_MEASURE=n → time one bank chunk against n queries and extrapolate."""
    import torch
    t0 = time.time()
    Z = load()
    K = 100
    tas = np.asarray(npz_memmap(V.DATA, "tas"))
    tas_t = torch.from_numpy(tas).to("mps")
    mu = Z["mu"].astype(np.float32)
    Q = {nm: torch.from_numpy(BS.unit(BS.unit(Z[nm + "/emb"].astype(np.float32)) - mu[None]).astype(np.float16)).to("mps")
         for nm in NB_SETS}
    meas = int(os.environ.get("BA_MEASURE", 0))
    if meas:
        Q = {"AU-val": Q["AU-val"][:meas], "A-val": Q["A-val"][:meas]}
    best = {nm: [torch.full((len(q), K), -9.0, device="mps", dtype=torch.float16), torch.zeros((len(q), K), dtype=torch.int64, device="mps")]
            for nm, q in Q.items()}
    sub = {nm: {t: [torch.full((len(Q[nm]), 50), -9.0, device="mps", dtype=torch.float16), torch.zeros((len(Q[nm]), 50), dtype=torch.int64, device="mps")]
                for t in ("tas", "main")} for nm in Q if nm.startswith("A-")}

    def merge(bv, bi, v, i, k):
        cv = torch.cat([bv, v], 1)
        ci = torch.cat([bi, i], 1)
        o = cv.topk(k, dim=1)
        return o.values, ci.gather(1, o.indices)
    nrows = 262144 if meas else None
    for a, X in v2_bank_chunks(Z, rows=nrows):
        nX = len(X)
        tc = tas_t[a:a + nX]
        for nm, q in Q.items():
            for i in range(0, len(q), 512):
                S_ = q[i:i + 512] @ X.T
                v, j = S_.topk(K, dim=1)
                bv, bi = best[nm]
                best[nm][0][i:i + 512], best[nm][1][i:i + 512] = merge(bv[i:i + 512], bi[i:i + 512], v, j + a, K)
                if nm in sub:
                    for t, m in (("tas", ~tc), ("main", tc)):
                        v, j = S_.masked_fill(m[None], -9.0).topk(50, dim=1)
                        bv, bi = sub[nm][t]
                        sub[nm][t][0][i:i + 512], sub[nm][t][1][i:i + 512] = merge(bv[i:i + 512], bi[i:i + 512], v, j + a, 50)
                torch.mps.synchronize()  # else MPS queues chunks and holds ~37 GB of temporaries
        del X, S_
        torch.mps.synchronize()
        torch.mps.empty_cache()
        log(f"bank rows {a + nX:,} ({time.time() - t0:.0f} s, MPS {torch.mps.driver_allocated_memory() / 1e9:.1f} GB)")
        if meas:
            n_all = sum(len(Z[nm + "/y"]) for nm in NB_SETS)
            per = (time.time() - t0) / meas / 262144
            log(f"measure: {per * 1e9:.2f} ns per query×row → national search ≈ "
                f"{per * n_all * 3897289 / 60:.1f} min for {n_all:,} queries")
            return
    out = {}
    for nm in Q:
        out[nm + "/v"], out[nm + "/i"] = best[nm][0].cpu().numpy().astype(np.float16), best[nm][1].cpu().numpy().astype(np.int32)
        for t in sub.get(nm, {}):
            out[f"{nm}/{t}_v"], out[f"{nm}/{t}_i"] = sub[nm][t][0].cpu().numpy().astype(np.float16), sub[nm][t][1].cpu().numpy().astype(np.int32)
    np.savez(os.path.join(WORK, "natnbrs.npz"), **out)
    log(f"national neighbours → natnbrs.npz ({time.time() - t0:.0f} s)")


def cmd_geo():
    """lat, lon, day, observer of every v2 training photo (iNat ids via the
    snapshot's work.duckdb: pobs photo → observation `o`); non-iNat extras
    (ALA, Commons) from their own list when it has coordinates, else NaN."""
    import duckdb
    import pyarrow as pa
    import pyarrow.parquet as pq
    t0 = time.time()
    pid = np.asarray(npz_memmap(V.DATA, "pid"))
    src = np.asarray(npz_memmap(V.DATA, "src"))
    ex = pq.read_table(os.path.join(BS.CACHE, "extra", "extra_photos_src.parquet"),
                       columns=["source", "photo_id", "lat", "lon", "observed_on"]).to_pydict()
    exp = np.array(ex["photo_id"], np.int64)
    srt = np.argsort(exp)
    pos = np.searchsorted(exp[srt], pid)
    hit = (src == 1) & (pos < len(exp)) & (exp[srt][np.minimum(pos, len(exp) - 1)] == pid)
    inat = ~hit
    log(f"{len(pid):,} rows, {inat.sum():,} with iNat photo ids ({time.time() - t0:.0f} s)")
    con = duckdb.connect(os.path.join(BS.CACHE, "sets", "work.duckdb"), read_only=True)
    con.register("q", pa.table({"row": np.nonzero(inat)[0].astype(np.int64), "photo_id": pid[inat].astype(np.int64)}))
    r = con.sql("""select q.row, o.lat, o.lon, o.observer_id, datediff('day', DATE '2000-01-01', o.observed_on) as day
                   from q join (select distinct photo_id, uuid from pobs) p using (photo_id) join o using (uuid)""").fetchnumpy()
    n = len(pid)
    out = {"lat": np.full(n, np.nan), "lon": np.full(n, np.nan), "day": np.full(n, -99999, np.int64),
           "obs": np.full(n, -1, np.int64)}
    rows = r["row"]
    out["lat"][rows], out["lon"][rows] = r["lat"], r["lon"]
    out["day"][rows] = np.where(np.ma.getmaskarray(np.ma.asarray(r["day"])), -99999, np.ma.filled(np.ma.asarray(r["day"]), -99999))
    out["obs"][rows] = r["observer_id"]
    j = srt[pos[hit]]
    out["lat"][hit] = np.array([np.nan if ex["lat"][k] is None else ex["lat"][k] for k in j], float)
    out["lon"][hit] = np.array([np.nan if ex["lon"][k] is None else ex["lon"][k] for k in j], float)
    import datetime
    d0 = datetime.date(2000, 1, 1)
    def dd(x):
        try:
            return (datetime.date.fromisoformat(str(x)[:10]) - d0).days
        except Exception:
            return -99999
    out["day"][hit] = np.array([dd(ex["observed_on"][k]) for k in j])
    tas = np.asarray(npz_memmap(V.DATA, "tas"))
    box = BS.in_tas(np.nan_to_num(out["lat"]), np.nan_to_num(out["lon"]))
    log(f"located {np.isfinite(out['lat']).sum():,} of {n:,}; in the Tasmania box {box.sum():,} (data 'tas' flag {tas.sum():,}, "
        f"flag & box {(tas & box).sum():,}) ({time.time() - t0:.0f} s)")
    np.savez(os.path.join(WORK, "train_geo.npz"), **out)


# ------------------------------------------------------------ scoring of kNN / prototype variants

def bucket(n):
    return np.select([n == 0, n < 10, n < 50], [0, 1, 2], 3)


class Scorer:
    """Per set: head log p + main prior on the device; score(L-function) → metrics.
    Variants add ω · max(L_knn, floor) to the head log p (log_softmax), then the
    prior — as build_ship.V2Ship inside the box, but with any bank, anywhere."""

    def __init__(self, Z, dev="mps"):
        import torch
        self.Z, self.dev = Z, dev
        self.W, self.b = head()
        self.cache = {}
        n_tr = Z["n_tr"]
        C = len(n_tr)
        act = (Z["rg_au"] > 0) & (Z["mapv"] == np.arange(C))
        self.tgt = np.bincount(bucket(n_tr[act]), minlength=4) / act.sum()
        self.n_tr = n_tr
        self.C = C
        self.torch = torch

    def base(self, nm):
        import torch
        if nm not in self.cache:
            self.cache = {}  # one set on the device at a time
            Lh = head_logp(self.Z, nm, self.W, self.b)
            P = np.asarray(prior("main", nm))
            self.cache[nm] = (torch.from_numpy(Lh).half().to(self.dev), torch.from_numpy(P).to(self.dev))
            del Lh, P
        return self.cache[nm]

    def run(self, nm, knn_fn=None, om=1.0, floor=-10.0, rows_box=None, box_fn=None, chunk=2048, rerank=0):
        """knn_fn(rows) → L_knn (len(rows) × C, torch, device) or None. box_fn: same,
        but with the BOX prior and only for rows_box (the shipped Tasmania config)."""
        import torch
        Lh, P = self.base(nm)
        n = Lh.shape[0]
        top5 = np.zeros((n, 5), np.int64)
        boxm = np.zeros(n, bool) if rows_box is None else rows_box
        for a in range(0, n, chunk):
            r = np.arange(a, min(n, a + chunk))
            L = Lh[a:a + chunk].float()
            if knn_fn is not None:
                Lk = knn_fn(r)
                if rerank:  # the kNN term only among the main path's top-`rerank` classes
                    t = (L + float(os.environ.get("LAM", MAIN[3])) * P[a:a + chunk].float()).topk(rerank, dim=1).indices
                    keep = torch.zeros_like(Lk, dtype=torch.bool).scatter_(1, t, True)
                    Lk = torch.where(keep, Lk, torch.full_like(Lk, -1e4))
                L = torch.log_softmax(L + om * Lk.clamp(min=floor), 1)
            L = L + float(os.environ.get("LAM", MAIN[3])) * P[a:a + chunk].float()
            if box_fn is not None and boxm[r].any():
                rb = r[boxm[r]]
                if not hasattr(self, "P2"):
                    self.P2 = BS.V2Prior(PRIOR)
                Pb = torch.from_numpy(self.P2.log_prior(self.Z[nm + "/lat"][rb], self.Z[nm + "/lon"][rb], *BOX[:3])
                                      .astype(np.float32)).to(self.dev)
                Lb = torch.log_softmax(Lh[torch.from_numpy(rb).to(self.dev)].float() + 2.0 * box_fn(rb).clamp(min=-30.0), 1) + BOX[3] * Pb
                L[torch.from_numpy(np.nonzero(boxm[r])[0]).to(self.dev)] = Lb
            top5[r] = L.topk(5, dim=1).indices.cpu().numpy()
        return top5

    def metrics(self, nm, top5, mask=None):
        Z = self.Z
        y, w = Z[nm + "/y"], Z[nm + "/w"]
        m = (y >= 0) if mask is None else (mask & (y >= 0))
        h1 = top5[:, 0] == y
        h5 = (top5 == y[:, None]).any(1)
        cls, inv = np.unique(y[m], return_inverse=True)
        cnt = np.bincount(inv)
        p1, p5 = np.bincount(inv, h1[m]) / cnt, np.bincount(inv, h5[m]) / cnt
        bk = bucket(self.n_tr[cls])
        out = {"n": int(m.sum()), "top1_sp": float(p1.mean()), "top5_sp": float(p5.mean()),
               "top1_nat": float((h1 * w)[m].sum() / w[m].sum()),
               "b19_top1_sp": float(p1[bk == 1].mean()) if (bk == 1).any() else None}
        vmix = np.bincount(bk, minlength=4) / len(cls)
        wc = (self.tgt / np.maximum(vmix, 1e-9))[bk]
        out["top1_sp_rw"] = float((p1 * wc).sum() / wc.sum())
        return out

    def report(self, top5s):
        """top5s: {set: top5} → the report table metrics."""
        Z = self.Z
        r = {}
        if "AU-test" in top5s:
            r["AU-test"] = self.metrics("AU-test", top5s["AU-test"])
            r["AU-test-euc"] = self.metrics("AU-test", top5s["AU-test"], Z["euc"][np.maximum(Z["AU-test/y"], 0)])
        if "A-test" in top5s:
            r["A-test"] = self.metrics("A-test", top5s["A-test"])
        if "C-report" in top5s:
            sub = Z["C-report/sub"]
            r["C-main"] = self.metrics("C-report", top5s["C-report"], sub == "main")
            r["C-euc"] = self.metrics("C-report", top5s["C-report"], sub == "euc")
        return r


def nbr_knn(sc, sims, idx, labels_t, k, tau, beta, cnt_t, rw_t=None, rho=0.0, geo=None):
    """L_knn from stored neighbours (sims/idx: numpy n × K) for the given rows."""
    import torch
    C = sc.C
    cw = None if not beta else cnt_t.clamp(min=1) ** -beta

    def fn(r):
        v = torch.from_numpy(sims[r, :k].astype(np.float32)).to(sc.dev)
        j = torch.from_numpy(idx[r, :k].astype(np.int64)).to(sc.dev)
        w = torch.exp((v - v[:, :1]) / tau)
        lab = labels_t[j]
        if cw is not None:
            w = w * cw[lab]
        if rw_t is not None and rho:
            w = w * rw_t[j] ** rho
        if geo is not None:
            w = w * geo(r, j)
        Pk = torch.zeros(len(r), C, device=sc.dev).scatter_add_(1, lab, w)
        return torch.log(Pk / Pk.sum(1, keepdim=True) + 1e-6 / C)
    return fn


def tune(sc, nb, labels_t, cnt_t, extra=None, rw_t=None, tag=""):
    """Stage A (k, τ, β; ω 1, floor −10) then B (ω, floor) on AU-val (re-weighted
    per species) + A-val (natural); J = mean of the two gains vs no kNN."""
    base = {nm: sc.metrics(nm, sc.run(nm)) for nm in ("AU-val", "A-val")}
    J0 = 0.5 * (base["AU-val"]["top1_sp_rw"] + base["A-val"]["top1_nat"])
    rows = []

    def ev(prm):
        res = {}
        for nm in ("AU-val", "A-val"):
            fn = nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], labels_t, prm["k"], prm["tau"], prm["beta"], cnt_t,
                         rw_t, prm.get("rho", 0.0))
            res[nm] = sc.metrics(nm, sc.run(nm, fn, prm["om"], prm["floor"]))
        J = 0.5 * (res["AU-val"]["top1_sp_rw"] + res["A-val"]["top1_nat"])
        rows.append({**prm, "J": J, "AU-val_rw": res["AU-val"]["top1_sp_rw"], "AU-val_sp": res["AU-val"]["top1_sp"],
                     "A-val_nat": res["A-val"]["top1_nat"], "A-val_sp": res["A-val"]["top1_sp"]})
        return J
    Kmax = nb["AU-val/v"].shape[1]
    gridA = [{"k": k, "tau": t, "beta": b_, "om": 1.0, "floor": -10.0, **(extra or {})}
             for k in (10, 25, 50, 100) if k <= Kmax for t in (0.02, 0.05, 0.1) for b_ in (0.0, 0.5, 1.0)]
    for prm in gridA:
        ev(prm)
    bA = max(rows, key=lambda r: r["J"])
    for om in (0.25, 0.5, 1.0, 2.0, 3.0):
        for fl in (-3.0, -10.0, -30.0):
            ev({**{k: bA[k] for k in ("k", "tau", "beta")}, "om": om, "floor": fl, **(extra or {})})
    best = max(rows, key=lambda r: r["J"])
    log(f"{tag} base J {J0:.4f} (AU-val rw {base['AU-val']['top1_sp_rw']:.4f}, A-val nat {base['A-val']['top1_nat']:.4f}) "
        f"→ best {best}")
    return best, rows, base


def cmd_natscore():
    import torch
    t0 = time.time()
    Z = load()
    sc = Scorer(Z)
    nb = dict(np.load(os.path.join(WORK, "natnbrs.npz")))
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    labels_t = torch.from_numpy(ytr).to(sc.dev)
    cnt_t = torch.bincount(labels_t, minlength=sc.C).float()
    out = {}
    best, rows, base = tune(sc, nb, labels_t, cnt_t, tag="national kNN")
    out["national"] = {"best": best, "grid": rows, "val_base": base}
    # same parameters, Tasmania-only / non-Tasmania v2 banks, on A-val (diagnostic)
    for t in ("tas", "main"):
        fn = nbr_knn(sc, nb[f"A-val/{t}_v"], nb[f"A-val/{t}_i"], labels_t, min(best["k"], 50), best["tau"], best["beta"], cnt_t)
        out[f"A-val {t}-only v2 bank"] = sc.metrics("A-val", sc.run("A-val", fn, best["om"], best["floor"]))
        log(t, out[f"A-val {t}-only v2 bank"])
    json.dump(out, open(os.path.join(WORK, "natscore_val.json"), "w"), indent=1)
    log(f"({time.time() - t0:.0f} s)")


def spherical_kmeans_np(X, m, rng, iters=15, fit_cap=2000):
    """k-means on unit rows (cosine), k-means++ init, fit on ≤ fit_cap rows,
    all rows assigned for the member counts → (centroids unit, counts)."""
    n = len(X)
    if n <= m:
        return X.copy(), np.ones(n, np.int64)
    F = X if n <= fit_cap else X[rng.choice(n, fit_cap, replace=False)]
    c = [F[rng.integers(len(F))]]
    d = 1 - F @ c[0]
    for _ in range(1, m):
        pr = np.maximum(d, 0) ** 2
        c.append(F[rng.choice(len(F), p=pr / pr.sum()) if pr.sum() > 0 else rng.integers(len(F))])
        d = np.minimum(d, 1 - F @ c[-1])
    Cn = np.stack(c)
    for _ in range(iters):
        a = (F @ Cn.T).argmax(1)
        S = np.zeros_like(Cn)
        np.add.at(S, a, F)
        nz = np.linalg.norm(S, axis=1)
        Cn = np.where(nz[:, None] > 0, S / np.maximum(nz, 1e-9)[:, None], Cn)
    a = (X @ Cn.T).argmax(1)
    cnt = np.bincount(a, minlength=m)
    return Cn[cnt > 0], cnt[cnt > 0]


def cmd_protos():
    """Per-class spherical k-means prototypes (K = argv[2]) of the v2-space training
    photos → WORK/protoK.npz (vectors fp16, labels, counts) + their top-100
    neighbours for every set (natnbrs layout) → WORK/protoK_nbrs.npz."""
    import torch
    K = int(sys.argv[2])
    t0 = time.time()
    Z = load()
    pth = os.path.join(WORK, f"proto{K}.npz")
    if not os.path.exists(pth):
        Xtr = npz_memmap(V.DATA, "Xtr")
        ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
        order = np.argsort(ytr, kind="stable")
        starts = np.r_[0, np.cumsum(np.bincount(ytr, minlength=len(Z["mapv"])))]
        mu = Z["mu"].astype(np.float32)
        rng = np.random.default_rng(K)
        vecs, labs, cnts = [], [], []
        X_all = np.asarray(Xtr)  # 8 GB fp16 in RAM: per-class gathers from the memmap are random reads
        log(f"loaded Xtr ({time.time() - t0:.0f} s)")
        for ci, c in enumerate(np.nonzero(np.diff(starts))[0]):
            if ci % 3000 == 0:
                log(f"  class {ci:,} ({time.time() - t0:.0f} s)")
            rows = order[starts[c]:starts[c + 1]]
            X = BS.unit(BS.unit(X_all[rows].astype(np.float32)) - mu[None]).astype(np.float32)
            cen, cnt = spherical_kmeans_np(X, K, rng)
            vecs.append(cen.astype(np.float16)), labs.append(np.full(len(cen), c, np.int32)), cnts.append(cnt)
        del X_all
        np.savez(pth, vectors=np.concatenate(vecs), labels=np.concatenate(labs), counts=np.concatenate(cnts))
        log(f"proto{K}: {sum(len(v) for v in vecs):,} rows ({time.time() - t0:.0f} s)")
    P = np.load(pth)
    B = torch.from_numpy(P["vectors"]).to("mps")
    out = {}
    for nm in NB_SETS:
        q = torch.from_numpy(BS.unit(BS.unit(Z[nm + "/emb"].astype(np.float32)) - Z["mu"][None]).astype(np.float16)).to("mps")
        vs, js = [], []
        for i in range(0, len(q), 512):
            v, j = (q[i:i + 512] @ B.T).topk(100, dim=1)
            vs.append(v.cpu().numpy()), js.append(j.cpu().numpy().astype(np.int32))
            torch.mps.synchronize()
        out[nm + "/v"], out[nm + "/i"] = np.concatenate(vs), np.concatenate(js)
    np.savez(os.path.join(WORK, f"proto{K}_nbrs.npz"), **out)
    log(f"proto{K} neighbours ({time.time() - t0:.0f} s)")


def box_knn_rows(Z, nm):
    """Rows of set nm inside the Tasmania box and the shipped Tasmanian-bank L_knn for
    them (U space) → (mask, fn(rows) → torch)."""
    import torch
    box = BS.in_tas(Z[nm + "/lat"], Z[nm + "/lon"])
    if not box.any():
        return box, None
    idx = np.nonzero(box)[0]
    sub = {k: v for k, v in Z.items()}
    sub[nm + "/emb"] = Z[nm + "/emb"][idx]
    Lk, _, _, _ = tas_knn(sub, nm)
    pos = np.full(len(box), -1)
    pos[idx] = np.arange(len(idx))
    Lk_t = torch.from_numpy(Lk).half()

    def fn(rows):
        return Lk_t[torch.from_numpy(pos[rows])].float().to("mps")
    return box, fn


def bank_bytes(rows, weights=False):
    return rows * (1024 + 2 + 2 + (2 if weights else 0))


def time_scan(rows, reps=20):
    """M4 CPU proxy for the on-device scan: one query against an int8 bank
    (dequantised per row-block of 8,192 rows, as a streaming implementation would)."""
    rng = np.random.default_rng(0)
    B = rng.integers(-127, 128, (min(rows, 65536), 1024), dtype=np.int8)
    q = rng.standard_normal(1024).astype(np.float32)
    t = time.time()
    for _ in range(reps):
        for a in range(0, len(B), 8192):
            _ = B[a:a + 8192].astype(np.float32) @ q
    return (time.time() - t) / reps * rows / len(B)


def strict_mask(Z, nm, km=0.2):
    """True where NO training photo of the photo's class (v2 data, 3.9M, located)
    lies within km of it (a stricter, place-disjoint split)."""
    f = os.path.join(WORK, f"strict-{nm}-{km}.npy")
    if os.path.exists(f):
        return np.load(f)
    G = np.load(os.path.join(WORK, "train_geo.npz"))
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    order = np.argsort(ytr, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(ytr, minlength=len(Z["mapv"])))]
    y, lat, lon = Z[nm + "/y"], Z[nm + "/lat"], Z[nm + "/lon"]
    ok = np.ones(len(y), bool)
    for c in np.unique(y[y >= 0]):
        rows = order[starts[c]:starts[c + 1]]
        la, lo = G["lat"][rows], G["lon"][rows]
        g = np.isfinite(la)
        la, lo = la[g], lo[g]
        for r in np.nonzero(y == c)[0]:
            kx = 111.32 * np.cos(np.radians(lat[r]))
            d = np.sqrt(((lo - lon[r]) * kx) ** 2 + ((la - lat[r]) * 110.57) ** 2)
            ok[r] = not (d <= km).any()
    np.save(f, ok)
    return ok


def cmd_report():
    """Every variant on the report sets (tests read once per final variant) + val."""
    import torch
    t0 = time.time()
    Z = load()
    sc = Scorer(Z)
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    lab_nat = torch.from_numpy(ytr).to(sc.dev)
    cnt_nat = torch.bincount(lab_nat, minlength=sc.C).float()
    variants = {}
    nv = json.load(open(os.path.join(WORK, "natscore_val.json")))
    variants["M main path everywhere (no bank)"] = dict(kind="none")
    variants["shipped: M + Tasmanian bank & box prior inside the box"] = dict(kind="box")
    variants["national kNN, all 3.9M photos (everywhere)"] = dict(kind="nbrs", file="natnbrs.npz", prm=nv["national"]["best"])
    for K in (4, 8, 16):
        f = os.path.join(WORK, f"protoscore{K}_val.json")
        if os.path.exists(f):
            variants[f"prototypes K={K} (everywhere)"] = dict(kind="nbrs", file=f"proto{K}_nbrs.npz", prm=json.load(open(f))["best"], K=K)
    f8 = os.path.join(WORK, "protoscore8_val.json")
    if os.path.exists(f8):
        variants["prototypes K=8 outside the box + shipped Tasmanian bank inside"] = dict(
            kind="nbrs", file="proto8_nbrs.npz", prm=json.load(open(f8))["best"], K=8, box=True)
    for f in sorted(os.listdir(os.path.join(WORK, "heads"))) if os.path.isdir(os.path.join(WORK, "heads")) else []:
        variants[f"head {f[:-4]} (no bank)"] = dict(kind="head", path=os.path.join(WORK, "heads", f))
    only = os.environ.get("BA_ONLY")
    res = json.load(open(os.path.join(WORK, "report.json"))) if os.path.exists(os.path.join(WORK, "report.json")) else {}
    for name, v in variants.items():
        if (only and only not in name) or (name in res and not only):
            continue
        if v["kind"] == "head":
            os.environ["HEAD"] = v["path"]
        else:
            os.environ.pop("HEAD", None)
        sc.cache = {}
        nbrs = np.load(os.path.join(WORK, v["file"])) if v["kind"] == "nbrs" else None
        if v["kind"] == "nbrs" and "K" in v:
            P = np.load(os.path.join(WORK, f"proto{v['K']}.npz"))
            lab_t = torch.from_numpy(P["labels"].astype(np.int64)).to(sc.dev)
            cnt_t = torch.bincount(lab_t, weights=torch.from_numpy(P["counts"].astype(np.float32)).to(sc.dev), minlength=sc.C)
            rw_t = torch.from_numpy(P["counts"].astype(np.float32)).to(sc.dev)
        else:
            lab_t, cnt_t, rw_t = lab_nat, cnt_nat, None
        top5s, val = {}, {}
        for nm in ("AU-val", "A-val", "AU-test", "A-test", "C-report"):
            kw = {}
            if v["kind"] == "box":
                box, fn = box_knn_rows(Z, nm)
                kw = dict(rows_box=box, box_fn=fn)
            elif v["kind"] == "nbrs":
                if v.get("box"):
                    box, fn = box_knn_rows(Z, nm)
                    kw = dict(rows_box=box, box_fn=fn)
                p_ = v["prm"]
                kw.update(knn_fn=nbr_knn(sc, nbrs[nm + "/v"], nbrs[nm + "/i"], lab_t, p_["k"], p_["tau"], p_["beta"], cnt_t,
                                         rw_t, p_.get("rho", 0.0)), om=p_["om"], floor=p_["floor"])
            t5 = sc.run(nm, **kw)
            if nm.endswith("val"):
                val[nm] = sc.metrics(nm, t5)
            else:
                top5s[nm] = t5
        r = sc.report(top5s)
        ntr = sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
        r["AU-test 1-9"] = sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
        for km in (0.2, 1.0):
            r[f"A-test strict {km} km"] = sc.metrics("A-test", top5s["A-test"], strict_mask(Z, "A-test", km))
        r["val"] = val
        if v["kind"] == "nbrs":
            rows = len(np.load(os.path.join(WORK, f"proto{v['K']}.npz"))["labels"]) if "K" in v else len(ytr)
            r["bank_rows"], r["bank_MB"] = rows, bank_bytes(rows, "K" in v) / 1e6 + (bank_bytes(82649) / 1e6 if v.get("box") else 0)
            r["scan_ms_per_photo_M4cpu"] = 1e3 * time_scan(rows)
        elif v["kind"] == "box":
            r["bank_rows"], r["bank_MB"], r["scan_ms_per_photo_M4cpu"] = 82649, bank_bytes(82649) / 1e6, 1e3 * time_scan(82649)
        res[name] = r
        log(name, json.dumps({k: (round(x["top1_sp"] * 100, 2), round(x["top1_nat"] * 100, 2)) for k, x in r.items()
                              if isinstance(x, dict) and "top1_sp" in x}), f"({time.time() - t0:.0f} s)")
        json.dump(res, open(os.path.join(WORK, "report.json"), "w"), indent=1)


def cmd_protoscore():
    """Tune the prototype-bank kNN (K = argv[2]) on val, as natscore (+ ρ: vote ×
    member count^ρ) → WORK/protoscoreK_val.json."""
    import torch
    K = int(sys.argv[2])
    Z = load()
    sc = Scorer(Z)
    P = np.load(os.path.join(WORK, f"proto{K}.npz"))
    nb = dict(np.load(os.path.join(WORK, f"proto{K}_nbrs.npz")))
    lab_t = torch.from_numpy(P["labels"].astype(np.int64)).to(sc.dev)
    rw_t = torch.from_numpy(P["counts"].astype(np.float32)).to(sc.dev)
    cnt_t = torch.zeros(sc.C, device=sc.dev).index_add_(0, lab_t, rw_t)
    out = {}
    for rho in (0.0, 0.5, 1.0):
        best, rows, base = tune(sc, nb, lab_t, cnt_t, extra={"rho": rho}, rw_t=rw_t, tag=f"proto{K} ρ{rho}")
        out[f"rho{rho}"] = {"best": best, "grid": rows}
    out["best"] = max((v["best"] for v in out.values()), key=lambda r: r["J"])
    out["val_base"] = base
    json.dump(out, open(os.path.join(WORK, f"protoscore{K}_val.json"), "w"), indent=1)
    log("chosen", out["best"])


def cmd_geoknn():
    """(iv) region-aware check: national kNN votes × (γ + exp(−d²/2σ²)), d = km
    between the query and the neighbour's training photo (unknown location → γ + 0)."""
    import torch
    Z = load()
    sc = Scorer(Z)
    nb = dict(np.load(os.path.join(WORK, "natnbrs.npz")))
    G = np.load(os.path.join(WORK, "train_geo.npz"))
    glat = torch.from_numpy(np.nan_to_num(G["lat"], nan=0.0)).float().to(sc.dev)
    glon = torch.from_numpy(np.nan_to_num(G["lon"], nan=0.0)).float().to(sc.dev)
    gok = torch.from_numpy(np.isfinite(G["lat"])).to(sc.dev)
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    lab = torch.from_numpy(ytr).to(sc.dev)
    cnt = torch.bincount(lab, minlength=sc.C).float()
    best = json.load(open(os.path.join(WORK, "natscore_val.json")))["national"]["best"]
    out = {}
    for sig in (None, 10.0, 50.0, 200.0):
        for gam in ((0.0,) if sig is None else (0.1, 1.0)):
            for om in (best["om"], 1.0):
                res = {}
                for nm in ("AU-val", "A-val"):
                    qlat = torch.from_numpy(Z[nm + "/lat"]).float().to(sc.dev)
                    qlon = torch.from_numpy(Z[nm + "/lon"]).float().to(sc.dev)

                    def geo(r, j, qlat=qlat, qlon=qlon):
                        rt = torch.from_numpy(r).to(sc.dev)
                        d = geo_km(qlat[rt][:, None], qlon[rt][:, None], glat[j], glon[j])
                        return gam + torch.where(gok[j], torch.exp(-d ** 2 / (2 * sig ** 2)), torch.zeros_like(d))
                    fn = nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], lab, best["k"], best["tau"], best["beta"], cnt,
                                 geo=None if sig is None else geo)
                    res[nm] = sc.metrics(nm, sc.run(nm, fn, om, best["floor"]))
                key = f"sigma {sig} gamma {gam} om {om}"
                out[key] = {"AU-val_rw": res["AU-val"]["top1_sp_rw"], "AU-val_sp": res["AU-val"]["top1_sp"],
                            "A-val_nat": res["A-val"]["top1_nat"], "J": 0.5 * (res["AU-val"]["top1_sp_rw"] + res["A-val"]["top1_nat"])}
                log(key, {k: round(v, 4) for k, v in out[key].items()})
    json.dump(out, open(os.path.join(WORK, "geoknn_val.json"), "w"), indent=1)


# ------------------------------------------------------------ uniform-bank follow-up

def build_bank(name, quota, seed=0, iters=15):
    """Per-class diversity pick (spherical k-means centres, member counts as
    weights) with quota(n_c) rows per class, v2 space → WORK/<name>.npz."""
    t0 = time.time()
    Z = load()
    pth = os.path.join(WORK, name + ".npz")
    if os.path.exists(pth):
        return
    Xtr = npz_memmap(V.DATA, "Xtr")
    ytr = Z["mapv"][np.asarray(npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    order = np.argsort(ytr, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(ytr, minlength=len(Z["mapv"])))]
    mu = Z["mu"].astype(np.float32)
    rng = np.random.default_rng(seed)
    vecs, labs, cnts = [], [], []
    for c in np.nonzero(np.diff(starts))[0]:
        n = starts[c + 1] - starts[c]
        m = int(quota(n))
        rows = order[starts[c]:starts[c + 1]]
        X = BS.unit(BS.unit(np.asarray(Xtr[np.sort(rows)], np.float32)) - mu[None]).astype(np.float32)
        cen, cnt = spherical_kmeans_np(X, m, rng, iters=iters)
        vecs.append(cen.astype(np.float16)), labs.append(np.full(len(cen), c, np.int32)), cnts.append(cnt)
    np.savez(pth, vectors=np.concatenate(vecs), labels=np.concatenate(labs), counts=np.concatenate(cnts))
    log(f"{name}: {sum(len(v) for v in vecs):,} rows ({time.time() - t0:.0f} s)")


def search_bank(name):
    import torch
    out_p = os.path.join(WORK, name + "_nbrs.npz")
    if os.path.exists(out_p):
        return
    Z = load()
    P = np.load(os.path.join(WORK, name + ".npz"))
    B = torch.from_numpy(P["vectors"]).to("mps")
    out = {}
    for nm in NB_SETS:
        q = torch.from_numpy(BS.unit(BS.unit(Z[nm + "/emb"].astype(np.float32)) - Z["mu"][None]).astype(np.float16)).to("mps")
        vs, js = [], []
        for i in range(0, len(q), 512):
            v, j = (q[i:i + 512] @ B.T).topk(100, dim=1)
            vs.append(v.cpu().numpy()), js.append(j.cpu().numpy().astype(np.int32))
            torch.mps.synchronize()
        out[nm + "/v"], out[nm + "/i"] = np.concatenate(vs), np.concatenate(js)
    np.savez(out_p, **out)


def tas_bank_everywhere():
    """The shipped 82.6k Tasmanian bank (v1 query space) searched for EVERY set →
    tasbank.npz (labels in U space, counts 1) + tasbank_nbrs.npz (top-50)."""
    import torch
    if os.path.exists(os.path.join(WORK, "tasbank_nbrs.npz")):
        return
    Z = load()
    hh, ha = BS.read_blob(os.path.join(BS.SHIP, "head.bin"))
    tmu = ha["centre"].astype(np.float32)
    bh, ba = BS.read_blob(os.path.join(BS.SHIP, "bank-int8.bin"))
    Bt = torch.from_numpy(ba["vectors"].astype(np.float16)).to("mps")
    st = torch.from_numpy(ba["scale"].astype(np.float16)).to("mps")
    lab = Z["s2u"][ba["labels"].astype(np.int64)]
    np.savez(os.path.join(WORK, "tasbank.npz"), labels=lab.astype(np.int32), counts=np.ones(len(lab), np.int64))
    out = {}
    for nm in NB_SETS:
        qs = torch.from_numpy(BS.unit(BS.unit(Z[nm + "/emb"].astype(np.float32)) - tmu[None]).astype(np.float16)).to("mps")
        vs, js = [], []
        for i in range(0, len(qs), 512):
            v, j = ((qs[i:i + 512] @ Bt.T) * st[None]).float().topk(50, dim=1)
            vs.append(v.cpu().numpy().astype(np.float16)), js.append(j.cpu().numpy().astype(np.int32))
            torch.mps.synchronize()
        out[nm + "/v"], out[nm + "/i"] = np.concatenate(vs), np.concatenate(js)
    np.savez(os.path.join(WORK, "tasbank_nbrs.npz"), **out)


def cmd_uniform():
    """One uniform rule (no box): bank kNN everywhere, count-balanced votes, kNN
    term only among the main path's top-10; ω (and β, rerank on/off, τ) chosen on
    J = mean(AU-val re-weighted per species, A-val natural); tests read once."""
    import torch
    t0 = time.time()
    if not os.environ.get("BA_BUILD_ONLY"):
        tas_bank_everywhere()
    Z = load()
    n_tr = Z["n_tr"]
    nz = n_tr[n_tr > 0]

    def quota_for(total, cap=1000):
        # rows ∝ min(n, cap), ≥ 1, ≤ n; scale f found by bisection to hit `total`
        lo, hi = 1e-5, 1.0
        for _ in range(50):
            f = (lo + hi) / 2
            tot = np.minimum(nz, np.maximum(1, np.round(f * np.minimum(nz, cap)))).sum()
            lo, hi = (f, hi) if tot < total else (lo, f)
        f = (lo + hi) / 2
        return lambda n: min(n, max(1, round(f * min(n, cap))))
    specs = {"strat85k": (quota_for(82649), 0), "strat170k": (quota_for(2 * 82649), 0),
             "proto4s1": (lambda n: 4, 1)}  # K=4 prototypes, second k-means seed
    only = os.environ.get("BA_BUILD_ONLY")
    for k_, (q_, sd) in specs.items():
        if not only or only == k_:
            build_bank(k_, q_, seed=sd)
    if only:
        return
    for nmb in ("strat85k", "strat170k", "proto4s1"):
        search_bank(nmb)
    log(f"banks ready ({time.time() - t0:.0f} s)")
    sc = Scorer(Z)
    res = json.load(open(os.path.join(WORK, "uniform.json"))) if os.path.exists(os.path.join(WORK, "uniform.json")) else {}
    for bank in ("tasbank", "strat85k", "strat170k", "proto4s1"):
        if bank in res:
            continue
        P = np.load(os.path.join(WORK, bank + ".npz"))
        nb = dict(np.load(os.path.join(WORK, bank + "_nbrs.npz")))
        lab_t = torch.from_numpy(P["labels"].astype(np.int64)).to(sc.dev)
        rw_t = torch.from_numpy(P["counts"].astype(np.float32)).to(sc.dev)
        cnt_t = torch.zeros(sc.C, device=sc.dev).index_add_(0, lab_t, rw_t)
        rows_g = []
        if bank == "proto4s1":  # seed check: the seed-0 K=4 parameters, no re-tuning
            grid = [dict(json.load(open(os.path.join(WORK, "protoscore4_val.json")))["best"], rerank=0)]
        else:
            k = nb["AU-val/v"].shape[1]
            grid = [{"k": min(50, k), "tau": t, "beta": b_, "om": om, "floor": -30.0, "rerank": rr, "rho": 0.0}
                    for rr in (10, 0) for b_ in (1.0, 0.5) for t in (0.05, 0.1) for om in (0.25, 0.5, 1.0, 2.0, 3.0)]
        for prm in grid:
            r = {}
            for nm in ("AU-val", "A-val"):
                fn = nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], lab_t, prm["k"], prm["tau"], prm["beta"], cnt_t, rw_t,
                             prm.get("rho", 0.0))
                r[nm] = sc.metrics(nm, sc.run(nm, fn, prm["om"], prm["floor"], rerank=prm["rerank"]))
            rows_g.append({**prm, "J": 0.5 * (r["AU-val"]["top1_sp_rw"] + r["A-val"]["top1_nat"]),
                           "AU-val_rw": r["AU-val"]["top1_sp_rw"], "A-val_nat": r["A-val"]["top1_nat"]})
        best = max(rows_g, key=lambda x: x["J"])
        log(bank, "chosen", best, f"({time.time() - t0:.0f} s)")
        top5s = {}
        for nm in ("AU-test", "A-test", "C-report"):
            fn = nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], lab_t, best["k"], best["tau"], best["beta"], cnt_t, rw_t,
                         best.get("rho", 0.0))
            top5s[nm] = sc.run(nm, fn, best["om"], best["floor"], rerank=best["rerank"])
        rep = sc.report(top5s)
        ntr = sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
        rep["AU-test 1-9"] = sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
        rep["A-test strict 0.2 km"] = sc.metrics("A-test", top5s["A-test"], strict_mask(Z, "A-test", 0.2))
        rows = len(P["labels"])
        rep["bank_rows"], rep["bank_MB"] = rows, bank_bytes(rows, bank != "tasbank") / 1e6
        res[bank] = {"best": best, "grid": rows_g, "report": rep}
        log(bank, json.dumps({k: (round(x["top1_sp"] * 100, 2), round(x["top1_nat"] * 100, 2)) for k, x in rep.items()
                              if isinstance(x, dict)}), rows, f"({time.time() - t0:.0f} s)")
        json.dump(res, open(os.path.join(WORK, "uniform.json"), "w"), indent=1)


if __name__ == "__main__":
    {"cache": cmd_cache, "decompose": cmd_decompose, "flips": cmd_flips, "mech": cmd_mech, "natsearch": cmd_natsearch, "geo": cmd_geo, "natscore": cmd_natscore, "protos": cmd_protos, "report": cmd_report, "protoscore": cmd_protoscore, "geoknn": cmd_geoknn, "uniform": cmd_uniform}[sys.argv[1]]()

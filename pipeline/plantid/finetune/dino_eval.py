#!/usr/bin/env python3
"""DINOv3 second-encoder pilot — Mac side.

  weights   download the gated DINOv3 checkpoints with the HF token from
            ~/.config/izzymap/hf.env (never printed or sent to a pod), convert to
            fp16 safetensors → cache/plantid/finetune/dino/weights/<key>/
  eval      heads on every arm's embeddings, test once → finetune/dino/eval.{json,md}

Arms (all on the fine-tune pilot's subset: 969 classes, its train / AU-val +
A-val / AU-test + A-test rows; ft_eval.py's protocol and head recipe —
train_v2.train: balanced softmax τ 1.5 with log π from the data, class-balanced
sampling K 50, decay to the init 0.01, Tasmanian photos × 3, 12-epoch cosine,
per-species val early stopping, τ-norm 0.5, head seeds 0 / 1; production
location prior λ 1):
  bioclip            the production embeddings, text init (= ft_eval "frozen")
  <v>                a DINOv3 variant alone (CLS ⊕ mean patch token, each
                     centred + normalised, then joined); init = the class-mean
                     prototype of the centred training photos (no text model)
  bioclip+<v>@w      [c(BioCLIP), w · c(DINOv3)] / √(1 + w²); init = [text row,
                     w · prototype] / √(1 + w²); w chosen on val per variant
Metrics per species (every species weighs the same) and natural mix; eucalypts,
classes with 1–9 training photos, genus; kNN-10; paired class-cluster bootstrap
vs bioclip.

Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'numpy<2.3' --with pyarrow
     --with safetensors --with huggingface_hub python3 -I pipeline/plantid/finetune/dino_eval.py …
"""
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.dirname(HERE)
sys.path.insert(0, P)
sys.path.insert(0, HERE)
import train_v2 as V  # noqa: E402

CACHE = os.path.normpath(os.path.join(P, "..", "cache", "plantid"))
FT = os.path.join(CACHE, "finetune")
PLAN = os.path.join(FT, "plan")
DINO = os.path.join(FT, "dino")
BA = os.path.join(V.V2, "bank_analysis")
DEV = "mps"
REPOS = {"vitl": "facebook/dinov3-vitl16-pretrain-lvd1689m", "vith": "facebook/dinov3-vith16plus-pretrain-lvd1689m"}
VARIANTS = ("dinol", "dinolhr", "dinoh")
WEIGHTS = (0.5, 0.75, 1.0)


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True).clip(1e-9)


def cmd_weights():
    import torch
    from huggingface_hub import hf_hub_download
    from safetensors.torch import load_file, save_file
    tok = None
    for line in open(os.path.expanduser("~/.config/izzymap/hf.env")):
        if line.startswith("HF_TOKEN="):
            tok = line.split("=", 1)[1].strip().strip('"')
    for k, repo in REPOS.items():
        od = os.path.join(DINO, "weights", k)
        os.makedirs(od, exist_ok=True)
        cfg = hf_hub_download(repo, "config.json", token=tok)
        st = hf_hub_download(repo, "model.safetensors", token=tok)
        sd = {n: (t.half() if t.is_floating_point() else t) for n, t in load_file(st).items()}
        save_file(sd, os.path.join(od, "model.safetensors"))
        open(os.path.join(od, "config.json"), "w").write(open(cfg).read())
        n = sum(t.numel() for t in sd.values())
        print(f"{k}: {repo} → {od} ({n / 1e6:.0f} M params, "
              f"{os.path.getsize(os.path.join(od, 'model.safetensors')) / 1e9:.2f} GB fp16)")
    del torch


def per_species(hit, y):
    _, inv = np.unique(y, return_inverse=True)
    return np.bincount(inv, hit) / np.bincount(inv)


def load_dino(name, row_of, n):
    d = os.path.join(FT, "runs", "dino")
    E, have = None, np.zeros(n, bool)
    for f in sorted(glob.glob(os.path.join(d, f"{name}-*.npz"))):
        z = np.load(f)
        r = row_of(z["photo_id"])
        x = np.concatenate([unit(z["cls"].astype(np.float32)), unit(z["pmean"].astype(np.float32))], 1)
        if E is None:
            E = np.zeros((n, x.shape[1]), np.float32)
        E[r] = x
        have[r] = z["ok"]
    return E, have


def cmd_eval():
    import pyarrow.parquet as pq
    import torch
    import ft_eval as FE
    T = pq.read_table(os.path.join(PLAN, "todo.parquet")).to_pydict()
    role, sset = np.array(T["role"]), np.array(T["set"])
    ys = np.array(T["ys"], np.int64)
    pid, w, tas = np.array(T["photo_id"], np.int64), np.array(T["w"]), np.array(T["tas"], bool)
    n = len(role)
    row_of = np.vectorize(dict(zip(pid.tolist(), range(n))).__getitem__, otypes=[np.int64])
    FE.ROW_OF = row_of
    FE.FROZEN_SRC = os.environ.get("FROZEN_SRC", "lora")
    cls = json.load(open(os.path.join(PLAN, "classes.json")))
    C = len(cls)
    cu = np.array([c["u"] for c in cls])
    euc = np.array([c["euc"] for c in cls])
    gid = np.unique([c["genus"] for c in cls], return_inverse=True)[1]
    bkt = np.array([c["bucket"] for c in cls])
    Tsub = np.load(os.path.join(PLAN, "text_sub.npy")).astype(np.float32)
    tmean = np.load(os.path.join(PLAN, "tmean.npy")).astype(np.float32)
    # BioCLIP: production training embeddings + the pod's frozen eval embeddings (as ft_eval)
    Eb, hb = FE.load_run("frozen", n)
    D = np.load(os.path.join(V.V2, "data-final.npz"))
    dpid = D["pid"]
    order = np.argsort(dpid)
    tr_all = np.nonzero(role == "train")[0]
    j = order[np.searchsorted(dpid[order], pid[tr_all])]
    assert (dpid[j] == pid[tr_all]).all()
    Eb[tr_all] = D["Xtr"][j]
    hb[tr_all] = True
    Eb = Eb.astype(np.float32)
    enc = {"bioclip": (Eb, hb)}
    for v in VARIANTS:
        if glob.glob(os.path.join(FT, "runs", "dino", f"{v}-*.npz")):
            enc[v] = load_dino(v, row_of, n)
    okall = np.logical_and.reduce([h for _, h in enc.values()])
    trc = np.nonzero((role == "train") & okall)[0]
    vau = np.nonzero((sset == "AU-val") & okall)[0]
    vaa = np.nonzero((sset == "A-val") & okall)[0]
    test = np.nonzero((role == "test") & okall)[0]
    val = np.r_[vau, vaa]
    # production prior rows (λ 1), restricted to the subset's classes
    Z = np.load(os.path.join(BA, "sets.npz"), allow_pickle=True)

    def prior_rows(rows):
        out = np.zeros((len(rows), C), np.float32)
        for nm, src in (("AU-test", "AU-test"), ("A-test", "A-test"), ("AU-val", "AU-val"), ("A-val", "A-val")):
            m = sset[rows] == nm
            if not m.any():
                continue
            zp = Z[src + "/pid"] if src + "/pid" in Z else None
            if zp is None:
                continue
            pos = {int(p): i for i, p in enumerate(zp)}
            pr = np.array([pos.get(int(p), -1) for p in pid[rows[m]]])
            assert (pr >= 0).all(), nm
            Pm = np.load(os.path.join(BA, f"prior-main-{src}.npy"), mmap_mode="r")
            out[m] = np.asarray(Pm[pr])[:, cu].astype(np.float32)
        return out
    PRt = prior_rows(test)
    # val rows: the same production prior computed from the photo's lat/lon (sets.npz keeps
    # no AU-val photo ids); checked against the cached test prior below
    import bank_analysis as BAm
    import build_ship as BS
    gp = BS.V2Prior(BAm.PRIOR)
    lat, lon = np.array(T["lat"]), np.array(T["lon"])

    def prior_ll(rows):
        out = np.zeros((len(rows), C), np.float32)
        for i in range(0, len(rows), 1024):
            r = rows[i:i + 1024]
            out[i:i + len(r)] = np.asarray(gp.log_prior(lat[r], lon[r], *BAm.MAIN[:3]), np.float32)[:, cu]
        return out
    chk = prior_ll(test[:200])
    print("val-prior parity on 200 test rows: max |Δ|", float(np.abs(chk - PRt[:200]).max()), flush=True)
    PRv = prior_ll(val)
    have_val_prior = True
    print(f"rows: train {len(trc):,}, val {len(val):,}, test {len(test):,}; encoders {list(enc)}; "
          f"val prior {'yes' if have_val_prior else 'no (val choice on head only)'}", flush=True)

    def centred(E):
        mu = unit(E[trc]).mean(0)
        return unit(unit(E) - mu).astype(np.float32)

    Cb = centred(Eb)
    Tc = unit(Tsub - tmean)
    yt, yv = ys[test], ys[val]
    proto = {}

    def protos(Cx):
        P_ = np.zeros((C, Cx.shape[1]), np.float32)
        np.add.at(P_, ys[trc], Cx[trc])
        return unit(P_)

    def train_eval(name, X, Tinit, seeds=(0, 1), val_only=False):
        Xv_ = X[val]
        nll = {}
        for s in (20, 30, 40, 50, 70, 100):
            L = torch.log_softmax(torch.from_numpy(s * Xv_[:len(vau)] @ unit(Tinit - Tinit.mean(0)).T), 1)
            nll[s] = float(-L.gather(1, torch.from_numpy(ys[vau])[:, None]).mean())
        s0 = min(nll, key=nll.get)
        Dd = {"T": Tinit.astype(np.float16), "mu": np.zeros(X.shape[1], np.float32), "s0": np.float32(s0),
              "ytr": ys[trc].astype(np.int32), "Xtr": X[trc].astype(np.float16), "tas": tas[trc], "genus": gid,
              "Xv": X[vau].astype(np.float16), "yv": ys[vau].astype(np.int32), "wv": w[vau].astype(np.float32),
              "Xa": X[vaa].astype(np.float16), "ya": ys[vaa].astype(np.int32), "wa": w[vaa].astype(np.float32)}
        out, hits = {"s0": s0, "dim": int(X.shape[1])}, {}
        for seed in seeds:
            cfg = dict(V.BASE, tau=1.5, wd=0.01, epochs=12, la_from="data", tas_weight=3.0, sampler="balanced:50",
                       name=f"{name}-s{seed}", seed=seed)
            curve, W, b, info, _ = V.train(cfg, Dd, DEV, log=lambda *a: None)
            W = W.astype(np.float32)
            nr = np.linalg.norm(W, axis=1, keepdims=True).clip(1e-6)
            W = W * (nr.mean() / nr) ** 0.5
            # val (selection of w): per species top-1, + prior when available
            Lv = torch.log_softmax(torch.from_numpy(X[val] @ W.T + b), 1).numpy()
            if PRv is not None:
                Lv = Lv + PRv
            out.setdefault("val_top1_sp", []).append(float(per_species(Lv.argmax(1) == yv, yv).mean()))
            if val_only:
                continue
            Lh = torch.log_softmax(torch.from_numpy(X[test] @ W.T + b), 1).numpy()
            for tag, L in (("head", Lh), ("prior", Lh + PRt)):
                top5 = np.argsort(-L, 1)[:, :5]
                h1 = top5[:, 0] == yt
                h5 = (top5 == yt[:, None]).any(1)
                hits.setdefault(tag, []).append(h1)
                d = {}
                for part, m in (("all", np.ones(len(test), bool)), ("AU", sset[test] == "AU-test"),
                                ("A", sset[test] == "A-test"), ("euc", euc[yt]), ("b19", bkt[yt] == 0)):
                    d[part] = {"top1_sp": float(per_species(h1[m], yt[m]).mean()),
                               "top5_sp": float(per_species(h5[m], yt[m]).mean()),
                               "top1_nat": float((h1 * w[test])[m].sum() / w[test][m].sum()),
                               "genus_sp": float(per_species((gid[top5[:, 0]] == gid[yt])[m], yt[m]).mean()),
                               "n": int(m.sum())}
                out[f"{tag}-s{seed}"] = d
        out["val_top1_sp"] = float(np.mean(out["val_top1_sp"]))
        if not val_only:  # kNN-10 over the training photos (centred cosine)
            Qtr = torch.from_numpy(X[trc]).to(DEV)
            ytr_t = torch.from_numpy(ys[trc]).to(DEV)
            pred = []
            for i in range(0, len(test), 512):
                S = torch.from_numpy(X[test[i:i + 512]]).to(DEV) @ Qtr.T
                v_, ix = S.topk(10, 1)
                votes = torch.zeros(len(ix), C, device=DEV).scatter_add_(1, ytr_t[ix], torch.exp(v_ / 0.05))
                pred.append(votes.argmax(1).cpu().numpy())
            h = np.concatenate(pred) == yt
            hits["knn10"] = [h]
            out["knn10"] = {"top1_sp": float(per_species(h, yt).mean()),
                            "euc_top1_sp": float(per_species(h[euc[yt]], yt[euc[yt]]).mean())}
        return out, hits

    res, allhits = {"rows": {"train": int(len(trc)), "val": int(len(val)), "test": int(len(test))}, "arms": {}}, {}
    o, hh = train_eval("bioclip", Cb, Tc)
    res["arms"]["bioclip"], allhits["bioclip"] = o, hh
    print("bioclip", json.dumps({k: o[k]["all"] for k in ("prior-s0",)}), "val", o["val_top1_sp"], flush=True)
    for v in VARIANTS:
        if v not in enc:
            continue
        Cd = centred(enc[v][0])
        proto[v] = protos(Cd)
        o, hh = train_eval(v, Cd, proto[v])
        res["arms"][v], allhits[v] = o, hh
        print(v, json.dumps(o["prior-s0"]["all"]), "val", o["val_top1_sp"], flush=True)
        # combined: choose w on val (head seed 0), then train both seeds and test once
        vals = {}
        for wt in WEIGHTS:
            X = np.concatenate([Cb, wt * Cd], 1) / np.sqrt(1 + wt * wt)
            Ti = np.concatenate([Tc, wt * proto[v]], 1) / np.sqrt(1 + wt * wt)
            vals[wt] = train_eval(f"bioclip+{v}@{wt}", X, Ti, seeds=(0,), val_only=True)[0]["val_top1_sp"]
        wt = max(vals, key=vals.get)
        X = np.concatenate([Cb, wt * Cd], 1) / np.sqrt(1 + wt * wt)
        Ti = np.concatenate([Tc, wt * proto[v]], 1) / np.sqrt(1 + wt * wt)
        nm = f"bioclip+{v}"
        o, hh = train_eval(nm, X, Ti)
        o["w"], o["w_val"] = wt, vals
        res["arms"][nm], allhits[nm] = o, hh
        print(nm, f"w {wt} (val {vals})", json.dumps(o["prior-s0"]["all"]), flush=True)
    # paired class-cluster bootstrap vs bioclip, per-species top-1 (mean over head seeds)
    rng = np.random.default_rng(0)
    cls_t, inv = np.unique(yt, return_inverse=True)
    cnt = np.bincount(inv)
    B = [rng.integers(len(cls_t), size=len(cls_t)) for _ in range(1000)]
    boot = {}
    for nm, hh in allhits.items():
        if nm == "bioclip":
            continue
        for tag, hs in hh.items():
            d = np.mean([np.bincount(inv, h) / cnt for h in hs], 0) - \
                np.mean([np.bincount(inv, h) / cnt for h in allhits["bioclip"][tag]], 0)
            bs = np.array([d[b_].mean() for b_ in B])
            boot[f"{nm}/{tag}"] = {"diff": float(d.mean()), "lo": float(np.percentile(bs, 2.5)),
                                   "hi": float(np.percentile(bs, 97.5))}
    res["bootstrap_vs_bioclip_top1_sp"] = boot
    os.makedirs(DINO, exist_ok=True)
    json.dump(res, open(os.path.join(DINO, "eval.json"), "w"), indent=1)
    write_md(res)


def write_md(res):
    L = ["# DINOv3 second-encoder pilot — results", "", f"Rows: {res['rows']}", "",
         "Per species top-1 / top-5 + natural top-1 with the production prior (head seed 0; seed 1 top-1); "
         "eucalypts, 1–9-photo classes, genus; head only; kNN-10.", "",
         "| arm | dim | val | top-1 | top-5 | nat | AU | A | euc | 1–9 | genus | seed-1 | head only | kNN10 | kNN10 euc |",
         "|---|" + "---|" * 14]
    for nm, o in res["arms"].items():
        a, s1, h = o["prior-s0"], o["prior-s1"]["all"], o["head-s0"]["all"]
        k = o["knn10"]
        L.append(f"| {nm}{' w ' + str(o['w']) if 'w' in o else ''} | {o['dim']} | {100 * o['val_top1_sp']:.1f} | "
                 f"{100 * a['all']['top1_sp']:.1f} | {100 * a['all']['top5_sp']:.1f} | {100 * a['all']['top1_nat']:.1f} | "
                 f"{100 * a['AU']['top1_sp']:.1f} | {100 * a['A']['top1_sp']:.1f} | {100 * a['euc']['top1_sp']:.1f} | "
                 f"{100 * a['b19']['top1_sp']:.1f} | {100 * a['all']['genus_sp']:.1f} | {100 * s1['top1_sp']:.1f} | "
                 f"{100 * h['top1_sp']:.1f} | {100 * k['top1_sp']:.1f} | {100 * k['euc_top1_sp']:.1f} |")
    L += ["", "Paired class-cluster bootstrap vs bioclip, per-species top-1 (pt, 95 %):", ""]
    for k_, v in res["bootstrap_vs_bioclip_top1_sp"].items():
        L.append(f"- {k_}: {100 * v['diff']:+.2f} [{100 * v['lo']:+.2f}, {100 * v['hi']:+.2f}]")
    open(os.path.join(DINO, "eval.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    {"weights": cmd_weights, "eval": cmd_eval}[sys.argv[1]]()

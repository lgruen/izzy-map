#!/usr/bin/env python3
"""Encoder fine-tuning pilot — evaluation (Mac). For every arm, the SAME
production head recipe is trained on that arm's embeddings (train_v2.train:
text init s0 · centred text, balanced softmax τ 1.5 with log π from the data,
class-balanced sampling K 50, decay to the init 0.01, Tasmanian photos × 3,
12-epoch cosine, per-species val early stopping; τ-norm 0.5 post hoc; head
seeds 0 and 1), so arms differ ONLY in the encoder. Arm "frozen" = the
data-final training embeddings (the production ones) + the pod's frozen
embeddings of the evaluation photos (parity-checked against data-final).

Test = the subset's AU-test ∪ A-test photos (held-out observers), head only and
+ the production location prior (bank_analysis prior-main, λ 1.0, restricted
to the subset's classes). Metrics: top-1/top-5 per species and natural mix,
eucalypts, the 1–9 bucket, genus accuracy, share of errors that are a
congener; kNN (1/5/10-NN over the subset's training photos, centred cosine);
zero-shot on the subset (969-way) and on the outside-subset probe
(22,122-way) = the text-alignment / forgetting check. Paired class-cluster
bootstrap (1,000×) of every arm − frozen on per-species top-1.

Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'numpy<2.3' --with pyarrow
     python3 -I pipeline/plantid/finetune/ft_eval.py [runs …]
"""
import glob
import json
import os
import sys

import numpy as np
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.dirname(HERE)
sys.path.insert(0, P)
import train_v2 as V  # noqa: E402

CACHE = os.path.normpath(os.path.join(P, "..", "cache", "plantid"))
FT = os.path.join(CACHE, "finetune")
PLAN = os.path.join(FT, "plan")
BA = os.path.join(V.V2, "bank_analysis")
DEV = "mps"


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True).clip(1e-9)


def load_run(name, nrows):
    """Embeddings placed by photo_id (shard `row` is the pod's row, which differs in smoke runs)."""
    E = np.zeros((nrows, 1024), np.float16)
    have = np.zeros(nrows, bool)
    pre = "frozen" if name == "frozen" else "emb"
    d = os.path.join(FT, "runs", name if name != "frozen" else FROZEN_SRC)
    full = json.load(open(os.path.join(d, "log.json")))["rows"] == nrows  # pod rows = todo rows (not a smoke run)
    for f in sorted(glob.glob(os.path.join(d, f"{pre}-*.npz"))):
        z = np.load(f)
        r = z["row"] if full else ROW_OF(z["photo_id"])
        E[r] = z["emb"]
        have[r] = z["ok"]
    return E, have


def per_species(hit, y):
    _, inv = np.unique(y, return_inverse=True)
    return np.bincount(inv, hit) / np.bincount(inv)


def main():
    global FROZEN_SRC
    import torch
    T = pq.read_table(os.path.join(PLAN, "todo.parquet")).to_pydict()
    role, sset = np.array(T["role"]), np.array(T["set"])
    ys, yg = np.array(T["ys"], np.int64), np.array(T["y"], np.int64)
    pid, w, tas = np.array(T["photo_id"], np.int64), np.array(T["w"]), np.array(T["tas"], bool)
    n = len(role)
    global ROW_OF
    # photo_id → todo row (a photo is in one role only, asserted by ft_plan; probe ∩ test = ∅)
    ROW_OF = np.vectorize(dict(zip(pid.tolist(), range(n))).__getitem__, otypes=[np.int64])
    cls = json.load(open(os.path.join(PLAN, "classes.json")))
    C = len(cls)
    cu = np.array([c["u"] for c in cls])
    euc = np.array([c["euc"] for c in cls])
    gname = [c["genus"] for c in cls]
    gid = np.unique(gname, return_inverse=True)[1]
    bkt = np.array([c["bucket"] for c in cls])
    Tsub = np.load(os.path.join(PLAN, "text_sub.npy"))
    tmean = np.load(os.path.join(PLAN, "tmean.npy"))
    Tall = np.load(os.path.join(V.CACHE, "australia", "text.npz"))["emb"].astype(np.float32)
    runs = sys.argv[1:] or sorted(os.path.basename(d) for d in glob.glob(os.path.join(FT, "runs", "*"))
                                  if glob.glob(os.path.join(d, "emb-*.npz")))
    if runs == ["none"]:  # the frozen arm alone
        runs = []
    FROZEN_SRC = os.environ.get("FROZEN_SRC") or next(
        r for r in runs + ["lora", "partial", "supcon-lora", "supcon-partial"]
        if len(glob.glob(os.path.join(FT, "runs", r, "frozen-*.npz"))) >= 3)
    # frozen arm: production training embeddings + pod frozen eval embeddings
    Ef, hf = load_run("frozen", n)
    D = np.load(os.path.join(V.V2, "data-final.npz"))
    dpid = D["pid"]
    order = np.argsort(dpid)
    tr = np.nonzero(role == "train")[0]
    j = order[np.searchsorted(dpid[order], pid[tr])]
    assert (dpid[j] == pid[tr]).all()
    Xtr_prod = D["Xtr"][j]
    chk = tr[hf[tr]]
    cos = (unit(Ef[chk].astype(np.float32)) * unit(Xtr_prod[hf[tr]].astype(np.float32))).sum(1)
    parity = {"n": int(len(chk)), "cos_min": float(cos.min()), "cos_median": float(np.median(cos))}
    print("frozen parity vs data-final:", parity)
    Ef[tr] = Xtr_prod
    hf[tr] = True
    arms = {"frozen": (Ef, hf)}
    for r in runs:
        arms[r] = load_run(r, n)
    # common rows: present in every arm
    okall = np.logical_and.reduce([h for _, h in arms.values()])
    # prior rows
    Z = np.load(os.path.join(BA, "sets.npz"), allow_pickle=True)
    prow = np.full(n, -1)
    for nm in ("AU-test", "A-test"):
        zp = Z[nm + "/pid"]
        pos = {int(p): i for i, p in enumerate(zp)}
        m = sset == nm
        prow[m] = [pos.get(int(p), -1) for p in pid[m]]
    test = np.nonzero((role == "test") & okall)[0]
    PR = np.zeros((len(test), C), np.float32)
    for nm in ("AU-test", "A-test"):
        Pm = np.load(os.path.join(BA, f"prior-main-{nm}.npy"), mmap_mode="r")
        m = sset[test] == nm
        PR[m] = np.asarray(Pm[prow[test[m]]])[:, cu].astype(np.float32)
    assert (prow[test] >= 0).all()
    probe = np.nonzero((role == "probe") & okall)[0]
    trc = np.nonzero((role == "train") & okall)[0]
    vau = np.nonzero((sset == "AU-val") & okall)[0]
    vaa = np.nonzero((sset == "A-val") & okall)[0]
    if not len(vaa):  # (smoke/bench dry runs only)
        vaa = vau
    yt = ys[test]
    res = {"parity": parity, "rows": {"train": int(len(trc)), "test": int(len(test)), "probe": int(len(probe))},
           "arms": {}}
    hits = {}
    for name, (E, _) in arms.items():
        X = E.astype(np.float32)
        mu = unit(X[trc]).mean(0)
        q_all = None

        def q(rows):
            return unit(unit(X[rows]) - mu).astype(np.float32)
        Tc = unit(Tsub.astype(np.float32) - tmean)
        qv = q(vau)
        nll = {}
        for s in (20, 30, 40, 50, 70, 100):
            L = torch.log_softmax(torch.from_numpy(s * qv @ Tc.T), 1)
            nll[s] = float(-L.gather(1, torch.from_numpy(ys[vau])[:, None]).mean())
        s0 = min(nll, key=nll.get)
        Dd = {"T": Tsub, "mu": mu, "s0": np.float32(s0), "ytr": ys[trc].astype(np.int32), "Xtr": X[trc].astype(np.float16),
              "tas": tas[trc], "genus": gid, "Xv": X[vau].astype(np.float16), "yv": ys[vau].astype(np.int32),
              "wv": w[vau].astype(np.float32), "Xa": X[vaa].astype(np.float16), "ya": ys[vaa].astype(np.int32),
              "wa": w[vaa].astype(np.float32)}
        out = {"s0": s0}
        qt = q(test)
        for seed in (0, 1):
            cfg = dict(V.BASE, tau=1.5, wd=0.01, epochs=12, la_from="data", tas_weight=3.0, sampler="balanced:50",
                       name=f"{name}-s{seed}", seed=seed)
            curve, W, b, info, _ = V.train(cfg, Dd, DEV, log=lambda *a: None)
            W = W.astype(np.float32)
            nr = np.linalg.norm(W, axis=1, keepdims=True).clip(1e-6)
            W = W * (nr.mean() / nr) ** 0.5
            Lh = torch.log_softmax(torch.from_numpy(qt @ W.T + b), 1).numpy()
            for tag, L in (("head", Lh), ("prior", Lh + 1.0 * PR)):
                top5 = np.argsort(-L, 1)[:, :5]
                h1 = top5[:, 0] == yt
                h5 = (top5 == yt[:, None]).any(1)
                hits.setdefault((name, tag), []).append(h1)
                err = ~h1
                d = {}
                for part, m in (("all", np.ones(len(test), bool)), ("AU", sset[test] == "AU-test"),
                                ("A", sset[test] == "A-test"), ("euc", euc[yt]), ("b19", bkt[yt] == 0)):
                    p1, p5 = per_species(h1[m], yt[m]), per_species(h5[m], yt[m])
                    d[part] = {"top1_sp": float(p1.mean()), "top5_sp": float(p5.mean()),
                               "top1_nat": float((h1 * w[test])[m].sum() / w[test][m].sum()),
                               "genus_sp": float(per_species((gid[top5[:, 0]] == gid[yt])[m], yt[m]).mean()),
                               "err_congener": float((gid[top5[:, 0]] == gid[yt])[m & err].mean()) if (m & err).any() else None,
                               "n": int(m.sum())}
                out.setdefault(f"{tag}-s{seed}", d)
            out[f"head-s{seed}-best_epoch"] = info["best_epoch"]
        # kNN over the training photos (centred cosine), per species top-1
        Qtr = torch.from_numpy(q(trc)).to(DEV)
        ytr_t = torch.from_numpy(ys[trc]).to(DEV)
        kn = {}
        for k in (1, 5, 10):
            pred = []
            for i in range(0, len(test), 512):
                S = torch.from_numpy(qt[i:i + 512]).to(DEV) @ Qtr.T
                v_, ix = S.topk(k, 1)
                lab = ytr_t[ix]
                votes = torch.zeros(len(lab), C, device=DEV).scatter_add_(1, lab, torch.exp(v_ / 0.05))
                pred.append(votes.argmax(1).cpu().numpy())
            pred = np.concatenate(pred)
            h = pred == yt
            hits.setdefault((name, f"knn{k}"), []).append(h)
            kn[f"knn{k}"] = {"top1_sp": float(per_species(h, yt).mean()),
                             "euc_top1_sp": float(per_species(h[euc[yt]], yt[euc[yt]]).mean()),
                             "err_congener": float((gid[pred] == gid[yt])[~h].mean())}
        out["knn"] = kn
        # zero-shot: subset (969-way) and outside probe (22,122-way)
        zs = (qt @ Tc.T).argmax(1) == yt
        TcA = unit(Tall - tmean)
        qp = q(probe)
        zp = []
        for i in range(0, len(probe), 1024):
            zp.append((torch.from_numpy(qp[i:i + 1024]).to(DEV) @ torch.from_numpy(TcA).to(DEV).T).topk(5, 1).indices.cpu().numpy())
        zp = np.concatenate(zp)
        ygp = yg[probe]
        out["zeroshot"] = {"subset_top1_sp": float(per_species(zs, yt).mean()),
                           "probe_top1_sp": float(per_species(zp[:, 0] == ygp, ygp).mean()),
                           "probe_top5_sp": float(per_species((zp == ygp[:, None]).any(1), ygp).mean()),
                           "probe_top1_nat": float(((zp[:, 0] == ygp) * w[probe]).sum() / w[probe].sum())}
        hits.setdefault((name, "zs_probe"), []).append(zp[:, 0] == ygp)
        res["arms"][name] = out
        print(name, json.dumps({k: (v["all"] if isinstance(v, dict) and "all" in v else v) for k, v in out.items()
                                if k.startswith("prior-s0") or k in ("knn", "zeroshot", "s0")})[:900], flush=True)
    # paired class-cluster bootstrap vs frozen (mean over head seeds)
    rng = np.random.default_rng(0)
    cls_t, inv = np.unique(yt, return_inverse=True)
    B = [rng.integers(len(cls_t), size=len(cls_t)) for _ in range(1000)]
    cnt = np.bincount(inv)

    def sp_vec(h):
        return np.bincount(inv, h) / cnt
    boot = {}
    for (name, tag), hs in hits.items():
        if name == "frozen" or tag == "zs_probe":
            continue
        d = np.mean([sp_vec(h) for h in hs], 0) - np.mean([sp_vec(h) for h in hits[("frozen", tag)]], 0)
        bs = np.array([d[b_].mean() for b_ in B])
        boot[f"{name}/{tag}"] = {"diff": float(d.mean()), "lo": float(np.percentile(bs, 2.5)),
                                 "hi": float(np.percentile(bs, 97.5))}
    res["bootstrap_vs_frozen_top1_sp"] = boot
    json.dump(res, open(os.path.join(FT, "eval.json"), "w"), indent=1)
    write_md(res)


def write_md(res):
    L = ["# Encoder fine-tuning pilot — results", "",
         f"Rows: {res['rows']}; frozen parity vs data-final: {res['parity']}", "",
         "Per species top-1 / top-5, natural top-1 (+ prior, head seed 0 | seed 1 top-1); eucalypts; 1–9 bucket; "
         "genus; share of errors that are a congener.", "",
         "| arm | all top-1 | all top-5 | nat | AU | A | euc | 1–9 | genus | err congener | seed-1 top-1 | head-only top-1 |"
         " kNN1 | kNN5 | kNN10 | kNN10 euc | zs subset | zs probe 22k top-1/top-5 |",
         "|---|" + "---|" * 17]
    for name, o in res["arms"].items():
        a, s1, h = o["prior-s0"], o["prior-s1"]["all"], o["head-s0"]["all"]
        k, z = o["knn"], o["zeroshot"]
        L.append(f"| {name} | {100 * a['all']['top1_sp']:.1f} | {100 * a['all']['top5_sp']:.1f} | "
                 f"{100 * a['all']['top1_nat']:.1f} | {100 * a['AU']['top1_sp']:.1f} | {100 * a['A']['top1_sp']:.1f} | "
                 f"{100 * a['euc']['top1_sp']:.1f} | {100 * a['b19']['top1_sp']:.1f} | {100 * a['all']['genus_sp']:.1f} | "
                 f"{100 * a['all']['err_congener']:.0f} % | {100 * s1['top1_sp']:.1f} | {100 * h['top1_sp']:.1f} | "
                 f"{100 * k['knn1']['top1_sp']:.1f} | {100 * k['knn5']['top1_sp']:.1f} | {100 * k['knn10']['top1_sp']:.1f} | "
                 f"{100 * k['knn10']['euc_top1_sp']:.1f} | {100 * z['subset_top1_sp']:.1f} | "
                 f"{100 * z['probe_top1_sp']:.1f} / {100 * z['probe_top5_sp']:.1f} |")
    L += ["", "Paired class-cluster bootstrap, arm − frozen, per-species top-1 (pt, 95 % interval):", ""]
    for k_, v in res["bootstrap_vs_frozen_top1_sp"].items():
        L.append(f"- {k_}: {100 * v['diff']:+.2f} [{100 * v['lo']:+.2f}, {100 * v['hi']:+.2f}]")
    open(os.path.join(FT, "eval.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()

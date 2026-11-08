#!/usr/bin/env python3
"""Rows for species WITHOUT training photos: can we predict what their trained
head row would look like, instead of leaving them at the frozen text vector?

Today ~3,800 classes of the v2 head (final-cb50-s1) have no training photo and
keep their initial row s0 · t_c (centred text vector, |row| = 50), while trained
rows grew to |row| ≈ 62–72 and moved away from the text (row drift ≈ 0.8). On
AU-test those classes score ~0 %: the text rows never win against trained ones.

Idea: a trained row is roughly "the text vector, moved toward how the species
actually looks in photos". That move Δ_c = W_c / s0 − t_c is learnable from the
classes that DO have photos, and much of it is shared within a genus:
  genus   Δ̂_c = mean Δ over trained congeners (fallback: mean over all)
  ridge   Δ̂_c = t_c · A, A fitted by ridge regression on trained classes
  both    Δ̂_c = [t_c, genus mean Δ] · A
then row = s0 · α · (t_c + Δ̂_c), bias = β (the trained rows' biases are
logit-adjusted; photo-less rows have b = 0).

Protocol (analysis only, nothing ships): the photos are never re-used for
training — the trained head is fixed. SIMULATED photo-less classes H = 25 % of
the classes with ≥ 10 training photos that appear in AU-val; their rows are
replaced by the text row (baseline) or a predicted row fitted WITHOUT them.
H is split by class hash into H-tune (choose α, β, ridge λ) and H-report. Leak
caveat: the other trained rows saw H's photos as negatives, which flatters H.
The CLEAN check is the AU-val photos of the TRULY photo-less classes (n_c = 0,
never used for tuning). Scoring = head_capacity.ValJ: log_softmax(logits / t)
+ λ · main prior, scale-kept τ-norm 0.5, merged columns masked.

Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'numpy<2.3' python3 -I
     pipeline/plantid/zeroshot_rows.py
"""
import hashlib
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
V2 = os.path.join(HERE, "..", "cache", "plantid", "australia", "v2")
RUN = os.environ.get("ZR_RUN", "final-cb50-s1")
TN = 0.5


def h01(i):
    return int.from_bytes(hashlib.sha256(f"zr{i}".encode()).digest()[:4], "big") / 2 ** 32


def taunorm(W, tn=TN):
    nr = np.linalg.norm(W, axis=-1, keepdims=True).clip(1e-6)
    return W * (nr.mean() / nr) ** tn


def main():
    import torch
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    r = np.load(os.path.join(V2, "runs", RUN + ".npz"))
    W0, b0, n = r["W"].astype(np.float32), r["b"].astype(np.float32), r["n_c"]
    D = np.load(os.path.join(V2, "data-final.npz"), mmap_mode="r")
    T, s0, genus = D["T"].astype(np.float32), float(D["s0"]), D["genus"]
    C = len(n)
    z = np.load(os.path.join(V2, "head_capacity", "vm", "val.npz"))
    cm = torch.from_numpy(z["cm"]).to(dev)
    lam = float(z["lam"])
    q = torch.from_numpy(z["AU-val/q"].astype(np.float32)).to(dev)
    y = z["AU-val/y"]
    P = torch.from_numpy(np.ascontiguousarray(
        np.load(os.path.join(V2, "head_capacity", "vm", "prior-main-AU-val.npy")))).to(dev).float()
    merged = z["cm"] < -1
    print(f"{RUN}: {C} classes, photo-less {int((n == 0).sum())}, merged {int(merged.sum())}, s0 {s0}, λ {lam}")

    inval = np.zeros(C, bool)
    inval[y[y >= 0]] = True
    trained = (n >= 10) & ~merged
    cand = np.where(trained & inval)[0]
    H = cand[np.array([h01(c) for c in cand]) < 0.25]
    Ht = H[np.array([h01(c * 7 + 1) for c in H]) < 0.5]
    Hr = np.setdiff1d(H, Ht)
    Z = np.where((n == 0) & inval & ~merged)[0]
    fit = np.setdiff1d(np.where(trained)[0], H)
    print(f"H {len(H)} (tune {len(Ht)}, report {len(Hr)}), true photo-less in AU-val {len(Z)}, fit on {len(fit)}")

    Delta = W0 / s0 - T                     # the move each trained class made
    # genus mean Δ over FIT classes only
    G = genus.max() + 1
    gs = np.zeros((G, T.shape[1]), np.float32)
    gc = np.zeros(G)
    np.add.at(gs, genus[fit], Delta[fit])
    np.add.at(gc, genus[fit], 1)
    gmean_all = Delta[fit].mean(0)
    gm = np.where(gc[:, None] > 0, gs / np.maximum(gc, 1)[:, None], gmean_all)
    has_g = gc[genus] > 0

    def ridge(X, Y, l):
        A = X.T @ X + l * np.eye(X.shape[1], dtype=np.float32)
        return np.linalg.solve(A, X.T @ Y)

    # within-fit cosine check of the ridge λ (by class hash halves)
    fa = fit[np.array([h01(c * 3 + 2) for c in fit]) < 0.8]
    fb = np.setdiff1d(fit, fa)

    def feats(cls, kind, gmx):
        if kind == "ridge":
            return T[cls]
        return np.concatenate([T[cls], gmx[genus[cls]]], 1)
    # genus means without the fb classes, for the inner check of "both"
    gs2, gc2 = np.zeros_like(gs), np.zeros(G)
    np.add.at(gs2, genus[fa], Delta[fa])
    np.add.at(gc2, genus[fa], 1)
    gm2 = np.where(gc2[:, None] > 0, gs2 / np.maximum(gc2, 1)[:, None], Delta[fa].mean(0))
    best_l = {}
    for kind in ("ridge", "both"):
        res = {}
        for l in (1.0, 10.0, 100.0, 1000.0):
            A = ridge(feats(fa, kind, gm2), Delta[fa], l)
            pr = feats(fb, kind, gm2) @ A
            cos = (pr * Delta[fb]).sum(1) / np.linalg.norm(pr, axis=1) / np.linalg.norm(Delta[fb], axis=1)
            res[l] = float(cos.mean())
        best_l[kind] = max(res, key=res.get)
        print(f"inner check {kind}: cos(Δ̂, Δ) by λ {res} → λ {best_l[kind]}")
    cg = (gm2[genus[fb]] * Delta[fb]).sum(1) / np.linalg.norm(gm2[genus[fb]], axis=1) / np.linalg.norm(Delta[fb], axis=1)
    print(f"inner check genus mean: cos {cg.mean():.3f}")

    preds = {"text": np.zeros_like(T)}
    preds["genus"] = gm[genus]
    for kind in ("ridge", "both"):
        A = ridge(feats(fit, kind, gm), Delta[fit], best_l[kind])
        preds[kind] = feats(np.arange(C), kind, gm) @ A

    TEMPS = (1.0, 1.25, 1.5, 2.0)

    def score(rows, cls_set, alpha, beta):
        """Replace rows of cls_set (and the true photo-less Z) → per-species top-1 on several groups."""
        W = W0.copy()
        b = b0.copy()
        rep = np.union1d(cls_set, Z)
        W[rep] = s0 * alpha * (T[rep] + rows[rep])
        b[rep] = beta
        Wt = torch.from_numpy(taunorm(W)).to(dev)
        bt = torch.from_numpy(b).to(dev)
        out = {}
        for t in TEMPS:
            pr = []
            for i in range(0, len(q), 4096):
                Z_ = q[i:i + 4096] @ Wt.T + bt + cm
                pr.append((torch.log_softmax(Z_ / t, 1) + lam * P[i:i + 4096]).argmax(1).cpu().numpy())
            pr = np.concatenate(pr)
            hit = (pr == y) & (y >= 0)
            m = y >= 0
            res = {}
            for nm, grp in (("Ht", Ht), ("Hr", Hr), ("Z", Z)):
                sel = np.isin(y, grp)
                cls, inv = np.unique(y[sel], return_inverse=True)
                res[nm] = float((np.bincount(inv, hit[sel]) / np.bincount(inv)).mean())
            rest = m & ~np.isin(y, np.union1d(H, Z))
            cls, inv = np.unique(y[rest], return_inverse=True)
            res["rest_sp"] = float((np.bincount(inv, hit[rest]) / np.bincount(inv)).mean())
            allm = m & ~np.isin(y, Hr)        # everything but H-report: the tuning objective
            cls, inv = np.unique(y[allm], return_inverse=True)
            res["tune_sp"] = float((np.bincount(inv, hit[allm]) / np.bincount(inv)).mean())
            cls, inv = np.unique(y[m], return_inverse=True)
            res["all_sp"] = float((np.bincount(inv, hit[m]) / np.bincount(inv)).mean())
            # how often a replaced class is predicted at all (false positives)
            res["pred_rep"] = float(np.isin(pr, rep).mean())
            out[t] = res
        return out

    results = {"run": RUN, "n_H": len(H), "n_Ht": len(Ht), "n_Hr": len(Hr), "n_Z": int(len(Z)), "rows": []}
    ref = score(preds["text"], np.array([], int), 1.0, 0.0)[1.0]
    print(f"reference (no change; Z at text rows): {ref}")
    results["reference"] = ref
    base = score(preds["text"], H, 1.0, 0.0)[1.0]
    print(f"baseline (H at text rows, as photo-less classes are today): {base}")
    results["baseline"] = base
    for kind, rows in preds.items():
        for alpha in (1.0, 1.15, 1.3, 1.45):
            for beta in (-1.0, 0.0, 1.0, 2.0, 3.0):
                for t, res in score(rows, H, alpha, beta).items():
                    row = dict(kind=kind, alpha=alpha, beta=beta, t=t, **res)
                    results["rows"].append(row)
        best = max((x for x in results["rows"] if x["kind"] == kind),
                   key=lambda x: x["tune_sp"])   # per species over all val classes but H-report
        print(f"{kind:6s} best on H-tune(+rest): α {best['alpha']} β {best['beta']} t {best['t']} → "
              f"Ht {best['Ht']:.3f} Hr {best['Hr']:.3f} Z {best['Z']:.3f} rest {best['rest_sp']:.3f} "
              f"all {best['all_sp']:.3f} pred_rep {best['pred_rep']:.3f}")
        results.setdefault("best", {})[kind] = best
    # ---- clean check, read once with the settings chosen above: AU-test photos of the
    # classes that TRULY have no training photo (all photo-less rows replaced; no H)
    Sz = np.load(os.path.join(V2, "bank_analysis", "sets.npz"), allow_pickle=True)
    mu = Sz["mu"]
    unit = lambda x: x / np.linalg.norm(x, axis=-1, keepdims=True)  # noqa: E731
    qt = torch.from_numpy(unit(unit(Sz["AU-test/emb"].astype(np.float32)) - mu)).to(dev)
    yt = Sz["AU-test/y"]
    Pt = np.load(os.path.join(V2, "bank_analysis", "prior-main-AU-test.npy"), mmap_mode="r")
    zl = np.where((n == 0) & ~merged)[0]
    zt = (yt >= 0) & np.isin(yt, zl)
    print(f"AU-test: {len(yt)} photos, {int(zt.sum())} of {len(np.unique(yt[zt]))} photo-less classes")
    gen_t = genus

    def test(rows, alpha, beta, t):
        W = W0.copy()
        b = b0.copy()
        W[zl] = s0 * alpha * (T[zl] + rows[zl])
        b[zl] = beta
        Wt = torch.from_numpy(taunorm(W)).to(dev)
        bt = torch.from_numpy(b).to(dev)
        top = []
        for i in range(0, len(qt), 4096):
            Z_ = qt[i:i + 4096] @ Wt.T + bt + cm
            L = torch.log_softmax(Z_ / t, 1) + lam * torch.from_numpy(np.asarray(Pt[i:i + 4096], np.float32)).to(dev)
            top.append(L.topk(5, 1).indices.cpu().numpy())
        top = np.concatenate(top)
        m = yt >= 0
        r1 = top[:, 0] == yt
        r5 = (top == yt[:, None]).any(1)
        g1 = gen_t[top[:, 0]] == gen_t[np.maximum(yt, 0)]

        def sp(sel, h):
            cls, inv = np.unique(yt[sel], return_inverse=True)
            return float((np.bincount(inv, h[sel]) / np.bincount(inv)).mean())
        rest = m & ~zt
        return {"zero_top1": sp(zt, r1), "zero_top5": sp(zt, r5), "zero_genus": sp(zt, g1),
                "rest_top1_sp": sp(rest, r1), "all_top1_sp": sp(m, r1),
                "pred_zero": float(np.isin(top[:, 0], zl).mean())}
    results["test"] = {"baseline": test(preds["text"], 1.0, 0.0, 1.0)}
    print("test baseline:", results["test"]["baseline"])
    for kind, bst in results["best"].items():
        results["test"][kind] = test(preds[kind], bst["alpha"], bst["beta"], bst["t"])
        print(f"test {kind}:", results["test"][kind])
    out = os.path.join(V2, "zeroshot_rows.json")
    json.dump(results, open(out, "w"), indent=1)
    print("→", out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""More expressive heads for the single model (v2), trained with the final
recipe of train_v2.py (`final-cb50-s1`: text init s0 · centred text, balanced
softmax with log π from the data, class-balanced sampling 50 / class / epoch,
τ 1.5, AdamW lr 1e-3 with decoupled decay toward the init 0.01, warmup 1 +
cosine over 12 epochs, Tasmanian photos ×3, per-species val early stopping) —
the training loop is a copy of train_v2.train with the head swapped:

  linear        the v2 head (sanity: reproduces final-cb50-s1 up to device noise)
  mproto:K      K vectors per class, class score = logsumexp_k(s0·W_ck·x) − log K
                (a K-component mixture per class); W0_ck = normalise(text_c +
                γ·(P_ck − mean_k P_ck)) from per-class k-means prototypes P of
                the training photos (bank_analysis.py protos K) to break the
                symmetry, γ = cfg "gamma" (0.5); classes with < K prototypes
                repeat the text vector
  adapter:H     residual MLP adapter: x' = normalise(x + U·GELU(A·x + a)),
                U zero-initialised (starts AS the linear text head), then the
                linear head on x'; A, a, U with ordinary weight decay

Standalone (numpy + torch). Usage:
  bank_heads.py train --data data-final.npz [--protos DIR] --out DIR '<json cfg>' …
  bank_heads.py vm --bucket gs://…/au --work /opt/izzy   (cloud: cfgs from
      $B/bank/cfgs.json, data $B/v2/data-final.npz, protos $B/bank/, results →
      $B/bank/runs/, finished runs skipped)
Bound (README-style, measured before launch): see the caller's notes.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

BASE = {"init": "text", "tau": 1.5, "wd": 0.01, "lr": 1e-3, "epochs": 12, "bs": 2048, "patience": 6, "seed": 1,
        "la_from": "data", "tas_weight": 3.0, "sampler": "balanced:50", "head": "linear", "gamma": 0.5,
        "awd": 0.01}


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def train(c, D, dev, protos_dir=None, log=print):
    import torch
    torch.manual_seed(c["seed"])
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
    on_dev = len(y) * 1024 * 2 <= float(os.environ.get("V2_GPU_BYTES", 8e9))
    Xc = centre(D["Xtr"]) if on_dev else torch.cat([centre(D["Xtr"][i:i + 262144]).cpu() for i in range(0, len(y), 262144)])
    yt = torch.from_numpy(y).to(dev)
    n_c = torch.bincount(yt, minlength=C).float()
    nc_np = n_c.cpu().numpy()
    K_ = float(c["sampler"].split(":")[1])
    m_c = np.where(nc_np > 0, K_, 0.0)
    m_t = torch.from_numpy(nc_np.astype(np.float32)).to(dev)  # la_from data
    logpi = torch.where(m_t > 0, torch.log(m_t / m_t.sum()), torch.full_like(m_t, -1e4))
    srt = np.argsort(y, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(y, minlength=C))]
    ep_rng = np.random.default_rng(c["seed"] + 1)

    def epoch_rows():
        cls = np.nonzero(m_c > 0)[0]
        cc = np.repeat(cls, m_c[cls].astype(np.int64))
        pick = starts[cc] + (ep_rng.random(len(cc)) * nc_np[cc]).astype(np.int64)
        return torch.from_numpy(ep_rng.permutation(srt[pick])).to(dev)
    Tc = torch.from_numpy(unit(D["T"].astype(np.float32) - D["T"].astype(np.float32).mean(0))).to(dev)
    s0 = float(D["s0"])
    kind, _, arg = c["head"].partition(":")
    params = []
    if kind == "mproto":
        K = int(arg)
        P = np.load(os.path.join(protos_dir, f"proto{K}.npz"))
        off = np.zeros((C, K, Tc.shape[1]), np.float32)
        lab, vec = P["labels"].astype(np.int64), P["vectors"].astype(np.float32)
        slot = np.zeros(C, np.int64)
        for r in range(len(lab)):
            off[lab[r], slot[lab[r]]] = vec[r]
            slot[lab[r]] += 1
        have = np.arange(K)[None, :] < slot[:, None]
        mean = np.where(slot[:, None] > 0, off.sum(1) / np.maximum(slot, 1)[:, None], 0)
        off = np.where(have[..., None], off - mean[:, None], 0).astype(np.float32)
        W0 = torch.nn.functional.normalize(Tc[:, None, :] + c["gamma"] * torch.from_numpy(off).to(dev), dim=-1)
        del off
    else:
        K = 1
        W0 = Tc[:, None, :]
    Dw = torch.nn.Parameter(torch.zeros_like(W0))
    beta = torch.nn.Parameter(torch.zeros(C, device=dev))
    params = [Dw, beta]
    A = U = a_ = None
    if kind == "adapter":
        H = int(arg)
        A = torch.nn.Parameter(torch.randn(H, Tc.shape[1], device=dev) / math.sqrt(Tc.shape[1]))
        a_ = torch.nn.Parameter(torch.zeros(H, device=dev))
        U = torch.nn.Parameter(torch.zeros(Tc.shape[1], H, device=dev))
    groups = [{"params": params, "weight_decay": c["wd"]}]
    if A is not None:
        groups.append({"params": [A, a_, U], "weight_decay": c["awd"]})
    opt = torch.optim.AdamW(groups, lr=c["lr"], betas=(0.9, 0.999))
    spe = -(-int(m_c.sum()) // c["bs"])
    total, warm = spe * c["epochs"], spe

    def lr_at(s):
        return (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm)))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)

    def feats(x):
        if A is None:
            return x
        return torch.nn.functional.normalize(x + torch.nn.functional.gelu(x @ A.T + a_) @ U.T, dim=-1)

    def logits(x):
        W = s0 * (W0 + Dw)                       # C × K × d
        f = feats(x)
        if K == 1:
            return f @ W[:, 0].T + s0 * beta
        z = torch.einsum("nd,ckd->nck", f, W)
        return torch.logsumexp(z, 2) - math.log(K) + s0 * beta
    Xv, yv, wv = centre(D["Xv"]), D["yv"].astype(np.int64), D["wv"]
    sw = torch.ones(len(y), device=dev)
    sw[torch.from_numpy(D["tas"]).to(dev)] = c["tas_weight"]
    tau = c["tau"]
    curve, best, bad, t0 = [], None, 0, time.time()
    for ep in range(1, c["epochs"] + 1):
        perm = epoch_rows()
        tl, tn = 0.0, 0
        for i in range(0, len(perm), c["bs"]):
            bi = perm[i:i + c["bs"]]
            xb = Xc[bi] if on_dev else Xc[bi.cpu()].to(dev, non_blocking=True)
            z = logits(xb.float()) + tau * logpi
            ce = torch.nn.functional.cross_entropy(z, yt[bi], reduction="none")
            loss = (ce * sw[bi]).sum() / sw[bi].sum()
            opt.zero_grad(set_to_none=True)
            loss.backward()
            opt.step()
            sched.step()
            tl += float(loss) * len(bi)
            tn += len(bi)
            if os.environ.get("BH_MAXSTEPS") and tn >= int(os.environ["BH_MAXSTEPS"]) * c["bs"]:
                break  # smoke test
        with torch.no_grad():
            pv = torch.cat([logits(Xv[j:j + 4096].float()).argmax(1) for j in range(0, len(Xv), 4096)]).cpu().numpy()
        _, inv = np.unique(yv, return_inverse=True)
        ma = float((np.bincount(inv, pv == yv) / np.bincount(inv)).mean())
        r = {"epoch": ep, "train_loss": tl / tn, "val_top1_sp": ma, "s": round(time.time() - t0, 1)}
        curve.append(r)
        log(f"  {c['name']} ep {ep}: train {r['train_loss']:.4f} val sp {ma:.4f} ({r['s']} s)")
        if best is None or ma > best[0]:
            st = {"W": (s0 * (W0 + Dw)).detach().cpu().numpy().astype(np.float16), "b": (s0 * beta).detach().cpu().numpy()}
            if A is not None:
                st.update(A=A.detach().cpu().numpy(), a=a_.detach().cpu().numpy(), U=U.detach().cpu().numpy())
            best, bad = (ma, ep, st), 0
        else:
            bad += 1
            if bad >= c["patience"]:
                break
    info = {"best_epoch": best[1], "best_val_top1_sp": best[0], "seconds": round(time.time() - t0, 1), "K": K}
    return curve, best[2], info, nc_np


def save(path, c, st, info, curve, n_c):
    np.savez(path, **st, n_c=n_c.astype(np.int32), meta=np.array(json.dumps({"cfg": c, "info": info, "curve": curve})))


def cmd_train(a):
    dev = "cuda" if __import__("torch").cuda.is_available() else "mps"
    D = dict(np.load(a.data))
    os.makedirs(a.out, exist_ok=True)
    for s in a.cfgs:
        c = dict(BASE, **json.loads(s))
        curve, st, info, n_c = train(c, D, dev, a.protos, lambda m: print(m, flush=True))
        save(os.path.join(a.out, c["name"] + ".npz"), c, st, info, curve, n_c)
        print(c["name"], info, flush=True)


def cmd_vm(a):
    B = a.bucket.rstrip("/")
    W = a.work
    od = os.path.join(W, "bank_runs")
    os.makedirs(od, exist_ok=True)
    sh = lambda *x: subprocess.run(list(x), check=True)  # noqa: E731
    sh("gcloud", "storage", "cp", f"{B}/bank/cfgs.json", W, "--quiet")
    cfgs = json.load(open(os.path.join(W, "cfgs.json")))
    r = subprocess.run(["gcloud", "storage", "ls", f"{B}/bank/runs/"], capture_output=True, text=True)
    have = {os.path.basename(l)[:-4] for l in r.stdout.split() if l.endswith(".npz")}
    todo = [dict(BASE, **c) for c in cfgs if c["name"] not in have]
    print(f"todo: {[c['name'] for c in todo]}", flush=True)
    if not todo:
        return
    pd = os.path.join(W, "protos")
    os.makedirs(pd, exist_ok=True)
    D = dict(np.load(os.path.join(W, "data-final.npz")))
    for c in todo:
        if c["head"].startswith("mproto"):  # fetched per run (the laptop may upload them late)
            f = f"proto{c['head'].split(':')[1]}.npz"
            if not os.path.exists(os.path.join(pd, f)) and subprocess.run(
                    ["gcloud", "storage", "cp", f"{B}/bank/{f}", pd, "--quiet"]).returncode != 0:
                print(f"{c['name']}: {f} not in GCS yet — skipped", flush=True)
                continue
        curve, st, info, n_c = train(c, D, "cuda", pd, lambda m: print(m, flush=True))
        p = os.path.join(od, c["name"] + ".npz")
        save(p, c, st, info, curve, n_c)
        sh("gcloud", "storage", "cp", p, f"{B}/bank/runs/", "--quiet")
        print(f"{c['name']}: {info}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("train")
    p.add_argument("--data", required=True)
    p.add_argument("--protos")
    p.add_argument("--out", required=True)
    p.add_argument("cfgs", nargs="+")
    p = sub.add_parser("vm")
    p.add_argument("--bucket", required=True)
    p.add_argument("--work", required=True)
    a = ap.parse_args()
    {"train": cmd_train, "vm": cmd_vm}[a.cmd](a)


if __name__ == "__main__":
    main()

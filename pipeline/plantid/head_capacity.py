#!/usr/bin/env python3
"""Was the v2 linear head UNDERTRAINED on common classes, and can a better head
(instead of the Tasmania-box kNN bank) close the gap the bank fills? Analysis
only — the shipped files and the other scripts are untouched (bank_analysis.py's
loaders, Scorer, val/test protocol and strict ≤ 200 m split are imported, not
copied; the training loop follows bank_heads.train = train_v2's final recipe).

Hypothesis: the final recipe (`final-cb50-s1`) draws K = 50 photos per class per
epoch × 12 epochs = 600 draws (with replacement), so a class with ~1,000 photos
never sees ~half of them — often the atypical views a kNN bank exploits.

Heads (cfg "head"; all on unit(unit(x) − μ), balanced softmax with log π from
the data, τ 1.5, text init s0 · centred text, decay toward the init, Tasmanian
photos ×3, scale-kept τ-norm 0.5 post hoc as shipped):
  linear       the v2 head; "epochs" 50 / 100 / 200 (cosine rescaled, 1 warm-up
               epoch); sampler "balanced:K" or "mix:K:u" = per epoch the K/class
               balanced draws PLUS u × as many photos uniform over ALL photos
               (without replacement within the epoch) — the common classes'
               whole spread gets covered while the tail stays protected
  adapter:H    h = normalise(x + U·drop(relu(V x + a))), U = 0 at init (starts
               AS the text-initialised linear head), linear classifier on h;
               "drop" dropout, "freeze_cls" epochs with the classifier frozen
  tip          Tip-Adapter-F: logits = FROZEN final-cb50-s1 head (τ-normed) +
               α · Σ_k exp(−β(1 − x·k̂)) · onehot(label_k) / n_keys(label)^γ;
               keys = a per-class farthest-point training-photo bank
               (bank_prune.py `cov` c200, 85k rows), fine-tuned with α, β; a
               photo never sees its OWN key in training (self-match masked)
  mproto       several prototypes per class ("representative views"), ADAPTIVE K_c
               ("kbreaks" [[50, 2], [150, 4], [300, 8]] = 1 below 50 photos, …);
               class score T·(logsumexp_k(z_ck / T) − log K_c), T learned (init
               "mp_T" 2); warm start from the trained linear head of the same seed
               (final-cb50-s<seed>; "mp_init" "text" = cold start from the text
               init, the recipe's 12 epochs): prototype k = W_c + γ‖W_c‖(ĉ_k − mean ĉ) with ĉ
               the class's spherical k-means centres (mean-preserving, so the pooled
               logit starts AT the linear one — γ = 0 reproduces J exactly; raw
               centres as prototypes jump in scale, image–image cosines being far
               larger than image–text ones); "mp_div" = penalty on the mean
               off-diagonal prototype cosine (collapse is logged every check)
  res:L:H      pre-LN residual MLP stack h += Linear·Dropout·GELU·Linear(LN h), last
               Linear zero-init (identity start), then renormalise → text-init head
  dense:L:H    DenseNet-style: block l sees LN([x, o_1 … o_l]) projected to 1024
               (projection starts as "the newest input"), h = x + Σ o_l
Selection: every eval check computes J = ½ (AU-val per species re-weighted to
the all-AU-species training-count mix + A-val natural) with the main prior
(bank_analysis MAIN) — the bank analysis' objective — and keeps the best; tests
are read once per final variant (`eval`).

Subcommands (local ones in eval_v2.py's env with FINAL / TAUNORM / V2DATA /
V2PRIOR as bank_analysis.py):
  coverage   expected fraction of each class's photos ever drawn by the final
             sampler, by class-size bucket; the Tasmania bank's and the
             national kNN's gain vs that fraction → HW/coverage.json
  prep       VM inputs → HW/vm/ (val pack, frozen τ-normed head, tip rows)
  measure    relative step cost of linear / adapter / tip / mix on this machine
  smoke      a few hundred steps of every head kind on a 200k-photo subset
  vm         (GPU VM, numpy + torch only) cfgs from $B/hc/cfgs.json (RE-READ
             after each run, so later runs can be added / dropped), results →
             $B/hc/runs/, checkpoints → $B/hc/ckpt/ (SPOT-resumable)
  vmscript   print the VM startup script
  eval       every run in HW/runs/ on the report sets, without and with the
             shipped Tasmania-box bank → HW/report.json + a markdown table
HW = env HC_WORK (default pipeline/cache/plantid/australia/v2/head_capacity).
"""
import json
import math
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

BASE = {"init": "text", "tau": 1.5, "wd": 0.01, "lr": 1e-3, "epochs": 12, "bs": 2048, "patience": 1000, "seed": 1,
        "la_from": "data", "tas_weight": 3.0, "sampler": "balanced:50", "head": "linear", "awd": 0.01,
        "drop": 0.0, "freeze_cls": 0, "eval_every": 0, "tip_alpha": 3.0, "tip_beta": 8.0, "tip_gamma": 0.5,
        "tip_lr": 1e-3, "kbreaks": [[50, 2], [150, 4], [300, 8]], "mp_gamma": 0.15, "mp_T": 2.0, "mp_div": 0.0}
TN = 0.5                      # scale-kept τ-norm, as shipped
CKPT_EVERY = 600.0            # s between SPOT checkpoints


def log(*a):
    print(*a, flush=True)


def HW():
    import train_v2 as V
    return os.environ.get("HC_WORK") or os.path.join(V.V2, "head_capacity")


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def taunorm(W, tn=TN):
    nr = np.linalg.norm(W, axis=-1, keepdims=True).clip(1e-6)
    return W * (nr.mean() / nr) ** tn


# ------------------------------------------------------------ val objective (VM + local)

class ValJ:
    """J = ½ (AU-val top-1 per species re-weighted + A-val natural), head log p
    (log_softmax with merged columns masked) + MAIN prior (λ 1), as
    bank_analysis.Scorer.run / metrics."""

    def __init__(self, vdir, dev):
        import torch
        z = np.load(os.path.join(vdir, "val.npz"))
        self.cm = torch.from_numpy(z["cm"]).to(dev)
        self.lam = float(z["lam"])
        self.S = {}
        for nm in ("AU-val", "A-val"):
            P = np.load(os.path.join(vdir, f"prior-main-{nm}.npy"), mmap_mode="r")
            self.S[nm] = dict(q=torch.from_numpy(z[nm + "/q"]).to(dev), y=z[nm + "/y"], w=z[nm + "/w"],
                              inv=z[nm + "/inv"], wcls=z[nm + "/wcls"], b19=z[nm + "/b19"],
                              P=torch.from_numpy(np.ascontiguousarray(P)).to(dev))

    TEMPS = (1.0, 1.25, 1.5, 2.0, 3.0)

    def __call__(self, f):
        """J at the best global temperature t of the image term (logits / t before the
        prior; long training sharpens the head, so a fixed t = 1 would confound
        calibration with ranking); out["t"] = that t, out["J_t1"] = J at t = 1."""
        import torch
        res = {}
        with torch.no_grad():
            for nm, S in self.S.items():
                prs = {t: [] for t in self.TEMPS}
                for i in range(0, len(S["q"]), 2048):
                    Z_ = f(S["q"][i:i + 2048].float()) + self.cm
                    Pp = self.lam * S["P"][i:i + 2048].float()
                    for t in self.TEMPS:
                        prs[t].append((torch.log_softmax(Z_ / t, 1) + Pp).argmax(1).cpu().numpy())
                m = S["y"] >= 0
                for t in self.TEMPS:
                    hit = (np.concatenate(prs[t]) == S["y"])[m]
                    p1 = np.bincount(S["inv"], hit) / np.bincount(S["inv"])
                    res.setdefault(t, {})[nm] = {
                        "nat": float((hit * S["w"][m]).sum() / S["w"][m].sum()), "sp": float(p1.mean()),
                        "rw": float((p1 * S["wcls"]).sum() / S["wcls"].sum()),
                        "b19": float(p1[S["b19"]].mean()) if S["b19"].any() else None}
        J = {t: 0.5 * (r["AU-val"]["rw"] + r["A-val"]["nat"]) for t, r in res.items()}
        tb = max(J, key=J.get)
        out = dict(res[tb], J=J[tb], t=tb, J_t1=J[1.0])
        return out


# ------------------------------------------------------------ multi-prototype helpers

def mp_kc(n_c, kbreaks):
    """Adaptive K per class: 1 below the first break, then K of the last break ≤ n_c."""
    Kc = np.ones(len(n_c), np.int64)
    for t, k in kbreaks:
        Kc[np.asarray(n_c) >= t] = k
    return Kc


def mp_blocks(Kc):
    """Prototype rows grouped by K, then class (ascending), then slot →
    [(K, classes, row_start, row_end)] (the layout is a function of Kc alone)."""
    out, a = [], 0
    for K in sorted(np.unique(Kc)):
        cls = np.nonzero(Kc == K)[0]
        out.append((int(K), cls, a, a + K * len(cls)))
        a += K * len(cls)
    return out


def mp_scores(z, blocks, C, T):
    """Per-class soft pooling of prototype logits z (n × R): T·(logsumexp_k(z_ck / T)
    − log K_c) — the mean for T → ∞, the max for T → 0, and EXACTLY the linear logit
    when a class's prototypes coincide (so log K_c keeps classes with different K
    on one scale before the location prior is added)."""
    import torch
    out = z.new_empty(z.shape[0], C)
    for K, cls, a, b in blocks:
        zz = z[:, a:b]
        if K == 1:
            out[:, cls] = zz
        else:
            out[:, cls] = T * (torch.logsumexp(zz.reshape(len(z), -1, K) / T, -1) - math.log(K))
    return out


def mp_taunorm(W, blocks, C, tn=TN):
    """Scale-kept τ-norm on the per-class norm (mean over a class's prototypes)."""
    import torch
    nr = W.norm(dim=1)
    cn = torch.zeros(C, device=W.device, dtype=W.dtype)
    row_cls = torch.empty(len(W), dtype=torch.long, device=W.device)
    for K, cls, a, b in blocks:
        cl = torch.as_tensor(cls, device=W.device)
        row_cls[a:b] = cl.repeat_interleave(K)
        cn[cl] = nr[a:b].reshape(-1, K).mean(1)
    cn = cn.clamp(min=1e-6)
    return W * ((cn.mean() / cn) ** tn)[row_cls][:, None]


def spherical_kmeans(X, K, rng, iters=12):
    """X (n × d unit, torch) → K unit centres; farthest-point seeding from a random
    photo (no host syncs); an empty cluster keeps its previous centre."""
    import torch
    F = torch.nn.functional
    n = len(X)
    i0 = int(rng.integers(n))
    cen = X.new_zeros(K, X.shape[1])
    cen[0] = X[i0]
    best = X @ X[i0]
    for k in range(1, K):          # farthest-point seeding, no host syncs
        j = best.argmin()
        cen[k] = X[j]
        best = torch.maximum(best, X @ X[j])
    for _ in range(iters):
        a = (X @ cen.T).argmax(1)
        new = torch.zeros_like(cen).index_add_(0, a, X)
        cnt = torch.bincount(a, minlength=K)
        cen = torch.where((cnt > 0)[:, None], F.normalize(new, dim=-1), cen)   # empty cluster keeps its centre
    return cen


def make_deep(kind, L, H, drop):
    """Residual feature stack on the frozen embedding, identity at init:
    res    h_{l+1} = h_l + f_l(LN(h_l)), f_l = Linear(d→H)·GELU·Dropout·Linear(H→d), last Linear zero-init
    dense  o_{l+1} = f_l(P_l LN([x, o_1 … o_l])) (P_l: (l+1)·d → d), h = x + Σ o_l (DenseNet-style
           input concatenation; the residual sum keeps the identity start)."""
    import torch
    nn = torch.nn

    class Deep(nn.Module):
        def __init__(self, d=1024):
            super().__init__()
            self.kind = kind
            self.ln = nn.ModuleList(nn.LayerNorm(d * ((i + 1) if kind == "dense" else 1)) for i in range(L))
            self.proj = nn.ModuleList(nn.Linear(d * (i + 1), d, bias=False) for i in range(L)) if kind == "dense" else None
            self.f1 = nn.ModuleList(nn.Linear(d, H) for _ in range(L))
            self.f2 = nn.ModuleList(nn.Linear(H, d) for _ in range(L))
            self.drop = nn.Dropout(drop)
            for m in self.f2:
                nn.init.zeros_(m.weight)
                nn.init.zeros_(m.bias)
            if self.proj is not None:  # start as "look at the newest input" (identity on x for block 0)
                for i, p in enumerate(self.proj):
                    with torch.no_grad():
                        p.weight.zero_()
                        p.weight[:, i * d:(i + 1) * d] = torch.eye(d)

        def forward(self, x):
            if self.kind == "res":
                h = x
                for ln, f1, f2 in zip(self.ln, self.f1, self.f2):
                    h = h + f2(self.drop(torch.nn.functional.gelu(f1(ln(h)))))
                return h
            outs, h = [x], x
            for ln, p, f1, f2 in zip(self.ln, self.proj, self.f1, self.f2):
                o = f2(self.drop(torch.nn.functional.gelu(f1(p(ln(torch.cat(outs, -1)))))))
                outs.append(o)
                h = h + o
            return h
    return Deep()


# ------------------------------------------------------------ training

def train(c, D, dev, vdir, log=log, ckpt=None, max_steps=None):
    """c: cfg; D: data dict (T, s0, mu, Xtr, ytr, tas); vdir: val pack (val.npz,
    priors, frozen head, tip rows); ckpt: (load_fn, save_fn) for SPOT resume."""
    import torch
    F = torch.nn.functional
    torch.manual_seed(c["seed"])
    C = D["T"].shape[0]
    mu = torch.from_numpy(D["mu"].astype(np.float32)).to(dev)

    def centre(X):
        out = []
        for i in range(0, len(X), 65536):
            x = torch.from_numpy(np.asarray(X[i:i + 65536]).astype(np.float32)).to(dev)
            out.append(F.normalize(F.normalize(x, dim=-1) - mu, dim=-1).half())
        return torch.cat(out)
    y = np.asarray(D["ytr"]).astype(np.int64)
    N = len(y)
    on_dev = N * 1024 * 2 <= float(os.environ.get("V2_GPU_BYTES", 8e9))
    Xc = centre(D["Xtr"]) if on_dev else torch.cat([centre(D["Xtr"][i:i + 262144]).cpu() for i in range(0, N, 262144)])
    yt = torch.from_numpy(y).to(dev)
    nc_np = np.bincount(y, minlength=C).astype(np.float64)
    m_t = torch.from_numpy(nc_np.astype(np.float32)).to(dev)
    logpi = torch.where(m_t > 0, torch.log(m_t / m_t.sum()), torch.full_like(m_t, -1e4))
    sp = c["sampler"].split(":")
    K_ = float(sp[1])
    u_ = float(sp[2]) if sp[0] == "mix" else 0.0
    m_c = np.where(nc_np > 0, K_, 0.0)
    srt = np.argsort(y, kind="stable")
    starts = np.r_[0, np.cumsum(np.bincount(y, minlength=C))]
    ep_rng = np.random.default_rng(c["seed"] + 1)
    n_bal = int(m_c.sum())
    n_uni = int(round(u_ * n_bal))

    def epoch_rows():
        cls = np.nonzero(m_c > 0)[0]
        cc = np.repeat(cls, m_c[cls].astype(np.int64))
        rows = srt[starts[cc] + (ep_rng.random(len(cc)) * nc_np[cc]).astype(np.int64)]
        if n_uni:
            rows = np.r_[rows, ep_rng.choice(N, n_uni, replace=n_uni > N)]
        return torch.from_numpy(ep_rng.permutation(rows)).to(dev)

    Tn = D["T"].astype(np.float32)
    Tc = torch.from_numpy(unit(Tn - Tn.mean(0))).to(dev)
    s0 = float(D["s0"])
    kind, _, arg = c["head"].partition(":")
    groups, extra = [], {}
    if kind == "tip":
        hz = np.load(os.path.join(vdir, "frozen-head.npz"))
        Wf = torch.from_numpy(hz["W"].astype(np.float32)).to(dev)   # τ-normed final-cb50-s1
        bf = torch.from_numpy(hz["b"].astype(np.float32)).to(dev)
        rows = np.load(os.path.join(vdir, "rows-tip.npy")).astype(np.int64)
        keys = torch.nn.Parameter(Xc[torch.from_numpy(rows).to(Xc.device)].to(dev).float())
        lab = yt[torch.from_numpy(rows).to(dev)]
        kof = torch.full((N,), -1, dtype=torch.long, device=dev)
        kof[torch.from_numpy(rows).to(dev)] = torch.arange(len(rows), device=dev)
        nk = torch.bincount(lab, minlength=C).float().clamp(min=1)
        knorm = nk ** -c["tip_gamma"]
        la = torch.nn.Parameter(torch.tensor(math.log(c["tip_alpha"]), device=dev))
        lb = torch.nn.Parameter(torch.tensor(math.log(c["tip_beta"]), device=dev))
        groups.append({"params": [keys, la, lb], "weight_decay": 0.0, "lr": c["tip_lr"]})
        Dw = beta = None
    elif kind == "mproto":
        # warm start from the trained linear head of the same seed (final-cb50-s<seed>)
        if c.get("mp_init", "warm") == "text":   # cold start: the recipe's text init, offsets on top
            hz = {"W": (s0 * Tc).cpu().numpy(), "b": np.zeros(C, np.float32)}
        else:
            hz = np.load(os.path.join(vdir, f"head-s{c['seed']}.npz"))
        Wt = hz["W"].astype(np.float32)
        Kc = mp_kc(nc_np, c["kbreaks"])
        blocks = mp_blocks(Kc)
        W0 = np.zeros((int(Kc.sum()), Wt.shape[1]), np.float32)
        nW = np.linalg.norm(Wt, axis=1)
        g = c["mp_gamma"]
        km_rng = np.random.default_rng(1000 + c["seed"])
        t_km = time.time()
        for K, cls, a, b in blocks:
            if K == 1:
                W0[a:b] = Wt[cls]
                continue
            for j, cl in enumerate(cls):
                rws = srt[starts[cl]:starts[cl + 1]]
                if len(rws) > 4000:
                    rws = np.sort(km_rng.choice(rws, 4000, replace=False))
                X = Xc[torch.from_numpy(rws).to(Xc.device)].to(dev).float()
                cen = spherical_kmeans(X, K, km_rng)                                # K × d unit
                # mean-preserving offsets: prototype k = W_c + γ‖W_c‖ (ĉ_k − mean ĉ) — the K
                # vectors point toward the class's k-means centres, their mean IS the trained
                # vector, so the pooled logit starts at (≥) the linear one: no calibration jump
                # from image–image cosines being far larger than image–text ones
                off = cen - cen.mean(0, keepdim=True)
                W0[a + j * K:a + (j + 1) * K] = (torch.from_numpy(Wt[cl]).to(dev)[None] + g * float(nW[cl]) * off).cpu().numpy()
        log(f"  {c['name']}: k-means init {len(W0)} prototypes ({time.time() - t_km:.0f} s); K_c "
            + str({int(k): int((Kc == k).sum()) for k in np.unique(Kc)}))
        W0s = torch.from_numpy(W0 / s0).to(dev)
        blocks_t = [(K, torch.from_numpy(cls).to(dev), a, b) for K, cls, a, b in blocks]
        beta0 = torch.from_numpy(hz["b"].astype(np.float32) / s0).to(dev)
        Dw = torch.nn.Parameter(torch.zeros_like(W0s))
        beta = torch.nn.Parameter(torch.zeros(C, device=dev))
        lT = torch.nn.Parameter(torch.tensor(math.log(c["mp_T"]), device=dev))
        groups.append({"params": [Dw, beta], "weight_decay": c["wd"]})
        groups.append({"params": [lT], "weight_decay": 0.0})
    else:
        Dw = torch.nn.Parameter(torch.zeros_like(Tc))
        beta = torch.nn.Parameter(torch.zeros(C, device=dev))
        groups.append({"params": [Dw, beta], "weight_decay": c["wd"]})
    V_ = a_ = U_ = deep = None
    if kind in ("res", "dense"):
        L_, H_ = (int(v) for v in arg.split(":"))
        deep = make_deep(kind, L_, H_, c["drop"]).to(dev)
        groups.append({"params": list(deep.parameters()), "weight_decay": c["awd"]})
    if kind == "adapter":
        H = int(arg)
        V_ = torch.nn.Parameter(torch.randn(H, Tc.shape[1], device=dev) / math.sqrt(Tc.shape[1]))
        a_ = torch.nn.Parameter(torch.zeros(H, device=dev))
        U_ = torch.nn.Parameter(torch.zeros(Tc.shape[1], H, device=dev))
        groups.append({"params": [V_, a_, U_], "weight_decay": c["awd"]})
    opt = torch.optim.AdamW(groups, lr=c["lr"], betas=(0.9, 0.999))
    spe = -(-(n_bal + n_uni) // c["bs"])
    total, warm = spe * c["epochs"], spe

    def lr_at(s):
        return (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm)))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lr_at)

    def feats(x, train_=False):
        if deep is not None:
            deep.train(train_)
            return F.normalize(deep(x), dim=-1)
        if V_ is None:
            return x
        h = torch.relu(x @ V_.T + a_)
        if train_ and c["drop"]:
            h = F.dropout(h, c["drop"])
        return F.normalize(x + h @ U_.T, dim=-1)

    def cache(x, bi=None):
        kn = F.normalize(keys, dim=-1)
        with torch.autocast(device_type="cuda" if dev == "cuda" else "cpu", dtype=torch.bfloat16, enabled=dev == "cuda"):
            s = x @ kn.T
        A = torch.exp(-lb.exp() * (1 - s.float()))
        if bi is not None:  # a training photo never matches its own key
            kk = kof[bi]
            hit = kk >= 0
            if hit.any():
                A = A.index_put((torch.nonzero(hit)[:, 0], kk[hit]), torch.zeros(int(hit.sum()), device=dev))
        out = torch.zeros(len(x), C, device=dev).index_add_(1, lab, A)
        return la.exp() * out * knorm

    def logits(x, bi=None, train_=False):
        if kind == "tip":
            return x @ Wf.T + bf + cache(x, bi)
        if kind == "mproto":
            return mp_scores(x @ (s0 * (W0s + Dw)).T, blocks_t, C, lT.exp()) + s0 * (beta0 + beta)
        f = feats(x, train_)
        return f @ (s0 * (Tc + Dw)).T + s0 * beta

    def diversity():
        """Mean off-diagonal cosine between a class's prototypes (K_c > 1)."""
        Wa = W0s + Dw
        tot, n = 0.0, 0
        for K, cls, a, b in blocks_t:
            if K == 1:
                continue
            Wn = F.normalize(Wa[a:b].view(-1, K, Wa.shape[1]), dim=-1)
            G = Wn @ Wn.transpose(1, 2)
            tot = tot + (G.sum((1, 2)) - K).sum() / (K * (K - 1))
            n += len(cls)
        return tot / max(n, 1)

    def eval_fn():
        """Logit function for val / storage: τ-norm on the classifier (not for tip:
        its frozen head is τ-normed already)."""
        if kind == "tip":
            return lambda q: logits(q)
        if kind == "mproto":
            Wn = mp_taunorm(s0 * (W0s + Dw), blocks_t, C)
            bb, T_ = s0 * (beta0 + beta), lT.exp()
            return lambda q: mp_scores(q @ Wn.T, blocks_t, C, T_) + bb
        W = s0 * (Tc + Dw)
        nr = W.norm(dim=1, keepdim=True).clamp(min=1e-6)
        Wn = W * (nr.mean() / nr) ** TN
        return lambda q: feats(q) @ Wn.T + s0 * beta

    def state():
        if kind == "tip":
            return {"keys": F.normalize(keys, dim=-1).detach().cpu().numpy().astype(np.float16),
                    "lab": lab.cpu().numpy().astype(np.int32), "alpha": float(la.exp()), "beta": float(lb.exp()),
                    "gamma": c["tip_gamma"], "W": hz["W"].astype(np.float16), "b": hz["b"].astype(np.float32),
                    "tn_applied": 1}
        if kind == "mproto":
            return {"W": (s0 * (W0s + Dw)).detach().cpu().numpy().astype(np.float16),
                    "b": (s0 * (beta0 + beta)).detach().cpu().numpy(), "Kc": Kc.astype(np.int16),
                    "T": float(lT.exp()), "tn_applied": 0}
        st = {"W": (s0 * (Tc + Dw)).detach().cpu().numpy().astype(np.float16),
              "b": (s0 * beta).detach().cpu().numpy(), "tn_applied": 0}
        if V_ is not None:
            st.update(V=V_.detach().cpu().numpy(), a=a_.detach().cpu().numpy(), U=U_.detach().cpu().numpy())
        if deep is not None:
            st.update({"deep." + k: v.detach().cpu().numpy() for k, v in deep.state_dict().items()})
        return st
    VJ = ValJ(vdir, dev)
    sw = torch.ones(N, device=dev)
    sw[torch.from_numpy(np.asarray(D["tas"])).to(dev)] = c["tas_weight"]
    tau = c["tau"]
    ev_every = c["eval_every"] or max(1, c["epochs"] // 25)
    plist = [p for g in groups for p in g["params"]]
    curve, best, bad, ep0, t0, tck = [], None, 0, 1, time.time(), time.time()
    if ckpt is not None:
        ck = ckpt[0]()
        if ck is not None:
            for p, v in zip(plist, ck["params"]):
                p.data.copy_(v.to(dev))
            opt.load_state_dict(ck["opt"])
            sched.load_state_dict(ck["sched"])
            ep_rng.bit_generator.state = ck["rng"]
            torch.set_rng_state(ck["torch_rng"])
            curve, best, bad, ep0 = ck["curve"], ck["best"], ck["bad"], ck["ep"] + 1
            log(f"  {c['name']}: resumed after epoch {ck['ep']}")
    steps = 0
    for ep in range(ep0, c["epochs"] + 1):
        perm = epoch_rows()
        tl, tn = 0.0, 0
        for i in range(0, len(perm), c["bs"]):
            bi = perm[i:i + c["bs"]]
            xb = Xc[bi] if on_dev else Xc[bi.cpu()].to(dev, non_blocking=True)
            z = logits(xb.float(), bi, True) + tau * logpi
            ce = F.cross_entropy(z, yt[bi], reduction="none")
            loss = (ce * sw[bi]).sum() / sw[bi].sum()
            if kind == "mproto" and c["mp_div"]:
                loss = loss + c["mp_div"] * diversity()
            opt.zero_grad(set_to_none=True)
            loss.backward()
            if kind != "tip" and ep <= c["freeze_cls"]:
                Dw.grad = beta.grad = None
            opt.step()
            sched.step()
            tl += float(loss) * len(bi)
            tn += len(bi)
            steps += 1
            if max_steps and steps >= max_steps:
                break
        r = {"epoch": ep, "train_loss": tl / max(tn, 1), "s": round(time.time() - t0, 1)}
        if ep % ev_every == 0 or ep == c["epochs"] or (max_steps and steps >= max_steps):
            v = VJ(eval_fn())
            r.update(J=v["J"], t=v["t"], J_t1=v["J_t1"], au_rw=v["AU-val"]["rw"], au_sp=v["AU-val"]["sp"], a_nat=v["A-val"]["nat"],
                     au_b19=v["AU-val"]["b19"])
            if kind == "tip":
                r.update(alpha=float(la.exp()), beta=float(lb.exp()))
            if kind == "mproto":
                with torch.no_grad():
                    r.update(T=float(lT.exp()), proto_cos=float(diversity()))
                log(f"  {c['name']} ep {ep}: T {r['T']:.3f}, mean prototype cos {r['proto_cos']:.3f}")
            if best is None or v["J"] > best[0]:
                best, bad = (v["J"], ep, state(), v), 0
            else:
                bad += 1
            log(f"  {c['name']} ep {ep}: train {r['train_loss']:.4f} J {v['J']:.4f} t {v['t']} (J t1 {v['J_t1']:.4f}; AU rw {v['AU-val']['rw']:.4f}"
                f" sp {v['AU-val']['sp']:.4f}, A nat {v['A-val']['nat']:.4f}) ({r['s']} s)")
            curve.append(r)
            if ckpt is not None and time.time() - tck > CKPT_EVERY and ep < c["epochs"]:
                ckpt[1]({"params": [p.detach().cpu() for p in plist], "opt": opt.state_dict(),
                         "sched": sched.state_dict(), "rng": ep_rng.bit_generator.state,
                         "torch_rng": torch.get_rng_state(), "curve": curve, "best": best, "bad": bad, "ep": ep})
                tck = time.time()
            if bad >= c["patience"]:
                break
        else:
            curve.append(r)
        if max_steps and steps >= max_steps:
            break
    last = state()   # the end of the schedule, whatever J says (long-training comparison)
    info = {"best_epoch": best[1], "best_J": best[0], "best_val": best[3], "seconds": round(time.time() - t0, 1),
            "steps_per_epoch": spe, "draws_per_epoch": n_bal + n_uni}
    info["last_epoch"] = curve[-1]["epoch"]
    return curve, best[2], info, nc_np, last


def save(path, c, st, info, curve, n_c):
    np.savez(path, **st, n_c=n_c.astype(np.int32), meta=np.array(json.dumps({"cfg": c, "info": info, "curve": curve})))


# ------------------------------------------------------------ VM

def cmd_vm(bucket, work):
    import torch
    B = bucket.rstrip("/") + "/hc"
    od = os.path.join(work, "hc_runs")
    os.makedirs(od, exist_ok=True)
    sh = lambda *x: subprocess.run(list(x), check=True)  # noqa: E731
    vdir = os.path.join(work, "hcv")
    os.makedirs(vdir, exist_ok=True)
    for f in ("val.npz", "prior-main-AU-val.npy", "prior-main-A-val.npy", "frozen-head.npz", "rows-tip.npy",
              "head-s0.npz", "head-s1.npz"):
        if not os.path.exists(os.path.join(vdir, f)):
            sh("gcloud", "storage", "cp", f"{B}/vm/{f}", vdir, "--quiet")
    D = None
    tried = set()
    while True:
        sh("gcloud", "storage", "cp", f"{B}/cfgs.json", work, "--quiet")
        cfgs = json.load(open(os.path.join(work, "cfgs.json")))
        r = subprocess.run(["gcloud", "storage", "ls", f"{B}/runs/"], capture_output=True, text=True)
        have = {os.path.basename(l)[:-4] for l in r.stdout.split() if l.endswith(".npz")}
        todo = [dict(BASE, **c) for c in cfgs if c["name"] not in have and c["name"] not in tried]
        log(f"todo: {[c['name'] for c in todo]}")
        if not todo:
            return
        c = todo[0]
        tried.add(c["name"])
        if D is None:
            D = dict(np.load(os.path.join(work, "data-final.npz")))
        cp = os.path.join(work, f"ck-{c['name']}.pt")
        g = f"{B}/ckpt/{c['name']}.pt"

        def ck_load():
            if subprocess.run(["gcloud", "storage", "cp", g, cp, "--quiet"]).returncode != 0:
                return None
            return torch.load(cp, weights_only=False)

        def ck_save(obj):
            torch.save(obj, cp)
            subprocess.run(["gcloud", "storage", "cp", cp, g, "--quiet"])
        curve, st, info, n_c, last = train(c, D, "cuda", vdir, log, (ck_load, ck_save))
        p = os.path.join(od, c["name"] + ".npz")
        if info["last_epoch"] != info["best_epoch"] and c["epochs"] > 12:
            pl = os.path.join(od, c["name"] + "-last.npz")
            save(pl, dict(c, name=c["name"] + "-last"), last, info, curve, n_c)
            sh("gcloud", "storage", "cp", pl, f"{B}/runs/", "--quiet")
        save(p, c, st, info, curve, n_c)
        sh("gcloud", "storage", "cp", p, f"{B}/runs/", "--quiet")
        log(f"{c['name']}: {json.dumps(info)}")
        torch.cuda.empty_cache()


VMSCRIPT = r"""#!/usr/bin/env bash
# head_capacity.py VM startup script: runs as root on EVERY boot (a SPOT
# preemption = STOP → `start` resumes from $B/hc/ckpt/ + skips finished runs).
# Log → $B/log/hc.log every minute; powers off when done, whatever the outcome.
set -uo pipefail
md() { curl -sf -H Metadata-Flavor:Google \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
B=$(md izzy-bucket)
W=/opt/izzy; mkdir -p "$W"; cd "$W"
exec >> "$W/hc.log" 2>&1
echo "== boot $(date -u +%FT%TZ)"
( while sleep 60; do gcloud storage cp "$W/hc.log" "$B/log/hc.log" --quiet 2>/dev/null; done ) &
finish() { echo "== end $(date -u +%FT%TZ) ($1)"; gcloud storage cp "$W/hc.log" "$B/log/hc.log" --quiet
           shutdown -h now; exit 0; }
for i in $(seq 90); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || finish "no GPU"
export HOME=/root PATH=/root/.local/bin:$PATH
uv --version 2>/dev/null | grep -q "^uv " || { rm -f /root/.local/bin/uv /root/.local/bin/uvx
  curl -LsSf https://astral.sh/uv/install.sh | sh; }
E="uv run --python 3.12 --with torch==2.7.* --with numpy<2.3 python3 -u"
gcloud storage cp "$B/hc/head_capacity.py" . --quiet || finish "no code"
[ -f data-final.npz ] || gcloud storage cp "$B/v2/data-final.npz" . --quiet || finish "no v2 data"
$E -c "import torch; print('env ok', torch.__version__, torch.cuda.is_available())" | grep -q "env ok" \
  || { uv cache clean; $E -c "import torch; print('env ok after clean', torch.__version__)"; }
export V2_GPU_BYTES=1.6e10
$E head_capacity.py vm "$B" "$W"; rc=$?
echo "head_capacity exit $rc"; [ $rc = 0 ] || finish "head_capacity failed"
finish ok
"""


# ------------------------------------------------------------ local: coverage

def size_bucket(n):
    edges = [1, 10, 50, 200, 500, 1000, 3000, 10 ** 9]
    names = ["1-9", "10-49", "50-199", "200-499", "500-999", "1000-2999", "3000+"]
    return np.digitize(n, edges[1:-1]), names


def cmd_coverage():
    import bank_analysis as BA
    import torch
    import train_v2 as V
    z = np.load(os.path.join(V.V2, "runs", BA.RUN + ".npz"))
    meta = json.loads(str(z["meta"]))
    E = len(meta["curve"])
    K = float(meta["cfg"]["sampler"].split(":")[1])
    draws = K * E
    n = z["n_c"].astype(np.float64)
    act = n > 0
    f = np.where(act, 1 - np.exp(draws * np.log1p(-1 / np.maximum(n, 1.0000001))), 0)
    f[n == 1] = 1.0
    bk, names = size_bucket(n)
    out = {"run": BA.RUN, "epochs": E, "K": K, "draws_per_class": draws,
           "photos_total": int(n.sum()), "photos_ever_drawn": float((n * f).sum() / n.sum()), "by_size": []}
    for i, nm in enumerate(names):
        m = act & (bk == i)
        if not m.any():
            continue
        out["by_size"].append({"bucket": nm, "classes": int(m.sum()), "photos": int(n[m].sum()),
                               "photo_share": float(n[m].sum() / n.sum()),
                               "frac_drawn_class_mean": float(f[m].mean()),
                               "frac_drawn_photo_weighted": float((n[m] * f[m]).sum() / n[m].sum()),
                               "draws_per_photo_median": float(np.median(draws / n[m]))})
    # gains vs coverage: shipped Tasmania bank (flipdump M vs F, A-val + A-test) and the
    # national kNN (AU-val, natscore_val best) — per photo, by its class's fraction drawn
    Z = BA.load()
    ntr = Z["n_tr"].astype(np.float64)
    fz = np.where(ntr > 0, 1 - np.exp(draws * np.log1p(-1 / np.maximum(ntr, 1.0000001))), 0)
    fz[ntr == 1] = 1.0
    fd = np.load(os.path.join(BA.WORK, "flipdump.npz"))
    fbins = [0, 0.3, 0.5, 0.7, 0.9, 0.99, 1.01]
    fnames = ["<0.3", "0.3-0.5", "0.5-0.7", "0.7-0.9", "0.9-0.99", ">=0.99"]

    def by_f(y, pa, pb, w=None):
        m = y >= 0
        fc = fz[np.maximum(y, 0)]
        b = np.digitize(fc, fbins[1:-1])
        rows = []
        for i, nm in enumerate(fnames):
            s = m & (b == i)
            if not s.any():
                continue
            ha, hb = (pa == y)[s], (pb == y)[s]
            rows.append({"frac_drawn": nm, "photos": int(s.sum()), "classes": int(len(np.unique(y[s]))),
                         "acc_without": float(ha.mean()), "acc_with": float(hb.mean()),
                         "gain_pt": float(100 * (hb.mean() - ha.mean())),
                         "gained": int((~ha & hb).sum()), "lost": int((ha & ~hb).sum()),
                         "median_n_train": float(np.median(ntr[y[s]]))})
        return rows
    ya = np.r_[Z["A-val/y"], Z["A-test/y"]]
    out["tas_bank_A_val+test"] = by_f(ya, np.r_[fd["A-val/M"], fd["A-test/M"]], np.r_[fd["A-val/F"], fd["A-test/F"]])
    # sanity: M accuracy on A-test matches the report's natural-mix number
    out["sanity_A-test_M_top1_unweighted"] = float((fd["A-test/M"] == Z["A-test/y"])[Z["A-test/y"] >= 0].mean())
    sc = BA.Scorer(Z)
    nv = json.load(open(os.path.join(BA.WORK, "natscore_val.json")))["national"]["best"]
    nb = np.load(os.path.join(BA.WORK, "natnbrs.npz"))
    ytr = Z["mapv"][np.asarray(BA.npz_memmap(V.DATA, "ytr")).astype(np.int64)]
    lab = torch.from_numpy(ytr).to(sc.dev)
    cnt = torch.bincount(lab, minlength=sc.C).float()
    t0 = sc.run("AU-val")[:, 0]
    fn = BA.nbr_knn(sc, nb["AU-val/v"], nb["AU-val/i"], lab, nv["k"], nv["tau"], nv["beta"], cnt)
    t1 = sc.run("AU-val", fn, nv["om"], nv["floor"])[:, 0]
    out["national_knn_AU-val"] = by_f(Z["AU-val/y"], t0, t1)
    os.makedirs(HW(), exist_ok=True)
    json.dump(out, open(os.path.join(HW(), "coverage.json"), "w"), indent=1)
    log(json.dumps({k: v for k, v in out.items() if k != "by_size"}, indent=1))
    log("by size:")
    for r in out["by_size"]:
        log("  ", r)


# ------------------------------------------------------------ local: VM inputs

def cmd_prep():
    import bank_analysis as BA
    import shutil
    vd = os.path.join(HW(), "vm")
    os.makedirs(vd, exist_ok=True)
    Z = BA.load()
    sc = BA.Scorer(Z)
    out = {"cm": BA.colmask(Z), "lam": np.float32(BA.MAIN[3])}
    mu = Z["mu"].astype(np.float32)
    for nm in ("AU-val", "A-val"):
        y, w = Z[nm + "/y"], Z[nm + "/w"]
        m = y >= 0
        cls, inv = np.unique(y[m], return_inverse=True)
        bk = BA.bucket(sc.n_tr[cls])
        vmix = np.bincount(bk, minlength=4) / len(cls)
        out[nm + "/q"] = BA.BS.unit(BA.BS.unit(Z[nm + "/emb"].astype(np.float32)) - mu[None]).astype(np.float16)
        out[nm + "/y"], out[nm + "/w"], out[nm + "/inv"] = y, w, inv
        out[nm + "/wcls"] = (sc.tgt / np.maximum(vmix, 1e-9))[bk]
        out[nm + "/b19"] = bk == 1
        shutil.copy(os.path.join(BA.WORK, f"prior-main-{nm}.npy"), vd)
    np.savez(os.path.join(vd, "val.npz"), **out)
    W, b = BA.head()   # final-cb50-s1, τ-normed 0.5 (scale kept)
    np.savez(os.path.join(vd, "frozen-head.npz"), W=W.astype(np.float16), b=b.astype(np.float32))
    rp = os.path.join(BA.WORK, "prune", os.environ.get("HC_TIP_ROWS", "rows-cov-c200-85000.npy"))
    shutil.copy(rp, os.path.join(vd, "rows-tip.npy"))
    log(f"prep → {vd}: {sorted(os.listdir(vd))}, tip rows from {rp} ({len(np.load(rp))})")


def small_D(n=200000, seed=0):
    import bank_analysis as BA
    import train_v2 as V
    rng = np.random.default_rng(seed)
    ytr = np.asarray(BA.npz_memmap(V.DATA, "ytr"))
    rows = np.sort(rng.choice(len(ytr), n, replace=False))
    D = {"Xtr": np.asarray(BA.npz_memmap(V.DATA, "Xtr")[rows]), "ytr": ytr[rows],
         "tas": np.asarray(BA.npz_memmap(V.DATA, "tas"))[rows]}
    for k in ("T", "s0", "mu"):
        D[k] = np.asarray(BA.npz_memmap(V.DATA, k))
    return D, rows


def cmd_smoke(measure=False):
    """Every head kind for a few steps on a 200k subset (MPS); with measure, the
    per-step time of each (relative cost vs linear → the L4 bound)."""
    import torch
    D, rows = small_D()
    vd = os.path.join(HW(), "vm")
    # the tip rows index the FULL training set: remap to the subset (keep the ones sampled)
    full = np.load(os.path.join(vd, "rows-tip.npy"))
    pos = np.searchsorted(rows, full)
    ok = (pos < len(rows)) & (rows[np.minimum(pos, len(rows) - 1)] == full)
    sd = os.path.join(HW(), "smoke_vm")
    os.makedirs(sd, exist_ok=True)
    for f in os.listdir(vd):
        if f != "rows-tip.npy" and not os.path.exists(os.path.join(sd, f)):
            os.symlink(os.path.join(vd, f), os.path.join(sd, f))
    np.save(os.path.join(sd, "rows-tip.npy"), pos[ok])
    log(f"subset {len(rows)} photos, tip keys {ok.sum()}")
    cfgs = [{"name": "s-linear", "epochs": 2}, {"name": "s-mix", "epochs": 2, "sampler": "mix:50:1"},
            {"name": "s-ad2048", "epochs": 2, "head": "adapter:2048", "drop": 0.1, "freeze_cls": 1},
            {"name": "s-ad4096", "epochs": 2, "head": "adapter:4096", "drop": 0.1},
            {"name": "s-tip", "epochs": 2, "head": "tip"},
            {"name": "s-mp", "epochs": 2, "head": "mproto", "sampler": "mix:50:1", "kbreaks": [[60, 2], [100, 4]], "mp_gamma": float(os.environ.get("HC_G", 0.15)), "mp_T": 2.0, "mp_init": os.environ.get("HC_MPINIT", "warm")},
            {"name": "s-res4", "epochs": 2, "head": "res:4:2048", "drop": 0.1},
            {"name": "s-dense4", "epochs": 2, "head": "dense:4:2048", "drop": 0.1}]
    if os.environ.get("HC_SMOKE"):
        cfgs = [c for c in cfgs if c["name"] in os.environ["HC_SMOKE"].split(",")]
    res = {}
    steps = int(os.environ.get("HC_STEPS", 60 if measure else 30))
    for c in cfgs:
        c = dict(BASE, **c)
        t = time.time()
        curve, st, info, _, _ = train(c, D, "mps", sd, log, max_steps=steps)
        torch.mps.synchronize()
        res[c["name"]] = {"s_total": round(time.time() - t, 1), "J": info["best_J"], "keys": sorted(st)}
        log(c["name"], res[c["name"]])
    if measure:  # pure step time (no val), same 2048-row batches
        import torch.nn.functional as F
        dev = "mps"
        C = D["T"].shape[0]
        x = F.normalize(torch.randn(2048, 1024, device=dev), dim=-1)
        yb = torch.randint(0, C, (2048,), device=dev)
        W = torch.nn.Parameter(torch.randn(C, 1024, device=dev))
        Kk = torch.nn.Parameter(torch.randn(85000, 1024, device=dev))
        lab = torch.randint(0, C, (85000,), device=dev)

        def t_step(f, n=20):
            for _ in range(3):
                f()
            torch.mps.synchronize()
            t = time.time()
            for _ in range(n):
                f()
            torch.mps.synchronize()
            return (time.time() - t) / n
        res["step_linear_s"] = t_step(lambda: F.cross_entropy(x @ W.T, yb).backward())
        for H in (2048, 4096):
            Vv = torch.nn.Parameter(torch.randn(H, 1024, device=dev))
            Uu = torch.nn.Parameter(torch.zeros(1024, H, device=dev))
            res[f"step_adapter{H}_s"] = t_step(lambda: F.cross_entropy(
                F.normalize(x + torch.relu(x @ Vv.T) @ Uu.T, dim=-1) @ W.T, yb).backward())
        res["step_tip_s"] = t_step(lambda: F.cross_entropy(x @ W.T + torch.zeros(2048, C, device=dev).index_add_(
            1, lab, torch.exp(-8 * (1 - x @ F.normalize(Kk, dim=-1).T))), yb).backward())
        for k in [k for k in res if k.startswith("step_") and k != "step_linear_s"]:
            res[k.replace("_s", "_rel")] = res[k] / res["step_linear_s"]
    json.dump(res, open(os.path.join(HW(), "smoke.json" if not measure else "measure.json"), "w"), indent=1)
    log(json.dumps(res, indent=1))


# ------------------------------------------------------------ local: evaluation

def hc_head_fn(path, tn=None, dev="mps"):
    """head_capacity run → f(q centred, torch) → logits; replaces bank_analysis.head_fn."""
    import torch
    F = torch.nn.functional
    z = np.load(path)
    cfg = json.loads(str(z["meta"]))["cfg"]
    W = z["W"].astype(np.float32)
    mp = None
    if "Kc" in z.files:
        blocks = [(K, torch.from_numpy(cls).to(dev), a, b) for K, cls, a, b in mp_blocks(z["Kc"].astype(np.int64))]
        C = len(z["Kc"])
        Wt = mp_taunorm(torch.from_numpy(W).to(dev), blocks, C, TN if tn is None else tn)
        mp = (blocks, C, float(z["T"]))
    else:
        if not int(z["tn_applied"]):
            W = taunorm(W, TN if tn is None else tn)
        Wt = torch.from_numpy(W).to(dev)
    bt = torch.from_numpy(z["b"].astype(np.float32)).to(dev)
    tT = float(os.environ.get("HC_T", 1.0))   # global temperature of the image term (tuned on val)
    ad = [torch.from_numpy(z[k].astype(np.float32)).to(dev) for k in ("V", "a", "U")] if "V" in z.files else None
    deep = None
    if any(k.startswith("deep.") for k in z.files):
        kind, _, arg = cfg["head"].partition(":")
        L_, H_ = (int(v) for v in arg.split(":"))
        deep = make_deep(kind, L_, H_, 0.0)
        deep.load_state_dict({k[5:]: torch.from_numpy(z[k]) for k in z.files if k.startswith("deep.")})
        deep = deep.to(dev).eval()
    tip = None
    if "keys" in z.files:
        C = W.shape[0]
        lab = torch.from_numpy(z["lab"].astype(np.int64)).to(dev)
        nk = torch.bincount(lab, minlength=C).float().clamp(min=1)
        am = float(os.environ.get("HC_ALPHA", 1.0))
        tip = (torch.from_numpy(z["keys"].astype(np.float32)).to(dev), lab, float(z["alpha"]) * am,
               float(z["beta"]), nk ** -float(z["gamma"]))

    def f(q):
        if ad is not None:
            q = F.normalize(q + torch.relu(q @ ad[0].T + ad[1]) @ ad[2].T, dim=-1)
        if deep is not None:
            with torch.no_grad():
                q = F.normalize(deep(q), dim=-1)
        if mp is not None:
            L = mp_scores(q @ Wt.T, mp[0], mp[1], mp[2]) + bt
        else:
            L = q @ Wt.T + bt
        if tip is not None and tip[2]:
            Kk, lab_, al, be, kn = tip
            A = torch.exp(-be * (1 - q @ Kk.T))
            L = L + al * torch.zeros_like(L).index_add_(1, lab_, A) * kn
        return L / tT
    return f


def head_cost(path):
    z = np.load(path)
    R, d = z["W"].shape
    C = len(z["b"])
    mb = R * d / 1e6           # int8 rows as shipped (the head is 23 MB in the pack): Σ K_c × 1024 for mproto
    macs = R * d
    dp = sum(z[k].size for k in z.files if k.startswith("deep."))
    if dp:
        mb += dp * 2 / 1e6          # deep stack fp16
        macs += sum(z[k].size for k in z.files if k.startswith("deep.") and k.endswith("weight") and z[k].ndim == 2)
    if "V" in z.files:
        H = z["V"].shape[0]
        mb += 2 * H * d * 2 / 1e6   # adapter fp16
        macs += 2 * H * d
    if "keys" in z.files:
        k = z["keys"].shape[0]
        mb += k * (d + 4) / 1e6     # int8 keys + scale + label
        macs += k * d
    return {"extra_MB_vs_linear": round(mb - C * d / 1e6, 1), "MMAC_per_photo_head": round(macs / 1e6, 1)}


def lean_scorer(BA):
    """Scorer.run streamed per chunk (head log p + prior computed on the fly, nothing
    n × C kept): the stock base() holds ~4–10 GB for AU-test, which swapped on a
    shared 32 GB Mac. Same arithmetic as bank_analysis.Scorer.run (no knn_fn)."""
    import torch
    memo = {}

    def head():
        key = (os.environ["HEAD"], os.environ.get("HC_T"), os.environ.get("HC_ALPHA"))
        if key not in memo:
            memo.clear()
            memo[key] = hc_head_fn(os.environ["HEAD"])
        return memo[key]

    def run(self, nm, knn_fn=None, om=1.0, floor=-10.0, rows_box=None, box_fn=None, chunk=2048, rerank=0):
        assert knn_fn is None and not rerank
        Z, dev = self.Z, self.dev
        f = head()
        mu = Z["mu"].astype(np.float32)
        cm = torch.from_numpy(BA.colmask(Z)).to(dev)
        e, Pm = Z[nm + "/emb"], BA.prior("main", nm)
        lam = float(os.environ.get("LAM", BA.MAIN[3]))
        n = len(e)
        top5 = np.zeros((n, 5), np.int64)
        boxm = np.zeros(n, bool) if rows_box is None else rows_box
        with torch.no_grad():
            for a in range(0, n, chunk):
                r = np.arange(a, min(n, a + chunk))
                q = BA.BS.unit(BA.BS.unit(e[a:a + chunk].astype(np.float32)) - mu[None]).astype(np.float32)
                Lh = torch.log_softmax(f(torch.from_numpy(q).to(dev)) + cm, 1).half().float()
                L = Lh + lam * torch.from_numpy(np.asarray(Pm[a:a + chunk])).to(dev).float()
                if box_fn is not None and boxm[r].any():
                    loc = np.nonzero(boxm[r])[0]
                    rb = r[loc]
                    if not hasattr(self, "P2"):
                        self.P2 = BA.BS.V2Prior(BA.PRIOR)
                    Pb = torch.from_numpy(self.P2.log_prior(Z[nm + "/lat"][rb], Z[nm + "/lon"][rb], *BA.BOX[:3])
                                          .astype(np.float32)).to(dev)
                    lt = torch.from_numpy(loc).to(dev)
                    L[lt] = torch.log_softmax(Lh[lt] + 2.0 * box_fn(rb).clamp(min=-30.0), 1) + BA.BOX[3] * Pb
                top5[r] = L.topk(5, dim=1).indices.cpu().numpy()
        return top5
    BA.Scorer.run = run


def cmd_eval(only=None):
    import bank_analysis as BA
    BA.head_fn = hc_head_fn
    lean_scorer(BA)
    rd = os.path.join(HW(), "runs")
    Z = BA.load()
    sc = BA.Scorer(Z)
    rp = os.path.join(HW(), "report.json")
    res = json.load(open(rp)) if os.path.exists(rp) else {}
    runs = sorted(f[:-4] for f in os.listdir(rd) if f.endswith(".npz"))
    boxes = {nm: BA.box_knn_rows(Z, nm) for nm in ("AU-val", "A-val", "AU-test", "A-test", "C-report")}
    t0 = time.time()
    for name in runs:
        if (only and only not in name) or (name in res and not only):
            continue
        path = os.path.join(rd, name + ".npz")
        os.environ["HEAD"] = path
        meta = json.loads(str(np.load(path)["meta"]))
        entry = {"cfg": meta["cfg"], "info": meta["info"], "cost": head_cost(path)}
        if "keys" in np.load(path).files:   # tune the cache weight post hoc on J (val only)
            grid = []
            # "<run>-a1" (a copy of a tip run) = the cache at its TRAINED weight (α' 1), not the
            # val-chosen one — to show what the cache does on test when val rejects it
            for am in ((1.0,) if name.endswith("-a1") else (0.0, 0.5, 0.75, 1.0, 1.5, 2.0)):
                os.environ["HC_ALPHA"] = str(am)
                sc.cache = {}
                v = {nm: sc.metrics(nm, sc.run(nm)) for nm in ("AU-val", "A-val")}
                grid.append((0.5 * (v["AU-val"]["top1_sp_rw"] + v["A-val"]["top1_nat"]), am))
            entry["alpha_grid"] = grid
            os.environ["HC_ALPHA"] = str(max(grid)[1])
            entry["alpha_mult"] = max(grid)[1]
        grid = []   # global temperature of the image term vs the prior (val J; every head, ref included)
        for tT in (0.8, 1.0, 1.25, 1.5, 2.0, 3.0):
            os.environ["HC_T"] = str(tT)
            sc.cache = {}
            v = {nm: sc.metrics(nm, sc.run(nm)) for nm in ("AU-val", "A-val")}
            grid.append((0.5 * (v["AU-val"]["top1_sp_rw"] + v["A-val"]["top1_nat"]), tT))
        entry["T_grid"], entry["T"] = grid, max(grid)[1]
        os.environ["HC_T"] = str(entry["T"])
        for var in ("none", "box"):
            sc.cache = {}
            top5s, val = {}, {}
            for nm in ("AU-val", "A-val", "AU-test", "A-test", "C-report"):
                kw = {}
                if var == "box":
                    kw = dict(rows_box=boxes[nm][0], box_fn=boxes[nm][1])
                t5 = sc.run(nm, **kw)
                if nm.endswith("val"):
                    val[nm] = sc.metrics(nm, t5)
                else:
                    top5s[nm] = t5
            r = sc.report(top5s)
            ntr = sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
            r["AU-test 1-9"] = sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
            r["A-test strict 0.2 km"] = sc.metrics("A-test", top5s["A-test"], BA.strict_mask(Z, "A-test", 0.2))
            r["val"] = val
            r["J"] = 0.5 * (val["AU-val"]["top1_sp_rw"] + val["A-val"]["top1_nat"])
            entry[var] = r
        os.environ.pop("HC_ALPHA", None)
        os.environ.pop("HC_T", None)
        res[name] = entry
        log(name, f"({time.time() - t0:.0f} s)", json.dumps({v: {k: (round(x["top1_sp"] * 100, 1), round(x["top1_nat"] * 100, 1))
                                                              for k, x in entry[v].items() if isinstance(x, dict) and "top1_sp" in x}
                                                          for v in ("none", "box")}))
        json.dump(res, open(rp, "w"), indent=1)
    table(res)


def table(res):
    cols = [("AU-test", "AU"), ("A-test", "A"), ("A-test strict 0.2 km", "A strict"), ("C-main", "C-main"),
            ("C-euc", "C-euc"), ("AU-test 1-9", "1-9")]
    lines = ["| run | val J | " + " | ".join(h for _, h in cols) + " | A +bank | A strict +bank | AU +bank | 1-9 +bank | extra MB | MMAC |",
             "|---" * (len(cols) + 8) + "|"]
    for name, e in sorted(res.items()):
        n, b = e["none"], e["box"]
        f = lambda r, k: f"{100 * r[k]['top1_sp']:.1f} / {100 * r[k]['top1_nat']:.1f}"  # noqa: E731
        lines.append(f"| {name} | {100 * n['J']:.2f} | " + " | ".join(f(n, k) for k, _ in cols) +
                     f" | {f(b, 'A-test')} | {f(b, 'A-test strict 0.2 km')} | {f(b, 'AU-test')} | {f(b, 'AU-test 1-9')}"
                     f" | {e['cost']['extra_MB_vs_linear']} | {e['cost']['MMAC_per_photo_head']} |")
    md = "\n".join(lines)
    open(os.path.join(HW(), "report.md"), "w").write(md + "\n")
    log(md)


def main():
    cmd = sys.argv[1]
    if cmd == "vm":
        cmd_vm(sys.argv[2], sys.argv[3])
    elif cmd == "vmscript":
        sys.stdout.write(VMSCRIPT)
    elif cmd == "coverage":
        cmd_coverage()
    elif cmd == "prep":
        cmd_prep()
    elif cmd == "smoke":
        cmd_smoke()
    elif cmd == "measure":
        cmd_smoke(measure=True)
    elif cmd == "eval":
        cmd_eval(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "table":
        table(json.load(open(os.path.join(HW(), "report.json"))))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Encoder fine-tuning pilot — runs on a GPU pod (or `--smoke` on the Mac).
Fetches the plan's photos (iNat open-data S3 "medium", keep-alive workers;
ALA/Commons photos arrive as uploaded tars), then per job.json `arm`:

  frozen          only the frozen embeddings (val/test/probe + 1,000 train rows)
  lora            LoRA (rank r, α 2r) on the last `blocks` blocks' attention
                  in-proj/out-proj and MLP fc/proj; everything else frozen
  partial         full fine-tune of the last `blocks` blocks + ln_post + proj,
                  layer-wise LR decay `llrd` from the top
  supcon-lora /   backbone as above, plus genus hard-negative batches and
  supcon-partial  SupCon + image–text terms (below)

Every arm: q = normalise(normalise(f(x)) − μ) (μ = the production train mean),
head logits = s0 · (q · (Tc + Δ)ᵀ + β), Tc = centred text rows of the subset
(text init, Δ = 0 at start, decay toward the init), balanced softmax
CE(logits + τ log π) with log π from the data's class counts, τ 1.5. Sampler:
per epoch ≤ `cap` photos per class without replacement (fresh draw). Train
augmentation: RandomResizedCrop(224, scale 0.6–1, bicubic), h-flip, colour
jitter (brightness 0.2, contrast 0.2, saturation 0.1, hue 0 — hue carries
flower colour). Eval = the production transform (short side 224 bicubic,
centre crop). bf16 autocast, AdamW, warmup + cosine; val (per-species top-1
of the joint head) after every epoch, best epoch kept.

supcon arms: a batch is, with probability 1 − `p_rand`, 4 genus groups of
P ≤ 8 species × M photos (M = 32 // P, with replacement for small classes),
else a random batch from the epoch pool. Loss = CE_bal + λ_sc · SupCon
(temperature t over the batch's q AND the fixed text rows of the batch's
species — same species positive, so congeners in the batch are the hard
negatives and a rare species' text row is always a positive) + λ_it · CE_bal
against the FIXED text classifier (s0 · q · Tcᵀ — keeps the text alignment).

Out (/work/out): log.json (curve, photos/s), frozen-NNNN.npz, emb-NNNN.npz
(row, photo_id, emb fp16, ok), weights-NN.npz (trainable tensors, ≤ 60 MB each),
head.npz (Δ, β). Never prints secrets (there are none on the pod).
"""
import argparse
import http.client
import io
import json
import math
import os
import queue
import tarfile
import threading
import time

import numpy as np

HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
HF = "hf-hub:imageomics/bioclip-2.5-vith14"
MAGIC = (b"\xff\xd8", b"\x89PNG", b"GIF8", b"RIFF")
DEF = {"arm": "lora", "blocks": 8, "rank": 16, "epochs": 3, "cap": 200, "bs": 128, "tau": 1.5, "s0": 50.0,
       "lr_head": 1e-3, "wd_head": 0.01, "lr_lora": 2e-4, "lr_ft": 2e-5, "llrd": 0.8, "wd_ft": 0.05,
       "warmup": 300, "p_rand": 0.25, "t_sc": 0.1, "l_sc": 1.0, "l_it": 0.5, "seed": 0, "workers": -1,
       "fetch_threads": 64, "max_steps": 0, "embed_bs": 256, "micro": 64, "smoke": 0}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ photos

def fetch(T, pdir, inn, threads):
    os.makedirs(pdir, exist_ok=True)
    for f in sorted(os.listdir(inn)):
        if f.startswith("photos-") and f.endswith(".tar"):
            with tarfile.open(os.path.join(inn, f)) as t:
                t.extractall(pdir, filter="data")
    todo = queue.Queue()
    n = 0
    for p, e, fl in zip(T["photo_id"], T["ext"], T["file"]):
        if not fl and not os.path.exists(os.path.join(pdir, f"{p}.{e}")):
            todo.put((p, e))
            n += 1
    log(f"fetch: {n:,} photos from S3")
    st = {"ok": 0, "missing": 0, "failed": 0, "bytes": 0}
    lock = threading.Lock()

    def worker():
        conn = None
        while True:
            try:
                p, e = todo.get_nowait()
            except queue.Empty:
                return
            res = "failed"
            for att in range(5):
                try:
                    if conn is None:
                        conn = http.client.HTTPSConnection(HOST, timeout=30)
                    conn.request("GET", f"/photos/{p}/medium.{e}", headers=UA)
                    r = conn.getresponse()
                    b = r.read()
                    if r.status == 200 and b.startswith(MAGIC):
                        fp = os.path.join(pdir, f"{p}.{e}")
                        with open(fp + ".part", "wb") as f:
                            f.write(b)
                        os.replace(fp + ".part", fp)
                        res = "ok"
                        with lock:
                            st["bytes"] += len(b)
                    elif r.status in (403, 404):
                        res = "missing"
                    else:
                        raise IOError(r.status)
                    break
                except Exception:  # noqa: BLE001
                    conn = None
                    time.sleep(1 + 2 * att)
            with lock:
                st[res] += 1
    t0 = time.time()
    ths = [threading.Thread(target=worker, daemon=True) for _ in range(threads)]
    for t in ths:
        t.start()
    while any(t.is_alive() for t in ths):
        time.sleep(30)
        dt = time.time() - t0
        log(f"  fetch {st['ok']:,} ok ({st['ok'] / dt:.0f}/s, {st['bytes'] / dt / 1e6:.1f} MB/s) "
            f"missing {st['missing']} failed {st['failed']}")
    st["seconds"] = round(time.time() - t0)
    return st


def path_of(pdir, p, e, fl):
    return os.path.join(pdir, fl if fl else f"{p}.{e}")


# ------------------------------------------------------------------ model

def build(cfg, dev):
    import open_clip
    import torch
    from torch.nn.utils import parametrize
    model, _, tf_eval = open_clip.create_model_and_transforms(HF)
    v = model.visual.to(dev)
    del model
    for p in v.parameters():
        p.requires_grad_(False)
    arm = cfg["arm"]
    nb = cfg["blocks"]
    blocks = v.transformer.resblocks
    L = len(blocks)
    groups = []
    if arm in ("lora", "supcon-lora"):
        class LoRA(torch.nn.Module):
            def __init__(self, out_f, in_f, r):
                super().__init__()
                self.A = torch.nn.Parameter(torch.randn(r, in_f, device=dev) / math.sqrt(in_f))
                self.B = torch.nn.Parameter(torch.zeros(out_f, r, device=dev))
                self.s = 2.0  # α = 2r

            def forward(self, W):
                return W + (self.B @ self.A).to(W.dtype) * self.s
        ps = []
        for li in range(L - nb, L):
            b = blocks[li]
            for mod, name in ((b.attn, "in_proj_weight"), (b.attn.out_proj, "weight"), (b.mlp.c_fc, "weight"),
                              (b.mlp.c_proj, "weight")):
                W = getattr(mod, name)
                lo = LoRA(W.shape[0], W.shape[1], cfg["rank"])
                parametrize.register_parametrization(mod, name, lo, unsafe=True)
                ps += [lo.A, lo.B]
        groups.append({"params": ps, "lr": cfg["lr_lora"], "weight_decay": 0.0})
    elif arm in ("partial", "supcon-partial"):
        for k, li in enumerate(range(L - 1, L - nb - 1, -1)):
            ps = list(blocks[li].parameters())
            for p in ps:
                p.requires_grad_(True)
            groups.append({"params": ps, "lr": cfg["lr_ft"] * cfg["llrd"] ** k, "weight_decay": cfg["wd_ft"]})
        top = list(v.ln_post.parameters()) + [v.proj]
        for p in top:
            p.requires_grad_(True)
        groups.append({"params": top, "lr": cfg["lr_ft"], "weight_decay": cfg["wd_ft"]})
    return v, tf_eval, groups


def trainable_state(v, cfg):
    """{name: tensor} of what the arm trains (LoRA A/B or the tuned blocks)."""
    out = {}
    for n, p in v.named_parameters():
        if p.requires_grad:
            out[n] = p.detach().float().cpu().clone()
    return out


def load_state(v, st):
    import torch
    cur = dict(v.named_parameters())
    with torch.no_grad():
        for n, t in st.items():
            cur[n].copy_(t.to(cur[n].device, cur[n].dtype))


# ------------------------------------------------------------------ data

class DS:
    def __init__(self, paths, tf):
        self.paths, self.tf = paths, tf

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, i):
        from PIL import Image
        with Image.open(self.paths[i]) as im:
            return self.tf(im.convert("RGB")), i


def loader(paths, tf, batches, workers):
    import torch
    return torch.utils.data.DataLoader(DS(paths, tf), batch_sampler=batches, num_workers=workers,
                                       pin_memory=True, prefetch_factor=4 if workers else None,
                                       persistent_workers=False)


def embed(v, paths, tf, dev, bs, workers, mu=None):
    import torch
    v.eval()
    out = np.zeros((len(paths), 1024), np.float16)
    batches = [list(range(i, min(len(paths), i + bs))) for i in range(0, len(paths), bs)]
    t0 = time.time()
    with torch.no_grad(), torch.autocast(dev, dtype=torch.bfloat16 if dev == "cuda" else torch.float16):
        for x, idx in loader(paths, tf, batches, workers):
            e = torch.nn.functional.normalize(v(x.to(dev, non_blocking=True)).float(), dim=-1)
            out[idx.numpy()] = e.cpu().numpy().astype(np.float16)
    dt = time.time() - t0
    return out, len(paths) / max(dt, 1e-9)


def write_shards(od, prefix, rows, pids, E, ok, n=4000):
    for k, i in enumerate(range(0, len(rows), n)):
        p = os.path.join(od, f"{prefix}-{k:04d}.npz")
        with open(p + ".part", "wb") as f:
            np.savez(f, row=rows[i:i + n], photo_id=pids[i:i + n], emb=E[i:i + n], ok=ok[i:i + n])
        os.replace(p + ".part", p)


# ------------------------------------------------------------------ main

def run(a):
    import pyarrow.parquet as pq
    import torch
    import torchvision.transforms as TT
    cfg = dict(DEF, **json.load(open(a.job)))
    inn, od, pdir = a.inp, a.out, a.photos
    os.makedirs(od, exist_ok=True)
    torch.manual_seed(cfg["seed"])
    rng = np.random.default_rng(cfg["seed"])
    dev = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.benchmark = True
    workers = cfg["workers"] if cfg["workers"] >= 0 else max(2, min(16, (os.cpu_count() or 8) - 2))
    T = pq.read_table(os.path.join(inn, "todo.parquet")).to_pydict()
    a.smoke = a.smoke or cfg.get("smoke", 0)
    if a.smoke:  # a few rows per role
        keep = []
        cl = json.load(open(os.path.join(inn, "classes.json")))
        g0 = [i for i, c in enumerate(cl) if c["genus"] == "Eucalyptus"][:cfg.get("bench_classes", 4)]  # ≥ 2 congeners
        tr_ = [i for i, (r, y) in enumerate(zip(T["role"], T["ys"])) if r == "train" and y in g0]
        keep += [tr_[j] for j in np.random.default_rng(0).permutation(len(tr_))[:a.smoke]]
        for role, k in (("val", 16), ("test", 16), ("probe", 8)):
            keep += [i for i, r in enumerate(T["role"]) if r == role][:k]
        T = {c: [v_[i] for i in keep] for c, v_ in T.items()}
    info = {"cfg": cfg, "dev": dev, "gpu": torch.cuda.get_device_name(0) if dev == "cuda" else dev,
            "cpus": os.cpu_count(), "workers": workers, "rows": len(T["role"])}
    info["fetch"] = fetch(T, pdir, inn, cfg["fetch_threads"])
    paths = [path_of(pdir, p, e, f) for p, e, f in zip(T["photo_id"], T["ext"], T["file"])]
    ok = np.array([os.path.exists(q) for q in paths])
    role = np.array(T["role"])
    ys = np.array(T["ys"], np.int64)
    pid = np.array(T["photo_id"], np.int64)
    info["missing"] = {r: int((~ok & (role == r)).sum()) for r in ("train", "val", "test", "probe")}
    json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
    log("missing", info["missing"])
    v, tf_eval, groups = build(cfg, dev)
    mu = torch.from_numpy(np.load(os.path.join(inn, "mu.npy")).astype(np.float32)).to(dev)
    Tc = np.load(os.path.join(inn, "text_sub.npy")).astype(np.float32)
    tmean = np.load(os.path.join(inn, "tmean.npy")).astype(np.float32)
    Tc = Tc - tmean
    Tc = torch.nn.functional.normalize(torch.from_numpy(Tc), dim=-1).to(dev)
    C = Tc.shape[0]
    s0 = float(cfg["s0"])
    # frozen embeddings: eval rows + 1,000 train rows (parity check against data-final)
    fr = np.nonzero(ok & ((role != "train") | (np.cumsum(role == "train") <= 1000)))[0]
    E, eps = embed(v, [paths[i] for i in fr], tf_eval, dev, cfg["embed_bs"], workers)
    write_shards(od, "frozen", fr, pid[fr], E, ok[fr])
    info["embed_frozen_photos_per_s"] = round(eps, 1)
    log(f"frozen: {len(fr):,} rows at {eps:.0f}/s")
    if cfg["arm"] == "frozen":
        info["done"] = True
        json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
        return
    # ---------------- training
    tr = np.nonzero(ok & (role == "train"))[0]
    va = np.nonzero(ok & (role == "val"))[0]
    ytr = ys[tr]
    n_c = np.bincount(ytr, minlength=C).astype(np.float64)
    logpi = torch.from_numpy(np.where(n_c > 0, np.log(np.maximum(n_c, 1) / n_c.sum()), -1e4).astype(np.float32)).to(dev)
    by_c = [tr[ytr == c] for c in range(C)]
    genus = np.array([g["genus"] for g in json.load(open(os.path.join(inn, "classes.json")))])
    gen_cls = {}
    for c in range(C):
        if n_c[c] > 0:
            gen_cls.setdefault(genus[c], []).append(c)
    multi = [g for g, cs in gen_cls.items() if len(cs) >= 2]
    bs = cfg["bs"]

    def epoch_pool():
        out = []
        for c in range(C):
            if len(by_c[c]):
                out.append(rng.permutation(by_c[c])[:cfg["cap"]])
        return rng.permutation(np.concatenate(out))

    def epoch_batches():
        pool = epoch_pool()
        nb_ = len(pool) // bs
        if not cfg["arm"].startswith("supcon"):
            return [pool[i * bs:(i + 1) * bs].tolist() for i in range(nb_)]
        out, j = [], 0
        for _ in range(nb_):
            if rng.random() < cfg["p_rand"] or not multi:
                out.append(pool[j:j + bs].tolist())
                j += bs
                continue
            b = []
            while len(b) < bs:
                cs = gen_cls[multi[rng.integers(len(multi))]]
                cs = rng.permutation(cs)[:8]
                M = 32 // len(cs)
                for c in cs:
                    b += rng.choice(by_c[c], M, replace=len(by_c[c]) < M).tolist()
            out.append(b[:bs])
        return out
    tf_tr = TT.Compose([TT.RandomResizedCrop(224, scale=(0.6, 1.0), interpolation=TT.InterpolationMode.BICUBIC),
                        TT.RandomHorizontalFlip(), TT.ColorJitter(0.2, 0.2, 0.1, 0.0), TT.ToTensor(),
                        TT.Normalize((0.48145466, 0.4578275, 0.40821073), (0.26862954, 0.26130258, 0.27577711))])
    Dw = torch.nn.Parameter(torch.zeros_like(Tc))
    beta = torch.nn.Parameter(torch.zeros(C, device=dev))
    opt = torch.optim.AdamW(groups + [{"params": [Dw, beta], "lr": cfg["lr_head"], "weight_decay": cfg["wd_head"]}],
                            betas=(0.9, 0.999))
    spe = sum(min(len(b_), cfg["cap"]) for b_ in by_c) // bs
    total = spe * cfg["epochs"]
    if cfg["max_steps"]:
        total = min(total, cfg["max_steps"])
    warm = min(cfg["warmup"], max(1, total // 10))
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: (s + 1) / warm if s < warm else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm))))
    adt = torch.bfloat16 if dev == "cuda" else torch.float16
    yt_all = torch.from_numpy(ys).to(dev)
    va_y = ys[va]
    curve, best, step = [], None, 0
    info.update({"train_rows": int(len(tr)), "steps_per_epoch": spe, "total_steps": total})
    log(f"train: {len(tr):,} photos, {spe} steps/epoch × {cfg['epochs']} = {total} steps, bs {bs}, {workers} workers")

    def q_of(x):
        e = torch.nn.functional.normalize(v(x).float(), dim=-1)
        return torch.nn.functional.normalize(e - mu, dim=-1)
    for ep in range(1, cfg["epochs"] + 1):
        v.train()
        bl = epoch_batches()
        t0, seen, tl = time.time(), 0, 0.0
        for x, idx in loader(paths, tf_tr, bl, workers):
            x = x.to(dev, non_blocking=True)
            yb = yt_all[idx.to(dev)]
            opt.zero_grad(set_to_none=True)
            mb = cfg["micro"] or len(idx)
            ltot = 0.0
            for c0 in range(0, len(idx), mb):  # micro-batches (gradient accumulation; SupCon within each)
                y = yb[c0:c0 + mb]
                with torch.autocast(dev, dtype=adt):
                    q = q_of(x[c0:c0 + mb])
                W = Tc + Dw
                logits = s0 * (q @ W.T + beta)
                loss = torch.nn.functional.cross_entropy(logits + cfg["tau"] * logpi, y)
                if cfg["arm"].startswith("supcon"):
                    uy = torch.unique(y)
                    F_ = torch.cat([q, Tc[uy]])                   # images, then the batch species' text rows
                    lab = torch.cat([y, uy])
                    S = q @ F_.T / cfg["t_sc"]                    # anchors = images only
                    n = q.shape[0]
                    self_m = torch.zeros_like(S, dtype=torch.bool)
                    self_m[:, :n] = torch.eye(n, dtype=torch.bool, device=dev)
                    S = S.masked_fill(self_m, -1e9)
                    pos = (y[:, None] == lab[None, :]) & ~self_m
                    lp = S - torch.logsumexp(S, 1, keepdim=True)
                    sc = -(lp * pos).sum(1) / pos.sum(1).clamp(min=1)
                    loss = loss + cfg["l_sc"] * sc.mean()
                    it = torch.nn.functional.cross_entropy(s0 * (q @ Tc.T) + cfg["tau"] * logpi, y)
                    loss = loss + cfg["l_it"] * it
                (loss * len(y) / len(idx)).backward()
                ltot += float(loss) * len(y) / len(idx)
            loss = torch.tensor(ltot)
            opt.step()
            sched.step()
            step += 1
            seen += len(idx)
            tl += float(loss) * len(idx)
            if step % 50 == 0:
                dt = time.time() - t0
                log(f"  ep {ep} step {step}/{total} loss {tl / seen:.4f} {seen / dt:.0f} photos/s "
                    f"mem {torch.cuda.max_memory_allocated() / 2 ** 30 if dev == 'cuda' else 0:.1f} GB")
            if cfg["max_steps"] and step >= total:
                break
        tps = seen / (time.time() - t0)
        # val: joint head, per species
        Ev, _ = embed(v, [paths[i] for i in va], tf_eval, dev, cfg["embed_bs"], workers)
        with torch.no_grad():
            qv = torch.nn.functional.normalize(torch.from_numpy(Ev.astype(np.float32)).to(dev) - mu, dim=-1)
            pv = (qv @ (Tc + Dw).T + beta).argmax(1).cpu().numpy()
            pz = (qv @ Tc.T).argmax(1).cpu().numpy()
        hit, hz = pv == va_y, pz == va_y
        cls_, inv = np.unique(va_y, return_inverse=True)
        sp = float((np.bincount(inv, hit) / np.bincount(inv)).mean())
        spz = float((np.bincount(inv, hz) / np.bincount(inv)).mean())
        r = {"epoch": ep, "train_loss": tl / max(seen, 1), "train_photos_per_s": round(tps, 1), "val_sp": sp,
             "val_zeroshot_sp": spz, "step": step, "s": round(time.time() - t0)}
        curve.append(r)
        info["curve"] = curve
        json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
        log(f"epoch {ep}: {r}")
        if best is None or sp > best[0]:
            best = (sp, ep, trainable_state(v, cfg), Dw.detach().cpu().clone(), beta.detach().cpu().clone())
        if cfg["max_steps"] and step >= total:
            break
    info["best_epoch"] = best[1]
    load_state(v, best[2])
    # ---------------- tuned embeddings of every row
    rows = np.nonzero(ok)[0]
    E, eps = embed(v, [paths[i] for i in rows], tf_eval, dev, cfg["embed_bs"], workers)
    write_shards(od, "emb", rows, pid[rows], E, ok[rows])
    info["embed_tuned_photos_per_s"] = round(eps, 1)
    np.savez(os.path.join(od, "head.npz"), Dw=best[3].numpy().astype(np.float16), beta=best[4].numpy())
    st = best[2]
    chunk, k, size = {}, 0, 0
    for n_, t_ in st.items():
        chunk[n_] = t_.numpy().astype(np.float16) if cfg["arm"].endswith("partial") else t_.numpy()
        size += chunk[n_].nbytes
        if size > 60e6:
            np.savez(os.path.join(od, f"weights-{k:02d}.npz"), **chunk)
            chunk, k, size = {}, k + 1, 0
    if chunk:
        np.savez(os.path.join(od, f"weights-{k:02d}.npz"), **chunk)
    info["done"] = True
    json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
    log("done")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--job", required=True)
    ap.add_argument("--inp", default="/work/in")
    ap.add_argument("--out", default="/work/out")
    ap.add_argument("--photos", default="/work/photos")
    ap.add_argument("--smoke", type=int, default=0, help="only this many train rows (+ a few eval rows)")
    run(ap.parse_args())


if __name__ == "__main__":
    main()

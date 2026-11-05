#!/usr/bin/env python3
"""Can a PRUNED national kNN bank (real training photos, picked to keep the
spread-out / hard ones — never centroids) replace the shipped Tasmania-box bank
with ONE uniform rule? Analysis only; the shipped files and the other scripts
are untouched (bank_analysis.py's loaders, Scorer, val/test protocol and strict
≤ 200 m split are imported, not copied).

Banks (all in v2 space, unit(unit(x) − μ), int8 × per-row scale as shipped),
built from the training photos after a near-duplicate drop (within a class:
cos ≥ 0.95 AND same observer within 1 km — or, observer unknown, same day
within 1 km), at budgets 85k / 170k / 340k rows (nested prefixes):
  err   error-driven: out-of-fold (4 folds by OBSERVER, the final-cb50 recipe,
        bank_heads.py linear) head predictions; photos whose true class is in
        the OOF top-10 but not top-1 first, then correct ones with margin < 2,
        then the rest of the errors; key |margin| − a·ln n_c (a = 0 / 0.5)
  cnn   condensed NN (Hart, batched) relative to the OOF top-10: photos in
        random order, added when the store's kNN re-ranking of the OOF top-10
        (ω 0.5, k 10, τ 0.05, same-observer neighbours excluded) gets them
        wrong while the true class is in the top-10; budget-capped
  cov   coverage: per-class farthest-point (k-centre) order from the most
        typical photo, rows ∝ min(n_c, cap) (cap 50 / 200 / ∞), ≥ 1 per class
  mix   cov (chosen cap) at half the budget ∪ err (chosen a) to the budget
  rand  control: uniformly random real photos
Scoring: bank kNN everywhere (no box), top-10 re-ranking, count-balanced votes;
(β, τ, ω) and the per-kind option chosen on J = ½(AU-val re-weighted per
species + A-val natural); tests read once per final variant; also the best
uniform bank outside + the shipped Tasmanian bank & box prior inside.

Subcommands (local: eval_v2.py's env, FINAL/TAUNORM/V2DATA/V2PRIOR as
bank_analysis.py):
  prep      folds (4, by observer hash), mapv, centred fp16 copy of Xtr → PW/
  dedup     near-duplicate drop → PW/keep.npy
  vm        (GPU VM, numpy + torch only) the 4 fold heads + OOF top-10 → $B/prune/
  vmscript  print the VM startup script
  oof       merge the fetched PW/oof-f*.npz → PW/oof.npz
  build     err / cov / mix banks → PW/bank-<name>.npy (row order = priority)
  cnn       the CNN bank → PW/bank-cnn.npy   (PRUNE_MEASURE=n: time n photos)
  search    top-100 neighbours of every set in every bank → PW/nb-<bank>-<rows>.npz
  score     val tuning + tests → PW/prune.json
"""
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
NF = 4
BUDGETS = (85000, 170000, 340000)
SEED = 7


def log(*a):
    print(*a, flush=True)


def fold_of(obs, pid, nf=NF):
    """Fold by observer (unknown observer → by photo id); a fixed integer hash."""
    key = np.where(obs >= 0, obs, -1 - pid).astype(np.int64).view(np.uint64)
    h = (key * np.uint64(0x9E3779B97F4A7C15)) >> np.uint64(40)
    return (h % np.uint64(nf)).astype(np.int8)


# ------------------------------------------------------------ VM (numpy + torch only)

VMSCRIPT = r"""#!/usr/bin/env bash
# bank_prune.py fold heads: runs as root on EVERY boot (SPOT preemption = STOP →
# start resumes; finished folds in $B/prune/ are skipped). Powers off when done.
set -uo pipefail
md() { curl -sf -H Metadata-Flavor:Google \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
B=$(md izzy-bucket)
W=/opt/izzy; mkdir -p "$W"; cd "$W"
exec >> "$W/prune.log" 2>&1
echo "== boot $(date -u +%FT%TZ)"
( while sleep 60; do gcloud storage cp "$W/prune.log" "$B/log/prune.log" --quiet 2>/dev/null; done ) &
finish() { echo "== end $(date -u +%FT%TZ) ($1)"; gcloud storage cp "$W/prune.log" "$B/log/prune.log" --quiet
           shutdown -h now; exit 0; }
for i in $(seq 90); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || finish "no GPU"
export HOME=/root PATH=/root/.local/bin:$PATH
uv --version 2>/dev/null | grep -q "^uv " || { rm -f /root/.local/bin/uv /root/.local/bin/uvx
  curl -LsSf https://astral.sh/uv/install.sh | sh; }
E="uv run --python 3.12 --with torch==2.7.* --with numpy<2.3 python3 -u"
for f in bank_prune.py bank_heads.py folds.npy mapv.npy; do
  gcloud storage cp "$B/prune/in/$f" . --quiet || finish "no $f"; done
[ -f data-final.npz ] || gcloud storage cp "$B/v2/data-final.npz" . --quiet || finish "no v2 data"
export V2_GPU_BYTES=1.6e10
$E bank_prune.py vm --bucket "$B" --work "$W"; rc=$?
echo "bank_prune exit $rc"; [ $rc = 0 ] || finish "bank_prune failed"
finish ok
"""


def cmd_vmscript():
    sys.stdout.write(VMSCRIPT)


def oof_outputs(W, b, Xc_rows, ytrue, mapv, dev, tn=0.5):
    """Head (τ-norm tn, merged twins masked) on centred rows → top-10 classes, their
    log p, the true class's log p and rank."""
    import torch
    W = W.astype(np.float32).reshape(W.shape[0], -1)
    if tn:
        nr = np.linalg.norm(W, axis=1, keepdims=True).clip(1e-6)
        W = W * (nr.mean() / nr) ** tn
    cm = np.zeros(len(mapv), np.float32)
    cm[mapv != np.arange(len(mapv))] = -1e4
    Wt = torch.from_numpy(W).to(dev)
    bt = torch.from_numpy(b.astype(np.float32) + cm).to(dev)
    n = len(ytrue)
    ti, tl = np.zeros((n, 10), np.int32), np.zeros((n, 10), np.float16)
    lt, rk = np.zeros(n, np.float16), np.zeros(n, np.int32)
    yt = torch.from_numpy(ytrue.astype(np.int64)).to(dev)
    for i in range(0, n, 8192):
        L = torch.log_softmax(Xc_rows[i:i + 8192].float() @ Wt.T + bt, 1)
        v, j = L.topk(10, dim=1)
        lp = L.gather(1, yt[i:i + 8192, None])[:, 0]
        ti[i:i + 8192], tl[i:i + 8192] = j.cpu().numpy(), v.cpu().numpy()
        lt[i:i + 8192] = lp.cpu().numpy()
        rk[i:i + 8192] = (L > lp[:, None]).sum(1).cpu().numpy()
    return ti, tl, lt, rk


def cmd_vm():
    import argparse
    import torch
    import bank_heads as BH
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--work", required=True)
    a = ap.parse_args()
    B, W = a.bucket.rstrip("/"), a.work
    r = subprocess.run(["gcloud", "storage", "ls", f"{B}/prune/"], capture_output=True, text=True)
    have = {os.path.basename(l) for l in r.stdout.split()}
    todo = [f for f in range(NF) if f"oof-f{f}.npz" not in have]
    log("todo folds", todo)
    if not todo:
        return
    D = dict(np.load(os.path.join(W, "data-final.npz")))
    folds = np.load(os.path.join(W, "folds.npy"))
    mapv = np.load(os.path.join(W, "mapv.npy"))
    assert len(folds) == len(D["ytr"])
    mu = torch.from_numpy(D["mu"]).cuda()
    for f in todo:
        tr = folds != f
        Df = dict(D, Xtr=D["Xtr"][tr], ytr=D["ytr"][tr], tas=D["tas"][tr])
        c = dict(BH.BASE, name=f"oof-f{f}", head="linear")
        curve, st, info, n_c = BH.train(c, Df, "cuda", None, lambda m: print(m, flush=True))
        del Df
        torch.cuda.empty_cache()
        ho = np.nonzero(~tr)[0]
        xs = []
        for i in range(0, len(ho), 65536):
            x = torch.from_numpy(D["Xtr"][ho[i:i + 65536]].astype(np.float32)).cuda()
            x = torch.nn.functional.normalize(torch.nn.functional.normalize(x, dim=-1) - mu, dim=-1)
            xs.append(x.half())
        Xc = torch.cat(xs)
        ti, tl, lt, rk = oof_outputs(st["W"], st["b"], Xc, mapv[D["ytr"][ho].astype(np.int64)], mapv, "cuda")
        del Xc
        torch.cuda.empty_cache()
        p = os.path.join(W, f"oof-f{f}.npz")
        np.savez(p, rows=ho.astype(np.int32), top_i=ti, top_l=tl, true_l=lt, rank=rk, W=st["W"], b=st["b"],
                 meta=np.array(json.dumps({"cfg": c, "info": info, "curve": curve})))
        subprocess.run(["gcloud", "storage", "cp", p, f"{B}/prune/", "--quiet"], check=True)
        log(f"fold {f}: {info}; OOF top-1 {(rk == 0).mean():.4f}, top-10 {(rk < 10).mean():.4f}")


# ------------------------------------------------------------ local

def _ba():
    import bank_analysis as BA
    return BA


def PW():
    p = os.path.join(_ba().WORK, "prune")
    os.makedirs(p, exist_ok=True)
    return p


def labels_u(Z):
    BA = _ba()
    return Z["mapv"][np.asarray(BA.npz_memmap(BA.V.DATA, "ytr")).astype(np.int64)]


def xc_memmap():
    return np.load(os.path.join(PW(), "xc.npy"), mmap_mode="r")


def cmd_prep():
    import torch
    BA = _ba()
    t0 = time.time()
    Z = BA.load()
    G = np.load(os.path.join(BA.WORK, "train_geo.npz"))
    pid = np.asarray(BA.npz_memmap(BA.V.DATA, "pid"))
    folds = fold_of(G["obs"], pid)
    np.save(os.path.join(PW(), "folds.npy"), folds)
    np.save(os.path.join(PW(), "mapv.npy"), Z["mapv"])
    log("fold sizes", np.bincount(folds), "observers per fold",
        [len(np.unique(G["obs"][(folds == f) & (G["obs"] >= 0)])) for f in range(NF)])
    out = os.path.join(PW(), "xc.npy")
    if not os.path.exists(out):
        Xtr = BA.npz_memmap(BA.V.DATA, "Xtr")
        arr = np.lib.format.open_memmap(out + ".part", "w+", np.float16, Xtr.shape)
        mu = torch.from_numpy(Z["mu"].astype(np.float32)).to("mps")
        for a in range(0, len(Xtr), 262144):
            x = torch.from_numpy(np.asarray(Xtr[a:a + 262144], np.float32)).to("mps")
            x = torch.nn.functional.normalize(torch.nn.functional.normalize(x, dim=-1) - mu, dim=-1)
            arr[a:a + 262144] = x.half().cpu().numpy()
        arr.flush()
        del arr
        os.replace(out + ".part", out)
    log(f"prep done ({time.time() - t0:.0f} s)")


def cmd_dedup():
    """Within a class: drop a photo if an earlier-kept photo of the same group (same
    observer; observer unknown → same day) lies within 1 km with cos ≥ 0.95 (v2 space).
    Unlocated photos are never dropped."""
    BA = _ba()
    t0 = time.time()
    Z = BA.load()
    G = np.load(os.path.join(BA.WORK, "train_geo.npz"))
    y = labels_u(Z)
    obs, day, lat, lon = G["obs"], G["day"], G["lat"], G["lon"]
    gk = np.where(obs >= 0, obs, np.where(day > -99999, -2 - day, -1))  # -1 = no group
    ok = (gk != -1) & np.isfinite(lat)
    rng = np.random.default_rng(SEED)
    rnd = rng.random(len(y))
    idx = np.nonzero(ok)[0]
    o = idx[np.lexsort((rnd[idx], gk[idx], y[idx]))]
    key_y, key_g = y[o], gk[o]
    brk = np.r_[0, np.nonzero((np.diff(key_y) != 0) | (np.diff(key_g) != 0))[0] + 1, len(o)]
    sizes = np.diff(brk)
    X = xc_memmap()
    keep = np.ones(len(y), bool)
    big = np.nonzero(sizes >= 2)[0]
    log(f"{len(big):,} groups with ≥ 2 photos ({sizes[big].sum():,} photos; largest {sizes.max()})")
    # read the grouped rows in one sorted pass per block of groups (random memmap reads are slow)
    for bi in range(0, len(big), 20000):
        gs = big[bi:bi + 20000]
        rows_all = np.concatenate([o[brk[g]:brk[g + 1]] for g in gs])
        srt = np.argsort(rows_all)
        Xall = np.empty((len(rows_all), X.shape[1]), np.float32)
        Xall[srt] = X[rows_all[srt]]
        pos = 0
        for g in gs:
            r = o[brk[g]:brk[g + 1]]
            n = len(r)
            Xg = Xall[pos:pos + n]
            pos += n
            S = Xg @ Xg.T
            kx = 111.32 * np.cos(np.radians(lat[r]))
            d = np.hypot((lon[r][:, None] - lon[r][None]) * kx[:, None], (lat[r][:, None] - lat[r][None]) * 110.57)
            dup = (S >= 0.95) & (d <= 1.0)
            np.fill_diagonal(dup, False)
            if not dup.any():
                continue
            gone = np.zeros(n, bool)
            for i in range(n):
                if not gone[i] and dup[i].any():
                    gone |= dup[i] & (np.arange(n) > i)
            keep[r[gone]] = False
        log(f"  groups {bi + len(gs):,}/{len(big):,}: dropped {(~keep).sum():,} ({time.time() - t0:.0f} s)")
    np.save(os.path.join(PW(), "keep.npy"), keep)
    n0, n1 = np.bincount(y, minlength=len(Z["mapv"])), np.bincount(y[keep], minlength=len(Z["mapv"]))
    log(f"dedup: kept {keep.sum():,} of {len(y):,} ({(~keep).mean():.2%} dropped); classes losing > 50 %: "
        f"{((n1 < 0.5 * n0) & (n0 > 0)).sum()} ({time.time() - t0:.0f} s)")


def cmd_oof():
    t0 = time.time()
    Z = _ba().load()
    y = labels_u(Z)
    n = len(y)
    top_i, top_l = np.zeros((n, 10), np.int32), np.zeros((n, 10), np.float16)
    true_l, rank = np.zeros(n, np.float16), np.full(n, -1, np.int32)
    info = {}
    for f in range(NF):
        z = np.load(os.path.join(PW(), f"oof-f{f}.npz"))
        r = z["rows"].astype(np.int64)
        top_i[r], top_l[r], true_l[r], rank[r] = z["top_i"], z["top_l"], z["true_l"], z["rank"]
        info[f] = json.loads(str(z["meta"]))["info"]
    assert (rank >= 0).all()
    np.savez(os.path.join(PW(), "oof.npz"), top_i=top_i, top_l=top_l, true_l=true_l, rank=rank)
    log("fold heads", info)
    log(f"OOF top-1 {(rank == 0).mean():.4f}, top-10 {(rank < 10).mean():.4f} ({time.time() - t0:.0f} s)")


def margin(oof):
    tl, lt, rk = oof["top_l"].astype(np.float32), oof["true_l"].astype(np.float32), oof["rank"]
    return np.where(rk == 0, lt - tl[:, 1], lt - tl[:, 0])


def order_err(keep, y, oof, a):
    """Priority order (row ids) of the error-driven bank."""
    m = margin(oof)
    rk = oof["rank"]
    n_c = np.bincount(y[keep], minlength=y.max() + 1).astype(np.float64)
    key = np.abs(m) - a * np.log(np.maximum(n_c[y], 1))
    tier = np.select([(rk > 0) & (rk < 10), (rk == 0) & (m < 2.0), rk >= 10], [0, 1, 2], 3)
    rows = np.nonzero(keep & (tier < 3))[0]
    return rows[np.lexsort((key[rows], tier[rows]))]


def quota(n, total, cap):
    """m_c = min(n, max(1, round(f · min(n, cap)))), f by bisection → Σ m_c ≈ total."""
    nz = n[n > 0]
    lo, hi = 1e-6, 1.0
    for _ in range(60):
        f = (lo + hi) / 2
        t = np.minimum(nz, np.maximum(1, np.round(f * np.minimum(nz, cap)))).sum()
        lo, hi = (f, hi) if t < total else (lo, f)
    f = (lo + hi) / 2
    return np.where(n > 0, np.minimum(n, np.maximum(1, np.round(f * np.minimum(n, cap)))), 0).astype(np.int64)


def fps_orders(keep, y, mmax):
    """Per class: farthest-point order (up to mmax[c] rows) from the photo nearest
    the class mean → {class: row ids}."""
    import torch
    t0 = time.time()
    X = xc_memmap()
    C = len(mmax)
    rows = np.nonzero(keep)[0]
    o = rows[np.argsort(y[rows], kind="stable")]
    st = np.r_[0, np.cumsum(np.bincount(y[o], minlength=C))]
    out = {}
    cls = np.nonzero(np.diff(st))[0]
    # stream classes in row order blocks: gather a block of classes' rows once (sorted reads)
    for bi in range(0, len(cls), 2000):
        cb = cls[bi:bi + 2000]
        ra = np.concatenate([o[st[c]:st[c + 1]] for c in cb])
        s_ = np.argsort(ra)
        XA = np.empty((len(ra), X.shape[1]), np.float32)
        XA[s_] = X[ra[s_]]
        XA = torch.from_numpy(XA).to("mps")
        pos = 0
        for c in cb:
            r = o[st[c]:st[c + 1]]
            n = len(r)
            Xc_ = XA[pos:pos + n]
            pos += n
            m = int(min(n, mmax[c]))
            if m >= n:
                mu_ = Xc_.mean(0)
                out[c] = r[torch.argsort(-(Xc_ @ mu_)).cpu().numpy()]
                continue
            first = int((Xc_ @ Xc_.mean(0)).argmax())
            pick = [first]
            d = 1 - Xc_ @ Xc_[first]
            for _ in range(m - 1):
                j = int(d.argmax())
                pick.append(j)
                d = torch.minimum(d, 1 - Xc_ @ Xc_[j])
            out[c] = r[np.array(pick)]
        log(f"  fps classes {bi + len(cb):,}/{len(cls):,} ({time.time() - t0:.0f} s)")
    return out


def cov_rows(orders, q):
    return np.concatenate([orders[c][:q[c]] for c in orders if q[c] > 0])


def cmd_build():
    """`build [err|cov]`: err (a 0 / 0.5), cov (cap 50 / 200 / ∞) at every budget →
    PW/rows-<bank>-<budget>.npy; `build mix <cap> <a>` after the 170k tuning."""
    t0 = time.time()
    Z = _ba().load()
    y = labels_u(Z)
    keep = np.load(os.path.join(PW(), "keep.npy"))
    n_c = np.bincount(y[keep], minlength=len(Z["mapv"]))
    what = sys.argv[2] if len(sys.argv) > 2 else "all"
    oof = dict(np.load(os.path.join(PW(), "oof.npz"))) if what in ("all", "err", "mix") else None
    if what == "mix":
        cap, a = sys.argv[3], float(sys.argv[4])
        orders = fps_orders(keep, y, quota(n_c, BUDGETS[-1] // 2, np.inf if cap == "inf" else float(cap)))
        oe = order_err(keep, y, oof, a)
        for B_ in BUDGETS:
            cv = cov_rows(orders, quota(n_c, B_ // 2, np.inf if cap == "inf" else float(cap)))
            rest = oe[~np.isin(oe, cv)][:B_ - len(cv)]
            np.save(os.path.join(PW(), f"rows-mix-c{cap}-a{a:g}-{B_}.npy"), np.sort(np.r_[cv, rest]))
            log(f"mix c{cap} a{a:g} {B_}: {len(cv):,} cov + {len(rest):,} err")
        return
    for a in ((0.0, 0.5) if what in ("all", "err") else ()):
        oe = order_err(keep, y, oof, a)
        log(f"err a{a:g}: {len(oe):,} candidates")
        for B_ in BUDGETS:
            r = oe[:B_]
            np.save(os.path.join(PW(), f"rows-err-a{a:g}-{B_}.npy"), np.sort(r))
            log(f"  {B_}: classes {len(np.unique(y[r])):,}, rank>0 {(oof['rank'][r] > 0).mean():.2f}, "
                f"median n_c {np.median(n_c[y[r]]):.0f}")
    caps = {"50": 50.0, "200": 200.0, "inf": np.inf}
    if what in ("err", "rand"):
        if what == "rand":  # control: uniformly random real photos (nested prefixes)
            perm = np.random.default_rng(SEED).permutation(np.nonzero(keep)[0])
            for B_ in BUDGETS:
                np.save(os.path.join(PW(), f"rows-rand-{B_}.npy"), np.sort(perm[:B_]))
        return
    mmax = np.max([quota(n_c, BUDGETS[-1], v) for v in caps.values()], axis=0)
    orders = fps_orders(keep, y, mmax)
    for k, v in caps.items():
        for B_ in BUDGETS:
            r = cov_rows(orders, quota(n_c, B_, v))
            np.save(os.path.join(PW(), f"rows-cov-c{k}-{B_}.npy"), np.sort(r))
            log(f"cov c{k} {B_}: {len(r):,} rows, classes {len(np.unique(y[r])):,}")
    log(f"build done ({time.time() - t0:.0f} s)")


def cmd_cnn():
    """Batched Hart CNN relative to the OOF top-10 (see the docstring)."""
    import torch
    BA = _ba()
    t0 = time.time()
    Z = BA.load()
    y = labels_u(Z)
    C = len(Z["mapv"])
    keep = np.load(os.path.join(PW(), "keep.npy"))
    oof = dict(np.load(os.path.join(PW(), "oof.npz")))  # a lazy NpzFile re-reads per access
    obs = np.load(os.path.join(BA.WORK, "train_geo.npz"))["obs"]
    X = xc_memmap()
    rk = oof["rank"]
    cand = np.nonzero(keep)[0]
    rng = np.random.default_rng(SEED)
    cand = cand[rng.permutation(len(cand))]
    meas = int(os.environ.get("PRUNE_MEASURE", 0))
    if meas:
        cand = cand[:meas]
    cap = BUDGETS[-1]
    dev = "mps"
    S_lab = torch.zeros(-(-cap // 65536) * 65536, dtype=torch.int64, device=dev)
    BLK = 65536
    capb = -(-cap // BLK) * BLK
    S = torch.zeros((capb, X.shape[1]), dtype=torch.float16, device=dev)
    S_obs = torch.full((capb,), -7, dtype=torch.int64, device=dev)
    valid = torch.zeros(capb, dtype=torch.bool, device=dev)
    store = []
    om, k, tau = 0.5, 10, 0.05
    bs = 4096
    # every MPS op has a FIXED shape (variable shapes made MPS cache buffers per shape:
    # +2 GB per batch): queries padded to bs, the store mirrored on the CPU and uploaded
    # in whole aligned bs-row chunks
    S_np = np.zeros((capb, X.shape[1]), np.float16)
    L_np, O_np, V_np = np.zeros(capb, np.int64), np.full(capb, -7, np.int64), np.zeros(capb, bool)
    seen = 0
    store_arr = np.zeros(0, np.int64)
    for p_ in range(2):
        for i in range(0, len(cand), bs):
            r = np.sort(cand[i:i + bs])
            nr = len(r)
            rp = np.r_[r, np.full(bs - nr, r[0])] if nr < bs else r
            q = torch.from_numpy(np.asarray(X[rp], np.float16)).to(dev)
            ti = torch.from_numpy(oof["top_i"][rp].astype(np.int64)).to(dev)
            tl = torch.from_numpy(oof["top_l"][rp].astype(np.float32)).to(dev)
            yt = torch.from_numpy(y[rp]).to(dev)
            ns = len(store)
            if ns >= k:
                qo = torch.from_numpy(np.where(obs[rp] >= 0, obs[rp], -11)).to(dev)
                vb, jb = [], []
                for a0 in range(0, ns, BLK):
                    sb = (q @ S[a0:a0 + BLK].T).masked_fill_((qo[:, None] == S_obs[None, a0:a0 + BLK]) | ~valid[None, a0:a0 + BLK], -9.0)
                    v_, j_ = sb.topk(k, dim=1)
                    vb.append(v_), jb.append(j_ + a0)
                    del sb
                vc, jc = torch.cat(vb, 1), torch.cat(jb, 1)
                v, t_ = vc.topk(k, dim=1)
                j = jc.gather(1, t_)
                v = v.float()
                w = torch.exp((v - v[:, :1]) / tau) * (v > -8).float()
                lab = S_lab[j]
                # votes for the top-10 classes only (a dense n × C scatter was the bottleneck)
                Pk = ((lab[:, None, :] == ti[:, :, None]).float() * w[:, None, :]).sum(2)
                Pk = Pk / w.sum(1, keepdim=True).clamp(min=1e-12)
                sc_ = tl + om * torch.log(Pk + 1e-6 / C)
            else:
                sc_ = tl
            pred = ti.gather(1, sc_.argmax(1, keepdim=True))[:, 0]
            wrong = (pred != yt).cpu().numpy()[:nr] & (rk[r] < 10)  # fixable: true class in the top-10
            if p_ == 1:  # second pass: rows already stored are skipped
                wrong &= ~np.isin(r, store_arr)
            add = r[wrong][:cap - ns]
            if len(add):
                S_np[ns:ns + len(add)] = X[add]
                L_np[ns:ns + len(add)], O_np[ns:ns + len(add)], V_np[ns:ns + len(add)] = y[add], obs[add], True
                for c0 in range(ns // bs * bs, ns + len(add), bs):
                    S[c0:c0 + bs] = torch.from_numpy(S_np[c0:c0 + bs]).to(dev)
                    S_lab[c0:c0 + bs] = torch.from_numpy(L_np[c0:c0 + bs]).to(dev)
                    S_obs[c0:c0 + bs] = torch.from_numpy(O_np[c0:c0 + bs]).to(dev)
                    valid[c0:c0 + bs] = torch.from_numpy(V_np[c0:c0 + bs]).to(dev)
                store.extend(add.tolist())
            torch.mps.synchronize()
            seen += nr
            if (i // bs) % int(os.environ.get("PRUNE_LOGEVERY", 50)) == 0:
                log(f"  pass {p_} photos {i + bs:,}/{len(cand):,}: store {len(store):,} "
                    f"(+{wrong.mean():.3f} of the batch) ({time.time() - t0:.0f} s, "
                    f"MPS {torch.mps.driver_allocated_memory() / 1e9:.1f} GB)")
            if len(store) >= cap:
                break
        if len(store) >= cap or meas:
            break
        store_arr = np.array(store)
    if meas:
        el = time.time() - t0
        log(f"measure: {meas:,} photos → store {len(store):,} in {el:.0f} s")
        return
    order = np.array(store, np.int64)
    np.save(os.path.join(PW(), "order-cnn.npy"), order)
    for B_ in BUDGETS:
        np.save(os.path.join(PW(), f"rows-cnn-{B_}.npy"), np.sort(order[:B_]))
    log(f"cnn: {len(order):,} rows after {seen:,} photos ({time.time() - t0:.0f} s)")


def bank_list():
    return sorted(f[5:-4] for f in os.listdir(PW()) if f.startswith("rows-") and f.endswith(".npy"))


def cmd_search():
    """int8 × per-row scale bank (as shipped) → top-100 per query of every set."""
    import torch
    BA = _ba()
    t0 = time.time()
    Z = BA.load()
    X = xc_memmap()
    names = sys.argv[2:] or bank_list()
    Q = {nm: torch.from_numpy(BA.BS.unit(BA.BS.unit(Z[nm + "/emb"].astype(np.float32)) - Z["mu"][None])
                              .astype(np.float16)).to("mps") for nm in BA.NB_SETS}
    for b in names:
        out_p = os.path.join(PW(), f"nb-{b}.npz")
        if os.path.exists(out_p):
            continue
        r = np.load(os.path.join(PW(), f"rows-{b}.npy"))
        V_ = np.asarray(X[r], np.float32)
        s = np.abs(V_).max(1, keepdims=True) / 127.0
        B8 = torch.from_numpy(np.round(V_ / s).astype(np.float16)).to("mps")
        st = torch.from_numpy(s[:, 0].astype(np.float32)).to("mps")
        out = {}
        for nm, q in Q.items():
            vs, js = [], []
            for i in range(0, len(q), 512):
                v, j = ((q[i:i + 512] @ B8.T).float() * st[None]).topk(100, dim=1)
                vs.append(v.cpu().numpy().astype(np.float16)), js.append(j.cpu().numpy().astype(np.int32))
                torch.mps.synchronize()
            out[nm + "/v"], out[nm + "/i"] = np.concatenate(vs), np.concatenate(js)
        np.savez(out_p, **out)
        del B8
        torch.mps.empty_cache()
        log(f"searched {b} ({len(r):,} rows, {time.time() - t0:.0f} s)")


GRID = [{"k": 50, "tau": t, "beta": b_, "om": om, "floor": -30.0, "rerank": 10, "rho": 0.0}
        for b_ in (0.5, 1.0) for t in (0.05, 0.1) for om in (0.1, 0.25, 0.5, 1.0, 2.0, 3.0)]
# `score extend`: a softer floor (a class without bank votes among the top-10 loses at most
# ω·|floor| nats) — the −30 grid's optimum sat at its smallest ω for every pruned bank
GRID2 = [{"k": 50, "tau": 0.05, "beta": b_, "om": om, "floor": fl, "rerank": 10, "rho": 0.0}
         for b_ in (0.5, 1.0) for fl in (-3.0, -10.0) for om in (0.25, 0.5, 1.0, 2.0)] + \
        [{"k": 50, "tau": 0.05, "beta": b_, "om": om, "floor": -1.5, "rerank": 10, "rho": 0.0}
         for b_ in (0.5, 1.0) for om in (1.0, 2.0, 4.0)]
PKEYS = ("k", "tau", "beta", "om", "floor", "rerank")


def cmd_score():
    """`score val <banks…>` tunes on val (GRID); `score extend <banks…>` adds GRID2 and re-picks;
    `score test <bank>[+box] …` reads the tests for the chosen parameters of those banks."""
    import torch
    BA = _ba()
    t0 = time.time()
    Z = BA.load()
    sc = BA.Scorer(Z)
    y = labels_u(Z)
    mode = sys.argv[2]
    pth = os.path.join(PW(), "prune.json")
    res = json.load(open(pth)) if os.path.exists(pth) else {}
    for b in sys.argv[3:] or bank_list():
        box = b.endswith("+box")
        bn = b[:-4] if box else b
        r = np.load(os.path.join(PW(), f"rows-{bn}.npy"))
        nb = dict(np.load(os.path.join(PW(), f"nb-{bn}.npz")))
        lab_t = torch.from_numpy(y[r]).to(sc.dev)
        cnt_t = torch.bincount(lab_t, minlength=sc.C).float()
        ent = res.setdefault(bn, {})
        if mode in ("val", "extend"):
            done = {tuple(g[k_] for k_ in PKEYS) for g in ent.get("grid", [])}
            todo = [g for g in (GRID if mode == "val" else GRID2) if tuple(g[k_] for k_ in PKEYS) not in done]
            if not todo:
                continue
            rows_g = ent.get("grid", [])
            for prm in todo:
                rr = {}
                for nm in ("AU-val", "A-val"):
                    fn = BA.nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], lab_t, prm["k"], prm["tau"], prm["beta"], cnt_t)
                    rr[nm] = sc.metrics(nm, sc.run(nm, fn, prm["om"], prm["floor"], rerank=prm["rerank"]))
                rows_g.append({**prm, "J": 0.5 * (rr["AU-val"]["top1_sp_rw"] + rr["A-val"]["top1_nat"]),
                               "AU-val_rw": rr["AU-val"]["top1_sp_rw"], "A-val_nat": rr["A-val"]["top1_nat"],
                               "A-val_sp": rr["A-val"]["top1_sp"]})
            ent["best"] = max(rows_g, key=lambda x: x["J"])
            ent["grid"] = rows_g
            ent["rows"] = int(len(r))
            log(bn, "val", {k: (round(v, 4) if isinstance(v, float) else v) for k, v in ent["best"].items()},
                f"({time.time() - t0:.0f} s)")
        else:
            key = "test_box" if box else "test"
            if key in ent:
                continue
            p_ = ent["best"]
            top5s = {}
            for nm in ("AU-test", "A-test", "C-report"):
                kw = {}
                if box:
                    bx, bf = BA.box_knn_rows(Z, nm)
                    kw = dict(rows_box=bx, box_fn=bf)
                fn = BA.nbr_knn(sc, nb[nm + "/v"], nb[nm + "/i"], lab_t, p_["k"], p_["tau"], p_["beta"], cnt_t)
                top5s[nm] = sc.run(nm, fn, p_["om"], p_["floor"], rerank=p_["rerank"], **kw)
            rep = sc.report(top5s)
            ntr = sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
            rep["AU-test 1-9"] = sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
            rep["A-test strict 0.2 km"] = sc.metrics("A-test", top5s["A-test"], BA.strict_mask(Z, "A-test", 0.2))
            rows = len(r)
            rep["bank_MB"] = BA.bank_bytes(rows) / 1e6 + (BA.bank_bytes(82649) / 1e6 if box else 0)
            rep["scan_ms_M4cpu"] = 1e3 * (BA.time_scan(rows) + (BA.time_scan(82649) if box else 0))
            ent[key] = rep
            log(b, json.dumps({k: (round(x["top1_sp"] * 100, 2), round(x["top1_nat"] * 100, 2)) for k, x in rep.items()
                               if isinstance(x, dict)}), f"{rep['bank_MB']:.0f} MB ({time.time() - t0:.0f} s)")
        json.dump(res, open(pth, "w"), indent=1)


if __name__ == "__main__":
    {"prep": cmd_prep, "dedup": cmd_dedup, "vm": cmd_vm, "vmscript": cmd_vmscript, "oof": cmd_oof,
     "build": cmd_build, "cnn": cmd_cnn, "search": cmd_search, "score": cmd_score}[sys.argv[1]]()

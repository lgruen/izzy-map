#!/usr/bin/env python3
"""Trained Australia-wide plant-ID model (README "Trained Australia-wide
model"): BioCLIP 2.5 embeddings of the observer-disjoint manifests that
`eval_australia.py plan` wrote (australia/plan/), a 22,122-class linear head,
per-class prototypes, an Australia-wide location prior and a temperature —
tuned on held-out val observers, reported on the eval's A and C test sets.

Subcommands

  manifest   (laptop) the photos still to embed = plan train ∪ eval minus the
             ones in emb/bioclip25 → australia/train/todo.parquet, cut into
             fixed 1,000-photo shards (shard k = rows 1000k…1000k+999).
  vm-embed   (cloud VM, GPU) for every shard whose result is not in GCS yet:
             fetch the 500 px photos from the iNat open-data bucket (keep-alive
             HTTPS per thread, in memory — photos never touch the disk),
             open_clip's eval transform, BioCLIP 2.5 fp16, upload
             emb/shard-NNNN.npz (photo_id, emb fp16 L2-normalised, missing).
             A SPOT preemption loses at most the shards in flight.
             --shards N stops after N shards (the smoke test).
  vm-train   (cloud VM, GPU) the head on every train embedding (heads for a
             small μ × epochs grid, each uploaded as it is written).
  fetch      (laptop) GCS → australia/train/ (embeddings, heads, logs).
  score      (laptop) prototypes, prior, tuning on val, report on A / C.

Run (laptop side): pipeline/plantid/cloud/run_au.sh (see its header).

Environments
  VM:     uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*'
              --with open_clip_torch --with pyarrow --with pillow --with 'numpy<2.3'
  laptop: eval_australia.py's (coremltools, scipy, duckdb, …).
"""
import argparse
import collections
import glob
import http.client
import json
import os
import queue
import subprocess
import sys
import threading
import time

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
TR = os.environ.get("IZZY_AU_TRAIN", os.path.join(AU, "train"))
SHARD = 1000
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"GIF8", b"RIFF")
HF = "hf-hub:imageomics/bioclip-2.5-vith14"
# head grid trained on the VM (μ = L2 pull towards the text vector; the
# Tasmanian eval chose μ 1e-5 at 40 epochs from {1e-5 … 1e-3} × {10, 20, 40})
MUS = (1e-5, 1e-4)
EPOCHS = (10, 20, 40)


def gs(*args, check=True):
    return subprocess.run(["gcloud", "storage", *args, "--quiet"], check=check,
                          capture_output=True, text=True)


# ------------------------------------------------------------------ manifest

def cmd_manifest(a):
    import duckdb
    os.makedirs(TR, exist_ok=True)
    have = set()
    for f in glob.glob(os.path.join(CACHE, "emb", "bioclip25", "img-*.npz")):
        have.update(np.load(f)["photo_id"].tolist())
    con = duckdb.connect()
    rows = con.execute(f"""
        SELECT DISTINCT photo_id, ext FROM (
          SELECT photo_id, ext FROM '{AU}/plan/train.parquet'
          UNION ALL SELECT photo_id, ext FROM '{AU}/plan/eval.parquet') ORDER BY photo_id""").fetchall()
    todo = [(p, e) for p, e in rows if p not in have]
    assert len({p for p, _ in todo}) == len(todo)
    t = pa.table({"photo_id": pa.array([p for p, _ in todo], pa.int64()),
                  "ext": [e for _, e in todo]})
    pq.write_table(t, os.path.join(TR, "todo.parquet"))
    print(f"{len(rows):,} photos in plan train ∪ eval, {len(rows) - len(todo):,} already embedded, "
          f"{len(todo):,} to do = {-(-len(todo) // SHARD)} shards of {SHARD}")


# ------------------------------------------------------------------ vm-embed

def cmd_vm_embed(a):
    import open_clip
    import torch
    from PIL import Image
    bucket = a.bucket.rstrip("/")
    T = pq.read_table(a.todo).to_pydict()
    ids, exts = T["photo_id"], T["ext"]
    nsh = -(-len(ids) // SHARD)
    out = os.path.join(a.work, "emb")
    os.makedirs(out, exist_ok=True)
    r = gs("ls", f"{bucket}/emb/", check=False)
    done = {int(os.path.basename(l)[6:10]) for l in r.stdout.split() if l.endswith(".npz")}
    todo = [k for k in range(nsh) if k not in done]
    if a.shards:
        todo = todo[:a.shards]
    print(f"{nsh} shards, {len(done)} in GCS, {len(todo)} to do now", flush=True)
    if not todo:
        return
    model, _, tf = open_clip.create_model_and_transforms(HF)
    model = model.visual.to(a.device).half().eval()
    torch.backends.cudnn.benchmark = True

    items = queue.Queue()
    for k in todo:
        for i in range(k * SHARD, min((k + 1) * SHARD, len(ids))):
            items.put((k, ids[i], exts[i]))
    results = queue.Queue(maxsize=2048)
    stats = {"bytes": 0, "missing": 0, "failed": 0, "fetched": 0}
    lock = threading.Lock()

    def fetcher():
        conn = None
        while True:
            try:
                k, pid, ext = items.get_nowait()
            except queue.Empty:
                return
            x, why = None, "failed"
            for attempt in range(5):
                try:
                    if conn is None:
                        conn = http.client.HTTPSConnection(HOST, timeout=30)
                    conn.request("GET", f"/photos/{pid}/medium.{ext}", headers=UA)
                    resp = conn.getresponse()
                    body = resp.read()
                    if resp.status == 200 and body.startswith(MAGIC):
                        import io
                        with Image.open(io.BytesIO(body)) as im:
                            x = tf(im.convert("RGB"))
                        with lock:
                            stats["bytes"] += len(body)
                            stats["fetched"] += 1
                    elif resp.status in (403, 404):
                        why = "missing"
                    else:
                        raise IOError(f"HTTP {resp.status}")
                    break
                except Exception:
                    conn = None
                    time.sleep(1 + 2 * attempt)
            if x is None:
                with lock:
                    stats[why] += 1
            results.put((k, pid, x, why))

    ths = [threading.Thread(target=fetcher, daemon=True) for _ in range(a.threads)]
    for t in ths:
        t.start()
    need = {k: min((k + 1) * SHARD, len(ids)) - k * SHARD for k in todo}
    buf = {k: {"id": [], "emb": [], "missing": []} for k in todo}
    uploads = []
    t0, last, n_emb, n_sh = time.time(), time.time(), 0, 0

    def finish(k):
        nonlocal n_sh
        b = buf.pop(k)
        p = os.path.join(out, f"shard-{k:04d}.npz")
        with open(p + ".part", "wb") as f:
            np.savez(f, photo_id=np.array(b["id"], np.int64),
                     emb=(np.concatenate(b["emb"]) if b["emb"] else np.zeros((0, 1024))).astype(np.float16),
                     missing=np.array(b["missing"], np.int64))
        os.replace(p + ".part", p)
        uploads.append(subprocess.Popen(["gcloud", "storage", "cp", p, f"{bucket}/emb/", "--quiet"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        n_sh += 1

    pend_k, pend_id, pend_x = [], [], []

    def run_batch():
        nonlocal n_emb
        with torch.inference_mode():
            e = model(torch.stack(pend_x).to(a.device, torch.float16))
            e = torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()
        for j, (k, pid) in enumerate(zip(pend_k, pend_id)):
            buf[k]["id"].append(pid)
            buf[k]["emb"].append(e[j:j + 1])
            need[k] -= 1
            if need[k] == 0:
                finish(k)
        n_emb += len(pend_x)
        pend_k.clear(), pend_id.clear(), pend_x.clear()

    left = sum(need.values())
    while left:
        k, pid, x, why = results.get()
        left -= 1
        if x is None:
            buf[k]["missing"].append(pid)
            need[k] -= 1
            if need[k] == 0 and not any(kk == k for kk in pend_k):
                finish(k)
            continue
        pend_k.append(k), pend_id.append(pid), pend_x.append(x)
        if len(pend_x) >= a.batch or left == 0:
            run_batch()
        if time.time() - last > 30:
            last = time.time()
            dt = last - t0
            print(f"  {n_emb:,} embedded ({n_emb / dt:.1f}/s), {stats['fetched'] / dt:.1f} fetched/s "
                  f"{stats['bytes'] / dt / 1e6:.1f} MB/s, missing {stats['missing']} failed "
                  f"{stats['failed']}, shards {n_sh}/{len(todo)}, queue {results.qsize()}", flush=True)
            uploads[:] = [u for u in uploads if u.poll() is None]
    if pend_x:
        run_batch()
    for k in list(buf):  # a shard whose last item was a miss after its batch
        if need[k] == 0:
            finish(k)
    for u in uploads:
        u.wait()
    bad = [u for u in uploads if u.returncode]
    dt = time.time() - t0
    s = {"shards": n_sh, "embedded": n_emb, "seconds": round(dt), "photos_per_s": round(n_emb / dt, 1),
         "mb_per_s": round(stats["bytes"] / dt / 1e6, 1), "missing": stats["missing"],
         "failed": stats["failed"], "upload_errors": len(bad),
         "gpu": torch.cuda.get_device_name(0) if a.device == "cuda" else a.device, "threads": a.threads, "batch": a.batch}
    print(json.dumps(s), flush=True)
    p = os.path.join(a.work, f"embed-run-{time.strftime('%Y%m%d-%H%M%S')}.json")
    json.dump(s, open(p, "w"))
    gs("cp", p, f"{bucket}/log/", check=False)
    assert not bad, "some shard uploads failed — rerun (they will be redone)"


# ------------------------------------------------------------------ vm-train

def load_train(emb_dirs, train_parquet, nU):
    """Train embeddings in train.parquet order (rows whose photo is missing
    upstream are dropped) → X (fp16), y, photo ids."""
    tr = pq.read_table(train_parquet, columns=["photo_id", "u"]).to_pydict()
    pid = np.array(tr["photo_id"], np.int64)
    y = np.array(tr["u"], np.int64)
    X = np.zeros((len(pid), 1024), np.float16)
    got = np.zeros(len(pid), bool)
    o = np.argsort(pid)
    for d in emb_dirs:
        for f in sorted(glob.glob(os.path.join(d, "img-*.npz")) + glob.glob(os.path.join(d, "shard-*.npz"))):
            z = np.load(f)
            p = z["photo_id"].astype(np.int64)
            i = np.searchsorted(pid, p, sorter=o).clip(0, len(pid) - 1)
            j = o[i]
            ok = pid[j] == p
            X[j[ok]] = z["emb"][ok]
            got[j[ok]] = True
    print(f"train: {got.sum():,} of {len(got):,} photos embedded "
          f"({(~got).sum():,} missing), {len(np.unique(y[got])):,} classes", flush=True)
    assert y.max() < nU
    return X[got], y[got], pid[got]


def train_heads(X, y, T, mus, epochs, device, save, seed=0, lr=1e-3, bs=2048):
    """evaluate.linear on GPU: head initialised at the centred text vectors,
    rows of classes without photos frozen there, class-balanced CE, μ‖ΔW‖²."""
    import torch
    torch.backends.cuda.matmul.allow_tf32 = True
    Xg = torch.from_numpy(X).to(device)  # fp16, centred + unit
    yg = torch.from_numpy(y).to(device)
    T0 = torch.from_numpy(T).to(device)
    counts = torch.bincount(yg, minlength=T.shape[0]).float()
    mask = (counts > 0).float()[:, None]
    w = (1.0 / counts.clamp(min=1))[yg]
    for mu in mus:
        torch.manual_seed(seed)
        D = torch.nn.Parameter(torch.zeros_like(T0))
        ls = torch.nn.Parameter(torch.tensor(float(np.log(30.0)), device=device))
        opt = torch.optim.Adam([D, ls], lr=lr)
        n, t0 = len(yg), time.time()
        for ep in range(1, max(epochs) + 1):
            perm = torch.randperm(n, device=device)
            for i in range(0, n, bs):
                b = perm[i:i + bs]
                W = T0 + mask * D
                ce = torch.nn.functional.cross_entropy(ls.exp() * Xg[b].float() @ W.T, yg[b],
                                                       reduction="none")
                loss = (ce * w[b]).sum() / w[b].sum() + mu * ((mask * D) ** 2).sum()
                opt.zero_grad(set_to_none=True)
                loss.backward()
                opt.step()
            if ep in epochs:
                W = (T0 + mask * D).detach().float().cpu().numpy()
                save(mu, ep, W, float(ls.exp()))
                print(f"  μ {mu:g} epoch {ep}: loss {float(loss):.4f} ({time.time() - t0:.0f} s)", flush=True)


def centre_unit(X, mu):
    import torch
    out = np.empty_like(X)
    m = torch.from_numpy(mu.astype(np.float32))
    for i in range(0, len(X), 65536):
        x = torch.from_numpy(X[i:i + 65536].astype(np.float32))
        x = torch.nn.functional.normalize(x, dim=-1) - m
        out[i:i + 65536] = torch.nn.functional.normalize(x, dim=-1).numpy().astype(X.dtype)
    return out


def cmd_vm_train(a):
    bucket = a.bucket.rstrip("/")
    w = a.work
    T = np.load(os.path.join(w, "text.npz"))["emb"].astype(np.float32)
    X, y, pid = load_train([os.path.join(w, "emb0"), os.path.join(w, "emb")],
                           os.path.join(w, "train.parquet"), len(T))
    mu_i = X.astype(np.float32).mean(0)
    Xc = centre_unit(X, mu_i)
    Tc = T - T.mean(0)
    Tc /= np.linalg.norm(Tc, axis=1, keepdims=True)
    od = os.path.join(w, "heads")
    os.makedirs(od, exist_ok=True)
    np.savez(os.path.join(od, "centre.npz"), image_mean=mu_i, text_mean=T.mean(0),
             n_train=np.bincount(y, minlength=len(T)))
    gs("cp", os.path.join(od, "centre.npz"), f"{bucket}/heads/", check=False)

    def save(mu, ep, W, scale):
        p = os.path.join(od, f"head-mu{mu:g}-ep{ep}.npz")
        np.savez(p, W=W.astype(np.float16), logit_scale=scale)
        gs("cp", p, f"{bucket}/heads/", check=False)
    train_heads(Xc, y, Tc.astype(np.float32), MUS, EPOCHS, "cuda", save)


# ------------------------------------------------------------------ score (laptop)

PRIOR_GRID = {"cell": 0.05, "lat0": -44.0, "lon0": 112.0, "ny": 690, "nx": 850}
SIGMAS = (5.0, 10.0, 25.0, 50.0)
ALPHAS = (4.0, 16.0, 64.0)
LAMS = (0.25, 0.5, 0.75, 1.0, 1.25)
TEMPS = np.exp(np.linspace(np.log(0.02), np.log(50), 41))


class NS:
    def __init__(self, **k):
        self.__dict__.update(k)


def all_embeddings():
    """Every BioCLIP 2.5 cloud fp16 embedding we have (emb/bioclip25 + the
    trained run's shards), sorted by photo id."""
    ids, es = [], []
    for f in sorted(glob.glob(os.path.join(CACHE, "emb", "bioclip25", "img-*.npz"))) + \
            sorted(glob.glob(os.path.join(TR, "emb", "shard-*.npz"))):
        z = np.load(f)
        ids.append(z["photo_id"].astype(np.int64))
        es.append(z["emb"].astype(np.float16))
    ids, E = np.concatenate(ids), np.concatenate(es)
    o = np.argsort(ids, kind="stable")
    ids, E = ids[o], E[o]
    keep = np.r_[True, ids[1:] != ids[:-1]]  # (a photo embedded twice: first copy)
    return ids[keep], E[keep]


def lookup(ids, pids):
    pids = np.asarray(pids, np.int64)
    i = np.searchsorted(ids, pids).clip(0, len(ids) - 1)
    return i, ids[i] == pids


def prior_counts(cell=PRIOR_GRID["cell"]):
    """eval_australia's prior records (pool observers, research grade, AU box,
    positional accuracy ≤ 5 km) aggregated per (cell, class)."""
    path = os.path.join(TR, f"prior_counts_{cell:g}.parquet")
    if not os.path.exists(path):
        import duckdb
        import eval_australia as EA
        con = EA.db()
        con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
        q = lambda c: c.replace("lat", "o.lat").replace("lon", "o.lon")  # noqa: E731
        t = con.execute(f"""
            SELECT floor((o.lat - {PRIOR_GRID['lat0']}) / {cell})::INTEGER AS cy,
                   floor((o.lon - {PRIOR_GRID['lon0']}) / {cell})::INTEGER AS cx, m.u,
                   count(*)::INTEGER AS n
            FROM o JOIN imap_v m USING (species_id)
            WHERE o.role = 'pool' AND {q(EA.AUS)} AND (o.pacc IS NULL OR o.pacc <= 5000)
            GROUP BY ALL""").to_arrow_table()
        pq.write_table(t, path)
    return pq.read_table(path).to_pydict()


def tsoftmax_nll(L, y):
    import torch
    m = y >= 0
    return float(-L[m].gather(1, y[m][:, None]).mean())


def fit_temp(raw, y, grid=TEMPS):
    """One temperature on raw logits / log p (multiplied: L = log_softmax(t·raw))
    minimising the NLL of the truth."""
    import torch
    best = None
    for t in grid:
        v = tsoftmax_nll(torch.log_softmax(float(t) * raw, 1), y)
        if best is None or v < best[0]:
            best = (v, float(t))
    return best[1]


def objective(L, S):
    """Mean of photo-weighted and per-species top-1 (evaluate.objective)."""
    hit = (L.argmax(1) == S.yt).cpu().numpy() & (S.y >= 0)
    inl = S.y >= 0
    micro = (hit[inl] * S.w[inl]).sum() / S.w[inl].sum()
    _, inv = np.unique(S.y[inl], return_inverse=True)
    macro = (np.bincount(inv, hit[inl]) / np.bincount(inv)).mean()
    return 0.5 * (micro + macro)


def predict(L, named=None):
    """top-5 class indices and p of the named (top-1) class from log p."""
    import torch
    o = L.topk(5, dim=1)
    top, lp1 = o.indices.cpu().numpy(), o.values[:, 0].cpu().numpy()
    if named is not None:
        named = np.asarray(named)
        sw = named != top[:, 0]
        lp1 = L[torch.arange(len(named)), torch.from_numpy(named).to(L.device)].cpu().numpy()
        for j in np.nonzero(sw)[0]:
            rest = [x for x in top[j] if x != named[j]]
            top[j] = [named[j]] + rest[:4]
    return top, np.exp(lp1)


def cmd_score(a):
    import torch
    import build_ship as BS
    import eval_australia as EA
    t0 = time.time()
    OUT = a.out or BS.SHIP
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    Ut = pq.read_table(os.path.join(AU, "labels.parquet"),
                       columns=["name", "genus", "family", "ship", "native", "euc", "inat_ids"]).to_pydict()
    nU = len(Ut["name"])
    Tt = np.load(os.path.join(AU, "text.npz"))["emb"].astype(np.float32)
    cen = np.load(os.path.join(TR, "heads", "centre.npz"))
    mu_i, n_tr = cen["image_mean"].astype(np.float32), cen["n_train"]
    ship = BS.Ship(BS.SHIP, "bank-int8.bin")
    lj = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    ship2u = np.full(len(lj), -1)
    for u, s_ in enumerate(Ut["ship"]):
        if s_ >= 0:
            ship2u[s_] = u
    nonlocal_ = np.ones(nU, bool)
    nonlocal_[ship2u] = False
    gnames = {g: i for i, g in enumerate(sorted(set(Ut["genus"])))}
    ctx = {"genus": np.array([gnames[g] for g in Ut["genus"]])}
    ids, E = all_embeddings()
    print(f"{len(ids):,} embeddings ({time.time() - t0:.0f} s)", flush=True)

    # ---- sets
    sets = {}

    def mk(name, emb, lat, lon, y, w, sp=None, sub=None, rows=None):
        emb = np.asarray(emb, np.float32)
        S = NS(name=name, n=len(emb), emb=emb, lat=np.asarray(lat, float), lon=np.asarray(lon, float),
               y=np.asarray(y, np.int64), w=np.asarray(w, float),
               sp=np.asarray(sp if sp is not None else y), sub=sub, rows=rows)
        S.Q = torch.from_numpy(BS.unit(BS.unit(emb) - mu_i[None, :]).astype(np.float32)).to(dev)
        S.yt = torch.from_numpy(np.maximum(S.y, 0)).to(dev)
        sets[name] = S
        return S
    SS = BS.load_sets()
    ev = SS["ev"]
    ids_w8, E_w8 = BS.load_parts(os.path.join(BS.SHIP, "eval", "coreml-w8"))
    pw8 = {int(p): i for i, p in enumerate(ids_w8)}
    for nm, X, e in (("A-val", ev["val"]["X"], ev["val"]),
                     ("A-test", E_w8[[pw8[int(p)] for p in ev["test"]["photo_id"]]], ev["test"])):
        y = np.where(e["y"] >= 0, ship2u[np.maximum(e["y"], 0)], -1)
        mk(nm, X, e["lat"], e["lon"], y, e["w"], sp=e["sp"])
    crows = EA.c_rows()
    ids_c, E_c = BS.load_parts(os.path.join(AU, "emb-w8"))
    cpos = {int(p): i for i, p in enumerate(ids_c)}
    for h in ("tune", "report"):
        rr = [r for r in crows if r["half"] == h and r["photo_id"] in cpos]
        mk("C-" + h, E_c[[cpos[r["photo_id"]] for r in rr]], [r["lat"] for r in rr], [r["lon"] for r in rr],
           [r["u"] for r in rr], [r["w"] for r in rr], sub=np.array([r["subset"] for r in rr]), rows=rr)
    # AU val/test (plan eval.parquet): AU-val minus every C-report and A-test observer
    te = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["observer_id", "split"]).to_pydict()
    excl = {r["observer_id"] for r in crows if r["half"] == "report"} | {
        o for o, sp_ in zip(te["observer_id"], te["split"]) if sp_ == "test"}
    pe = pq.read_table(os.path.join(AU, "plan", "eval.parquet"),
                       columns=["observer_id", "lat", "lon", "role", "u", "photo_id", "n_split"]).to_pydict()
    pe = {k: np.array(v) for k, v in pe.items()}
    i_e, ok_e = lookup(ids, pe["photo_id"])
    for role, nm in (("val", "AU-val"), ("test", "AU-test")):
        m = ok_e & (pe["role"] == role)
        if role == "val":
            m &= ~np.isin(pe["observer_id"], list(excl))
        u = pe["u"][m]
        cnt = collections.Counter(u.tolist())
        w = pe["n_split"][m] / np.array([cnt[x] for x in u])
        S = mk(nm, E[i_e[m]], pe["lat"][m], pe["lon"][m], u, w)
        S.observer = pe["observer_id"][m]
    # tuning subset of AU-val (observer hash), ≤ ~a.tune photos
    S = sets["AU-val"]
    frac = min(1.0, a.tune / S.n)
    hv = np.array([int.from_bytes(__import__("hashlib").sha256(f"{o}tune".encode()).digest()[:4], "big")
                   / 2 ** 32 for o in S.observer])
    m = hv < frac
    u = S.y[m]
    cnt = collections.Counter(u.tolist())
    full = collections.Counter(S.y.tolist())
    mk("AU-tune", S.emb[m], S.lat[m], S.lon[m], u, S.w[m] * np.array([full[x] / cnt[x] for x in u]))
    for nm, S in sets.items():
        print(f"  {nm}: {S.n:,} photos, {len(set(S.y[S.y >= 0])):,} classes", flush=True)
    TUNE = ("AU-tune", "A-val")

    # ---- Tasmanian shipped scorer (v0 and the hybrid's local part)
    for nm in TUNE:
        S = sets[nm]
        S.Ls = torch.from_numpy(ship.logp(S.emb, S.lat, S.lon).astype(np.float32)).to(dev)
    print(f"Ship log p ({time.time() - t0:.0f} s)", flush=True)

    res = {"sizes": {"U": nU, "train_classes": int((n_tr > 0).sum()), "train_photos": int(n_tr.sum())},
           "sets": {nm: {"photos": S.n, "classes": len(set(S.y[S.y >= 0]))} for nm, S in sets.items()}}

    # ---- 1. head: μ × epochs by AU-tune objective (image only), temperature on AU-tune
    heads = sorted(glob.glob(os.path.join(TR, "heads", "head-mu*-ep*.npz")))
    hres = []
    for f in heads:
        W = torch.from_numpy(np.load(f)["W"].astype(np.float32)).to(dev)
        S = sets["AU-tune"]
        raw = S.Q @ W.T
        t = fit_temp(raw, S.yt.masked_fill(torch.from_numpy(S.y < 0).to(dev), -1))
        r = {"head": os.path.basename(f), "temp": t, "obj": objective(raw, S)}
        hres.append(r)
        print(f"  {r}", flush=True)
    best = max(hres, key=lambda r: r["obj"])
    res["heads"] = hres
    W = np.load(os.path.join(TR, "heads", best["head"]))["W"].astype(np.float32)
    t_head = best["temp"]
    # int8 head (per-row): same objective?
    q8, sc8 = BS.int8_rows(W)
    W8 = q8.astype(np.float32) * sc8.astype(np.float32)[:, None]
    o8 = objective(sets["AU-tune"].Q @ torch.from_numpy(W8).to(dev).T, sets["AU-tune"])
    res["head_int8_obj"] = o8
    print(f"head {best['head']} T {t_head:.3f} obj {best['obj']:.4f}; int8 rows obj {o8:.4f}", flush=True)
    head_int8 = o8 >= best["obj"] - 0.001
    Wuse = W8 if head_int8 else W
    Wt = torch.from_numpy(Wuse).to(dev)
    for nm in TUNE:
        S = sets[nm]
        S.Lh = torch.log_softmax(t_head * (S.Q @ Wt.T), 1)

    # ---- 2. prototypes (1 per class: normalised sum of the centred train photos)
    X, y, _ = load_train([os.path.join(CACHE, "emb", "bioclip25"), os.path.join(TR, "emb")],
                         os.path.join(AU, "plan", "train.parquet"), nU)
    Pm = np.zeros((nU, 1024), np.float32)
    for i in range(0, len(X), 65536):
        xc = BS.unit(BS.unit(X[i:i + 65536].astype(np.float32)) - mu_i[None, :])
        np.add.at(Pm, y[i:i + 65536], xc)
    has = np.bincount(y, minlength=nU) > 0
    plab = np.nonzero(has)[0]
    Pv = BS.unit(Pm[plab])
    pq8, psc = BS.int8_rows(Pv)
    pwt = np.bincount(y, minlength=nU)[plab].clip(max=65535).astype(np.uint16)
    del X
    print(f"prototypes: {len(plab):,} classes ({time.time() - t0:.0f} s)", flush=True)
    for nm in TUNE:
        S = sets[nm]
        S.nb = BS.knn_neighbours(S.Q.cpu().numpy(), pq8, psc.astype(np.float32), 50)
    kres, bestk = [], None
    for k in (10, 25, 50):
        for tau in (0.02, 0.05, 0.1):
            for rho in (0.0, 0.5):
                S = sets["AU-tune"]
                Lk = BS.knn_vote(*S.nb, plab, nU, k, tau, pwt, rho)
                v = objective(torch.from_numpy(Lk.astype(np.float32)), NS(**{**S.__dict__, "yt": S.yt.cpu()}))
                kres.append({"k": k, "tau": tau, "rho": rho, "obj": v})
                if bestk is None or v > bestk["obj"]:
                    bestk = kres[-1]
    print(f"kNN on prototypes: best {bestk}", flush=True)
    kp = {x: bestk[x] for x in ("k", "tau", "rho")}

    def knn_L(S):
        if not hasattr(S, "nb"):
            S.nb = BS.knn_neighbours(S.Q.cpu().numpy(), pq8, psc.astype(np.float32), 50)
        return torch.from_numpy(BS.knn_vote(*S.nb, plab, nU, kp["k"], kp["tau"], pwt, kp["rho"])
                                .astype(np.float32)).to(dev)
    S = sets["AU-tune"]
    S.Lk_raw = knn_L(S)
    t_knn = fit_temp(S.Lk_raw, S.yt)
    oms = {}
    for om in (0.0, 0.25, 0.5, 1.0, 2.0, 4.0):
        oms[om] = objective(S.Lh + om * torch.log_softmax(t_knn * S.Lk_raw, 1), S)
    omega = max(oms, key=oms.get)
    t_bl = fit_temp(S.Lh + omega * torch.log_softmax(t_knn * S.Lk_raw, 1), S.yt) if omega else 1.0
    res["knn"] = {"sweep": kres, "chosen": kp, "knn_temp": t_knn, "omega_sweep": oms, "omega": omega,
                  "blend_temp": t_bl}
    print(f"blend: ω {omega} ({oms}), knn T {t_knn:.3f}, blend T {t_bl:.3f}", flush=True)

    def img_L(S):
        if not omega:
            return S.Lh
        return torch.log_softmax(t_bl * (S.Lh + omega * torch.log_softmax(t_knn * knn_L(S), 1)), 1)
    for nm in TUNE:
        sets[nm].Li = img_L(sets[nm])
    # zero-shot pull: centred cosine to the class text vectors (BioCLIP's own knowledge
    # of rare / photo-less classes, which the trained rows partly forget)
    Tc = Tt - Tt.mean(0)
    Tc /= np.linalg.norm(Tc, axis=1, keepdims=True)
    tq8, tsc = BS.int8_rows(Tc)
    Tct = torch.from_numpy(tq8.astype(np.float32) * tsc.astype(np.float32)[:, None]).to(dev)
    zres = []
    for kz in (30.0, 50.0, 70.0, 100.0):
        S = sets["AU-tune"]
        Lz = torch.log_softmax(kz * (S.Q @ Tct.T), 1)
        for oz in (0.0, 0.25, 0.5, 1.0, 2.0):
            zres.append({"kappa": kz, "omega": oz, "obj": objective(S.Li + oz * Lz, S)})
    bz = max(zres, key=lambda r: r["obj"])
    res["zeroshot"] = {"sweep": zres, "chosen": bz}
    print(f"zero-shot blend: chosen {bz} (none {[r['obj'] for r in zres if r['omega'] == 0][0]:.4f})", flush=True)
    for nm in TUNE:
        S = sets[nm]
        if bz["omega"]:
            S.Li = torch.log_softmax(S.Li + bz["omega"] * torch.log_softmax(bz["kappa"] * (S.Q @ Tct.T), 1), 1)

    # ---- 3. Australia-wide prior: σ, α, λ on AU-tune
    pc = prior_counts()
    tmp = os.path.join(TR, "au-prior-tuning.bin")
    BS.write_deg_prior(tmp, np.array(pc["cy"]), np.array(pc["cx"]), np.array(pc["u"]), np.array(pc["n"]),
                       nU, PRIOR_GRID, 25.0, 16.0, "tuning copy")
    prior = BS.DegPrior(tmp)
    freq = torch.from_numpy(prior.freq.astype(np.float32)).to(dev)
    for nm in TUNE:
        S = sets[nm]
        S.K = {s_: torch.from_numpy(prior.density(S.lat, S.lon, s_).astype(np.float32)) for s_ in SIGMAS}

    def lprior(S, s_, al):
        K = S.K[s_].to(dev)
        return torch.log((K + al * freq[None, :]) / (K.sum(1, keepdim=True) + al))
    pres = []
    for s_ in SIGMAS:
        for al in ALPHAS:
            lp = lprior(sets["AU-tune"], s_, al)
            for lam in LAMS:
                pres.append({"sigma": s_, "alpha": al, "lam": lam,
                             "obj": objective(sets["AU-tune"].Li + lam * lp, sets["AU-tune"])})
    bp = max(pres, key=lambda r: r["obj"])
    res["prior"] = {"sweep": pres, "chosen": bp, "image_only_obj": objective(sets["AU-tune"].Li, sets["AU-tune"])}
    print(f"prior: chosen {bp} (image only {res['prior']['image_only_obj']:.4f})", flush=True)
    for nm in TUNE:
        S = sets[nm]
        S.La = torch.log_softmax(S.Li + bp["lam"] * lprior(S, bp["sigma"], bp["alpha"]), 1)
    t_fin = 1.0 / fit_temp(sets["AU-tune"].La, sets["AU-tune"].yt)  # L / T
    print(f"final temperature T = {t_fin:.3f} (log p / T)", flush=True)

    # ---- 4. hybrid with the Tasmanian scorer, strict A-val guard
    nl = torch.from_numpy(nonlocal_).to(dev)
    s2u = torch.from_numpy(ship2u).to(dev)

    def hybrid(S, prm):
        La = torch.log_softmax(S.La / prm["tau"] - prm["b"] * nl[None, :].float(), 1)
        p_out = La[:, nl].exp().sum(1, keepdim=True).clamp(0, 1)
        Lf = La.clone()
        Lf[:, s2u] = torch.log((1 - p_out).clamp_min(1e-30)) + S.Ls
        top = Lf.argmax(1)
        bl = s2u[S.Ls.argmax(1)]
        ar = torch.arange(S.n, device=dev)
        swap = nl[top] & (Lf[ar, top] - Lf[ar, bl] <= prm["m"])
        return Lf, torch.where(swap, bl, top)

    def mets(S, L, named=None, mask=None):
        top, p1 = predict(L, None if named is None else named.cpu().numpy())
        return EA.metrics(S, top, p1, ctx, mask)
    def v0L(Ls):
        L = torch.full((Ls.shape[0], nU), -1e9, device=dev)
        L[:, s2u] = Ls
        return L
    base = mets(sets["A-val"], v0L(sets["A-val"].Ls))
    hres = []
    for tau in (0.75, 1.0, 1.5):
        for b in (0.0, 1.0, 2.0, 4.0):
            for m_ in (0.0, 1.0, 2.0):
                prm = {"tau": tau, "b": b, "m": m_}
                Lf, nm_ = hybrid(sets["A-val"], prm)
                rA = mets(sets["A-val"], Lf, nm_)
                Lf2, nm2 = hybrid(sets["AU-tune"], prm)
                hit = (nm2 == sets["AU-tune"].yt).cpu().numpy()
                S = sets["AU-tune"]
                micro = (hit * S.w).sum() / S.w.sum()
                _, inv = np.unique(S.y, return_inverse=True)
                obj = 0.5 * (micro + (np.bincount(inv, hit) / np.bincount(inv)).mean())
                ok = rA["top1_w"] >= base["top1_w"] - 0.0005 and rA["conf_wrong_w"] <= base["conf_wrong_w"] + 0.0005
                hres.append({"prm": prm, "A-val_top1_w": rA["top1_w"], "A-val_conf_wrong_w": rA["conf_wrong_w"],
                             "obj": obj, "ok": ok})
    good = [r for r in hres if r["ok"]]
    bh = max(good or hres, key=lambda r: r["obj"])
    res["hybrid"] = {"sweep": hres, "chosen": bh, "n_ok": len(good), "v0_A-val": base}
    print(f"hybrid: chosen {bh} ({len(good)}/{len(hres)} pass the strict A-val guard; t1 obj "
          f"{objective(sets['AU-tune'].La, sets['AU-tune']):.4f})", flush=True)
    Lf, _ = hybrid(sets["AU-tune"], bh["prm"])
    t_hfin = 1.0 / fit_temp(Lf, sets["AU-tune"].yt)
    print(f"hybrid final T = {t_hfin:.3f}", flush=True)

    # ---- 5. write the shipping files, then score everything FROM THE FILES
    os.makedirs(OUT, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d")
    hd = {"weight": q8, "scale": sc8} if head_int8 else {"weight": W.astype(np.float16)}
    BS.write_blob(os.path.join(OUT, "au-head.bin"),
                  {"kind": "plantid-head", "version": 1, "model": HF, "labels": nU, "temp": t_head,
                   "bias": None, "variant": "int8 per-row" if head_int8 else "fp16",
                   "recipe": "q = normalise(normalise(embedding) − centre); log p = log_softmax(temp · "
                             "(weight · q) [× scale per row when int8]); rows of classes without train "
                             "photos are their centred text embeddings",
                   "trained": {"photos": int(n_tr.sum()), "classes_with_photos": int((n_tr > 0).sum()),
                               "head": best["head"], "built": stamp}},
                  {**hd, "centre": mu_i})
    BS.write_blob(os.path.join(OUT, "au-protos.bin"),
                  {"kind": "plantid-bank", "variant": "proto1-int8", "rows": int(len(plab)),
                   "recipe": "one prototype per class with train photos = normalise(Σ centred train "
                             "embeddings); similarity = scale[row] · (q · vectors[row]); weight = train "
                             "photos (capped 65535)",
                   "scoring": {**kp, "knn_temp": t_knn, "omega": omega, "blend_temp": t_bl,
                               "zs_kappa": bz["kappa"], "zs_omega": bz["omega"],
                               "lam": bp["lam"], "final_temp": t_fin},
                   "hybrid": {**bh["prm"], "final_temp": t_hfin}},
                  {"vectors": pq8, "scale": psc, "labels": plab.astype(np.uint16), "weight": pwt})
    BS.write_deg_prior(os.path.join(OUT, "au-prior.bin"), np.array(pc["cy"]), np.array(pc["cx"]),
                       np.array(pc["u"]), np.array(pc["n"]), nU, PRIOR_GRID, bp["sigma"], bp["alpha"],
                       "pool-observer research-grade iNat records (no val/test observer; positional "
                       "accuracy ≤ 5 km), Australia box incl. Tasmania, counts per (cell, class)")
    BS.write_blob(os.path.join(OUT, "au-text.bin"),
                  {"kind": "plantid-text", "version": 1, "model": HF, "rows": nU,
                   "recipe": "centred unit text vectors of the classes' taxonomic prompts (\"a photo of "
                             "<kingdom … epithet>.\"), int8 per row: t = scale[row] · vectors[row]; "
                             "L_zs = log_softmax(zs_kappa · (q · t)) with the head's q"},
                  {"vectors": tq8, "scale": tsc})
    write_au_labels(Ut, lj, n_tr, OUT)
    ash = BS.AuShip(OUT, ship)
    res["chosen"] = {"head": best["head"], "head_int8": bool(head_int8), "t_head": t_head, **kp,
                     "zs_kappa": bz["kappa"], "zs_omega": bz["omega"],
                     "knn_temp": t_knn, "omega": omega, "blend_temp": t_bl, **{k: bp[k] for k in
                     ("sigma", "alpha", "lam")}, "final_temp": t_fin, "hybrid": {**bh["prm"], "final_temp": t_hfin}}
    rep, VARS = {}, ("v0", "t_head", "t1", "t1_cal", "th", "th_cal", "tg_cal")

    def preds(S, lo, hi):
        """(top-5, p1) per variant for rows lo:hi, from the files (AuShip)."""
        e, la, lo_ = S.emb[lo:hi], S.lat[lo:hi], S.lon[lo:hi]
        Ls = ship.logp(e, la, lo_).astype(np.float32)
        L1u = ash.logp_au(e, la, lo_, calibrated=False)
        Lh, named = ash.hybrid(e, la, lo_)
        L1 = BS.log_softmax(L1u / t_fin)
        tas = BS.in_tas(la, lo_)
        out = {"v0": predict(v0L(torch.from_numpy(Ls).to(dev))),
               "t_head": predict(torch.log_softmax(t_head * (S.Q[lo:hi] @ Wt.T), 1))}
        tt = lambda x: torch.from_numpy(np.ascontiguousarray(x, np.float32)).to(dev)  # noqa: E731
        out["t1"], out["t1_cal"] = predict(tt(L1u)), predict(tt(L1))
        # uncalibrated hybrid: same ranking, p before the final temperature
        out["th"] = predict(torch.log_softmax(tt(Lh) * t_hfin, 1), named)
        out["th_cal"] = predict(tt(Lh), named)
        # geo-gated: the hybrid inside the Tasmania box, the AU model alone elsewhere
        out["tg_cal"] = predict(tt(np.where(tas[:, None], Lh, L1)), np.where(tas, named, L1.argmax(1)))
        return out
    for nm in ("A-val",) + tuple(a.report):
        S = sets[nm]
        parts = [preds(S, lo, min(lo + 2048, S.n)) for lo in range(0, S.n, 2048)]
        P_ = {v: (np.concatenate([p[v][0] for p in parts]), np.concatenate([p[v][1] for p in parts]))
              for v in VARS}
        S.P = P_
        out = {}
        for v in VARS:
            top, p1 = P_[v]
            M = lambda mask=None: EA.metrics(S, top, p1, ctx, mask)  # noqa: E731
            if nm == "C-report":
                ins = np.array([Ut["ship"][u] >= 0 for u in S.y])
                out[v] = {"main": M(S.sub == "main"), "euc": M(S.sub == "euc"),
                          "main_in2675": M((S.sub == "main") & ins), "main_not2675": M((S.sub == "main") & ~ins)}
            elif nm == "AU-test":
                ntr = n_tr[S.y]
                out[v] = {"all": M()}
                for lo, hi, tn in ((0, 0, "0"), (1, 4, "1-4"), (5, 19, "5-19"), (20, 99, "20-99"),
                                   (100, 10 ** 9, "100")):
                    out[v]["train_" + tn] = M((ntr >= lo) & (ntr <= hi))
                out[v]["euc"] = M(np.array([Ut["euc"][u] for u in S.y]))
                tas = BS.in_tas(S.lat, S.lon)
                out[v]["tas"], out[v]["mainland"] = M(tas), M(~tas)
            else:
                out[v] = M()
        rep[nm] = out
        print(f"{nm} ({time.time() - t0:.0f} s): " + ", ".join(
            f"{v} {100 * (r['main']['top1_sp'] if nm == 'C-report' else r['all']['top1_w'] if nm == 'AU-test' else r['top1_w']):.1f}"
            for v, r in out.items()), flush=True)
    # paired A-test vs v0
    S = sets["A-test"]
    inl = S.y >= 0
    r0 = inl & (S.P["v0"][0][:, 0] == S.y)
    for v in ("th_cal", "t1_cal"):
        rh = inl & (S.P[v][0][:, 0] == S.y)
        res[f"{v[:2]}_A_paired"] = {"lost": int((r0 & ~rh).sum()), "gained": int((~r0 & rh).sum()),
                                    "photos": int(inl.sum())}
    res["report"] = rep
    files = {f: BS.size_of(os.path.join(OUT, f)) for f in ("au-head.bin", "au-protos.bin", "au-prior.bin",
                                                               "au-text.bin", "au-labels.json")}
    res["files"] = files
    json.dump(res, open(os.path.join(TR, "results.json"), "w"), indent=1, default=float)
    write_md(res, os.path.join(TR, "results.md"))
    print(open(os.path.join(TR, "results.md")).read())
    print(f"total {time.time() - t0:.0f} s")


def write_au_labels(Ut, lj, n_tr, out_dir):
    """au-labels.json: one entry per class (= row of au-head.bin); `ship` = the
    Tasmanian label index (head.bin row) or −1; UN links copied from the
    Tasmanian labels.json."""
    import build_ship as BS
    out = []
    for u in range(len(Ut["name"])):
        e = {"name": Ut["name"][u], "genus": Ut["genus"][u], "family": Ut["family"][u] or "",
             "native": bool(Ut["native"][u]), "inat": [int(i) for i in (Ut["inat_ids"][u] or [])],
             "ship": int(Ut["ship"][u]), "train_photos": int(n_tr[u])}
        if e["ship"] >= 0 and "un" in lj[e["ship"]]:
            e["un"] = lj[e["ship"]]["un"]
        out.append(e)
    json.dump({"version": 1, "model": HF, "count": len(out),
               "note": "index = row of au-head.bin / class id of au-protos.bin and au-prior.bin; "
                       "ship = row of the Tasmanian head.bin (labels.json index) or -1; un as in labels.json",
               "labels": out}, open(os.path.join(out_dir, "au-labels.json"), "w"), ensure_ascii=False,
              separators=(",", ":"))


def write_md(res, path):
    P = lambda x: "–" if x is None else f"{100 * x:.1f}"  # noqa: E731
    rep = res["report"]
    out = ["| variant | A top-1 (w) | A top-5 | A conf. wrong | C-main top-1 sp. / w | C-main top-5 | "
           "C-main genus sp. | C-main conf. wrong | euc top-1 | euc top-5 | euc genus | euc conf. wrong | "
           "AU-test top-1 w / sp. | AU-test conf. wrong |", "|" + "---|" * 14]
    for v in rep["A-test"]:
        A, M, Eu, T = rep["A-test"][v], rep["C-report"][v]["main"], rep["C-report"][v]["euc"], rep["AU-test"][v]["all"]
        out.append(f"| {v} | {P(A['top1_w'])} | {P(A['top5_w'])} | {P(A['conf_wrong_w'])} | "
                   f"{P(M['top1_sp'])} / {P(M['top1_w'])} | {P(M['top5'])} | {P(M['genus1_sp'])} | "
                   f"{P(M['conf_wrong'])} | {P(Eu['top1'])} | {P(Eu['top5'])} | {P(Eu['genus1'])} | "
                   f"{P(Eu['conf_wrong'])} | {P(T['top1_w'])} / {P(T['top1_sp'])} | {P(T['conf_wrong_w'])} |")
    out += ["", "AU-test by training photos of the true class (top-1 per species):"]
    for v in rep["AU-test"]:
        r = rep["AU-test"][v]
        out.append(f"- {v}: " + ", ".join(f"{k[6:]} {P(r[k]['top1_sp'])} (n {r[k]['n']})"
                                          for k in r if k.startswith("train_")) +
                   f"; Tasmania {P(r['tas']['top1_w'])}, mainland {P(r['mainland']['top1_w'])}, "
                   f"eucalypts {P(r['euc']['top1'])} (n {r['euc']['n']})")
    out += ["", f"chosen: {json.dumps(res['chosen'])}",
            f"paired A-test vs v0: th {res['th_A_paired']}, t1 {res['t1_A_paired']}",
            f"files: {res['files']}"]
    open(path, "w").write("\n".join(out) + "\n")


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("manifest")
    p = sub.add_parser("vm-embed")
    p.add_argument("--bucket", required=True)
    p.add_argument("--todo", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--shards", type=int, default=0)
    p.add_argument("--threads", type=int, default=48)
    p.add_argument("--batch", type=int, default=128)
    p.add_argument("--device", default="cuda")
    p = sub.add_parser("vm-train")
    p.add_argument("--bucket", required=True)
    p.add_argument("--work", required=True)
    p = sub.add_parser("score")
    p.add_argument("--tune", type=int, default=12000, help="AU-val photos used for tuning sweeps")
    p.add_argument("--report", nargs="+", default=["A-test", "C-report", "AU-test"])
    p.add_argument("--out", help="where the au-* shipping files go (default ship/)")
    a = ap.parse_args()
    sys.path.insert(0, HERE)
    {"manifest": cmd_manifest, "vm-embed": cmd_vm_embed, "vm-train": cmd_vm_train,
     "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    main()

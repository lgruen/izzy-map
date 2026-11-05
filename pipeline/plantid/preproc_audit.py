#!/usr/bin/env python3
"""Image-preprocessing audit for the BioCLIP 2.5 plant ID (notes/preprocessing.md).

Read-only with respect to every other script: it imports a few helpers
(build_ship.preprocess / resize_crop, train_v2.train) but writes only to
pipeline/cache/plantid/preproc/ (gitignored).

Subcommands:
  repro      the de-dup calibration's "same photo, two iNat sizes" pairs
             (expand_inat calibrate-emb, seed 3): fetch medium/small/large,
             record size, EXIF orientation, ICC profile, then ONE pipeline
             (open_clip eval transform, fp32 on MPS) for every file, plus
             controls (medium downscaled to the small's size, fp16).
  scan       EXIF orientation / ICC profile census of the local iNat photos
  parity     on-device emulation vs the training recipe on N photos:
             EXIF transpose, P3 handling, Core ML w8 vs torch fp16
  views      crop strategies (centre / pad / squash / 5-crop / avg) as
             embeddings (Core ML w8 on the ANE, or torch on cuda/mps)
  score      top-1/top-5 of the v2 head on stored view embeddings

Env (one for all):
  uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \
    --with open_clip_torch --with coremltools --with 'numpy<2.3' --with pyarrow \
    --with pillow --with pandas python3 -I pipeline/plantid/preproc_audit.py <cmd>
"""
import argparse
import concurrent.futures as cf
import glob
import http.client
import io
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CACHE = os.path.join(HERE, "..", "cache", "plantid")
OUT = os.path.join(CACHE, "preproc")
WORK = os.path.join(CACHE, "extra", "work")
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"GIF8", b"RIFF")
HF = "hf-hub:imageomics/bioclip-2.5-vith14"
MEAN = np.array([0.48145466, 0.4578275, 0.40821073], np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], np.float32)


def fetch(pid, ext, size, conn=None):
    c = conn or http.client.HTTPSConnection(HOST, timeout=30)
    for attempt in range(3):
        try:
            c.request("GET", f"/photos/{pid}/{size}.{ext}", headers=UA)
            r = c.getresponse()
            b = r.read()
            return b if r.status == 200 and b.startswith(MAGIC) else None
        except Exception:  # noqa: BLE001
            c = http.client.HTTPSConnection(HOST, timeout=30)
            time.sleep(1 + attempt)
    return None


def fetch_many(items, threads=32):
    """items = [(key, pid, ext, size)] → {key: bytes or None}"""
    out = {}
    with cf.ThreadPoolExecutor(threads) as ex:
        futs = {ex.submit(fetch, p, e, s): k for k, p, e, s in items}
        for f in cf.as_completed(futs):
            out[futs[f]] = f.result()
    return out


def info(body):
    from PIL import Image
    with Image.open(io.BytesIO(body)) as im:
        icc = im.info.get("icc_profile")
        desc = None
        if icc:
            try:
                from PIL import ImageCms
                desc = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(icc))).strip()
            except Exception:  # noqa: BLE001
                desc = "unreadable"
        return {"w": im.width, "h": im.height, "mode": im.mode, "fmt": im.format,
                "orient": int(im.getexif().get(274, 1) or 1), "icc": desc, "bytes": len(body)}


def to_tensor(rgb224):
    x = (np.asarray(rgb224, np.float32) / 255.0 - MEAN) / STD
    return x.transpose(2, 0, 1)


class Torch:
    def __init__(self, dev=None, half=False):
        import open_clip
        import torch
        self.torch = torch
        self.dev = dev or ("cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu")
        m, _, self.tf = open_clip.create_model_and_transforms(HF)
        self.dtype = torch.float16 if half else torch.float32
        self.m = m.visual.to(self.dev).to(self.dtype).eval()

    def __call__(self, X, bs=32):
        out = []
        with self.torch.inference_mode():
            for i in range(0, len(X), bs):
                x = self.torch.from_numpy(np.ascontiguousarray(np.stack(X[i:i + bs]))).to(self.dev, self.dtype)
                e = self.m(x).float()
                out.append(self.torch.nn.functional.normalize(e, dim=-1).cpu().numpy())
        return np.concatenate(out)


class CoreML:
    def __init__(self, variant="w8", cu="ALL"):
        import coremltools as ct
        p = os.path.join(CACHE, "ship", "encoder", f"PlantEncoder-{variant}.mlpackage")
        self.m = ct.models.MLModel(p, compute_units=ct.ComputeUnit[cu])

    def __call__(self, X, bs=None):
        out = []
        for x in X:
            e = self.m.predict({"pixel_values": x[None].astype(np.float32)})["embedding"].reshape(-1)
            out.append(e / np.linalg.norm(e))
        return np.stack(out).astype(np.float32)


def rgb(body, exif=False):
    from PIL import Image, ImageOps
    im = Image.open(io.BytesIO(body))
    if exif:
        im = ImageOps.exif_transpose(im)
    return im.convert("RGB")


# ------------------------------------------------------------------ repro

def cmd_repro(a):
    import pyarrow.parquet as pq
    import pandas as pd
    from build_ship import resize_crop
    from PIL import Image
    C = pq.read_table(os.path.join(WORK, "candidates.parquet"),
                      columns=["photo_id", "ext", "observation_uuid"]).to_pandas()
    H = pd.concat([pq.read_table(f, columns=["photo_id", "status"]).to_pandas()
                   for f in sorted(glob.glob(os.path.join(WORK, "hashes-cand-part*.parquet")))])
    C = C[C["photo_id"].isin(H.loc[H["status"].isin(["ok", "local"]), "photo_id"])]
    g = C.groupby("observation_uuid")
    pairs = [(int(x.iloc[0].photo_id), x.iloc[0].ext) for _, x in g if len(x) >= 2]
    rng = np.random.default_rng(3)
    pairs = [pairs[i] for i in rng.permutation(len(pairs))][:a.n]
    t0 = time.time()
    B = fetch_many([((p, s), p, e, s) for p, e in pairs for s in ("small", "medium", "large", "original")])
    print(f"fetched {sum(v is not None for v in B.values())} files in {time.time() - t0:.0f} s", flush=True)
    rows, X, keys = [], [], []
    for p, e in pairs:
        if B.get((p, "medium")) is None or B.get((p, "small")) is None:
            continue
        r = {"photo_id": p, "ext": e}
        for s in ("small", "medium", "large", "original"):
            if B.get((p, s)) is not None:
                r[s] = info(B[(p, s)])
        rows.append(r)
        med = rgb(B[(p, "medium")])
        for s in ("small", "medium", "large"):
            if B.get((p, s)) is not None:
                X.append(to_tensor(resize_crop(rgb(B[(p, s)]))))
                keys.append((p, s))
                if r[s]["orient"] != 1:
                    X.append(to_tensor(resize_crop(rgb(B[(p, s)], exif=True))))
                    keys.append((p, s + "-exif"))
        # control: the medium reduced to the small's pixel size (bicubic, as iNat would)
        sw, sh = r["small"]["w"], r["small"]["h"]
        X.append(to_tensor(resize_crop(med.resize((sw, sh), Image.LANCZOS))))
        keys.append((p, "med->small"))
    print(f"{len(rows)} photos, {len(X)} tensors", flush=True)
    t1 = time.time()
    E = Torch(half=False)(X)
    print(f"fp32 {E.shape[0]} embeddings in {time.time() - t1:.0f} s", flush=True)
    ix = {k: i for i, k in enumerate(keys)}
    t1 = time.time()
    hk = [k for k in keys if k[1] in ("medium", "small")]
    Eh = Torch(half=True)([X[ix[k]] for k in hk])
    ih = {k: i for i, k in enumerate(hk)}
    print(f"fp16 in {time.time() - t1:.0f} s", flush=True)
    for r in rows:
        p = r["photo_id"]
        m = E[ix[(p, "medium")]]
        for k in ("small", "large", "med->small", "small-exif", "large-exif", "medium-exif"):
            if (p, k) in ix:
                r[f"cos_{k}"] = float(m @ E[ix[(p, k)]])
        r["cos_small_fp16"] = float(Eh[ih[(p, "medium")]] @ Eh[ih[(p, "small")]])
        r["cos_fp16_vs_fp32_medium"] = float(Eh[ih[(p, "medium")]] @ m)
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, "repro.json"), "w"), indent=1)
    df = pd.json_normalize(rows)
    pct = lambda s: s.quantile([0, .1, .5, .9]).round(4).tolist()  # noqa: E731
    for c in [c for c in df.columns if c.startswith("cos_")]:
        print(f"{c:28s} min/p10/p50/p90 {pct(df[c].dropna())}")
    df["small_short"] = df[["small.w", "small.h"]].min(1)
    df["aspect"] = df[["medium.w", "medium.h"]].max(1) / df[["medium.w", "medium.h"]].min(1)
    cols = ["photo_id", "small.w", "small.h", "medium.w", "medium.h", "large.w", "large.h", "original.w",
            "original.h", "medium.orient", "small.orient", "large.orient", "medium.icc", "small.icc",
            "cos_small", "cos_med->small", "cos_small_fp16", "cos_large"]
    cols = [c for c in cols if c in df.columns]
    print(df.sort_values("cos_small")[cols].head(12).to_string())
    print("corr(cos_small, small short side)", round(df["cos_small"].corr(df["small_short"]), 3),
          "corr(cos_small, cos_med->small)", round(df["cos_small"].corr(df["cos_med->small"]), 3))
    print("orientation tags:", {s: df[f"{s}.orient"].value_counts().to_dict() for s in ("small", "medium", "large")
                                if f"{s}.orient" in df})
    print("icc:", {s: df[f"{s}.icc"].fillna("none").value_counts().to_dict() for s in ("small", "medium", "large")
                   if f"{s}.icc" in df})


# ------------------------------------------------------------------ scan

def cmd_scan(a):
    """EXIF orientation + ICC census of local iNat photos (header reads only)."""
    import collections
    from PIL import Image, ImageCms
    dirs = [os.path.join(CACHE, d) for d in ("photos", "australia/photos", "extra/inat")]
    files = []
    for d in dirs:
        fs = sorted(glob.glob(os.path.join(d, "*.*")))
        rng = np.random.default_rng(0)
        files += [fs[i] for i in rng.permutation(len(fs))[:a.n]]

    def one(f):
        try:
            with Image.open(f) as im:
                o = int(im.getexif().get(274, 1) or 1)
                icc = im.info.get("icc_profile")
                d = None
                if icc:
                    try:
                        d = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(icc))).strip()
                    except Exception:  # noqa: BLE001
                        d = "unreadable"
                return os.path.basename(os.path.dirname(f)), o, d, im.mode, im.format
        except Exception as e:  # noqa: BLE001
            return os.path.basename(os.path.dirname(f)), -1, repr(e)[:40], None, None
    t = time.time()
    with cf.ThreadPoolExecutor(8) as ex:
        R = list(ex.map(one, files))
    out = {}
    for d in sorted({r[0] for r in R}):
        rr = [r for r in R if r[0] == d]
        out[d] = {"n": len(rr), "orientation": dict(collections.Counter(r[1] for r in rr)),
                  "icc": dict(collections.Counter(r[2] or "none" for r in rr).most_common(8)),
                  "mode": dict(collections.Counter(r[3] for r in rr)), "format": dict(collections.Counter(r[4] for r in rr))}
    out["seconds"] = round(time.time() - t, 1)
    os.makedirs(OUT, exist_ok=True)
    json.dump(out, open(os.path.join(OUT, "scan.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


# ------------------------------------------------------------------ manifest

def cmd_manifest(a):
    """Test sets (A-test, AU-test) with labels after eval_v2's class merges,
    their reference embeddings, the v2 head, training photo ids → preproc/manifest.npz"""
    import collections
    import pyarrow.parquet as pq
    import eval_v2 as EV
    import train_v2 as V
    import build_ship as BS
    t0 = time.time()
    D, U, genus, euc, sets, ship, ash = EV.load_sets()
    run = np.load(os.path.join(V.V2, "runs", a.run + ".npz"))
    L_ = pq.read_table(os.path.join(CACHE, "australia", "labels.parquet"),
                       columns=["name", "inat_ids", "family"]).to_pydict()
    C = D["T"].shape[0]
    n_tr = run["n_c"].copy()
    merge = V.class_merges(L_["name"], L_["inat_ids"], n_tr, V.name_map_pairs(L_["inat_ids"]))
    mapv = np.arange(C)
    for f_, t_ in merge.items():
        mapv[f_] = t_
        n_tr[t_] += n_tr[f_]
        n_tr[f_] = 0
    out = {"W": run["W"], "b": run["b"], "mu": D["mu"], "T": D["T"], "s0": D["s0"], "genus": genus,
           "euc": np.asarray(euc, bool), "n_tr": n_tr, "merge_from": np.array(list(merge), np.int64)}
    for nm in ("A-test", "AU-test"):
        S = sets[nm]
        y = np.where(S.y >= 0, mapv[np.maximum(S.y, 0)], -1)
        k = nm.replace("-", "")
        out[k + "_pid"], out[k + "_ext"], out[k + "_y"] = np.asarray(S.pid, np.int64), np.asarray(S.ext), y
        out[k + "_w"], out[k + "_emb"] = S.w, S.emb
    # training photos: ids from data.npz, ext from the two train tables
    ext = {}
    for f in (os.path.join(CACHE, "australia", "plan", "train.parquet"), os.path.join(CACHE, "sets", "train.parquet")):
        t = pq.read_table(f, columns=["photo_id", "ext"]).to_pydict()
        ext.update(zip(t["photo_id"], t["ext"]))
    out["tr_pid"], out["tr_y"] = D["pid"], D["ytr"]
    out["tr_ext"] = np.array([ext.get(int(p), "") for p in D["pid"]])
    out["tr_tas"] = D["tas"]
    print({k: v.shape for k, v in out.items()}, "missing ext", int((out["tr_ext"] == "").sum()))
    os.makedirs(OUT, exist_ok=True)
    np.savez(os.path.join(OUT, "manifest.npz"), **out)
    json.dump({"family": L_["family"], "name": L_["name"]}, open(os.path.join(OUT, "labels.json"), "w"))
    print(f"manifest in {time.time() - t0:.0f} s")


def load_manifest():
    return np.load(os.path.join(OUT, "manifest.npz"), allow_pickle=False)


def head_scores(M, E, W=None, b=None):
    """v2 head logits (eval_v2.logits) for raw embeddings E → top-5 indices."""
    W = M["W"].astype(np.float32) if W is None else W
    b = M["b"].astype(np.float32) if b is None else b
    q = E.astype(np.float32)
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    q = q - M["mu"]
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    L = q @ W.T + b
    if W.shape[0] == M["W"].shape[0]:
        L[:, M["merge_from"]] = -1e4
    return np.argsort(-L, axis=1)[:, :5]


def metrics(top, y, w=None, mask=None):
    m = (y >= 0) if mask is None else (mask & (y >= 0))
    t, yy = top[m], y[m]
    r1 = t[:, 0] == yy
    r5 = (t == yy[:, None]).any(1)
    ww = np.ones(len(yy)) if w is None else w[m]
    cls = np.unique(yy)
    sp1 = np.mean([r1[yy == c].mean() for c in cls])
    sp5 = np.mean([r5[yy == c].mean() for c in cls])
    return {"n": int(m.sum()), "species": int(len(cls)), "sp_top1": round(100 * sp1, 2), "sp_top5": round(100 * sp5, 2),
            "nat_top1": round(100 * float((r1 * ww).sum() / ww.sum()), 2),
            "nat_top5": round(100 * float((r5 * ww).sum() / ww.sum()), 2)}


# ------------------------------------------------------------------ parity

def app_square(im):
    """PlantIDPhoto.pixels(in: default crop) + PlantIDPreprocess.tensor: the
    largest centred square in whole pixels, then Pillow bicubic to 224."""
    from PIL import Image
    W, H = im.size
    s = min(W, H)
    x, y = int(round((W - s) / 2)), int(round((H - s) / 2))  # unit-rect rounding ≈ this
    sq = im.crop((x, y, x + s, y + s))
    return np.asarray(sq.resize((224, 224), Image.BICUBIC), np.uint8)


def to_srgb(im, body):
    from PIL import ImageCms
    icc = Image_icc(body)
    if not icc:
        return im, False
    try:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        d = ImageCms.getProfileDescription(src).strip()
        if d.lower().startswith("srgb") or "61966" in d:
            return im, False
        return ImageCms.profileToProfile(im, src, ImageCms.createProfile("sRGB"), outputMode="RGB"), True
    except Exception:  # noqa: BLE001
        return im, False


def Image_icc(body):
    from PIL import Image
    with Image.open(io.BytesIO(body)) as im:
        return im.info.get("icc_profile")


def cmd_parity(a):
    from build_ship import resize_crop
    M = load_manifest()
    rng = np.random.default_rng(11)
    y_all = M["AUtest_y"]
    idx = rng.permutation(np.flatnonzero(y_all >= 0))[:a.n]
    pids, exts = M["AUtest_pid"][idx], M["AUtest_ext"][idx]
    t0 = time.time()
    B = fetch_many([((int(p), s), int(p), e, s) for p, e in zip(pids, exts) for s in ("medium", "original")], 48)
    print(f"fetched {sum(v is not None for v in B.values())}/{len(B)} in {time.time() - t0:.0f} s", flush=True)
    enc = CoreML(a.variant)
    keep, V = [], {k: [] for k in ("train_w8", "app_w8", "app_orig_w8", "app_srgb_w8")}
    conv = []
    t1 = time.time()
    for j, (p, e) in enumerate(zip(pids, exts)):
        bm, bo = B.get((int(p), "medium")), B.get((int(p), "original"))
        if bm is None or bo is None:
            continue
        im = rgb(bm)
        xs = [to_tensor(resize_crop(im)), to_tensor(app_square(im)), to_tensor(app_square(rgb(bo, exif=True)))]
        ims, c = to_srgb(Image_open_rgb(bm), bm)
        xs.append(to_tensor(app_square(ims)))
        E = enc(xs)
        for k, v in zip(V, E):
            V[k].append(v)
        keep.append(idx[j])
        conv.append(c)
    print(f"{len(keep)} photos x 4 in {time.time() - t1:.0f} s", flush=True)
    keep, conv = np.array(keep), np.array(conv)
    ref = M["AUtest_emb"][keep].astype(np.float32)
    ref /= np.linalg.norm(ref, axis=1, keepdims=True)
    y, w = M["AUtest_y"][keep], M["AUtest_w"][keep]
    res = {"n": len(keep), "converted_to_srgb": int(conv.sum()), "variants": {}}
    top0 = head_scores(M, ref)
    res["variants"]["cloud_fp16 (training recipe)"] = {**metrics(top0, y, w), "cos_vs_cloud": 1.0}
    for k, v in V.items():
        E = np.stack(v)
        cos = (E * ref).sum(1)
        top = head_scores(M, E)
        r = metrics(top, y, w)
        r["cos_vs_cloud"] = {q: round(float(np.percentile(cos, q)), 4) for q in (0, 1, 10, 50)}
        r["top1_changed_vs_cloud"] = int((top[:, 0] != top0[:, 0]).sum())
        if k == "app_srgb_w8":
            m = conv
            r["on_converted_only"] = {"n": int(m.sum()), "cloud": metrics(top0, y, w, m), "srgb": metrics(top, y, w, m),
                                      "cos_p50": round(float(np.median(cos[m])), 4), "cos_min": round(float(cos[m].min()), 4)}
        res["variants"][k] = r
    json.dump(res, open(os.path.join(OUT, f"parity-{a.variant}.json"), "w"), indent=1)
    print(json.dumps(res, indent=1))


def Image_open_rgb(body):
    from PIL import Image
    return Image.open(io.BytesIO(body)).convert("RGB")


# ------------------------------------------------------------------ plan (crop experiment + pilot)

PILOT_DIR = os.path.join(OUT, "in")


def bucket_of(n):
    return np.where(n == 0, 0, np.where(n < 10, 1, np.where(n < 50, 2, 3)))


def cmd_plan(a):
    """views.parquet (crop experiment: A-test + AU-test, stratified by the
    class's training count), pilot_train.parquet + pilot_test.parquet."""
    import pyarrow as pa
    import pyarrow.parquet as pq
    M = load_manifest()
    rng = np.random.default_rng(5)
    n_tr, euc = M["n_tr"], M["euc"]
    os.makedirs(PILOT_DIR, exist_ok=True)
    rows = {"photo_id": [], "ext": [], "u": [], "set": []}
    for k in ("Atest", "AUtest"):
        y = M[k + "_y"]
        ok = np.flatnonzero(y >= 0)
        bk = bucket_of(n_tr[y[ok]])
        take = []
        for b_ in range(4):
            c = ok[bk == b_]
            take += rng.permutation(c)[:a.views // 4].tolist()
        if len(take) < a.views:  # thin buckets (A-test): fill from the rest
            rest = np.setdiff1d(ok, take)
            take += rng.permutation(rest)[:a.views - len(take)].tolist()
        for i in take:
            rows["photo_id"].append(int(M[k + "_pid"][i])); rows["ext"].append(str(M[k + "_ext"][i]))
            rows["u"].append(int(y[i])); rows["set"].append(k)
    pq.write_table(pa.table(rows), os.path.join(PILOT_DIR, "views.parquet"))
    print("views:", len(rows["u"]))
    # pilot classes: training photos AND test photos
    ty = np.concatenate([M["Atest_y"], M["AUtest_y"]])
    has_test = np.bincount(ty[ty >= 0], minlength=len(n_tr)) > 0
    cand = np.flatnonzero(has_test & (n_tr > 0))
    bk = bucket_of(n_tr[cand])
    pick = []
    e = cand[euc[cand]]
    pick += rng.permutation(e)[:a.euc].tolist()
    for b_, k in ((1, a.b1), (2, a.b2), (3, a.b3)):
        c = np.setdiff1d(cand[(bk == b_) & ~euc[cand]], pick)
        pick += rng.permutation(c)[:k].tolist()
    pick = np.array(sorted(pick))
    print(f"pilot classes {len(pick)}: euc {euc[pick].sum()}, buckets",
          {b_: int((bucket_of(n_tr[pick]) == b_).sum()) for b_ in (1, 2, 3)})
    ps = set(pick.tolist())
    tr = {"photo_id": [], "ext": [], "u": []}
    for u in pick:
        ii = np.flatnonzero(M["tr_y"] == u)
        ii = rng.permutation(ii)[:a.cap_train]
        for i in sorted(ii):
            tr["photo_id"].append(int(M["tr_pid"][i])); tr["ext"].append(str(M["tr_ext"][i])); tr["u"].append(int(u))
    te = {"photo_id": [], "ext": [], "u": [], "set": [], "w": []}
    for k in ("Atest", "AUtest"):
        y = M[k + "_y"]
        for u in pick:
            ii = rng.permutation(np.flatnonzero(y == u))[:a.cap_test]
            for i in sorted(ii):
                te["photo_id"].append(int(M[k + "_pid"][i])); te["ext"].append(str(M[k + "_ext"][i]))
                te["u"].append(int(u)); te["set"].append(k); te["w"].append(float(M[k + "_w"][i]))
    assert not set(tr["photo_id"]) & set(te["photo_id"])
    pq.write_table(pa.table(tr), os.path.join(PILOT_DIR, "pilot_train.parquet"))
    pq.write_table(pa.table(te), os.path.join(PILOT_DIR, "pilot_test.parquet"))
    np.save(os.path.join(PILOT_DIR, "pilot_classes.npy"), pick)
    print(f"pilot train photos {len(tr['u'])}, test photos {len(te['u'])} "
          f"(A {te['set'].count('Atest')}, AU {te['set'].count('AUtest')})")


# ------------------------------------------------------------------ worker (VM or local)

ORGANS = ["flower", "fruit", "flower bud", "leaf", "bark"]
PROMPTS = ["a photo of a flower", "a photo of a fruit", "a photo of a flower bud", "a photo of a leaf",
           "a photo of tree bark"]
GREY = (122, 116, 104)  # CLIP mean as uint8


def sq_crop(im, cx, cy, side):
    """Square of `side` px centred at (cx, cy), shifted inside the image where
    it fits, padded with the CLIP-mean grey where it does not → 224² uint8."""
    from PIL import Image
    W, H = im.size
    side = max(8, int(round(side)))
    x0 = int(round(cx - side / 2)); y0 = int(round(cy - side / 2))
    if side <= W:
        x0 = min(max(x0, 0), W - side)
    else:
        x0 = int(round((W - side) / 2))
    if side <= H:
        y0 = min(max(y0, 0), H - side)
    else:
        y0 = int(round((H - side) / 2))
    if x0 >= 0 and y0 >= 0 and x0 + side <= W and y0 + side <= H:
        c = im.crop((x0, y0, x0 + side, y0 + side))
    else:
        c = Image.new("RGB", (side, side), GREY)
        c.paste(im.crop((max(x0, 0), max(y0, 0), min(x0 + side, W), min(y0 + side, H))), (max(-x0, 0), max(-y0, 0)))
    return np.asarray(c.resize((224, 224), Image.BICUBIC), np.uint8)


def views_basic(im):
    """Crop-experiment views of one (medium) photo."""
    from PIL import Image
    from build_ship import resize_crop
    W, H = im.size
    out = {"centre": resize_crop(im)}
    s = max(W, H)
    pad = Image.new("RGB", (s, s), GREY)
    pad.paste(im, ((s - W) // 2, (s - H) // 2))
    out["pad"] = np.asarray(pad.resize((224, 224), Image.BICUBIC), np.uint8)
    out["squash"] = np.asarray(im.resize((224, 224), Image.BICUBIC), np.uint8)
    # 5-crop at 256 (CLIP's classic multi-crop): short side → 256, 224 crops
    nw, nh = (256, int(256 * H / W)) if W <= H else (int(256 * W / H), 256)
    r = im.resize((nw, nh), Image.BICUBIC)
    for k, (x, y) in {"c256": ((nw - 224) // 2, (nh - 224) // 2), "tl": (0, 0), "tr": (nw - 224, 0),
                      "bl": (0, nh - 224), "br": (nw - 224, nh - 224)}.items():
        out[k] = np.asarray(r.crop((x, y, x + 224, y + 224)), np.uint8)
    return out


class Detector:
    def __init__(self, dev):
        import torch
        from transformers import Owlv2ForObjectDetection, Owlv2Processor
        self.torch, self.dev = torch, dev
        self.dtype = torch.float16 if dev == "cuda" else torch.float32
        self.m = Owlv2ForObjectDetection.from_pretrained("google/owlv2-base-patch16-ensemble").to(dev).to(self.dtype).eval()
        proc = Owlv2Processor.from_pretrained("google/owlv2-base-patch16-ensemble")
        t = proc.tokenizer(PROMPTS, padding="max_length", max_length=16, return_tensors="pt")
        self.ids, self.am = t["input_ids"].to(dev), t["attention_mask"].to(dev)
        self.mean = torch.tensor([0.48145466, 0.4578275, 0.40821073], device=dev).view(1, 3, 1, 1)
        self.std = torch.tensor([0.26862954, 0.26130258, 0.27577711], device=dev).view(1, 3, 1, 1)

    def __call__(self, ims, thr=0.15):
        """→ per image a list of (organ, score, x0, y0, x1, y1) in pixels."""
        torch = self.torch
        F = torch.nn.functional
        px = []
        for im in ims:  # HF Owlv2ImageProcessor: [0,1], pad bottom/right with 0.5, resize 960, CLIP norm
            a = torch.from_numpy(np.asarray(im, np.uint8)).to(self.dev).permute(2, 0, 1).float() / 255
            H, W = a.shape[1:]
            S = max(H, W)
            p = torch.full((3, S, S), 0.5, device=self.dev)
            p[:, :H, :W] = a
            px.append(F.interpolate(p[None], size=(960, 960), mode="bilinear", antialias=True, align_corners=False))
        x = ((torch.cat(px) - self.mean) / self.std).to(self.dtype)
        B, Q = x.shape[0], len(PROMPTS)
        with torch.inference_mode():
            o = self.m(input_ids=self.ids.repeat(B, 1), attention_mask=self.am.repeat(B, 1), pixel_values=x)
        sc = torch.sigmoid(o.logits.float()).cpu().numpy()  # B × P × Q
        bx = o.pred_boxes.float().cpu().numpy()  # B × P × 4 (cx, cy, w, h) of the padded square
        out = []
        for i, im in enumerate(ims):
            W, H = im.size
            S = max(W, H)
            res = []
            for q in range(Q):
                j = np.argsort(-sc[i, :, q])[:5]
                for jj in j:
                    if sc[i, jj, q] < thr:
                        break
                    cx, cy, w, h = (float(v) for v in bx[i, jj] * S)
                    res.append((ORGANS[q], float(sc[i, jj, q]), max(0., cx - w / 2), max(0., cy - h / 2),
                                min(float(W), cx + w / 2), min(float(H), cy + h / 2)))
            out.append(res)
        return out


def iou(a, b):
    ix = max(0., min(a[4], b[4]) - max(a[2], b[2])); iy = max(0., min(a[5], b[5]) - max(a[3], b[3]))
    inter = ix * iy
    u = (a[4] - a[2]) * (a[5] - a[3]) + (b[4] - b[2]) * (b[5] - b[3]) - inter
    return inter / u if u > 0 else 0.


def organ_boxes(dets, W, H, k):
    """≤ k boxes: score ≥ .25, by score, NMS across organs (IoU > .5), longer
    box side ≥ 12 % of the photo's short side (smaller = a speck in a wide
    shot), area ≤ 60 % of the photo (bigger = the whole plant ≈ centre)."""
    short = min(W, H)
    keep = []
    for d in sorted(dets, key=lambda d: -d[1]):
        bw, bh = d[4] - d[2], d[5] - d[3]
        if d[1] < 0.25 or max(bw, bh) < 0.12 * short or bw * bh > 0.6 * W * H:
            continue
        if any(iou(d, e) > 0.5 for e in keep):
            continue
        keep.append(d)
        if len(keep) >= k:
            break
    return keep


def box_crop(im, d, margin=1.15):
    cx, cy = (d[2] + d[4]) / 2, (d[3] + d[5]) / 2
    return sq_crop(im, cx, cy, max(d[4] - d[2], d[5] - d[3]) * margin)


def pilot_views(im, dets, pid, train):
    """→ list of (view, organ, score, box, uint8 224²)."""
    from build_ship import resize_crop
    W, H = im.size
    short = min(W, H)
    out = [("centre", "", 0., (0, 0, 0, 0), resize_crop(im))]
    r = np.random.default_rng(int(pid))
    if train:
        for i in range(3):  # RandomResizedCrop-style square zooms 1.5–2.5×
            z = r.uniform(1.5, 2.5)
            side = short / z
            cx = r.uniform(side / 2, W - side / 2); cy = r.uniform(side / 2, H - side / 2)
            out.append((f"zoom{i}", "", z, (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2),
                        sq_crop(im, cx, cy, side)))
    else:
        out.append(("zoom2c", "", 2., (W / 2 - short / 4, H / 2 - short / 4, W / 2 + short / 4, H / 2 + short / 4),
                    sq_crop(im, W / 2, H / 2, short / 2)))
    for i, d in enumerate(organ_boxes(dets, W, H, 3)):
        out.append((f"organ{i}", d[0], d[1], tuple(d[2:]), box_crop(im, d)))
    return out


def cmd_work(a):
    """Embed the crop experiment and the pilot, shard by shard (resumable;
    with --bucket the shards go to GCS and existing ones are skipped)."""
    import subprocess
    import threading
    import pyarrow.parquet as pq
    import torch
    from PIL import Image
    dev = a.device or ("cuda" if torch.cuda.is_available() else "mps")
    inp = a.inp or PILOT_DIR
    out = a.out or os.path.join(OUT, "work")
    os.makedirs(out, exist_ok=True)
    done = set(os.path.basename(f) for f in glob.glob(os.path.join(out, "*.npz")))
    if a.bucket:
        r = subprocess.run(["gcloud", "storage", "ls", a.bucket + "/out/"], capture_output=True, text=True)
        done |= {os.path.basename(x) for x in r.stdout.split() if x.endswith(".npz")}
    jobs = []
    for kind, f, size in (("views", "views.parquet", "medium"), ("ptest", "pilot_test.parquet", "large"),
                          ("ptrain", "pilot_train.parquet", "large")):
        if a.only and kind not in a.only:
            continue
        t = pq.read_table(os.path.join(inp, f)).to_pydict()
        n = len(t["photo_id"]) if not a.limit else min(a.limit, len(t["photo_id"]))
        for k in range(0, n, a.shard):
            name = f"{kind}-{k // a.shard:04d}.npz"
            if name not in done:
                jobs.append((kind, size, name, list(zip(t["photo_id"][k:k + a.shard], t["ext"][k:k + a.shard]))))
    print(f"{len(jobs)} shards to do on {dev}", flush=True)
    if not jobs:
        return
    enc = Torch(dev, half=(dev == "cuda"))
    det = Detector(dev) if any(j[0] != "views" for j in jobs) else None
    pool = cf.ThreadPoolExecutor(8)

    def load(job):
        kind, size, name, items = job
        conns = threading.local()

        def one(pe):
            p, e = pe
            if not hasattr(conns, "c"):
                conns.c = http.client.HTTPSConnection(HOST, timeout=30)
            b = fetch(p, e, size, conns.c) or (fetch(p, e, "medium", conns.c) if size != "medium" else None)
            if b is None:
                return p, None
            try:
                im = Image.open(io.BytesIO(b))
                im.draft("RGB", (1100, 1100))
                return p, im.convert("RGB")
            except Exception:  # noqa: BLE001
                return p, None
        with cf.ThreadPoolExecutor(32) as ex:
            return list(ex.map(one, items))

    nxt = pool.submit(load, jobs[0])
    t0, n_img, n_emb = time.time(), 0, 0
    for ji, job in enumerate(jobs):
        kind, size, name, items = job
        got = nxt.result()
        if ji + 1 < len(jobs):
            nxt = pool.submit(load, jobs[ji + 1])
        good = [(p, im) for p, im in got if im is not None]
        missing = [p for p, im in got if im is None]
        rec = []  # (pid, view, organ, score, box, uint8)
        if kind == "views":
            for p, v in zip([p for p, _ in good], pool.map(lambda g: views_basic(g[1]), good)):
                for k, x in v.items():
                    rec.append((p, k, "", 0., (0, 0, 0, 0), x))
        else:
            D = []
            for i in range(0, len(good), a.det_bs):
                D += det([im for _, im in good[i:i + a.det_bs]])
            pv = list(pool.map(lambda gd: pilot_views(gd[0][1], gd[1], gd[0][0], kind == "ptrain"), zip(good, D)))
            for (p, im), v in zip(good, pv):
                for r_ in v:
                    rec.append((p,) + r_)
            alld = [(p, im.size, d) for (p, im), d in zip(good, D)]
        X = list(pool.map(lambda r_: to_tensor(r_[5]), rec))
        E = enc(X, bs=a.enc_bs).astype(np.float16)
        arr = dict(photo_id=np.array([r_[0] for r_ in rec], np.int64), view=np.array([r_[1] for r_ in rec]),
                   organ=np.array([r_[2] for r_ in rec]), score=np.array([r_[3] for r_ in rec], np.float32),
                   box=np.array([r_[4] for r_ in rec], np.float32), emb=E, missing=np.array(missing, np.int64))
        if kind != "views":
            arr["dets"] = np.array(json.dumps([[p, list(sz), d] for p, sz, d in alld]))
            if a.samples and kind == "ptrain" and ji == [j[2] for j in jobs].index(name) and name.endswith("0000.npz"):
                sd = os.path.join(out, "samples")
                os.makedirs(sd, exist_ok=True)
                for r_ in [r_ for r_ in rec if r_[1].startswith("organ")][:a.samples]:
                    Image.fromarray(r_[5]).save(os.path.join(sd, f"{r_[0]}-{r_[1]}-{r_[2].replace(' ', '_')}.jpg"), quality=90)
                    full = dict(good)[r_[0]].copy()
                    full.thumbnail((400, 400))
                    full.save(os.path.join(sd, f"{r_[0]}-full.jpg"), quality=85)
        f = os.path.join(out, name)
        with open(f + ".part", "wb") as fh:
            np.savez(fh, **arr)
        os.replace(f + ".part", f)
        if a.bucket:
            subprocess.run(["gcloud", "storage", "cp", f, a.bucket + "/out/", "--quiet"], check=False)
        n_img += len(good); n_emb += len(rec)
        dt = time.time() - t0
        print(f"{name}: {len(good)} photos ({len(missing)} missing), {len(rec)} views; total {n_img} photos "
              f"{n_img / dt:.1f}/s, {n_emb / dt:.1f} emb/s", flush=True)
    if a.bucket and a.samples:
        subprocess.run(["gcloud", "storage", "rsync", os.path.join(out, "samples"), a.bucket + "/samples", "--quiet"],
                       check=False)


# ------------------------------------------------------------------ analysis

def load_shards(kind, d=None):
    d = d or os.environ.get("PREPROC_WORK", os.path.join(OUT, "work"))
    fs = sorted(glob.glob(os.path.join(d, f"{kind}-*.npz")))
    Z = [np.load(f) for f in fs]
    cols = ("photo_id", "view", "organ", "score", "box", "emb")
    R = {c: np.concatenate([z[c] for z in Z]) for c in cols}
    R["missing"] = np.concatenate([z["missing"] for z in Z])
    R["dets"] = []
    for z in Z:
        if "dets" in z.files:
            R["dets"] += json.loads(str(z["dets"]))
    print(f"{kind}: {len(fs)} shards, {len(R['photo_id'])} rows, {len(set(R['photo_id'].tolist()))} photos, "
          f"{len(R['missing'])} missing")
    return R


def unit(x):
    x = np.asarray(x, np.float32)
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


def cmd_views(a):
    """Crop strategies with the v2 head (22,122 classes) → preproc/views.json"""
    import pyarrow.parquet as pq
    M = load_manifest()
    R = load_shards("views")
    t = pq.read_table(os.path.join(PILOT_DIR, "views.parquet")).to_pydict()
    wmap = {}
    for k in ("Atest", "AUtest"):
        wmap.update({(k, int(p)): float(w) for p, w in zip(M[k + "_pid"], M[k + "_w"])})
    ref = {}
    for k in ("Atest", "AUtest"):
        ref.update({int(p): e for p, e in zip(M[k + "_pid"], M[k + "_emb"])})
    idx = {(int(p), str(v)): i for i, (p, v) in enumerate(zip(R["photo_id"], R["view"]))}
    out = {}
    for setk in ("Atest", "AUtest"):
        rows = [(int(p), u) for p, u, s_ in zip(t["photo_id"], t["u"], t["set"]) if s_ == setk
                and (int(p), "centre") in idx]
        P = [p for p, _ in rows]
        y = np.array([u for _, u in rows])
        w = np.array([wmap[(setk, p)] for p in P])
        V = {v: unit(R["emb"][[idx[(p, v)] for p in P]]) for v in
             ("centre", "pad", "squash", "c256", "tl", "tr", "bl", "br")}
        cos_ref = (V["centre"] * unit(np.stack([ref[p] for p in P]))).sum(1)
        combos = {"centre (current)": V["centre"], "pad (whole photo)": V["pad"], "squash": V["squash"],
                  "avg(centre, pad)": unit(V["centre"] + V["pad"]),
                  "5-crop avg @256": unit(V["c256"] + V["tl"] + V["tr"] + V["bl"] + V["br"]),
                  "avg(centre, 5-crop)": unit(V["centre"] + unit(V["c256"] + V["tl"] + V["tr"] + V["bl"] + V["br"])),
                  "avg(centre, pad, squash)": unit(V["centre"] + V["pad"] + V["squash"])}
        bk = bucket_of(M["n_tr"][y])
        res = {"cos(VM centre, eval embedding)": {q: round(float(np.percentile(cos_ref, q)), 4) for q in (0, 1, 50)}}
        base = None
        for k, E in combos.items():
            top = head_scores(M, E)
            r = metrics(top, y, w)
            r["euc"] = metrics(top, y, w, M["euc"][y])
            r["b1-9"] = metrics(top, y, w, bk == 1)
            if base is None:
                base = top[:, 0] == y
            else:
                c = top[:, 0] == y
                r["paired"] = {"gained": int((c & ~base).sum()), "lost": int((~c & base).sum())}
            res[k] = r
        out[setk] = res
    json.dump(out, open(os.path.join(OUT, "views.json"), "w"), indent=1)
    for setk, res in out.items():
        print(setk, res["cos(VM centre, eval embedding)"])
        for k, r in res.items():
            if k.startswith("cos"):
                continue
            print(f"  {k:26s} sp {r['sp_top1']:6.2f}/{r['sp_top5']:6.2f}  nat {r['nat_top1']:6.2f}/{r['nat_top5']:6.2f}"
                  f"  euc {r['euc']['sp_top1']:6.2f}  1-9 {r['b1-9']['sp_top1']:6.2f}  {r.get('paired', '')}")


def train_head(X, y, M, classes, Xv, yv, steps=2000, bs=512, lr=1e-3, wd=0.01, tau=1.0, dev="mps", seed=0,
               last=False):
    """v2 recipe on the pilot classes: W = s0 (Tc + Δ), b = s0 β, logit-adjusted
    CE (τ 1), AdamW toward the text init, warmup + cosine; FIXED step count for
    every arm (arms differ in sample counts); checkpoint = best per-species
    val top-1 every 100 steps (val = AU-val ∪ A-val centre crops of the pilot
    classes)."""
    import math
    import torch
    torch.manual_seed(seed)
    C = len(classes)
    T = M["T"].astype(np.float32)
    Tc = unit(T - T.mean(0))[classes]
    s0 = float(M["s0"])
    mu = M["mu"]

    def centre(E):
        return torch.from_numpy(unit(unit(E) - mu)).to(dev)
    Xt, yt = centre(X), torch.from_numpy(y).to(dev)
    n_c = torch.bincount(yt, minlength=C).float()
    logpi = torch.where(n_c > 0, torch.log(n_c / n_c.sum()), torch.full_like(n_c, -1e4))
    W0 = torch.from_numpy(Tc).to(dev)
    Dw = torch.nn.Parameter(torch.zeros_like(W0))
    beta = torch.nn.Parameter(torch.zeros(C, device=dev))
    opt = torch.optim.AdamW([Dw, beta], lr=lr, weight_decay=wd)
    warm = max(1, steps // 12)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: (s + 1) / warm if s < warm else
                                              0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, steps - warm))))
    Xvt = centre(Xv)
    g = torch.Generator(device="cpu").manual_seed(seed)
    best = (-1, None, None, 0)
    for st in range(steps):
        bi = torch.randint(0, len(yt), (bs,), generator=g).to(dev)
        L = Xt[bi] @ (s0 * (W0 + Dw)).T + s0 * beta
        loss = torch.nn.functional.cross_entropy(L + tau * logpi, yt[bi])
        opt.zero_grad(set_to_none=True)
        loss.backward()
        opt.step()
        sched.step()
        if (st + 1) % 100 == 0:
            with torch.no_grad():
                W, b = s0 * (W0 + Dw), s0 * beta
                pv = (Xvt @ W.T + b).argmax(1).cpu().numpy()
            acc = np.mean([np.mean(pv[yv == c] == c) for c in np.unique(yv)])
            if acc > best[0] or (last and st + 1 == steps):
                best = (acc, W.detach().cpu().numpy(), b.detach().cpu().numpy(), st + 1)
    return best[1], best[2], {"val_sp_top1": round(100 * best[0], 2), "step": best[3]}


FERNS = {"Pteridaceae", "Dennstaedtiaceae", "Blechnaceae", "Dicksoniaceae", "Aspleniaceae", "Polypodiaceae",
         "Lindsaeaceae", "Gleicheniaceae", "Schizaeaceae", "Hymenophyllaceae", "Dryopteridaceae", "Osmundaceae",
         "Cyatheaceae", "Lygodiaceae", "Davalliaceae", "Thelypteridaceae", "Athyriaceae", "Nephrolepidaceae",
         "Ophioglossaceae", "Marsileaceae", "Salviniaceae", "Psilotaceae", "Tectariaceae", "Lomariopsidaceae",
         "Woodsiaceae", "Cystopteridaceae", "Oleandraceae", "Equisetaceae"}


def group_of(u, fam, euc):
    f = fam[u] or ""
    if euc[u]:
        return "eucalypts"
    if f == "Poaceae":
        return "grasses"
    if f in ("Cyperaceae", "Juncaceae", "Restionaceae"):
        return "sedges/rushes/restios"
    if f in FERNS or f in ("Lycopodiaceae", "Selaginellaceae", "Isoetaceae"):
        return "ferns & allies"
    if f == "Orchidaceae":
        return "orchids"
    if f in ("Myrtaceae",):
        return "other Myrtaceae"
    if f == "Fabaceae":
        return "Fabaceae"
    if f == "Asteraceae":
        return "Asteraceae"
    if f == "Proteaceae":
        return "Proteaceae"
    return "other"


def cmd_pilot(a):
    """Train a head per arm (a–d) on the pilot classes, score both query types
    → preproc/pilot.json"""
    import collections
    import pyarrow.parquet as pq
    M = load_manifest()
    lab = json.load(open(os.path.join(OUT, "labels.json")))
    fam = lab["family"]
    euc = M["euc"]
    classes = np.load(os.path.join(PILOT_DIR, "pilot_classes.npy"))
    cpos = {int(u): i for i, u in enumerate(classes)}
    Rt, Rq = load_shards("ptrain"), load_shards("ptest")
    tr = pq.read_table(os.path.join(PILOT_DIR, "pilot_train.parquet")).to_pydict()
    te = pq.read_table(os.path.join(PILOT_DIR, "pilot_test.parquet")).to_pydict()
    ytr = {int(p): cpos[u] for p, u in zip(tr["photo_id"], tr["u"])}
    # val: data.npz AU-val / A-val rows of pilot classes
    D = np.load(os.path.join(CACHE, "australia", "v2", "data.npz"))
    vm = np.isin(D["yv"], classes)
    am = np.isin(D["ya"], classes)
    Xv = np.concatenate([D["Xv"][vm], D["Xa"][am]]).astype(np.float32)
    yv = np.array([cpos[int(u)] for u in np.concatenate([D["yv"][vm], D["ya"][am]])])
    v = Rt["view"].astype(str)
    pid = Rt["photo_id"]
    is_c, is_z, is_o = v == "centre", np.char.startswith(v, "zoom"), np.char.startswith(v, "organ")
    has_o = set(pid[is_o].tolist())
    fallback = np.array([p not in has_o for p in pid]) & is_c
    arms = {"a centre": is_c, "b centre+3 zooms": is_c | is_z, "c centre+organs": is_c | is_o,
            "d organs only (centre if none)": is_o | fallback}
    yall = np.array([ytr[int(p)] for p in pid])
    # fallback stats
    photos = sorted(set(pid[is_c].tolist()))
    grp = collections.Counter()
    grp_fb = collections.Counter()
    organ_ct = collections.Counter(Rt["organ"][is_o].tolist())
    for p in photos:
        g_ = group_of(classes[ytr[p]], fam, euc)
        grp[g_] += 1
        grp_fb[g_] += p not in has_o
    fb = {"photos": len(photos), "no_organ_crop": int(sum(grp_fb.values())),
          "by_group": {g_: {"photos": grp[g_], "fallback": grp_fb[g_], "pct": round(100 * grp_fb[g_] / grp[g_], 1)}
                       for g_ in sorted(grp, key=lambda k: -grp[k])},
          "organ_crops_by_type": dict(organ_ct), "organ_crops_per_photo": round(int(is_o.sum()) / len(photos), 2)}
    print(json.dumps(fb, indent=1))
    # queries
    q = Rq["view"].astype(str)
    qp = Rq["photo_id"]
    tmeta = {int(p): (cpos[u], s_, w) for p, u, s_, w in zip(te["photo_id"], te["u"], te["set"], te["w"])}
    P = sorted(set(qp[q == "centre"].tolist()))
    qi = {(int(p_), v_): i for i, (p_, v_) in enumerate(zip(qp, q))}
    yq = np.array([tmeta[p][0] for p in P])
    wq = np.array([tmeta[p][2] for p in P])
    setq = np.array([tmeta[p][1] for p in P])
    Qc = Rq["emb"][[qi[(p, "centre")] for p in P]]
    Qz = Rq["emb"][[qi[(p, "zoom2c")] for p in P]]
    has_q = np.array([(p, "organ0") in qi for p in P])
    Qo = np.stack([Rq["emb"][qi[(p, "organ0")]] if (p, "organ0") in qi else Rq["emb"][qi[(p, "zoom2c")]] for p in P])
    otype = np.array([Rq["organ"][qi[(p, "organ0")]] if (p, "organ0") in qi else "none (zoom)" for p in P])
    # every organ crop of the test photos (organ-type analysis)
    oi = np.flatnonzero(np.char.startswith(q, "organ"))
    Qall, yall_q, tall = Rq["emb"][oi], np.array([tmeta[int(p_)][0] for p_ in qp[oi]]), Rq["organ"][oi].astype(str)
    n_full = M["n_tr"][classes[yq]]
    masks = {"all": None, "eucalypts": euc[classes[yq]], "1-9 photos": (n_full >= 1) & (n_full <= 9),
             "AU-test": setq == "AUtest", "A-test": setq == "Atest"}
    res = {"fallback": fb, "queries": {"photos": len(P), "with organ crop": int(has_q.sum()),
                                       "organ0 types": dict(collections.Counter(otype.tolist()))}, "arms": {}}

    def score(W, b, E):
        L = unit(unit(E) - M["mu"]) @ W.T + b
        return np.argsort(-L, 1)[:, :5]
    # the production v2 head (22,122 classes) on the same queries, for reference
    full = {}
    for qn, E in (("centre", Qc), ("organ", Qo), ("zoom2c", Qz)):
        top = head_scores(M, E)
        top = np.where(np.isin(top, classes), top, -1)
        top = np.vectorize(lambda u: cpos.get(int(u), -1))(top)
        full[qn] = metrics(top, yq, wq)
    res["v2 head (22,122 classes), same queries"] = full
    base_c = {}
    for arm, m in arms.items():
        t0 = time.time()
        W, b, inf = train_head(Rt["emb"][m], yall[m], M, classes, Xv, yv, steps=a.steps, last=a.last, seed=a.seed)
        r = {"train_samples": int(m.sum()), **inf, "seconds": round(time.time() - t0, 1)}
        tops = {qn: score(W, b, E) for qn, E in (("centre", Qc), ("organ", Qo), ("zoom2c", Qz))}
        for qn, top in tops.items():
            r[qn] = {mk: metrics(top, yq, wq, mm) for mk, mm in masks.items()}
            r[qn]["organ found only"] = metrics(top, yq, wq, has_q)
        r["mix 50/50"] = {mk: {k2: round((r["centre"][mk][k2] + r["organ"][mk][k2]) / 2, 2)
                               for k2 in ("sp_top1", "sp_top5", "nat_top1", "nat_top5")} for mk in masks}
        for qn, top in tops.items():
            c_ = top[:, 0] == yq
            if arm.startswith("a "):
                base_c[qn] = c_
            else:
                r[qn]["paired vs a"] = {"gained": int((c_ & ~base_c[qn]).sum()), "lost": int((~c_ & base_c[qn]).sum())}
        r["organ0 by type"] = {t_: metrics(tops["organ"], yq, None, otype == t_) for t_ in np.unique(otype)}
        r["centre query, same photos, by organ0 type"] = {t_: metrics(tops["centre"], yq, None, otype == t_)
                                                          for t_ in np.unique(otype)}
        ta = score(W, b, Qall)
        r["every test organ crop by type"] = {t_: metrics(ta, yall_q, None, tall == t_) for t_ in np.unique(tall)}
        res["arms"][arm] = r
        print(arm, r["train_samples"], inf, {qn: (r[qn]["all"]["sp_top1"], r[qn]["eucalypts"]["sp_top1"],
                                                   r[qn]["1-9 photos"]["sp_top1"]) for qn in ("centre", "organ", "zoom2c")},
              flush=True)
    json.dump(res, open(os.path.join(OUT, f"pilot{a.tag}.json"), "w"), indent=1)


def cmd_sheet(a):
    """Contact sheet of training organ crops (full photo with the box + label)."""
    from PIL import Image, ImageDraw
    import pyarrow.parquet as pq
    lab = json.load(open(os.path.join(OUT, "labels.json")))
    tr = pq.read_table(os.path.join(PILOT_DIR, "pilot_train.parquet")).to_pydict()
    name = {int(p): lab["name"][u] for p, u in zip(tr["photo_id"], tr["u"])}
    sd = os.path.join(OUT, "work", "samples")
    z = np.load(sorted(glob.glob(os.path.join(OUT, "work", "ptrain-*.npz")))[0])
    dets = {d[0]: d[1] for d in json.loads(str(z["dets"]))}
    crops = sorted(glob.glob(os.path.join(sd, "*-organ*.jpg")))[:a.n]
    tiles = []
    for c in crops:
        b = os.path.basename(c)[:-4]
        p, view, org = b.split("-", 2)
        p = int(p)
        full = Image.open(os.path.join(sd, f"{p}-full.jpg")).convert("RGB")
        m = (z["photo_id"] == p) & (z["view"] == view)
        bx = z["box"][m][0]
        s = full.size[0] / dets[p][0]
        d = ImageDraw.Draw(full)
        d.rectangle([bx[0] * s, bx[1] * s, bx[2] * s, bx[3] * s], outline=(255, 0, 0), width=3)
        full.thumbnail((220, 220))
        tile = Image.new("RGB", (450, 250), "white")
        tile.paste(full, (0, 0))
        tile.paste(Image.open(c).resize((220, 220)), (228, 0))
        ImageDraw.Draw(tile).text((2, 232), f"{len(tiles)}: {name[p]} | {org}", fill=(0, 0, 0))
        tiles.append(tile)
    cols = 3
    for k in range(0, len(tiles), 12):
        part = tiles[k:k + 12]
        sheet = Image.new("RGB", (cols * 450, ((len(part) + cols - 1) // cols) * 250), "white")
        for i, t_ in enumerate(part):
            sheet.paste(t_, ((i % cols) * 450, (i // cols) * 250))
        sheet.save(os.path.join(OUT, f"sheet-{k // 12}.jpg"), quality=85)
    print(len(tiles), "tiles")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("repro")
    p.add_argument("--n", type=int, default=80)
    p = sub.add_parser("scan")
    p.add_argument("--n", type=int, default=20000)
    p = sub.add_parser("manifest")
    p.add_argument("--run", default="v2fix-e12-tasw3")
    p = sub.add_parser("parity")
    p.add_argument("--n", type=int, default=400)
    p.add_argument("--variant", default="w8")
    p = sub.add_parser("plan")
    p.add_argument("--views", type=int, default=1000)
    p.add_argument("--euc", type=int, default=100)
    p.add_argument("--b1", type=int, default=140)
    p.add_argument("--b2", type=int, default=130)
    p.add_argument("--b3", type=int, default=130)
    p.add_argument("--cap-train", type=int, default=60)
    p.add_argument("--cap-test", type=int, default=15)
    p = sub.add_parser("work")
    p.add_argument("--inp")
    p.add_argument("--out")
    p.add_argument("--bucket")
    p.add_argument("--device")
    p.add_argument("--only", nargs="*")
    p.add_argument("--limit", type=int)
    p.add_argument("--shard", type=int, default=500)
    p.add_argument("--det-bs", type=int, default=16)
    p.add_argument("--enc-bs", type=int, default=128)
    p.add_argument("--samples", type=int, default=60)
    sub.add_parser("views")
    p = sub.add_parser("pilot")
    p.add_argument("--steps", type=int, default=2000)
    p.add_argument("--last", action="store_true", help="final step, no val checkpoint")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--tag", default="")
    p = sub.add_parser("sheet")
    p.add_argument("--n", type=int, default=48)
    a = ap.parse_args()
    {"views": cmd_views, "pilot": cmd_pilot, "sheet": cmd_sheet, "repro": cmd_repro, "scan": cmd_scan, "manifest": cmd_manifest, "parity": cmd_parity, "plan": cmd_plan,
     "work": cmd_work}[a.cmd](a)


if __name__ == "__main__":
    main()

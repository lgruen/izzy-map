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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("repro")
    p.add_argument("--n", type=int, default=80)
    p = sub.add_parser("scan")
    p.add_argument("--n", type=int, default=20000)
    p = sub.add_parser("manifest")
    p.add_argument("--run", default="v2fix-e12-tasw3")
    a = ap.parse_args()
    {"repro": cmd_repro, "scan": cmd_scan, "manifest": cmd_manifest}[a.cmd](a)


if __name__ == "__main__":
    main()

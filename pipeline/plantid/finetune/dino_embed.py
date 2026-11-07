#!/usr/bin/env python3
"""DINOv3 second-encoder pilot — runs on a GPU pod (or `--smoke N` on the Mac).

Question: does a self-supervised encoder (DINOv3, Meta 2025: no text, trained
so that crops of one image agree → fine visual detail) add to BioCLIP 2.5
(image–text contrastive on taxonomic names) for rare Australian species? The
pod only EMBEDS; heads, prior and metrics are computed on the Mac
(dino_eval.py) on exactly the fine-tune pilot's subset (969 classes, all their
data-final training photos, held-out val/test observers).

Photos: as ft_train.fetch (iNat open-data "medium" from S3, ALA/Commons from
the uploaded tars). Weights: uploaded by the Mac in ≤ 95 MB parts (gated on
Hugging Face — the pod gets no token), reassembled under /work/models/<key>/.

Variants (job.json "variants", default below): model key + square input
size. Preprocessing = the production geometry (short side → size, bicubic,
centre crop), ImageNet mean/std (DINOv3's). Per photo two vectors from the
final (layer-normed) tokens: CLS, and the mean of the patch tokens (register
tokens excluded); Perception Encoder: its projected image embedding (cls). Out: /work/out/<name>-NNNN.npz {row, photo_id, cls, pmean
(fp16), ok}, log.json (rates).
"""
import argparse
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ft_train as FTT  # noqa: E402  (fetch, path_of, write paths — same photos as the fine-tune pilot)

VARIANTS = [{"name": "dinol", "model": "vitl", "size": 224},
            {"name": "dinolhr", "model": "vitl", "size": 336},
            {"name": "dinoh", "model": "vith", "size": 224},
            {"name": "pel", "model": "pecore", "size": 336}]
MEAN, STD = (0.485, 0.456, 0.406), (0.229, 0.224, 0.225)   # DINOv3 (ImageNet)
PE_HUB = "hf-hub:timm/PE-Core-L-14-336"   # Perception Encoder core L/14 @ 336 (open_clip; not gated)
PE_REV = None                              # pinned by the pod log (open_clip prints the resolved file)
NORM = {"vitl": (MEAN, STD), "vith": (MEAN, STD), "pecore": ((0.5, 0.5, 0.5), (0.5, 0.5, 0.5))}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class DS:
    def __init__(self, paths, variants):
        import torchvision.transforms as TT
        self.paths = paths
        self.tf = {v["name"]: TT.Compose([TT.Resize(v["size"], interpolation=TT.InterpolationMode.BICUBIC),
                                          TT.CenterCrop(v["size"]), TT.ToTensor(), TT.Normalize(*NORM[v["model"]])])
                   for v in variants}

    def __len__(self):
        return len(self.paths)

    def __getitem__(self, i):
        from PIL import Image
        with Image.open(self.paths[i]) as im:
            im = im.convert("RGB")
            return {k: tf(im) for k, tf in self.tf.items()}, i


def run(a):
    import pyarrow.parquet as pq
    import torch
    from transformers import AutoModel
    job = json.load(open(a.job))
    variants = job.get("variants", VARIANTS)
    od, pdir = a.out, a.photos
    os.makedirs(od, exist_ok=True)
    dev = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
    torch.backends.cuda.matmul.allow_tf32 = True
    workers = job.get("workers", max(2, min(16, (os.cpu_count() or 8) - 2)))
    T = pq.read_table(os.path.join(a.inp, "todo.parquet")).to_pydict()
    if a.smoke:
        T = {c: v[:a.smoke] for c, v in T.items()}
    info = {"job": job, "dev": dev, "gpu": torch.cuda.get_device_name(0) if dev == "cuda" else dev,
            "cpus": os.cpu_count(), "workers": workers, "rows": len(T["role"])}
    info["fetch"] = FTT.fetch(T, pdir, a.inp, job.get("fetch_threads", 64))
    paths = [FTT.path_of(pdir, p, e, f) for p, e, f in zip(T["photo_id"], T["ext"], T["file"])]
    ok = np.array([os.path.exists(q) for q in paths])
    pid = np.array(T["photo_id"], np.int64)
    rows = np.nonzero(ok)[0]
    info["missing"] = int((~ok).sum())
    json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
    log(f"{len(rows):,} photos to embed ({info['missing']} missing)")
    dt = torch.bfloat16 if dev == "cuda" else torch.float16
    models, dims = {}, {}
    for k in sorted({v["model"] for v in variants}):
        if k == "pecore":  # image tower only; output = the projected (CLIP) embedding
            import open_clip
            m_, _, _ = open_clip.create_model_and_transforms(PE_HUB)
            m = m_.visual.to(dev, dt).eval()
            del m_
            dims[k] = int(m(torch.zeros(1, 3, 336, 336, device=dev, dtype=dt)).shape[-1])
        else:
            m = AutoModel.from_pretrained(os.path.join(a.models, k), torch_dtype=dt).to(dev).eval()
            dims[k] = m.config.hidden_size
        models[k] = m
        log(f"model {k}: dim {dims[k]}, {sum(p.numel() for p in m.parameters()) / 1e6:.0f} M params")
    out = {v["name"]: (np.zeros((len(paths), dims[v["model"]]), np.float16),
                       np.zeros((len(paths), dims[v["model"]]), np.float16)) for v in variants}
    bs = job.get("bs", 128)
    batches = [rows[i:i + bs].tolist() for i in range(0, len(rows), bs)]
    sub = [paths[i] for i in range(len(paths))]
    dl = torch.utils.data.DataLoader(DS(sub, variants), batch_sampler=batches, num_workers=workers, pin_memory=True,
                                     prefetch_factor=4 if workers else None)
    t0, done, gpu_s = time.time(), 0, {v["name"]: 0.0 for v in variants}
    with torch.no_grad():
        for xs, idx in dl:
            idx = idx.numpy()
            for v in variants:
                m = models[v["model"]]
                t1 = time.time()
                x = xs[v["name"]].to(dev, dt, non_blocking=True)
                if v["model"] == "pecore":  # one vector; pmean stays 0 (dino_eval uses cls only then)
                    out[v["name"]][0][idx] = m(x).float().cpu().numpy().astype(np.float16)
                else:
                    h = m(pixel_values=x).last_hidden_state.float()
                    r = 1 + m.config.num_register_tokens
                    out[v["name"]][0][idx] = h[:, 0].cpu().numpy().astype(np.float16)
                    out[v["name"]][1][idx] = h[:, r:].mean(1).cpu().numpy().astype(np.float16)
                if dev == "cuda":
                    torch.cuda.synchronize()
                gpu_s[v["name"]] += time.time() - t1
            done += len(idx)
            if done // bs % 200 == 0:
                el = time.time() - t0
                log(f"  {done:,}/{len(rows):,} ({done / el:.0f}/s; GPU s per variant "
                    f"{ {k: round(s) for k, s in gpu_s.items()} })")
    el = time.time() - t0
    info["embed_photos_per_s"] = round(len(rows) / el, 1)
    info["gpu_photos_per_s"] = {k: round(len(rows) / max(s, 1e-9), 1) for k, s in gpu_s.items()}
    log(f"embedded {len(rows):,} in {el:.0f} s ({info['embed_photos_per_s']}/s); per variant {info['gpu_photos_per_s']}")
    allr = np.arange(len(paths))
    for name, (c, pm) in out.items():
        for k, i in enumerate(range(0, len(allr), 4000)):
            p = os.path.join(od, f"{name}-{k:04d}.npz")
            with open(p + ".part", "wb") as f:
                np.savez(f, row=allr[i:i + 4000], photo_id=pid[i:i + 4000], cls=c[i:i + 4000],
                         pmean=pm[i:i + 4000], ok=ok[i:i + 4000])
            os.replace(p + ".part", p)
    info["done"] = True
    json.dump(info, open(os.path.join(od, "log.json"), "w"), indent=1)
    log("done")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--job", required=True)
    ap.add_argument("--inp", default="/work/in")
    ap.add_argument("--out", default="/work/out")
    ap.add_argument("--photos", default="/work/photos")
    ap.add_argument("--models", default="/work/models")
    ap.add_argument("--smoke", type=int, default=0, help="only the first N rows")
    run(ap.parse_args())


if __name__ == "__main__":
    main()

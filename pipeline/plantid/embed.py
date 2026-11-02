#!/usr/bin/env python3
"""Plant-ID evaluation, step 3: image + text embeddings with BioCLIP / BioCLIP 2.

Writes pipeline/cache/plantid/emb/<model>/
  img-NNNN.npz   shards of {photo_id, emb (float16, L2-normalised)}; resumable
  text.npz       {species_id, emb} for the label set's taxonomic prompts
  info.json      model id, dim, logit_scale, throughput

Prompt = BioCLIP's "taxonomic" form: "a photo of Plantae Tracheophyta
Magnoliopsida Proteales Proteaceae Banksia marginata." (kingdom → family +
binomial; iNat's taxa table has no common names, and only UN species have
one, so a mixed prompt would bias the comparison).

Preprocessing is open_clip's own eval transform (bicubic resize of the short
side to 224, centre crop, CLIP mean/std). The phone must reproduce exactly
this — a different resize filter shifts every embedding a little (see
README.md, "parity").
"""
import argparse
import glob
import json
import os
import time

import numpy as np
import torch
import open_clip
import pyarrow.parquet as pq
from PIL import Image

MODELS = {"bioclip": "hf-hub:imageomics/bioclip",
          "bioclip2": "hf-hub:imageomics/bioclip-2",
          "bioclip25": "hf-hub:imageomics/bioclip-2.5-vith14"}  # ViT-H/14, Feb 2026
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")


class Photos(torch.utils.data.Dataset):
    def __init__(self, items, root, tf):
        self.items, self.root, self.tf = items, root, tf

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        pid, ext = self.items[i]
        try:
            with Image.open(os.path.join(self.root, f"{pid}.{ext}")) as im:
                return pid, self.tf(im.convert("RGB")), True
        except Exception:
            return pid, torch.zeros(3, 224, 224), False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--model", choices=MODELS, required=True)
    ap.add_argument("--sets", default=os.path.join(CACHE, "sets"))
    ap.add_argument("--photos", default=os.path.join(CACHE, "photos"))
    ap.add_argument("--out", default=os.path.join(CACHE, "emb"))
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--shard", type=int, default=4096)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--limit", type=int, help="embed at most N photos (timing runs)")
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else
                    "mps" if torch.backends.mps.is_available() else "cpu")
    ap.add_argument("--fp32", action="store_true", help="no half precision on GPU")
    a = ap.parse_args()
    out = os.path.join(a.out, a.model)
    os.makedirs(out, exist_ok=True)

    model, _, tf = open_clip.create_model_and_transforms(MODELS[a.model])
    tok = open_clip.get_tokenizer(MODELS[a.model])
    half = a.device != "cpu" and not a.fp32
    dtype = torch.float16 if half else torch.float32
    model = model.to(a.device).to(dtype).eval()
    info_path = os.path.join(out, "info.json")
    prev = json.load(open(info_path)) if os.path.exists(info_path) else None
    if prev and glob.glob(os.path.join(out, "img-*.npz")) and \
            prev.get("dtype") != str(dtype).replace("torch.", ""):
        raise SystemExit(f"{out} holds {prev.get('dtype')} embeddings; this run would add "
                         f"{dtype} ones — delete the directory or match --fp32")

    # text: one prompt per label species
    labels = pq.read_table(os.path.join(a.sets, "labels.parquet"),
                           columns=["species_id", "taxo"]).to_pylist()
    with torch.no_grad():
        embs = []
        for i in range(0, len(labels), 256):
            t = tok([f"a photo of {r['taxo']}." for r in labels[i:i + 256]]).to(a.device)
            e = model.encode_text(t)
            embs.append(torch.nn.functional.normalize(e, dim=-1).float().cpu().numpy())
    np.savez(os.path.join(out, "text.npz"),  # rewritten every run: follows labels.parquet
             species_id=np.array([r["species_id"] for r in labels], dtype=np.int64),
             emb=np.concatenate(embs).astype(np.float16))
    print(f"text: {len(labels):,} prompts")

    # images: every photo in train ∪ test, skipping shards already written
    ids = {}
    for f in ("train", "test"):
        for r in pq.read_table(os.path.join(a.sets, f + ".parquet"),
                               columns=["photo_id", "ext"]).to_pylist():
            ids[r["photo_id"]] = r["ext"]
    done = set()
    for f in glob.glob(os.path.join(out, "img-*.npz")):
        done.update(np.load(f)["photo_id"].tolist())
    have = {p for p, e in ids.items() if os.path.exists(os.path.join(a.photos, f"{p}.{e}"))}
    todo = sorted(have - done)
    if a.limit:
        todo = todo[:a.limit]
    print(f"images: {len(ids):,} in sets, {len(have):,} downloaded, {len(done):,} embedded, "
          f"{len(todo):,} to do on {a.device}")
    dl = torch.utils.data.DataLoader(Photos([(p, ids[p]) for p in todo], a.photos, tf),
                                     batch_size=a.batch, num_workers=a.workers)
    run_id, shard_no = time.strftime("%Y%m%d-%H%M%S"), 0  # unique names per run
    buf_id, buf_e, n, bad, t0 = [], [], 0, 0, time.time()

    def flush():
        nonlocal shard_no, buf_id, buf_e
        if buf_id:
            path = os.path.join(out, f"img-{run_id}-{shard_no:04d}.npz")
            with open(path + ".part", "wb") as f:  # atomic: no half-written shard
                np.savez(f, photo_id=np.array(buf_id, dtype=np.int64),
                         emb=np.concatenate(buf_e).astype(np.float16))
            os.replace(path + ".part", path)
            shard_no += 1
            buf_id, buf_e = [], []

    with torch.no_grad():
        for pid, x, ok in dl:
            e = model.encode_image(x.to(a.device, dtype))
            e = torch.nn.functional.normalize(e, dim=-1).float().cpu().numpy()
            keep = ok.numpy()
            bad += int((~keep).sum())
            buf_id += pid[keep].tolist()
            buf_e.append(e[keep])
            n += len(pid)
            if len(buf_id) >= a.shard:
                flush()
                print(f"  {n:,}/{len(todo):,}  {n / (time.time() - t0):.0f} img/s", flush=True)
    flush()
    dt = time.time() - t0
    rate = n / dt if dt > 0 else 0
    info = {"model": MODELS[a.model], "dim": int(model.visual.output_dim)
            if hasattr(model.visual, "output_dim") else None,
            "logit_scale": float(model.logit_scale.detach().float().exp()), "device": a.device,
            "dtype": str(dtype).replace("torch.", ""),
            "runs": (prev or {}).get("runs", []) + [
                {"run": run_id, "images": n, "img_per_s": round(rate, 1), "unreadable": bad}]}
    json.dump(info, open(info_path, "w"), indent=1)
    print(f"done: {n:,} images in {dt:.0f} s ({rate:.0f} img/s), {bad} unreadable")


if __name__ == "__main__":
    main()

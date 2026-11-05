#!/usr/bin/env python3
"""Parity check of RunPod shards against the GCP L4 run (same photo ids):
cosine of the fp16 embeddings and pHash/dHash equality.
  uv run --with numpy --with pyarrow --with pandas python3 -I runpod_check.py NEW.npz [REF_DIR]"""
import glob
import os
import sys

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

EX = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "cache", "plantid", "extra"))
z = np.load(sys.argv[1])
ref = {}
for f in sorted(glob.glob(os.path.join(sys.argv[2] if len(sys.argv) > 2 else os.path.join(EX, "emb"), "shard-*.npz"))):
    r = np.load(f)
    want = set(z["photo_id"].tolist())
    for i, p in enumerate(r["photo_id"].tolist()):
        if p in want:
            ref[p] = r["emb"][i].astype(np.float32)
    if len(ref) == len(want):
        break
ids = [int(p) for p in z["photo_id"] if int(p) in ref]
E = z["emb"].astype(np.float32)[[i for i, p in enumerate(z["photo_id"]) if int(p) in ref]]
R = np.stack([ref[p] for p in ids])
cos = (E * R).sum(1) / np.linalg.norm(E, axis=1) / np.linalg.norm(R, axis=1)
H = pd.concat([pq.read_table(f).to_pandas() for f in glob.glob(os.path.join(EX, "work", "hashes-cand-part*.parquet"))])
H = H.drop_duplicates("photo_id").set_index("photo_id")
pos = {int(p): i for i, p in enumerate(z["photo_id"])}
same_p = np.mean([int(z["phash"][pos[p]]) == int(H.loc[p, "phash"]) for p in ids])
same_d = np.mean([int(z["dhash"][pos[p]]) == int(H.loc[p, "dhash"]) for p in ids])
print(f"{len(ids)} photos compared (missing on pod: {len(z['missing'])}); cos min {cos.min():.5f} "
      f"p1 {np.percentile(cos, 1):.5f} median {np.median(cos):.6f}; pHash equal {same_p:.3f}, dHash equal {same_d:.3f}")

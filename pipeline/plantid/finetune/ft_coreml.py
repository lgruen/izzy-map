#!/usr/bin/env python3
"""Encoder fine-tuning pilot — does a TUNED encoder survive the on-device
export? Loads BioCLIP 2.5 (pinned revision, HF cache), applies a pilot run's
weights (LoRA merged into the base weights: W + 2·B·A; or the tuned blocks
as-is), traces + converts to Core ML fp16 exactly as export_coreml.py, then
w8 (linear symmetric int8 per output channel, as build_ship.py `encoders`),
and compares on N test photos: Core ML w8 (ALL compute units) vs PyTorch fp32
of the same tuned encoder — cosine and top-1 agreement of the run's joint head.

Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' --with open_clip_torch
     --with coremltools --with 'numpy<2.3' --with pyarrow --with pillow
     python3 -I pipeline/plantid/finetune/ft_coreml.py RUN [--n 100]
"""
import argparse
import glob
import http.client
import io
import json
import os
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "..", "cache", "plantid"))
FT = os.path.join(CACHE, "finetune")
HF = "hf-hub:imageomics/bioclip-2.5-vith14"


def merged_state(run_dir, visual):
    import torch
    st = {}
    for f in sorted(glob.glob(os.path.join(run_dir, "weights-*.npz"))):
        z = np.load(f)
        st.update({k: torch.from_numpy(z[k].astype(np.float32)) for k in z.files})
    cur = visual.state_dict()
    out = {}
    lora = [k for k in st if k.endswith(".A")]
    if lora:  # names like transformer.resblocks.31.attn.parametrizations.in_proj_weight.0.A
        for kA in lora:
            base = kA.split(".parametrizations.")[0]
            pname = kA.split(".parametrizations.")[1].split(".")[0]
            B = st[kA[:-1] + "B"]
            key = f"{base}.{pname}"
            out[key] = cur[key] + 2.0 * (B @ st[kA])
    else:
        out = {k: v for k, v in st.items() if k in cur}
        assert len(out) == len(st), set(st) - set(cur)
    return out


def main():
    import coremltools as ct
    import coremltools.optimize.coreml as cto
    import open_clip
    import pyarrow.parquet as pq
    import torch
    from PIL import Image
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--n", type=int, default=100)
    a = ap.parse_args()
    rd = os.path.join(FT, "runs", a.run)
    out = os.path.join(FT, "coreml", a.run)
    os.makedirs(out, exist_ok=True)
    model, _, tf = open_clip.create_model_and_transforms(HF)
    v = model.visual.eval()
    ms = merged_state(rd, v)
    missing = v.load_state_dict({**v.state_dict(), **ms})
    print(f"applied {len(ms)} tuned tensors ({missing})")
    for p in v.parameters():
        p.requires_grad_(False)
    torch.backends.mha.set_fastpath_enabled(False)
    # test photos (subset test rows), fetched from the open-data bucket
    T = pq.read_table(os.path.join(FT, "plan", "todo.parquet"), columns=["photo_id", "ext", "role"]).to_pydict()
    rows = [i for i, r in enumerate(T["role"]) if r == "test"]
    rows = [rows[i] for i in np.random.default_rng(0).permutation(len(rows))[:a.n]]
    conn = http.client.HTTPSConnection("inaturalist-open-data.s3.amazonaws.com", timeout=30)
    xs = []
    for i in rows:
        conn.request("GET", f"/photos/{T['photo_id'][i]}/medium.{T['ext'][i]}",
                     headers={"User-Agent": "izzymap-plantid-eval/1"})
        b = conn.getresponse().read()
        with Image.open(io.BytesIO(b)) as im:
            xs.append(tf(im.convert("RGB")).numpy())
    X = np.stack(xs).astype(np.float32)
    t0 = time.time()
    with torch.no_grad():
        ref = torch.cat([v(torch.from_numpy(X[i:i + 10])) for i in range(0, len(X), 10)]).numpy()
        traced = torch.jit.trace(v, torch.from_numpy(X[:1]))
    print(f"torch fp32 + trace {time.time() - t0:.0f} s")
    t1 = time.time()
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="pixel_values", shape=(1, 3, 224, 224), dtype=np.float32)],
                    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS18)
    cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    w8 = cto.linear_quantize_weights(ml, config=cfg)
    pkg = os.path.join(out, "PlantEncoder-w8.mlpackage")
    w8.save(pkg)
    print(f"converted + w8 in {time.time() - t1:.0f} s")
    m = ct.models.MLModel(pkg, compute_units=ct.ComputeUnit.ALL)
    t2 = time.time()
    E = np.stack([m.predict({"pixel_values": x[None]})["embedding"].reshape(-1) for x in X])
    per = (time.time() - t2) / len(X)
    un = lambda z: z / np.linalg.norm(z, axis=1, keepdims=True)  # noqa: E731
    cos = (un(E) * un(ref)).sum(1)
    # top-1 agreement through the run's joint head (centred space)
    hd = np.load(os.path.join(rd, "head.npz"))
    mu = np.load(os.path.join(FT, "plan", "mu.npy"))
    Ts = np.load(os.path.join(FT, "plan", "text_sub.npy")).astype(np.float32) - np.load(os.path.join(FT, "plan", "tmean.npy"))
    W = un(Ts) + hd["Dw"].astype(np.float32)
    top = lambda e: (un(un(e) - mu) @ W.T + hd["beta"]).argmax(1)  # noqa: E731
    agree = float((top(E) == top(ref)).mean())
    # the merged PyTorch encoder must reproduce the pod's tuned embeddings (bf16 there)
    pod = {}
    for f in sorted(glob.glob(os.path.join(rd, "emb-*.npz"))):
        z = np.load(f)
        pod.update({int(rw): e for rw, e in zip(z["row"], z["emb"])})
    have = [k for k, i in enumerate(rows) if i in pod]
    cpod = (un(np.stack([pod[rows[k]] for k in have]).astype(np.float32)) * un(ref[have])).sum(1) if have else np.array([np.nan])
    r = {"run": a.run, "n": len(X), "pod_vs_merged_cos_min": float(cpod.min()), "pod_rows": len(have), "cos_min": float(cos.min()), "cos_p1": float(np.percentile(cos, 1)),
         "cos_median": float(np.median(cos)), "top1_agree": agree, "s_per_photo_ane": round(per, 3)}
    json.dump(r, open(os.path.join(out, "check.json"), "w"), indent=1)
    print(r)
    assert cos.min() > 0.99, "Core ML w8 drifts from PyTorch"


if __name__ == "__main__":
    main()

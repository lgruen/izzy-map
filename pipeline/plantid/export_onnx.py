"""Export a BioCLIP image encoder to ONNX for the in-browser feasibility test
(probe/plantid/, retired — last in commit 04ea5d9). Writes a self-contained data folder that the test page
reads from one base URL (it was R2, retired 2026-11-04; now a local server):

  <out>/model.onnx            graph only (weights live in the shards)
  <out>/model-NN.bin          weights, <= --shard-mb each (resumable download)
  <out>/manifest.json         files + sizes + sha256, preprocessing, references
  <out>/labels.json           species names (index = row of text-f16.bin)
  <out>/text-f16.bin          L2-normalised text vectors, float16, row-major
  <out>/samples/<id>.jpg      the bundled CC0 test photos
  <out>/samples-f16.bin       their PyTorch-preprocessed input tensors

The weights are float16 (no quantisation): fp32 reference embeddings for the
sample photos are computed first, then the model is cast to half and traced.
Input stays float32 (cast inside the graph), output is the raw (unnormalised)
float32 embedding.

  uv run --with torch --with torchvision --with open_clip_torch --with onnx \
      --with onnxruntime --with pillow --with numpy --with pyarrow \
      python3 -I pipeline/plantid/export_onnx.py --model bioclip25
"""
import argparse, hashlib, json, os, shutil, sys, time

import numpy as np
import onnx
import pyarrow.parquet as pq
import torch
import open_clip
from onnx.external_data_helper import set_external_data
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")
MODELS = {"bioclip": "hf-hub:imageomics/bioclip", "bioclip2": "hf-hub:imageomics/bioclip-2",
          "bioclip25": "hf-hub:imageomics/bioclip-2.5-vith14"}
# CC0 test-split photos (pipeline/cache/plantid/sets/test.parquet) that
# BioCLIP 2.5 names correctly (top-1 margins 0.08-0.15 in cosine, so the phone
# test judges numeric drift by the embedding cosine, not by top-1 flips).
# BioCLIP (v1) gets the last one wrong even in fp32; the page compares with
# the laptop's answer, not the true species.
SAMPLES = [637002849, 474508960, 594582089]


class Encoder(torch.nn.Module):
    def __init__(self, visual):
        super().__init__()
        self.visual = visual

    def forward(self, pixel_values):  # float32 in, float32 out, fp16 inside
        return self.visual(pixel_values.to(next(self.visual.parameters()).dtype)).float()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def shard(model, out, shard_bytes):
    """Move every initializer into model-NN.bin files of <= shard_bytes."""
    files, cur, n, f = [], 0, -1, None
    for t in model.graph.initializer:
        raw = t.raw_data
        if not raw:  # typed fields (tiny scalars) stay inline
            continue
        if f is None or (cur + len(raw) > shard_bytes and cur > 0):
            if f:
                f.close()
            n += 1
            name = f"model-{n:02d}.bin"
            files.append(name)
            f = open(os.path.join(out, name), "wb")
            cur = 0
        f.write(raw)
        set_external_data(t, location=name, offset=cur, length=len(raw))
        t.ClearField("raw_data")
        t.data_location = onnx.TensorProto.EXTERNAL
        cur += len(raw)
    f.close()
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="bioclip25", choices=MODELS)
    ap.add_argument("--out")
    ap.add_argument("--shard-mb", type=int, default=64)
    ap.add_argument("--opset", type=int, default=17)
    a = ap.parse_args()
    out = a.out or os.path.join(CACHE, "onnx", a.model)
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "samples"))
    t0 = time.time()
    model, _, preprocess = open_clip.create_model_and_transforms(MODELS[a.model])
    model.eval()
    print(f"loaded in {time.time() - t0:.0f} s; preprocess: {preprocess}")

    # sample photos + their fp32 reference embeddings and zero-shot top 5
    test = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"),
                         columns=["photo_id", "ext", "license", "species_id"]).to_pylist()
    test = {r["photo_id"]: r for r in test}
    labels = pq.read_table(os.path.join(CACHE, "sets", "labels.parquet"),
                           columns=["species_id", "name", "family"]).to_pylist()
    text = np.load(os.path.join(CACHE, "emb", a.model, "text.npz"))
    sid = text["species_id"].tolist()
    assert sid == [r["species_id"] for r in labels], "text.npz out of step with labels.parquet"
    T = text["emb"].astype(np.float32)
    xs, refs = [], []
    for pid in SAMPLES:
        r = test[pid]
        assert r["license"] == "CC0", (pid, r["license"])
        src = os.path.join(CACHE, "photos", f"{pid}.{r['ext']}")
        shutil.copy(src, os.path.join(out, "samples", f"{pid}.jpg"))
        x = preprocess(Image.open(src).convert("RGB")).unsqueeze(0)
        with torch.no_grad():
            e = model.visual(x).float()[0].numpy()
        u = e / np.linalg.norm(e)
        s = T @ u
        top = np.argsort(-s)[:5]
        truth = sid.index(r["species_id"])
        if top[0] != truth:
            print(f"  WARNING {pid}: fp32 top-1 is not the true species")
        xs.append(x.numpy().astype(np.float16))
        refs.append({"photo_id": pid, "file": f"samples/{pid}.jpg", "license": "CC0",
                     "url": f"https://www.inaturalist.org/photos/{pid}",
                     "species": labels[truth]["name"],
                     "top5": [[int(i), round(float(s[i]), 5)] for i in top],
                     "embedding": [round(float(v), 6) for v in u]})
        print(f"  {pid}: {labels[truth]['name']}  top1 {s[top[0]]:.4f} vs {s[top[1]]:.4f}")
    np.concatenate(xs).tofile(os.path.join(out, "samples-f16.bin"))
    json.dump({"names": [r["name"] for r in labels], "families": [r["family"] for r in labels]},
              open(os.path.join(out, "labels.json"), "w"), separators=(",", ":"))
    T.astype(np.float16).tofile(os.path.join(out, "text-f16.bin"))

    # fp16 graph
    enc = Encoder(model.visual.half()).eval()
    for p in enc.parameters():
        p.requires_grad_(False)
    # nn.MultiheadAttention's fused inference fast path has no ONNX export
    torch.backends.mha.set_fastpath_enabled(False)
    tmp = os.path.join(out, "_full.onnx")
    t1 = time.time()
    with torch.no_grad():
        torch.onnx.export(enc, torch.from_numpy(xs[0].astype(np.float32)), tmp,
                          input_names=["pixel_values"], output_names=["embedding"],
                          opset_version=a.opset, dynamo=False, do_constant_folding=True)
    print(f"exported in {time.time() - t1:.0f} s")
    m = onnx.load(tmp)
    os.remove(tmp)
    files = shard(m, out, a.shard_mb << 20)
    onnx.save(m, os.path.join(out, "model.onnx"))
    ops = sorted({n.op_type for n in m.graph.node})
    print("ops:", " ".join(ops))

    # check with onnxruntime (CPU) against the fp32 references
    import onnxruntime as ort
    sess = ort.InferenceSession(os.path.join(out, "model.onnx"), providers=["CPUExecutionProvider"])
    cos = []
    for x, ref in zip(xs, refs):
        e = sess.run(None, {"pixel_values": x.astype(np.float32)})[0][0]
        cos.append(float(np.dot(e / np.linalg.norm(e), ref["embedding"])))
    print("onnxruntime CPU fp16 vs torch fp32 cosine:", [round(c, 5) for c in cos])

    entries = [{"name": n, "bytes": os.path.getsize(os.path.join(out, n)), "sha256": sha256(os.path.join(out, n))}
               for n in ["model.onnx"] + files]
    manifest = {
        "model": a.model, "hf": MODELS[a.model], "dtype": "float16",
        "built": time.strftime("%Y-%m-%d"), "opset": a.opset, "ops": ops,
        "input": {"name": "pixel_values", "size": 224},
        "files": entries, "weights_bytes": sum(e["bytes"] for e in entries[1:]),
        "labels": {"count": len(labels), "dim": int(T.shape[1])},
        "samples": refs, "cpu_cosine": cos,
    }
    pc = open_clip.get_model_preprocess_cfg(model)
    assert pc["size"] in (224, (224, 224)), pc
    manifest["input"].update({"mean": list(pc["mean"]), "std": list(pc["std"]),
                              "resize": pc.get("resize_mode", "shortest"),
                              "interpolation": pc.get("interpolation", "bicubic")})
    json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    print(f"done in {time.time() - t0:.0f} s: {len(files)} shards, "
          f"{manifest['weights_bytes'] / 1e9:.2f} GB weights -> {out}")


if __name__ == "__main__":
    sys.exit(main())

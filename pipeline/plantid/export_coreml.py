"""Convert a BioCLIP image encoder to Core ML for the native iPhone test
(native/plantid-test/). Reuses the ONNX export's folder for everything but the
model, so the app checks against exactly the same reference numbers as the
Safari test page:

  <onnx>/manifest.json, labels.json, text-f16.bin, samples-f16.bin, samples/
      (written by export_onnx.py — run that first)

Writes <out>/ (default pipeline/cache/plantid/coreml/<model>/):
  PlantEncoder.mlpackage   fp16 weights (no quantisation), input float32
                           1x3x224x224 "pixel_values", output "embedding"
  data/test.json           model name, preprocessing, the 3 samples' laptop
                           embeddings + top-5 (copied from the ONNX manifest)
  data/labels.json, text-f16.bin, samples-f16.bin, samples/*.jpg   (copies)

and checks the converted model on this Mac (CPU only and all compute units)
against the PyTorch fp32 embeddings.

  # numpy < 2.3: coremltools casts 1-element arrays with int()
  uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \
      --with open_clip_torch --with coremltools --with 'numpy<2.3' \
      python3 -I pipeline/plantid/export_coreml.py --model bioclip25
"""
import argparse, json, os, shutil, sys, time

import coremltools as ct
import numpy as np
import open_clip
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")
MODELS = {"bioclip": "hf-hub:imageomics/bioclip", "bioclip2": "hf-hub:imageomics/bioclip-2",
          "bioclip25": "hf-hub:imageomics/bioclip-2.5-vith14"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="bioclip25", choices=MODELS)
    ap.add_argument("--out")
    a = ap.parse_args()
    src = os.path.join(CACHE, "onnx", a.model)
    out = a.out or os.path.join(CACHE, "coreml", a.model)
    man = json.load(open(os.path.join(src, "manifest.json")))
    if os.path.exists(out):
        shutil.rmtree(out)
    data = os.path.join(out, "data")  # the app bundles this folder as-is
    os.makedirs(data)
    for f in ["labels.json", "text-f16.bin", "samples-f16.bin"]:
        shutil.copy(os.path.join(src, f), data)
    shutil.copytree(os.path.join(src, "samples"), os.path.join(data, "samples"))
    json.dump({"model": a.model, "hf": man["hf"], "input": man["input"], "labels": man["labels"],
               "samples": man["samples"], "built": time.strftime("%Y-%m-%d")},
              open(os.path.join(data, "test.json"), "w"), indent=1)

    t0 = time.time()
    model, _, _ = open_clip.create_model_and_transforms(MODELS[a.model])
    visual = model.visual.eval()
    for p in visual.parameters():
        p.requires_grad_(False)
    # the fused MHA inference fast path doesn't trace into convertible ops
    torch.backends.mha.set_fastpath_enabled(False)
    xs = np.fromfile(os.path.join(src, "samples-f16.bin"), dtype=np.float16).reshape(-1, 3, 224, 224)
    x0 = torch.from_numpy(xs[:1].astype(np.float32))
    with torch.no_grad():
        traced = torch.jit.trace(visual, x0)
    print(f"loaded + traced in {time.time() - t0:.0f} s")

    t1 = time.time()
    ml = ct.convert(traced, convert_to="mlprogram",
                    inputs=[ct.TensorType(name="pixel_values", shape=(1, 3, 224, 224), dtype=np.float32)],
                    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
                    compute_precision=ct.precision.FLOAT16,
                    minimum_deployment_target=ct.target.iOS18)
    ml.short_description = f"{man['hf']} image encoder, float16 weights"
    pkg = os.path.join(out, "PlantEncoder.mlpackage")
    ml.save(pkg)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(pkg) for f in fs)
    print(f"converted in {time.time() - t1:.0f} s: {size / 1e9:.2f} GB")

    refs = [np.array(s["embedding"], dtype=np.float32) for s in man["samples"]]
    for cu in [ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.ALL]:
        t2 = time.time()
        m = ct.models.MLModel(pkg, compute_units=cu)
        load = time.time() - t2
        cos, times = [], []
        for x, ref in zip(xs, refs):
            t3 = time.time()
            e = m.predict({"pixel_values": x[None].astype(np.float32)})["embedding"].reshape(-1)
            times.append(time.time() - t3)
            cos.append(float(np.dot(e / np.linalg.norm(e), ref)))
        print(f"{cu.name}: load {load:.1f} s, per photo {[round(t, 2) for t in times]} s, "
              f"cosine vs torch fp32 {[round(c, 5) for c in cos]}")
        assert min(cos) > 0.99, "Core ML output drifts from PyTorch"
    print(f"done in {time.time() - t0:.0f} s -> {out}")


if __name__ == "__main__":
    sys.exit(main())

"""Check probe/plantid/pilresize.js against Pillow + torchvision, bit for bit.
(The Safari test page was deleted with the web app; the module is read from
commit 04ea5d9 via `git show`.)

Decodes test images with Pillow, runs the open_clip resize + centre crop in
Python and (via node) in the JS module, and compares the uint8 outputs. Real
sample photos plus synthetic images in awkward sizes (odd crops, landscape,
portrait, tiny, huge, exact-224 sides).

  uv run --with torch --with torchvision --with pillow --with numpy \
      python3 -I pipeline/plantid/check_pilresize.py
"""
import glob, json, os, subprocess, sys, tempfile

import numpy as np
from PIL import Image
from torchvision import transforms as T

HERE = os.path.dirname(os.path.abspath(__file__))
WEB_COMMIT = "04ea5d9"  # last commit with probe/ (the retired Safari test page)
SAMPLES = os.path.join(HERE, "..", "cache", "plantid", "onnx", "bioclip25", "samples")


def main():
    tf = T.Compose([T.Resize(224, interpolation=T.InterpolationMode.BICUBIC, antialias=True), T.CenterCrop(224)])
    rng = np.random.default_rng(0)
    imgs = [Image.open(p).convert("RGB") for p in sorted(glob.glob(os.path.join(SAMPLES, "*.jpg")))]
    smooth = lambda w, h: Image.fromarray(np.clip(  # noqa: E731 — gradients + noise
        np.add.outer(np.linspace(0, 255, h), np.linspace(0, 255, w))[..., None] / 2
        + rng.normal(0, 40, (h, w, 3)), 0, 255).astype(np.uint8))
    imgs += [smooth(w, h) for w, h in [(500, 375), (375, 500), (501, 333), (224, 224), (224, 300),
                                      (300, 224), (225, 227), (100, 80), (4032, 3024), (3000, 4000), (1000, 999)]]
    with tempfile.TemporaryDirectory() as d:
        JS = os.path.join(d, "pilresize.js")
        with open(JS, "wb") as f:
            f.write(subprocess.check_output(["git", "-C", HERE, "show", f"{WEB_COMMIT}:probe/plantid/pilresize.js"]))
        cases = []
        for i, im in enumerate(imgs):
            a = np.asarray(im, dtype=np.uint8)
            a.tofile(os.path.join(d, f"{i}.rgb"))
            np.asarray(tf(im), dtype=np.uint8).tofile(os.path.join(d, f"{i}.ref"))
            cases.append({"i": i, "w": im.width, "h": im.height})
        script = f"""
import {{ resizeCrop }} from {json.dumps("file://" + os.path.abspath(JS))};
import fs from "fs";
const out = [];
for (const c of {json.dumps(cases)}) {{
  const src = new Uint8Array(fs.readFileSync({json.dumps(d)} + "/" + c.i + ".rgb"));
  const ref = new Uint8Array(fs.readFileSync({json.dumps(d)} + "/" + c.i + ".ref"));
  const got = resizeCrop(src, c.w, c.h, 224, 3);
  let diff = 0, maxd = 0;
  for (let k = 0; k < ref.length; k++) {{ const e = Math.abs(ref[k] - got[k]); if (e) diff++; if (e > maxd) maxd = e; }}
  out.push({{ ...c, n: ref.length, len: got.length, diff, maxd }});
}}
console.log(JSON.stringify(out));
"""
        p = os.path.join(d, "t.mjs")
        open(p, "w").write(script)
        res = json.loads(subprocess.check_output(["node", p]))
    bad = 0
    for r in res:
        ok = r["diff"] == 0 and r["len"] == r["n"]
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} {r['w']}x{r['h']}: {r['diff']} of {r['n']} values differ (max {r['maxd']})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

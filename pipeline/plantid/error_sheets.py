#!/usr/bin/env python3
"""Contact sheets for the manual error analysis of v2 (README "Single model
(v2)"): stated-but-wrong answers ("wrong but sure": p ≥ the ladder's species
threshold, wrong species) sampled across AU-test / C-main / C-euc / A-test,
and Tasmania's photos the single model loses against the gated hybrid. Per
case: the query photo, a training photo of the predicted species and of the
true species (iNat open-data 500 px; photos stay in the gitignored cache),
names, p, the no-prior answer (prior contribution), location, training-photo
counts. → australia/v2/errors/{sheet-*.png, cases.json}

Env: uv run --with pillow --with pyarrow --with 'numpy<2.3' python3 -I …"""
import http.client
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import pyarrow.parquet as pq
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
V2 = os.path.join(AU, "v2")
OUT = os.path.join(V2, "errors")
PH = os.path.join(OUT, "photos")
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}


def fetch(pid, ext):
    p = os.path.join(PH, f"{pid}.{ext}")
    for d in (os.path.join(CACHE, "photos"), os.path.join(AU, "photos"), PH):
        q = os.path.join(d, f"{pid}.{ext}")
        if os.path.exists(q):
            return q
    try:
        c = http.client.HTTPSConnection(HOST, timeout=30)
        c.request("GET", f"/photos/{pid}/medium.{ext}", headers=UA)
        r = c.getresponse()
        body = r.read()
        if r.status == 200:
            open(p, "wb").write(body)
            return p
    except Exception:  # noqa: BLE001
        pass
    return None


def main():
    os.makedirs(PH, exist_ok=True)
    run = sys.argv[1] if len(sys.argv) > 1 else "v2fix-e12"
    U = pq.read_table(os.path.join(AU, "labels.parquet"), columns=["name", "euc"]).to_pydict()
    n_tr = np.load(os.path.join(V2, "runs", run + ".npz"))["n_c"]
    tr = pq.read_table(os.path.join(AU, "plan", "train.parquet"), columns=["u", "photo_id", "ext", "region"]).to_pydict()
    ref = {}
    for u, p, e, rg in sorted(zip(tr["u"], tr["photo_id"], tr["ext"], tr["region"]), key=lambda r: (r[3], r[1])):
        ref.setdefault(u, (p, e))  # an Australian training photo first
    rng = np.random.default_rng(11)
    cases = []

    def pick(setname, mask, k, tag):
        P = np.load(os.path.join(V2, f"pred-{setname}.npz"), allow_pickle=True)
        thr = float(P["thr"][0])
        wrong = (P["p1"] >= thr) & (P["top"][:, 0] != P["y"]) & mask(P)
        idx = np.nonzero(wrong)[0]
        for i in rng.permutation(idx)[:k]:
            cases.append({"tag": tag, "set": setname, "pid": int(P["pid"][i]), "ext": str(P["ext"][i]),
                          "y": int(P["y"][i]), "pred": int(P["top"][i, 0]), "p": float(P["p1"][i]),
                          "noprior": int(P["top_noprior"][i, 0]), "p_noprior": float(P["p1_noprior"][i]),
                          "lat": float(P["lat"][i]), "lon": float(P["lon"][i]), "pool": int(wrong.sum())})
    euc = np.array(U["euc"])
    pick("AU-test", lambda P: ~euc[np.maximum(P["y"], 0)], 20, "AU-test")
    pick("AU-test", lambda P: euc[np.maximum(P["y"], 0)], 10, "AU-test euc")
    pick("C-report", lambda P: P["sub"] == "main", 15, "C-main")
    pick("C-report", lambda P: P["sub"] == "euc", 15, "C-euc")
    pick("A-test", lambda P: np.ones(len(P["y"]), bool), 20, "A-test")
    # Tasmania: photos the hybrid gets right and v2 wrong
    P = np.load(os.path.join(V2, "pred-A-test.npz"), allow_pickle=True)
    H = np.load(os.path.join(V2, "pred-A-test-hybrid.npz"))
    assert (H["pid"] == P["pid"]).all()
    lost = np.nonzero((H["top"][:, 0] == P["y"]) & (P["top"][:, 0] != P["y"]) & (P["y"] >= 0))[0]
    for i in rng.permutation(lost)[:30]:
        cases.append({"tag": "Tas lost", "set": "A-test", "pid": int(P["pid"][i]), "ext": str(P["ext"][i]),
                      "y": int(P["y"][i]), "pred": int(P["top"][i, 0]), "p": float(P["p1"][i]),
                      "noprior": int(P["top_noprior"][i, 0]), "p_noprior": float(P["p1_noprior"][i]),
                      "lat": float(P["lat"][i]), "lon": float(P["lon"][i]), "pool": int(len(lost))})
    jobs = [(c["pid"], c["ext"]) for c in cases]
    for c in cases:
        for k in ("pred", "y"):
            if c[k] >= 0 and c[k] in ref:
                jobs.append(ref[c[k]])
    with ThreadPoolExecutor(8) as ex:
        got = dict(zip(jobs, ex.map(lambda j: fetch(*j), jobs)))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 15)
    except Exception:  # noqa: BLE001
        font = ImageFont.load_default()
    H_, W_ = 230, 230
    per = 8
    for s in range(0, len(cases), per):
        chunk = cases[s:s + per]
        sheet = Image.new("RGB", (3 * W_ + 560, per * (H_ + 10)), "white")
        d = ImageDraw.Draw(sheet)
        for r, c in enumerate(chunk):
            y0 = r * (H_ + 10)
            for j, key in enumerate(((c["pid"], c["ext"]), ref.get(c["pred"]), ref.get(c["y"]) if c["y"] >= 0 else None)):
                pth = got.get(key) if key else None
                if pth:
                    try:
                        im = Image.open(pth).convert("RGB")
                        im.thumbnail((W_, H_))
                        sheet.paste(im, (j * W_, y0))
                    except Exception:  # noqa: BLE001
                        pass
            nm = lambda u: "(not in label set)" if u < 0 else f"{U['name'][u]} [{int(n_tr[u])} train]"  # noqa: E731
            txt = [f"#{s + r} {c['tag']}  photo {c['pid']}",
                   f"TRUE: {nm(c['y'])}",
                   f"SAID: {nm(c['pred'])}  p={c['p']:.2f}",
                   f"no prior: {nm(c['noprior'])} p={c['p_noprior']:.2f}",
                   f"at {c['lat']:.3f}, {c['lon']:.3f}",
                   "cols: query | train photo of SAID | of TRUE"]
            for k, t in enumerate(txt):
                d.text((3 * W_ + 10, y0 + 8 + 22 * k), t, fill="black", font=font)
        sheet.save(os.path.join(OUT, f"sheet-{s // per:02d}.png"))
    json.dump(cases, open(os.path.join(OUT, "cases.json"), "w"), indent=1)
    print(f"{len(cases)} cases, {sum(v is not None for v in got.values())}/{len(got)} photos, "
          f"{-(-len(cases) // per)} sheets → {OUT}")


if __name__ == "__main__":
    main()

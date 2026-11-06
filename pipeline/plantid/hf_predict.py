#!/usr/bin/env python3
"""IzzyMap plant identifier (Australia): photo (+ optional location) → species.

Frozen BioCLIP 2.5 ViT-H/14 image embedding → two multi-prototype heads (mean of
their logits) → × adaptive location prior → temperature-calibrated probabilities →
the answer ladder (species / genus / not sure). Every parameter comes from
config.json; the encoder is loaded from Hugging Face at the pinned revision.

  python predict.py photo.jpg --lat -42.88 --lon 147.33      # top 5 + the ladder answer
  python predict.py photo.jpg                                 # no location: country-wide frequency
  python predict.py photo.jpg --int8 --json                   # the int8 heads (as in the app); JSON out

Requirements (tested): python 3.12, torch 2.7, open_clip_torch 3.3.0, numpy < 2.3,
pillow, safetensors, huggingface_hub. CPU is fine (~1–3 s per photo for the encoder).
Licence: CC BY-NC 4.0 (this folder); BioCLIP 2.5 is MIT (downloaded separately).
"""
import argparse
import json
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def log_softmax(z):
    z = z - z.max(-1, keepdims=True)
    return z - np.log(np.exp(z).sum(-1, keepdims=True))


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True)


class PlantID:
    """The release's scorer. `logp(emb, lat, lon)` → (calibrated log p, image-only log p),
    both (n × classes); lat/lon None = no location."""

    def __init__(self, folder=HERE, int8=False):
        from safetensors.numpy import load_file
        self.cfg = json.load(open(os.path.join(folder, "config.json")))
        sc = self.cfg["scoring"]
        H = load_file(os.path.join(folder, "heads-int8.safetensors" if int8 else "heads-fp16.safetensors"))
        self.centre = H["centre"].astype(np.float32)
        self.heads = []
        for j, hc in enumerate(sc["heads"]):
            p = f"head{j}."
            W = H[p + "weight"].astype(np.float32)
            if int8:
                W = W * H[p + "scale"].astype(np.float32)[:, None]
            kc, row0 = H[p + "kc"].astype(np.int64), H[p + "row0"].astype(np.int64)
            groups = [(int(K), np.nonzero(kc == K)[0]) for K in np.unique(kc)]
            groups = [(K, cls, row0[cls][:, None] + np.arange(K)[None]) for K, cls in groups]
            self.heads.append((W, H[p + "bias"].astype(np.float32), groups, float(hc["pool_temperature"])))
        P = load_file(os.path.join(folder, "prior.safetensors"))
        self.pr = json.load(open(os.path.join(folder, "prior.json")))
        self.rowptr, self.sp = P["rowptr"].astype(np.int64), P["species"].astype(np.int64)
        assert self.pr["transform"] == "log1p"
        self.cnt = np.log1p(P["count"].astype(np.float64))
        self.freq = P["freq_log1p"].astype(np.float64)
        self.code, self.sig, self.alp = P["sigma_code"], P["sigma_km"].astype(np.float64), P["alpha"].astype(np.float64)
        lab = json.load(open(os.path.join(folder, "labels.json")))["labels"]
        self.labels = lab
        gn = {}
        self.genus = np.array([gn.setdefault(l["genus"], len(gn)) for l in lab])
        self.gnames = list(gn)
        self.photos = np.array([l["training_photos"] for l in lab])
        self.C = len(lab)

    # -- image term
    def head_logits(self, q):
        """Mean over heads; class c's K_c prototype logits z pooled as T·(logsumexp(z/T) − log K_c) + bias."""
        out = np.zeros((len(q), self.C), np.float32)
        for W, b, groups, T in self.heads:
            with np.errstate(all="ignore"):   # macOS Accelerate BLAS raises spurious FP flags in float32 matmul
                Z = q @ W.T
            assert np.isfinite(Z).all()
            for K, cls, idx in groups:
                if K == 1:
                    out[:, cls] += Z[:, idx[:, 0]] + b[cls]
                    continue
                zz = Z[:, idx]
                m = zz.max(-1)
                out[:, cls] += m + T * (np.log(np.exp((zz - m[..., None]) / T).sum(-1)) - np.log(K)) + b[cls]
        return out / len(self.heads)

    # -- location term
    def density(self, lat, lon, sigma):
        """K[c] = Σ over grid cells within radius_sigmas·σ of (lat, lon) of log1p(count)·exp(−d²/2σ²)."""
        g = self.pr["grid"]
        cd, r = g["cell_deg"], g["radius_sigmas"] * sigma
        ky, kx = g["km_per_deg_lat"], g["km_per_deg_lon"] * np.cos(np.radians(lat))
        wy, wx = int(np.ceil(r / (ky * cd))) + 1, int(np.ceil(r / (kx * cd))) + 1
        iy0 = int(np.floor((lat - g["lat0"]) / cd))
        ix0 = int(np.floor((lon - g["lon0"]) / cd))
        iy, ix = np.meshgrid(np.arange(iy0 - wy, iy0 + wy + 1), np.arange(ix0 - wx, ix0 + wx + 1), indexing="ij")
        dy = (g["lat0"] + (iy + 0.5) * cd - lat) * ky
        dx = (g["lon0"] + (ix + 0.5) * cd - lon) * kx
        d2 = dx ** 2 + dy ** 2
        ok = (d2 <= r * r) & (iy >= 0) & (iy < g["ny"]) & (ix >= 0) & (ix < g["nx"])
        K = np.zeros(self.C)
        for cell, w in zip((iy * g["nx"] + ix)[ok], np.exp(-d2[ok] / (2 * sigma * sigma))):
            a, b = self.rowptr[cell], self.rowptr[cell + 1]
            np.add.at(K, self.sp[a:b], w * self.cnt[a:b])
        return K

    def log_prior(self, lat, lon):
        """log((K + α f) / (ΣK + α)) with (σ, α) of the photo's grid cell; no location → log f."""
        if lat is None:
            return np.log(self.freq)
        g = self.pr["grid"]
        iy = min(max(int(np.floor((lat - g["lat0"]) / g["cell_deg"])), 0), g["ny"] - 1)
        ix = min(max(int(np.floor((lon - g["lon0"]) / g["cell_deg"])), 0), g["nx"] - 1)
        k = int(self.code[iy, ix])
        s, a = float(self.sig[k]), float(self.alp[k])
        K = self.density(float(lat), float(lon), s)
        return np.log((K + a * self.freq) / (K.sum() + a))

    def logp(self, emb, lat=None, lon=None):
        sc = self.cfg["scoring"]
        e = np.atleast_2d(np.asarray(emb, np.float32))
        q = unit(unit(e) - self.centre[None]).astype(np.float32)
        Li = log_softmax(self.head_logits(q) / sc["image_temperature"])
        P = sc["prior"]["lambda"] * self.log_prior(lat, lon)[None]
        T = sc["calibration_temperature"]
        return log_softmax(log_softmax(Li + P) / T), log_softmax(Li / T)

    def ladder(self, lp, lpi):
        """Species if p ≥ the threshold of the named class's training-photo bucket (and the image-only
        p ≥ image_floor); else the genus with the most summed p if ≥ genus threshold; else not sure."""
        lad = self.cfg["scoring"]["ladder"]
        p = np.exp(lp)
        o = np.argsort(-p)
        n1, n2 = int(o[0]), int(o[1])
        n = self.photos[n1]
        bucket = 0 if n == 0 else 1 if n < 10 else 2 if n < 50 else 3
        thr = lad["species_threshold_by_bucket"][bucket]
        close = lad["congener_ratio"] < 1 and self.genus[n1] == self.genus[n2] and p[n2] >= lad["congener_ratio"] * p[n1]
        if p[n1] >= thr and np.exp(lpi[n1]) >= lad["image_floor"] and not close:
            return {"kind": "species", "label": n1, "name": self.labels[n1]["name"], "p": float(p[n1]), "threshold": thr}
        gp = np.bincount(self.genus, p, minlength=len(self.gnames))
        g = int(gp.argmax())
        if gp[g] >= lad["genus_threshold"]:
            top = [int(u) for u in o if self.genus[u] == g][:3]
            return {"kind": "genus", "genus": self.gnames[g], "p": float(gp[g]),
                    "top": [self.labels[u]["name"] for u in top]}
        return {"kind": "not sure"}


class Encoder:
    """BioCLIP 2.5 ViT-H/14 at the pinned revision (open_clip), its own preprocessing:
    shortest side → 224 (bicubic), centre crop 224, CLIP mean/std. RGB decode ignoring any
    embedded colour profile (as in training)."""

    def __init__(self, folder=HERE, device="cpu"):
        import open_clip
        import torch
        from huggingface_hub import snapshot_download
        enc = json.load(open(os.path.join(folder, "config.json")))["encoder"]
        path = snapshot_download(enc["hf_repo"], revision=enc["revision"])
        self.model, _, self.tf = open_clip.create_model_and_transforms("local-dir:" + path)
        self.model = self.model.to(device).eval()
        self.torch, self.device = torch, device

    def __call__(self, image_path):
        from PIL import Image
        x = self.tf(Image.open(image_path).convert("RGB"))[None].to(self.device)
        with self.torch.no_grad():
            return self.model.encode_image(x).float().cpu().numpy()[0]


def main():
    ap = argparse.ArgumentParser(description="IzzyMap plant identifier (Australia)")
    ap.add_argument("image")
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lon", type=float)
    ap.add_argument("--int8", action="store_true", help="the int8 heads (as in the app) instead of fp16")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if (a.lat is None) != (a.lon is None):
        ap.error("give both --lat and --lon, or neither")
    m = PlantID(int8=a.int8)
    e = Encoder(device=a.device)(a.image)
    lp, lpi = m.logp(e, a.lat, a.lon)
    lp, lpi = lp[0], lpi[0]
    o = np.argsort(-lp)[:a.top]
    res = {"top": [{"rank": i + 1, "name": m.labels[c]["name"], "common_name": m.labels[c].get("common_name"),
                    "p": float(np.exp(lp[c])), "p_image_only": float(np.exp(lpi[c]))} for i, c in enumerate(o)],
           "answer": m.ladder(lp, lpi), "location": None if a.lat is None else [a.lat, a.lon]}
    if a.json:
        print(json.dumps(res, indent=1, ensure_ascii=False))
        return
    for r in res["top"]:
        cn = f" ({r['common_name']})" if r["common_name"] else ""
        print(f"{r['rank']}. {r['name']}{cn}  p = {r['p']:.3f}  (image only {r['p_image_only']:.3f})")
    ans = res["answer"]
    print("answer:", {"species": lambda: f"{ans['name']} (p {ans['p']:.2f} ≥ {ans['threshold']:.2f})",
                      "genus": lambda: f"genus {ans['genus']} (p {ans['p']:.2f}): {', '.join(ans['top'])}",
                      "not sure": lambda: "not sure"}[ans["kind"]]())


if __name__ == "__main__":
    main()

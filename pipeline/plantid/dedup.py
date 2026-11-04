#!/usr/bin/env python3
"""Near-duplicate guard for extra training photos (notes/data_expansion.md).

Every later photo source (iNat extras, ALA, Wikimedia — which mirror iNat
photos) goes through the same two stages before its photos may train:

  1. perceptual hashes, BEFORE embedding (cheap, from the downloaded bytes):
     pHash (DCT, 64 bit) and dHash (gradient, 64 bit) of a greyscale decode;
     a candidate is a near-duplicate of a reference photo when BOTH Hamming
     distances are within the calibrated thresholds. Used against every
     evaluation photo (drop the candidate) and within the candidates (keep
     the first in rank order).
  2. embedding cosine, AFTER embedding (BioCLIP 2.5 fp16, the training
     embeddings): candidate vs evaluation embeddings, cosine ≥ the calibrated
     threshold = duplicate. Catches what hashes miss (crops, colour edits)
     and confirms hash hits.

Thresholds come from `calibrate` on KNOWN duplicates: the same iNat photo as
"small" (240 px), "medium" (500 px) and "large" (1024 px) — iNat's own
resizes — plus a JPEG q50 re-encode and a 90 % centre crop of the medium;
negatives = another photo of the same observation (burst shots, the hardest
honest negatives), and random pairs.

API (also used by expand_inat.py):
  hashes(bytes) -> {"phash": int, "dhash": int}         (uint64 as Python int)
  near_any(pc, dc, pr, dr, tp, td) -> (hit[bool], j[int])  candidates vs refs
  near_within(p, d, tp, td) -> (dup[bool], j[int])         j < i, rank order
  emb_near(Q, R, thr) -> (hit[bool], j[int], best_cos)     stage 2
Hamming search = numpy's native bitwise_count over blocks, brute force:
measured on the M4 ~0.5–1.2e9 pair checks/s (261k × 85k vs eval 52 s; 261k
within 353 s). Multi-index hashing was tried and is NOT a fit: pHash bits
of natural photos are skewed (the DC bit, low frequencies), so exact-chunk
buckets are huge. For lists several times larger, use a native binary
index (faiss IndexBinaryFlat) or restrict the within-list pass.
Embedding search = blocked matmul.
"""
import io
import json
import os
import time

import numpy as np

MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"GIF8", b"RIFF")
PHASH_SIZE = 8


def _grey(body):
    from PIL import Image
    im = Image.open(io.BytesIO(body))
    # JPEG DCT-domain downscale: decode at ≥ 128 px instead of full size
    # (4–8× faster; the hashes resize to 32 / 9 px anyway). Applied to every
    # photo alike, so references and candidates hash the same way.
    im.draft("L", (128, 128))
    return im.convert("L")


def _bits(a):
    return int.from_bytes(np.packbits(a.reshape(-1).astype(np.uint8)).tobytes(), "big")


def hashes(body):
    """pHash (imagehash's: 32×32 DCT, top-left 8×8 vs median) and dHash
    (9×8 horizontal gradient) of an image's bytes, as unsigned 64-bit ints."""
    import imagehash
    g = _grey(body)
    return {"phash": _bits(imagehash.phash(g, hash_size=PHASH_SIZE).hash),
            "dhash": _bits(imagehash.dhash(g, hash_size=8).hash)}


def _u64(x):
    return np.asarray(x).astype(np.uint64)


def near_any(pc, dc, pr, dr, tp, td, block=2048):
    """For every candidate: is there a reference within pHash ≤ tp AND dHash
    ≤ td? Returns (hit, index of the best such reference by pHash + dHash)."""
    pc, dc, pr, dr = map(_u64, (pc, dc, pr, dr))
    hit = np.zeros(len(pc), bool)
    j = np.full(len(pc), -1, np.int64)
    if not len(pr):
        return hit, j
    for lo in range(0, len(pc), block):
        a = np.bitwise_count(pc[lo:lo + block, None] ^ pr[None, :])
        b = np.bitwise_count(dc[lo:lo + block, None] ^ dr[None, :])
        ok = (a <= tp) & (b <= td)
        h = ok.any(1)
        hit[lo:lo + block] = h
        if h.any():
            s = np.where(ok, a.astype(np.int16) + b, 999)
            j[lo:lo + block] = np.where(h, s.argmin(1), -1)
    return hit, j


def near_within(p, d, tp, td, block=2048):
    """Near-duplicates inside one ranked list: i is a duplicate when an
    EARLIER j (< i) is within both thresholds (the first copy is kept)."""
    p, d = _u64(p), _u64(d)
    n = len(p)
    dup = np.zeros(n, bool)
    j = np.full(n, -1, np.int64)
    for lo in range(0, n, block):
        hi = min(n, lo + block)
        a = np.bitwise_count(p[lo:hi, None] ^ p[None, :hi])
        b = np.bitwise_count(d[lo:hi, None] ^ d[None, :hi])
        ok = (a <= tp) & (b <= td)
        ok &= np.arange(hi)[None, :] < np.arange(lo, hi)[:, None]  # only earlier rows
        h = ok.any(1)
        dup[lo:hi] = h
        j[lo:hi] = np.where(h, ok.argmax(1), -1)
    return dup, j


def emb_near(Q, R, thr, block=4096, exclude=None):
    """Stage 2: cosine of L2-normalised embeddings; hit = max cos ≥ thr.
    `exclude` (optional, len(Q) × len(R) callable mask) is not needed for
    candidates vs eval (disjoint by construction)."""
    Q = np.asarray(Q, np.float32)
    R = np.asarray(R, np.float32)
    best = np.full(len(Q), -1.0, np.float32)
    j = np.full(len(Q), -1, np.int64)
    for lo in range(0, len(R), block):
        S = Q @ R[lo:lo + block].T
        k = S.argmax(1)
        v = S[np.arange(len(Q)), k]
        upd = v > best
        best[upd], j[upd] = v[upd], lo + k[upd]
    return best >= thr, j, best


# ------------------------------------------------------------------ calibration

def _variants(body):
    """Synthetic duplicates of one medium photo: JPEG q50, 90 % centre crop."""
    from PIL import Image
    im = Image.open(io.BytesIO(body)).convert("RGB")
    out = {}
    b = io.BytesIO()
    im.save(b, "JPEG", quality=50)
    out["q50"] = b.getvalue()
    w, h = im.size
    c = im.crop((int(w * .05), int(h * .05), int(w * .95), int(h * .95)))
    b = io.BytesIO()
    c.save(b, "JPEG", quality=90)
    out["crop90"] = b.getvalue()
    return out


def calibrate(work, H, C, n=300, threads=16, seed=7):
    """Hash-stage thresholds. Positives: n candidate photos as iNat's small /
    large vs the medium we hashed, + q50 + crop90. Hard negatives: another
    candidate photo of the same observation. Random negatives: 20,000 random
    candidate pairs. Writes work/calibration.json (+ the raw distances)."""
    import concurrent.futures as cf
    import http.client
    import threading
    H = H.to_pandas()
    C = C.to_pandas()
    H = H[H["status"].isin(["ok", "local"])]
    M = C.merge(H[["photo_id", "phash", "dhash"]], on="photo_id")
    rng = np.random.default_rng(seed)
    pick = M.iloc[rng.choice(len(M), min(n, len(M)), replace=False)]
    host = "inaturalist-open-data.s3.amazonaws.com"
    loc = threading.local()

    def get(pid, ext, size):
        for attempt in range(4):
            try:
                c = getattr(loc, "c", None) or http.client.HTTPSConnection(host, timeout=30)
                loc.c = c
                c.request("GET", f"/photos/{pid}/{size}.{ext}", headers={"User-Agent": "izzymap-plantid-eval/1"})
                r = c.getresponse()
                b = r.read()
                return b if r.status == 200 and b.startswith(MAGIC) else None
            except Exception:  # noqa: BLE001
                loc.c = None
                time.sleep(1 + attempt)
        return None

    def one(row):
        pid, ext = int(row.photo_id), row.ext
        med = get(pid, ext, "medium")
        if med is None:
            return None
        h0 = hashes(med)
        r = {"photo_id": pid, "medium_phash": h0["phash"], "check_phash": int(row.phash)}
        for size in ("small", "large"):
            b = get(pid, ext, size)
            if b:
                h = hashes(b)
                r[size] = (bin(h0["phash"] ^ h["phash"]).count("1"), bin(h0["dhash"] ^ h["dhash"]).count("1"))
        for k, b in _variants(med).items():
            h = hashes(b)
            r[k] = (bin(h0["phash"] ^ h["phash"]).count("1"), bin(h0["dhash"] ^ h["dhash"]).count("1"))
        return r
    t = time.time()
    with cf.ThreadPoolExecutor(threads) as ex:
        pos = [r for r in ex.map(one, list(pick.itertuples())) if r]
    print(f"positives: {len(pos)} photos ({time.time() - t:.0f} s)", flush=True)
    # hard negatives: pairs of photos of one observation (both in the candidates)
    g = M.groupby("observation_uuid")
    pairs = [(x.iloc[0], x.iloc[1]) for _, x in g if len(x) >= 2]
    rng.shuffle(pairs)
    pairs = pairs[:20000]
    hn = [(bin(int(a.phash) ^ int(b.phash)).count("1"), bin(int(a.dhash) ^ int(b.dhash)).count("1")) for a, b in pairs]
    ii = rng.integers(0, len(M), (20000, 2))
    ph, dh = M["phash"].to_numpy(np.uint64), M["dhash"].to_numpy(np.uint64)
    rn = list(zip(np.bitwise_count(ph[ii[:, 0]] ^ ph[ii[:, 1]]).tolist(),
                  np.bitwise_count(dh[ii[:, 0]] ^ dh[ii[:, 1]]).tolist()))
    kinds = ("small", "large", "q50", "crop90")
    P = {k: np.array([r[k] for r in pos if k in r]) for k in kinds}
    HN, RN = np.array(hn), np.array(rn)
    grid = []
    for tp in range(0, 17, 2):
        for td in range(0, 21, 2):
            rec = {"phash": tp, "dhash": td}
            for k in kinds:
                rec["recall_" + k] = float(((P[k][:, 0] <= tp) & (P[k][:, 1] <= td)).mean()) if len(P[k]) else None
            rec["same_obs_flagged"] = float(((HN[:, 0] <= tp) & (HN[:, 1] <= td)).mean()) if len(HN) else None
            rec["random_flagged"] = float(((RN[:, 0] <= tp) & (RN[:, 1] <= td)).mean())
            grid.append(rec)
    # choice: 100 % recall on iNat's own resizes (small, large) and q50 with a
    # 2× margin over the largest distance any of them showed (leakage guard:
    # a false drop costs one training photo, a miss leaks an eval photo), and
    # no random pair flagged. Crops are left to the embedding stage. Random
    # pairs only bound the false-positive rate per pair (< ~1.5e-4 at 0 of
    # 20k) — check the real hits by eye (notes).
    mx_p = max(int(P[k][:, 0].max()) for k in ("small", "large", "q50") if len(P[k]))
    mx_d = max(int(P[k][:, 1].max()) for k in ("small", "large", "q50") if len(P[k]))
    want = (min(16, 2 * mx_p), min(20, 2 * mx_d + 2))
    chosen = next((r for r in grid if (r["phash"], r["dhash"]) == want and r["random_flagged"] == 0), None)
    pct = lambda a: {q: float(np.percentile(a, q)) for q in (50, 90, 99, 100)} if len(a) else None  # noqa: E731
    out = {"n_positive_photos": len(pos), "n_same_obs_pairs": len(HN), "n_random_pairs": len(RN),
           "medium_rehash_identical": float(np.mean([r["medium_phash"] == r["check_phash"] for r in pos])),
           "distance_percentiles": {k: {"phash": pct(P[k][:, 0]), "dhash": pct(P[k][:, 1])} for k in kinds if len(P[k])}
           | {"same_obs": {"phash": pct(HN[:, 0]), "dhash": pct(HN[:, 1])},
              "random": {"phash": pct(RN[:, 0]), "dhash": pct(RN[:, 1])}},
           "grid": grid, "chosen": chosen}
    json.dump(out, open(os.path.join(work, "calibration.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "grid"}, indent=1))
    return out


def choose_emb(grid):
    """BioCLIP cosine does NOT separate duplicates from other photos of the
    same plant (measured: iNat's 240 px "small" vs the medium can be 0.77–0.95,
    another photo of the same observation up to 0.95). Two roles instead:
    confirm = the highest threshold keeping ≥ 98 % of every known-duplicate
    kind with no random pair (a hash hit with cos ≥ confirm is a duplicate);
    standalone = the lowest threshold flagging no same-observation and no
    random pair (catches crops / edits the hashes miss, at partial recall)."""
    kinds = ("small", "large", "q50", "crop90")
    conf = [r for r in grid if min(r[k] for k in kinds) >= 0.98 and r["random"] == 0]
    alone = [r for r in grid if r["same_obs"] == 0 and r["random"] == 0]
    return {"confirm": max(conf, key=lambda r: r["thr"]) if conf else None,
            "standalone": min(alone, key=lambda r: r["thr"]) if alone else None}


def calibrate_emb(work, pairs, fetch, n_max=80, device=None):
    """Embedding-stage threshold (BioCLIP 2.5, open_clip eval transform, fp16
    — the training embeddings' recipe; here on MPS). `pairs` = list of
    (photo_id, ext, other_photo_id, other_ext): a photo and another photo of
    the same observation. `fetch(pid, ext, size)` → bytes or None.
    Positives: medium vs small / large / q50 / crop90 of the same photo.
    Negatives: medium vs the other photo of its observation (hard), and vs
    the other photos of the other pairs (random). → work/calibration-emb.json"""
    import open_clip
    import torch
    from PIL import Image
    dev = device or ("mps" if torch.backends.mps.is_available() else "cpu")
    t0 = time.time()
    model, _, tf = open_clip.create_model_and_transforms("hf-hub:imageomics/bioclip-2.5-vith14")
    model = model.visual.to(dev).half().eval()
    print(f"model {time.time() - t0:.0f} s", flush=True)
    items, keys = [], []
    for pid, ext, opid, oext in pairs[:n_max]:
        med = fetch(pid, ext, "medium")
        oth = fetch(opid, oext, "medium")
        if med is None or oth is None:
            continue
        v = {"medium": med, "other": oth, **_variants(med)}
        for size in ("small", "large"):
            b = fetch(pid, ext, size)
            if b:
                v[size] = b
        for k, b in v.items():
            items.append(b)
            keys.append((pid, k))
    t1 = time.time()
    E = []
    with torch.inference_mode():
        for lo in range(0, len(items), 32):
            x = torch.stack([tf(Image.open(io.BytesIO(b)).convert("RGB")) for b in items[lo:lo + 32]])
            e = model(x.to(dev, torch.float16))
            E.append(torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy())
    E = np.concatenate(E)
    print(f"{len(items)} embeddings in {time.time() - t1:.0f} s", flush=True)
    idx = {k: i for i, k in enumerate(keys)}
    pids = sorted({p for p, _ in keys})
    cos = {k: [] for k in ("small", "large", "q50", "crop90", "same_obs", "random")}
    for j, p in enumerate(pids):
        m = E[idx[(p, "medium")]]
        for k in ("small", "large", "q50", "crop90"):
            if (p, k) in idx:
                cos[k].append(float(m @ E[idx[(p, k)]]))
        cos["same_obs"].append(float(m @ E[idx[(p, "other")]]))
        for q in pids[j + 1:j + 6]:
            cos["random"].append(float(m @ E[idx[(q, "other")]]))
    pct = lambda a: {q: round(float(np.percentile(a, q)), 4) for q in (0, 1, 10, 50, 90, 99, 100)} if a else None  # noqa: E731
    grid = []
    for thr in np.round(np.arange(0.80, 0.995, 0.01), 3):
        r = {"thr": float(thr)}
        for k, v in cos.items():
            r[k] = float(np.mean(np.array(v) >= thr)) if v else None
        grid.append(r)
    chosen = choose_emb(grid)
    out = {"photos": len(pids), "embeddings": len(items), "seconds": round(time.time() - t0),
           "device": dev, "cos_percentiles": {k: pct(v) for k, v in cos.items()}, "grid": grid, "chosen": chosen}
    json.dump(out, open(os.path.join(work, "calibration-emb.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "grid"}, indent=1))
    return out

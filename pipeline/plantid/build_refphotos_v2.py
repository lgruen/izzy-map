#!/usr/bin/env python3
"""Offline reference photos v2 (notes/refphotos_v2.md): one photo per species of
the final Australia-wide plant-ID model (18,361 classes with training photos),
chosen by Claude Opus from the 5 candidates nearest the species' mean embedding.

Stages (run in order; every stage is resumable and reads/writes
cache/plantid/refphotos/v2/):

  select   candidates per species from the final training set (data-final.npz:
           iNat plan + Tasmanian + k1000 extras + ALA/APII/Commons sources),
           nearest the class mean, ref-eligible only; probe-flagged (hand /
           specimen) last; → cands.parquet (≤ 5 per species)
  fetch    iNat 500 px "medium" for the candidates (resumable, refphotos/src/)
           and 384 px JPEG thumbnails of every candidate (v2/thumb/)
  pilot    claude_pick.py-style request building lives in `vision` below:
           `vision warm|pilot|submit|collect` (see notes)
  build    encode the picked photos → pack-v2/refphotos/ (index.json,
           credits.json, AVIF q55 / 512 px, ND photos as original JPEG bytes)

  uv run --with duckdb --with pyarrow --with pandas --with numpy \\
      --with scikit-learn --with 'pillow>=11.3' --with anthropic \\
      python3 -I pipeline/plantid/build_refphotos_v2.py <stage> [...]
"""
import argparse
import base64
import collections
import hashlib
import io
import json
import os
import sys
import time
import warnings

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_refphotos as BR  # noqa: E402  (shared helpers: dims scan, fetch, encode, labels)

warnings.filterwarnings("ignore")
CACHE = BR.CACHE
AU = BR.AU
V2 = os.path.join(BR.OUT, "v2")
THUMB = os.path.join(V2, "thumb")
PACK = os.path.join(BR.OUT, "pack-v2", "refphotos")
DATA = os.path.join(AU, "v2", "data-final.npz")
SOURCES = os.path.join(CACHE, "sources", "extra_photos_sources.parquet")
SRC_IDS = os.path.join(AU, "v2", "extra_sources_ids.parquet")
K1000 = os.path.join(CACHE, "extra", "extra_photos_k1000.parquet")
QLABELS = os.path.join(HERE, "notes", "refphotos_quality_labels.json")
K = 5            # candidates per species
POOL = 24        # nearest-to-mean rows kept per species before the size gate
LOGIT_FLAG = 3.0  # refine_refphotos.LOGIT_FLAG_TRAIN: probe logit that flags a hand/specimen
SRC_BIG = 2 ** 61  # source (ALA/Commons) photo ids are hashes above this
ND = ("CC-BY-ND", "CC-BY-NC-ND")
LIC_LABEL = {"CC0": "CC0", "PD": "Public domain", "CC-BY": "CC BY", "CC-BY-NC": "CC BY-NC",
             "CC-BY-SA": "CC BY-SA", "CC-BY-NC-SA": "CC BY-NC-SA", "CC-BY-ND": "CC BY-ND",
             "CC-BY-NC-ND": "CC BY-NC-ND"}
LIC_URL = {"CC0": "https://creativecommons.org/publicdomain/zero/1.0/",
           "PD": "https://creativecommons.org/publicdomain/mark/1.0/",
           "CC-BY": "https://creativecommons.org/licenses/by/4.0/",
           "CC-BY-NC": "https://creativecommons.org/licenses/by-nc/4.0/",
           "CC-BY-SA": "https://creativecommons.org/licenses/by-sa/4.0/",
           "CC-BY-NC-SA": "https://creativecommons.org/licenses/by-nc-sa/4.0/",
           "CC-BY-ND": "https://creativecommons.org/licenses/by-nd/4.0/",
           "CC-BY-NC-ND": "https://creativecommons.org/licenses/by-nc-nd/4.0/"}


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ metadata

def inat_tables():
    """photo_id → metadata for the plan/Tasmanian training photos and the k1000 extras."""
    import duckdb
    import pandas as pd
    con = duckdb.connect()
    plan = con.execute(f"""
        SELECT photo_id::BIGINT AS photo_id, uuid::VARCHAR AS obs, observer_id, ext, license AS licence
        FROM '{AU}/plan/train.parquet'
        UNION ALL
        SELECT photo_id::BIGINT, uuid::VARCHAR, observer_id, ext, license
        FROM '{CACHE}/sets/train.parquet'
        WHERE photo_id NOT IN (SELECT photo_id FROM '{AU}/plan/train.parquet')""").df()
    plan = plan.drop_duplicates("photo_id").reset_index(drop=True)
    ex = pd.read_parquet(K1000, columns=["photo_id", "ext", "observation_uuid", "observer_id", "login",
                                         "observer_name", "licence", "source", "attribution"])
    ex = ex.rename(columns={"observation_uuid": "obs"})
    ex["photo_id"] = ex["photo_id"].astype(np.int64)
    return plan, ex


def probe_logit_fn():
    """The refine pass's linear probe P(hand/lab/label), refitted from the 452 labelled photos
    (embeddings in refine/near_emb.npz + snap_emb.npz). Returns f(X float32 (n,1024)) → logit."""
    from sklearn.linear_model import LogisticRegression
    RF = os.path.join(BR.OUT, "refine")
    z = np.load(os.path.join(RF, "near_emb.npz"))
    zs = np.load(os.path.join(RF, "snap_emb.npz"))
    emb = dict(zip(zs["photo_id"].tolist(), zs["emb"].astype(np.float32)))
    emb.update(zip(z["photo_id"].tolist(), z["emb"].astype(np.float32)))
    lab = {int(k): v for k, v in json.load(open(QLABELS))["labels"].items()}
    ids = sorted(lab)
    X = np.stack([emb[i] for i in ids])
    y = np.array([lab[i] != "ok" for i in ids], int)
    scale = 1 / float(X.std(0).mean())
    m = LogisticRegression(C=0.3, max_iter=5000).fit(X * scale, y)
    return lambda Z: m.decision_function(Z * scale)


# ------------------------------------------------------------------ select

def cmd_select(a):
    import pandas as pd
    os.makedirs(V2, exist_ok=True)
    out = os.path.join(V2, "cands.parquet")
    L = BR.labels()
    D = np.load(DATA, mmap_mode="r")
    y = np.asarray(D["ytr"]).astype(np.int64)
    pid = np.asarray(D["pid"]).astype(np.int64)
    src = np.asarray(D["src"])
    Xtr = D["Xtr"]
    n = len(y)
    say(f"{n:,} training rows, {len(np.unique(y)):,} classes")

    # ---- row metadata (aligned with the rows of Xtr) ---------------------------------
    plan, ex = inat_tables()
    ev = BR.eval_photo_ids()
    s = pd.read_parquet(SOURCES)
    ids = pd.read_parquet(SRC_IDS, columns=["photo_id", "image_id"])
    s = s.set_index("image_id")
    kind = np.zeros(n, np.int8)       # 0 plan iNat, 1 k1000 iNat, 2 ALA, 3 Commons
    ok = np.zeros(n, bool)
    tier = np.zeros(n, np.int8)       # 1 = identification unverified (needs-id / name map)
    obs = np.zeros(n, object)
    m0 = src == 0
    m2 = (src == 1) & (pid >= SRC_BIG)
    m1 = (src == 1) & (pid < SRC_BIG)
    ip = pd.Index(plan["photo_id"]).get_indexer(pid[m0])
    assert (ip >= 0).all()
    kind[m0] = 0
    ok[m0] = True
    obs[np.flatnonzero(m0)] = plan["obs"].values[ip]
    ie = pd.Index(ex["photo_id"]).get_indexer(pid[m1])
    assert (ie >= 0).all()
    kind[m1] = 1
    ok[m1] = True
    tier[m1] = ex["source"].isin(["inat-needs-id", "inat-name-map"]).values[ie].astype(np.int8)
    obs[np.flatnonzero(m1)] = ex["obs"].values[ie]
    im = ids.set_index("photo_id")["image_id"]
    iid = im.reindex(pid[m2]).values
    assert not pd.isna(iid).any()
    srow = s.reindex(iid)  # ~1 % of the ids are in dropped_sources.parquet now (not eligible)
    srow["source"] = srow["source"].fillna("ala-field")
    kind[m2] = np.where(srow["source"].values == "commons", 3, 2)
    ok[m2] = srow["ref_ok"].fillna(False).values.astype(bool) & srow["local_path"].notna().values
    obs[np.flatnonzero(m2)] = np.where(srow["observation_uuid"].notna(), srow["observation_uuid"],
                                       "c" + pd.Series(iid).astype(str).values).astype(object)
    ok &= ~np.isin(pid, np.fromiter(ev, np.int64))
    say(f"rows: plan {m0.sum():,}, k1000 {m1.sum():,}, sources {m2.sum():,}; ref-eligible {ok.sum():,}")

    # ---- class mean + cos per row, top POOL eligible per class ------------------------
    order = np.argsort(y, kind="stable")
    ys = y[order]
    starts = np.flatnonzero(np.r_[True, ys[1:] != ys[:-1]])
    ends = np.r_[starts[1:], n]
    cls = ys[starts]
    pool = []   # (u, rank, row, cos)
    t0 = time.time()
    CH = 60000
    i = 0
    while i < len(cls):
        j = i + 1
        while j < len(cls) and ends[j - 1] - starts[i] < CH:
            j += 1
        lo, hi = starts[i], ends[j - 1]
        idx = order[lo:hi]
        srt = np.argsort(idx)
        X = np.empty((len(idx), Xtr.shape[1]), np.float32)
        X[srt] = np.asarray(Xtr[idx[srt]], np.float32)
        X /= np.linalg.norm(X, axis=1, keepdims=True)
        for c in range(i, j):
            a0, a1 = starts[c] - lo, ends[c] - lo
            mu = X[a0:a1].mean(0)
            mu /= np.linalg.norm(mu)
            cs = X[a0:a1] @ mu
            rows = idx[a0:a1]
            e = np.flatnonzero(ok[rows])
            e = e[np.argsort(-cs[e], kind="stable")]
            seen, k = set(), 0
            for q in e:
                o = obs[rows[q]]
                if o in seen:
                    continue
                seen.add(o)
                pool.append((int(cls[c]), k, int(rows[q]), float(cs[q])))
                k += 1
                if k >= POOL:
                    break
        i = j
        if (i // 500) != ((i - 1) // 500) or i == len(cls):
            say(f"  classes {i:,}/{len(cls):,} ({time.time() - t0:.0f} s)")
    P = pd.DataFrame(pool, columns=["u", "rank", "row", "cos"])
    P["pid"] = pid[P["row"].values]
    P["kind"] = kind[P["row"].values]
    P["tier"] = tier[P["row"].values]
    P["obs"] = obs[P["row"].values].astype(str)
    say(f"pool: {len(P):,} rows over {P['u'].nunique():,} classes; "
        f"{(P['cos'].groupby(P['u']).first()).describe()[['min', '50%']].to_dict()}")

    # ---- per-kind metadata + size gate -------------------------------------------------
    inat = P["kind"] <= 1
    ip_ = pd.Index(plan["photo_id"]).get_indexer(P["pid"].values)
    ie_ = pd.Index(ex["photo_id"]).get_indexer(P["pid"].values)
    obs_ids = set(plan["observer_id"].values[ip_[(P["kind"] == 0).values]].tolist())
    names = BR.observers(obs_ids)
    rec = collections.defaultdict(list)
    dims_need = []
    for r, (k_, p_, a_, b_) in enumerate(zip(P["kind"].values, P["pid"].values, ip_, ie_)):
        if k_ <= 1:
            if k_ == 0:
                row = plan.iloc[a_]
                login, by = names.get(int(row["observer_id"]), ("?", "?"))
                lic = row["licence"]
            else:
                row = ex.iloc[b_]
                login = row["login"]
                by = row["observer_name"] if isinstance(row["observer_name"], str) and row["observer_name"] else login
                lic = row["licence"]
            attr = (f"{by}, CC0 (no rights reserved), via iNaturalist" if lic == "CC0"
                    else f"© {by}, {LIC_LABEL[lic]}, via iNaturalist")
            rec["photo_id"].append(int(p_))
            rec["ext"].append(row["ext"])
            rec["licence"].append(lic)
            rec["by"].append(by)
            rec["login"].append(login)
            rec["attribution"].append(attr)
            rec["image_id"].append("")
            rec["page_url"].append(f"https://www.inaturalist.org/photos/{int(p_)}")
            rec["obs_url"].append(f"https://www.inaturalist.org/observations/{row['obs']}")
            rec["local"].append(os.path.join(BR.SRC, f"{int(p_)}.{row['ext']}"))
            dims_need.append(int(p_))
        else:
            rec["photo_id"].append(0)
            rec["ext"].append("")
            rec["licence"].append("")
            rec["by"].append("")
            rec["login"].append("")
            rec["attribution"].append("")
            rec["image_id"].append("")
            rec["page_url"].append("")
            rec["obs_url"].append("")
            rec["local"].append("")
    for k_, v in rec.items():
        P[k_] = v
    # ALA / Commons rows
    sm = ~inat.values
    iid2 = im.reindex(P["pid"].values[sm]).values
    sr = s.loc[iid2]
    P.loc[sm, "image_id"] = iid2
    P.loc[sm, "licence"] = sr["license"].values
    P.loc[sm, "by"] = sr["login"].fillna("").values
    P.loc[sm, "login"] = sr["login"].fillna("").values
    P.loc[sm, "attribution"] = sr["attribution"].values
    P.loc[sm, "page_url"] = sr["page_url"].values
    P.loc[sm, "obs_url"] = sr["page_url"].values
    P.loc[sm, "local"] = sr["local_path"].values
    P.loc[sm, "ext"] = sr["ext"].values
    P["w"] = 0
    P["h"] = 0
    P.loc[sm, "w"] = sr["w_img"].fillna(0).astype(int).values
    P.loc[sm, "h"] = sr["h_img"].fillna(0).astype(int).values
    say(f"scanning original sizes of {len(set(dims_need)):,} iNat photos …")
    dims = BR.scan_dims(dims_need).to_pydict()
    dm = {p: (w, h) for p, w, h in zip(dims["photo_id"], dims["width"], dims["height"])}
    for r in np.flatnonzero(inat.values):
        w_, h_ = dm.get(int(P["photo_id"].iat[r]), (None, None))
        P.iat[r, P.columns.get_loc("w")] = w_ or 0
        P.iat[r, P.columns.get_loc("h")] = h_ or 0
    long_ = np.maximum(P["w"], P["h"])
    short = np.minimum(P["w"], P["h"]).clip(lower=1)
    bad_shape = (long_ < 500) | (long_ > 2.5 * short)
    # sources: file is already the 500 px copy; accept ≥ 400 long edge
    bad_shape[sm] = (long_[sm] < 400) | (long_[sm] > 2.5 * short[sm])
    say(f"size gate drops {bad_shape.sum():,} of {len(P):,} pool rows")
    P = P[~bad_shape.values].copy()

    # ---- probe: hand / specimen flag on the 12 nearest remaining per class -------------
    P = P.sort_values(["u", "rank"]).reset_index(drop=True)
    P["pos"] = P.groupby("u").cumcount()
    P = P[P["pos"] < 12].copy()
    logit = probe_logit_fn()
    Z = np.empty((len(P), Xtr.shape[1]), np.float32)
    rows = P["row"].values
    srt = np.argsort(rows)
    for lo in range(0, len(srt), 50000):
        sl = srt[lo:lo + 50000]
        Z[sl] = np.asarray(Xtr[rows[sl]], np.float32)
    Z /= np.linalg.norm(Z, axis=1, keepdims=True)
    P["probe"] = logit(Z)
    P["flagged"] = P["probe"] >= LOGIT_FLAG
    say(f"probe flags {P['flagged'].mean():.1%} of {len(P):,} candidates")
    P = P.sort_values(["u", "tier", "flagged", "cos"], ascending=[True, True, True, False])
    P["cand"] = P.groupby("u").cumcount()
    P = P[P["cand"] < K].copy()
    P["name"] = [L[u]["name"] for u in P["u"]]

    # ---- v1 pick as a lone candidate for classes without any v2 candidate --------------
    have = set(P["u"])
    v1 = json.load(open(os.path.join(BR.OUT, "pack", "refphotos", "index.json")))["photos"]
    extra = []
    for nm, r in v1.items():
        if r["u"] in have:
            continue
        f = os.path.join(BR.SRC, f"{r['photo']}.{r['ext']}")
        extra.append({"u": r["u"], "name": nm, "cand": 0, "kind": 0, "photo_id": r["photo"], "ext": r["ext"],
                      "licence": r["license"], "by": r["by"], "login": r["login"],
                      "attribution": r["attribution"], "image_id": "", "pid": r["photo"], "cos": np.nan,
                      "probe": np.nan, "flagged": False, "tier": 0, "obs": r["obs"],
                      "page_url": f"https://www.inaturalist.org/photos/{r['photo']}",
                      "obs_url": f"https://www.inaturalist.org/observations/{r['obs']}", "local": f,
                      "w": 500, "h": 500, "v1": True})
    P["v1"] = False
    P = pd.concat([P, pd.DataFrame(extra)], ignore_index=True) if extra else P
    cols = ["u", "name", "cand", "kind", "pid", "photo_id", "image_id", "ext", "licence", "by", "login",
            "attribution", "page_url", "obs_url", "local", "w", "h", "cos", "probe", "flagged", "tier", "obs", "v1"]
    P = P[cols].sort_values(["u", "cand"]).reset_index(drop=True)
    pq.write_table(pa.Table.from_pandas(P, preserve_index=False), out)
    cnt = P.groupby("u").size().value_counts().sort_index().to_dict()
    say(f"cands.parquet: {len(P):,} candidates, {P['u'].nunique():,} species ({len(extra)} from v1); "
        f"candidates per species {cnt}; kinds {P['kind'].value_counts().sort_index().to_dict()}; "
        f"licences {P['licence'].value_counts().to_dict()}")


# ------------------------------------------------------------------ fetch + thumbnails

def _thumb(job):
    from PIL import Image, ImageOps
    src, dst = job
    try:
        im = ImageOps.exif_transpose(Image.open(src))
        im = im.convert("RGB")
        w, h = im.size
        s_ = 384 / max(w, h)
        if s_ < 1:
            im = im.resize((max(1, round(w * s_)), max(1, round(h * s_))), Image.LANCZOS)
        b = io.BytesIO()
        im.save(b, "JPEG", quality=82)
        with open(dst + ".part", "wb") as f:
            f.write(b.getvalue())
        os.replace(dst + ".part", dst)
        return True
    except Exception:
        return False


def thumb_path(pid):
    return os.path.join(THUMB, f"{pid}.jpg")


def cmd_fetch(a):
    from multiprocessing import Pool
    C = pq.read_table(os.path.join(V2, "cands.parquet")).to_pandas()
    os.makedirs(THUMB, exist_ok=True)
    inat = C[C["kind"] <= 1]
    todo = sorted({(int(p), e) for p, e, l in zip(inat["photo_id"], inat["ext"], inat["local"])
                   if not os.path.exists(l)})
    if a.limit:
        todo = todo[:a.limit]
    say(f"{len(C):,} candidates; {len(todo):,} iNat photos to fetch")
    if todo:
        t0 = time.time()
        st = BR.fetch_many(todo, a.workers)
        dt = time.time() - t0
        say(f"fetched {st['ok']:,} ({st['bytes'] / 1e6:.0f} MB) in {dt:.0f} s = {st['ok'] / dt:.0f}/s; "
            f"{st['missing']} gone upstream, {st['failed']} failed")
        if st["gone"]:
            json.dump(st["gone"], open(os.path.join(V2, "gone.json"), "w"))
    jobs = [(l, thumb_path(p)) for l, p in zip(C["local"], C["pid"])
            if os.path.exists(l) and not os.path.exists(thumb_path(p))]
    if a.limit:
        jobs = jobs[:a.limit]
    say(f"{len(jobs):,} thumbnails to make")
    t0 = time.time()
    with Pool(os.cpu_count()) as pool:
        res = pool.map(_thumb, jobs, chunksize=64)
    say(f"thumbnails: {sum(res):,} ok, {len(res) - sum(res)} failed in {time.time() - t0:.0f} s")
    have = sum(os.path.exists(thumb_path(p)) for p in C["pid"])
    say(f"candidates with a thumbnail: {have:,} of {len(C):,}")


# ------------------------------------------------------------------ Claude Opus picks (Batches API)

KEYFILE = os.path.expanduser("~/.config/izzymap/anthropic.env")
MODEL = "claude-opus-5-5"
# USD per million tokens. Batch = 50 % of standard. 1-hour cache write = 2x base input.
PRICE_BATCH = {"in": 2.00, "out": 10.00, "write1h": 4.00, "write5m": 2.50, "read": 0.10}
PRICE_STD = {"in": 4.00, "out": 20.00, "write1h": 8.00, "write5m": 5.00, "read": 0.20}
FLAGS = ["hand", "person", "specimen", "label", "blurry", "not_plant", "other"]
MAX_BATCH_BYTES = 180e6   # the API limit is 256 MB per batch
SYSTEM = """You choose the reference photo for each plant species in an offline field guide used by a botanist in Australia. For each species you see up to five candidate photos, numbered in the order shown. They come from iNaturalist, the Australian Plant Image Index and Wikimedia Commons and were identified as that species by their uploaders or curators. The photos are shown downscaled (384 px on the long edge), so judge composition, subject and clarity rather than fine pixel detail.

Choose the single best REFERENCE photo: the one that best helps someone recognise this species in the field.

A good reference photo:
- is sharp enough and reasonably exposed (a slightly soft photo is fine if the subject is still clear);
- shows the whole plant or a diagnostic feature (flowers, fruit or capsules, buds, bark, leaves), with the plant's typical look;
- has the plant as the clear subject. Garden, cultivated and roadside plants are fine, and so are close-ups, habit shots and trees seen in their setting. When several photos are good, prefer the one that shows the most of what you would use to recognise the species (flowers or fruit with leaves, or the typical habit) over a single leaf, a distant clump or a cluttered scene.

Reject only when there is a real problem:
- a hand or person DOMINATES the photo or hides the plant. A fingertip, a sleeve or a person at the edge of the frame is fine; a hand holding up a sprig as the main subject is not;
- a pressed or herbarium specimen (plant on paper or card, a mounted sheet);
- a label, sign, ruler, notebook or printed page is the main content, or the photo is a screenshot or a photo of a screen or book;
- the plant is not the subject (an insect, bird or landscape with no identifiable plant), or the photo shows no plant;
- badly blurred, very dark or heavily overexposed.

Score every photo from 1 to 5 (5 = excellent reference, 4 = good, 3 = usable but mediocre, 2 = poor, 1 = unusable) and flag any problems: hand, person, specimen (pressed or herbarium), label (sign, label, ruler, printed text, screenshot), blurry (also very dark or overexposed), not_plant (no plant visible, or the plant is not the subject), other (anything else that makes it a poor reference; explain in the reason). Flag a hand or person only when it is noticeable; the flag list may be empty.

Then choose the best photo by its number. If NONE of the photos is acceptable as a reference, set chosen to null and none_acceptable to true. If only one photo is shown, accept it (chosen 1) unless it has a rejecting problem. Do not try to verify the identification; judge photo quality and usefulness only. Keep the reason to one or two short sentences."""


def load_key():
    """ANTHROPIC_API_KEY into this process's environment only (never printed, logged or written)."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        return
    with open(KEYFILE) as f:
        for line in f:
            line = line.strip()
            if line.startswith("ANTHROPIC_API_KEY="):
                os.environ["ANTHROPIC_API_KEY"] = line.split("=", 1)[1].strip().strip('"').strip("'")
                return
    sys.exit(f"no ANTHROPIC_API_KEY line in {KEYFILE}")


def client():
    import anthropic
    load_key()
    return anthropic.Anthropic()


SCHEMA = {
    "type": "object",
    "properties": {
        "photos": {"type": "array", "items": {
            "type": "object",
            "properties": {"photo": {"type": "integer", "enum": [1, 2, 3, 4, 5]},
                           "score": {"type": "integer", "enum": [1, 2, 3, 4, 5]},
                           "flags": {"type": "array", "items": {"type": "string", "enum": FLAGS}}},
            "required": ["photo", "score", "flags"], "additionalProperties": False}},
        "none_acceptable": {"type": "boolean"},
        "chosen": {"anyOf": [{"type": "integer", "enum": [1, 2, 3, 4, 5]}, {"type": "null"}]},
        "reason": {"type": "string"}},
    "required": ["photos", "none_acceptable", "chosen", "reason"],
    "additionalProperties": False}


def request_params(name, thumbs):
    """Identical system / thinking / effort / output_config for EVERY request (one cache entry):
    the 1-hour breakpoint sits on the instruction block, the species and photos vary after it."""
    n = len(thumbs)
    content = [{"type": "text", "text": f"Species: {name}. {n} candidate photo{'s' if n > 1 else ''} follow."}]
    for k, b in enumerate(thumbs, 1):
        content.append({"type": "text", "text": f"Photo {k}:"})
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                    "data": base64.standard_b64encode(b).decode()}})
    content.append({"type": "text", "text": "Score every photo, then choose the best reference photo for "
                                            "this species (or null if none is acceptable)."})
    return {"model": MODEL, "max_tokens": 4096,
            "system": [{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral", "ttl": "1h"}}],
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
            "messages": [{"role": "user", "content": content}]}


def usage_cost(u, price):
    cc = u.get("cache_creation") or {}
    w1 = cc.get("ephemeral_1h_input_tokens") or 0
    w5 = cc.get("ephemeral_5m_input_tokens") or 0
    if not cc:
        w1 = u.get("cache_creation_input_tokens") or 0
    return (u.get("input_tokens", 0) * price["in"] + u.get("output_tokens", 0) * price["out"]
            + w1 * price["write1h"] + w5 * price["write5m"]
            + (u.get("cache_read_input_tokens") or 0) * price["read"]) / 1e6


def cand_table():
    """cands.parquet minus candidates without a thumbnail, grouped by species (candidate order)."""
    C = pq.read_table(os.path.join(V2, "cands.parquet")).to_pandas()
    C = C[[os.path.exists(thumb_path(p)) for p in C["pid"]]]
    return {int(u): g.sort_values("cand").to_dict("records") for u, g in C.groupby("u")}


def spend_add(kind, usd, **kw):
    with open(os.path.join(V2, "spend.jsonl"), "a") as f:
        f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "kind": kind, "usd": usd, **kw}) + "\n")


def spend_total():
    p = os.path.join(V2, "spend.jsonl")
    return sum(json.loads(l)["usd"] for l in open(p)) if os.path.exists(p) else 0.0


def thumbs_of(rows):
    return [open(thumb_path(r["pid"]), "rb").read() for r in rows]


def pilot_set(G, seed=20261105):
    rng = np.random.default_rng(seed)
    us = sorted(G)
    euc = [u for u in us if G[u][0]["name"].split()[0] in ("Eucalyptus", "Corymbia", "Angophora")]
    by_n = collections.defaultdict(list)
    for u in us:
        by_n[len(G[u])].append(u)
    pick = [int(x) for x in rng.choice([u for u in euc if len(G[u]) == 5], 8, replace=False)]
    want = {5: 30, 4: 3, 3: 3, 2: 3, 1: 3}
    for n_, c in want.items():
        pool = [u for u in by_n[n_] if u not in pick]
        pick += [int(x) for x in rng.choice(pool, c, replace=False)]
    return pick


def cmd_warm(a):
    """ONE immediate (non-batch) real request that writes the 1-hour cache entry."""
    G = cand_table()
    u = pilot_set(G)[0]
    rows = G[u]
    c = client()
    m = c.messages.create(**request_params(rows[0]["name"], thumbs_of(rows)))
    us = m.usage.to_dict()
    usd = usage_cost(us, PRICE_STD)
    spend_add("warm", usd, u=u)
    rec = {"u": u, "name": rows[0]["name"], "stop_reason": m.stop_reason, "usage": us, "usd": usd}
    json.dump(rec, open(os.path.join(V2, "warm.json"), "w"), indent=1)
    print(json.dumps(rec, indent=1))
    if not (us.get("cache_creation_input_tokens") or 0) > 0:
        sys.exit("cache_creation_input_tokens == 0: the prefix did not cache (check the minimum length)")


def cmd_submit(a):
    G = cand_table()
    os.makedirs(os.path.join(V2, "vision"), exist_ok=True)
    bfile = os.path.join(V2, "vision", "batches.json")
    batches = json.load(open(bfile)) if os.path.exists(bfile) else []
    done = {r["u"] for r in load_results().values() if r.get("usable")}
    inflight = {u for b in batches if not b.get("collected") for u in b["us"]}
    if a.pilot:
        us = [u for u in pilot_set(G) if u not in done and u not in inflight]
        label = "pilot"
    else:
        if not a.approve_spend:
            sys.exit("a full run needs --approve-spend (the pilot's projection must be <= $85)")
        us = [u for u in sorted(G) if u not in done and u not in inflight]
        label = "full"
    if a.limit:
        us = us[:a.limit]
    say(f"{label}: {len(us):,} species to submit")
    c = client()
    chunk, size, sent = [], 0, 0

    def flush():
        nonlocal chunk, size, sent
        if not chunk:
            return
        b = c.messages.batches.create(requests=[{"custom_id": f"u{u}", "params": p} for u, p in chunk])
        batches.append({"id": b.id, "label": label, "us": [u for u, _ in chunk],
                        "created": time.strftime("%Y-%m-%dT%H:%M:%S"), "mb": round(size / 1e6, 1),
                        "shown": {str(u): [int(r["pid"]) for r in G[u]] for u, _ in chunk}})
        json.dump(batches, open(bfile, "w"), indent=1)
        sent += len(chunk)
        say(f"  batch {b.id}: {len(chunk)} requests, {size / 1e6:.0f} MB ({sent:,}/{len(us):,})")
        chunk, size = [], 0

    for u in us:
        rows = G[u]
        p = request_params(rows[0]["name"], thumbs_of(rows))
        sz = len(json.dumps(p))
        if size + sz > MAX_BATCH_BYTES or len(chunk) >= 10000:
            flush()
        chunk.append((u, p))
        size += sz
    flush()


def load_results():
    p = os.path.join(V2, "vision", "results.jsonl")
    out = {}
    if os.path.exists(p):
        for l in open(p):
            r = json.loads(l)
            out[r["custom_id"]] = r
    return out


def cmd_collect(a):
    c = client()
    bfile = os.path.join(V2, "vision", "batches.json")
    batches = json.load(open(bfile))
    res = load_results()
    t0 = time.time()
    while True:
        pend = 0
        for b in batches:
            if b.get("collected"):
                continue
            bb = c.messages.batches.retrieve(b["id"])
            rc = bb.request_counts
            say(f"{b['label']} {b['id']}: {bb.processing_status} (processing {rc.processing}, ok {rc.succeeded}, "
                f"err {rc.errored}, expired {rc.expired})")
            if bb.processing_status != "ended":
                pend += 1
                continue
            tot, nread, nwrite = 0.0, 0, 0
            for r in c.messages.batches.results(b["id"]):
                rec = {"custom_id": r.custom_id, "batch": b["id"], "type": r.result.type, "usable": False}
                if r.result.type == "succeeded":
                    m = r.result.message
                    us = m.usage.to_dict()
                    rec.update(stop_reason=m.stop_reason, usage=us, usd=usage_cost(us, PRICE_BATCH))
                    tot += rec["usd"]
                    nread += us.get("cache_read_input_tokens") or 0
                    nwrite += us.get("cache_creation_input_tokens") or 0
                    if m.stop_reason == "end_turn":
                        txt = next((x.text for x in m.content if x.type == "text"), "")
                        try:
                            o = json.loads(txt)
                            rec["out"] = o
                            shown = b["shown"][r.custom_id[1:]]
                            rec["shown"] = shown
                            n = len(shown)
                            ch = o.get("chosen")
                            rec["usable"] = ch is None or (isinstance(ch, int) and 1 <= ch <= n)
                        except ValueError:
                            rec["raw"] = txt[:300]
                else:
                    err = getattr(r.result, "error", None)
                    rec["error"] = err.to_dict() if err is not None and hasattr(err, "to_dict") else str(err)
                rec["u"] = int(r.custom_id[1:])
                # keep a usable earlier result over a failed retry
                if not (res.get(r.custom_id, {}).get("usable") and not rec["usable"]):
                    res[r.custom_id] = rec
            b["collected"] = True
            b["usd"] = tot
            b["cache_read_tokens"] = nread
            b["cache_write_tokens"] = nwrite
            spend_add("batch", tot, batch=b["id"], label=b["label"], n=len(b["us"]))
            json.dump(batches, open(bfile, "w"), indent=1)
            with open(os.path.join(V2, "vision", "results.jsonl"), "w") as f:
                for k in sorted(res, key=lambda k: int(k[1:])):
                    f.write(json.dumps(res[k]) + "\n")
            say(f"  collected {len(b['us'])} results, cost ${tot:.4f}, cache read {nread:,} / write {nwrite:,} tokens")
        if not pend or not a.wait or time.time() - t0 > a.max_wait:
            break
        time.sleep(a.every)


def cmd_stats(a):
    """Cost per species from the collected results (and the full-run projection from the pilot)."""
    res = [r for r in load_results().values() if r["type"] == "succeeded"]
    G = cand_table()
    pil = [r for r in res if r["u"] in set(pilot_set(G))]
    src = pil if a.pilot_only else res
    n = np.array([len(G[r["u"]]) for r in src])
    cost = np.array([r["usd"] for r in src])
    ur = lambda k: np.array([r["usage"].get(k) or 0 for r in src])  # noqa: E731
    say(f"{len(src)} results: mean ${cost.mean():.5f}/species; cache read tokens/req {ur('cache_read_input_tokens').mean():.0f}, "
        f"write {ur('cache_creation_input_tokens').mean():.0f}, input {ur('input_tokens').mean():.0f}, "
        f"output {ur('output_tokens').mean():.0f}")
    A = np.c_[np.ones(len(n)), n]
    coef = np.linalg.lstsq(A, cost, rcond=None)[0]
    say(f"cost ~ {coef[0]:.5f} + {coef[1]:.5f} x n_candidates")
    cnt = collections.Counter(len(v) for v in G.values())
    proj = sum(c * (coef[0] + coef[1] * k) for k, c in cnt.items())
    say(f"species by candidates {dict(sorted(cnt.items()))}; full-run projection ${proj:.2f}; "
        f"spent so far ${spend_total():.3f}")


# ------------------------------------------------------------------ build the pack folder

def source_of(r):
    return {0: "inat", 1: "inat", 2: "ala", 3: "commons"}[int(r["kind"])]


def cmd_build(a):
    from multiprocessing import Pool
    from PIL import Image
    L = BR.labels()
    G = cand_table()
    res = load_results()
    picks, none, unresolved = {}, [], []
    for u in sorted(G):
        r = res.get(f"u{u}")
        if not r or not r.get("usable"):
            unresolved.append(u)
            continue
        ch = r["out"]["chosen"]
        if ch is None:
            none.append(u)
            continue
        pid = r["shown"][ch - 1]
        row = next(x for x in G[u] if int(x["pid"]) == pid)
        picks[u] = (row, r["out"])
    say(f"{len(picks):,} picks, {len(none):,} none acceptable, {len(unresolved):,} unresolved")
    if unresolved and not a.allow_unresolved:
        sys.exit("unresolved species (run submit/collect again, or --allow-unresolved)")
    ev = BR.eval_photo_ids()
    assert not (ev & {int(r["photo_id"]) for r, _ in picks.values() if r["kind"] <= 1}), "evaluation photo picked"
    os.makedirs(PACK, exist_ok=True)
    slugs = {}
    for u, (row, _) in picks.items():
        sl = BR.slug(L[u]["name"])
        assert sl not in slugs, (sl, L[u]["name"])
        slugs[sl] = u
    jobs, orig, files = [], {}, {}
    for sl, u in slugs.items():
        row = picks[u][0]
        if row["licence"] in ND:
            assert row["kind"] <= 1, row
            b = open(row["local"], "rb").read()
            assert b.startswith(BR.MAGIC), row["local"]
            fn = f"{sl}.{row['ext'].lower()}"
            with open(os.path.join(PACK, fn), "wb") as f:   # byte-for-byte as iNat serves it
                f.write(b)
            with Image.open(os.path.join(PACK, fn)) as im:
                orig[u] = (fn, im.size, len(b))
            files[u] = fn
        else:
            fn = f"{sl}.avif"
            files[u] = fn
            jobs.append((row["local"], os.path.join(PACK, fn), a.edge, a.quality))
    t0 = time.time()
    with Pool(os.cpu_count()) as pool:
        enc = {d: (wh, n) for d, wh, n in pool.imap_unordered(BR._encode, jobs, chunksize=16)}
    say(f"encoded {len(enc):,} AVIF in {time.time() - t0:.0f} s; {len(orig)} ND photos copied as original JPEG bytes")
    keep = set(files.values()) | {"index.json", "credits.json"}
    for f in os.listdir(PACK):
        if f not in keep:
            os.remove(os.path.join(PACK, f))
    photos, per, lic_tot, src_tot = {}, {}, collections.Counter(), collections.Counter()
    for u in sorted(picks):
        row, out = picks[u]
        fn = files[u]
        if u in orig:
            _, (w, h), nb = orig[u]
        else:
            (w, h), nb = enc[os.path.join(PACK, fn)]
        src = source_of(row)
        lab = LIC_LABEL.get(row["licence"], row["licence"])
        if src == "ala" and "CC BY 3.0 AU" in row["attribution"]:
            lab = "CC BY 3.0 AU"
        score = next((x["score"] for x in out["photos"] if x["photo"] == out["chosen"]), None)
        photos[L[u]["name"]] = {
            "u": u, "file": fn, "w": w, "h": h, "bytes": nb, "licence": row["licence"], "licence_label": lab,
            "attribution": row["attribution"], "source": src, "by": row["by"],
            "photo": int(row["photo_id"]) if src == "inat" else row["image_id"],
            "obs": row["obs"] if src in ("inat", "ala") else "", "page_url": row["page_url"],
            "original_bytes": u in orig, "score": score}
        key = (src, row["by"] or "(unknown)")
        d = per.setdefault(key, {"source": src, "name": key[1], "photos": 0, "licences": {}})
        d["photos"] += 1
        d["licences"][row["licence"]] = d["licences"].get(row["licence"], 0) + 1
        lic_tot[row["licence"]] += 1
        src_tot[src] += 1
    total = sum(p["bytes"] for p in photos.values())
    index = {
        "version": 2,
        "about": "One reference photo per plant-ID species (key = au-labels.json name; u = its index), chosen by "
                 "Claude Opus among the 5 candidates nearest the species' mean embedding. Sources: iNaturalist "
                 "open data, ALA (APII and others) and Wikimedia Commons; each photo (c) its author under the "
                 "licence given. Show 'attribution' next to the photo. NC licences: non-commercial use only. "
                 "Photos with original_bytes are CC BY-ND / BY-NC-ND and are the unmodified iNaturalist JPEG.",
        "labels": "au-labels.json", "count": len(photos), "edge": a.edge, "format": f"avif q{a.quality}",
        "bytes": total, "licences": {k: {"label": LIC_LABEL[k], "url": LIC_URL[k]} for k in sorted(lic_tot)},
        "photos": photos}
    json.dump(index, open(os.path.join(PACK, "index.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    cred = sorted(per.values(), key=lambda d: (-d["photos"], d["name"].lower()))
    json.dump({"version": 2, "about": "Reference-photo credits by author and source, with the number of photos "
               "and their licences.", "photos": len(photos), "authors": len(cred), "licences": dict(lic_tot),
               "sources": dict(src_tot), "credits": cred},
              open(os.path.join(PACK, "credits.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    ix = os.path.getsize(os.path.join(PACK, "index.json"))
    cr = os.path.getsize(os.path.join(PACK, "credits.json"))
    stat = {"photos": len(photos), "none_acceptable": len(none), "unresolved": len(unresolved),
            "sources": dict(src_tot), "licences": dict(lic_tot), "authors": len(cred), "avif_and_jpeg_bytes": total,
            "index_bytes": ix, "credits_bytes": cr, "pack_bytes": total + ix + cr,
            "original_jpeg_photos": len(orig)}
    json.dump(stat, open(os.path.join(V2, "build.json"), "w"), indent=1)
    json.dump({"none_acceptable": [L[u]["name"] for u in none], "unresolved": [L[u]["name"] for u in unresolved]},
              open(os.path.join(V2, "no_photo.json"), "w"), indent=1)
    print(json.dumps(stat, indent=1))


def cmd_sheet(a):
    from PIL import Image, ImageDraw, ImageFont
    d = json.load(open(os.path.join(PACK, "index.json")))["photos"]
    rng = np.random.default_rng(a.seed)
    names = sorted(d)
    euc = [n for n in names if n.split()[0] in ("Eucalyptus", "Corymbia", "Angophora")]
    rand = [names[i] for i in rng.choice(len(names), 24, replace=False)]
    euc = [euc[i] for i in rng.choice(len(euc), 12, replace=False)]
    cell, cap, cols = 300, 34, 6
    rows_ = (36 + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, rows_ * (cell + cap)), "white")
    dr = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=13)
    for i, n in enumerate(rand + euc):
        r = d[n]
        im = Image.open(os.path.join(PACK, r["file"])).convert("RGB")
        im.thumbnail((cell - 6, cell - 6))
        x, y = (i % cols) * cell, (i // cols) * (cell + cap)
        sheet.paste(im, (x + 3, y + 3))
        mark = "EUC " if i >= 24 else ""
        dr.text((x + 4, y + cell), f"{mark}{n}", fill="black", font=font)
        dr.text((x + 4, y + cell + 16), f"{r['source']} {r['licence_label']}  score {r['score']}", fill="#555", font=font)
    out = os.path.join(BR.OUT, "pack-v2", "contact-sheet.jpg")
    sheet.save(out, quality=85)
    print(out)


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("select")
    p = sp.add_parser("fetch")
    p.add_argument("--workers", type=int, default=48)
    p.add_argument("--limit", type=int)
    sp.add_parser("warm")
    p = sp.add_parser("submit")
    p.add_argument("--pilot", action="store_true")
    p.add_argument("--approve-spend", action="store_true")
    p.add_argument("--limit", type=int)
    p = sp.add_parser("collect")
    p.add_argument("--wait", action="store_true")
    p.add_argument("--every", type=int, default=30)
    p.add_argument("--max-wait", type=int, default=3000)
    p = sp.add_parser("stats")
    p.add_argument("--pilot-only", action="store_true")
    p = sp.add_parser("build")
    p.add_argument("--edge", type=int, default=512)
    p.add_argument("--quality", type=int, default=55)
    p.add_argument("--allow-unresolved", action="store_true")
    p = sp.add_parser("sheet")
    p.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    {"select": cmd_select, "fetch": cmd_fetch, "warm": cmd_warm, "submit": cmd_submit,
     "collect": cmd_collect, "stats": cmd_stats, "build": cmd_build, "sheet": cmd_sheet}[a.cmd](a)


if __name__ == "__main__":
    main()

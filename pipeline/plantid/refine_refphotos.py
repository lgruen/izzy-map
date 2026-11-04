#!/usr/bin/env python3
"""Refine the offline reference photos picked by build_refphotos.py
(notes/refphotos_refine.md): better picks for the text-only classes and a
photo-quality audit of every pick, both with BioCLIP 2.5 itself.

Subcommands (in order):

  gather   text-only classes that have a snapshot photo (the 557): ALL
           eligible candidates — research-grade observation in the local
           open-data snapshot, CC0/PD/BY/BY-NC photo, never an evaluation
           photo (build_refphotos.eval_photo_ids) — at most --per (10) per
           class: one photo per observation first (lead photo, unshared,
           Australian), then further photos of the same observations.
           → refphotos/refine/snap.parquet
  fetch    download the 500 px medium of every snap candidate (--what snap)
           or of every final pick that is not on disk yet (--what picks, after
           `score`) into refphotos/src/ (same files as build_refphotos).
  embed    BioCLIP 2.5 image embeddings of the snap candidates on MPS fp16
           (open_clip eval transform, exactly as embed.py; 2,741 photos in
           ~10 min on the M4). --limit N = timing run (not saved).
           → refine/snap_emb.npz
  near     training-photo classes: the 20 photos nearest the class mean (the
           same mean/cosine as build_refphotos select) + their embeddings and
           the class means, from the existing embeddings (nothing re-embedded).
           → refine/near.parquet, refine/near_emb.npz
  qtext    zero-shot prompt-pair directions (PAIRS) → refine/qtext.npz.
           Diagnostics only: measured AUC 0.55–0.69 against hand-set labels.
  score    P(bad photo) = a logistic-regression probe on the BioCLIP 2.5 image
           embedding, fitted to hand-set labels (notes/
           refphotos_quality_labels.json: ok / hand / lab / label, set by eye
           from contact sheets). Training-photo classes keep their pick unless
           its logit ≥ LOGIT_FLAG_TRAIN (or it is labelled bad); then the
           nearest-to-mean photo (of 10) with logit ≤ LOGIT_OK and ≥
           LOGIT_GAIN lower, not a known bad shape. Snapshot classes: all
           candidates ranked by −logit + W_LEAD·lead photo + W_TEXT·z(cosine
           to the class TEXT vector, australia/text.npz = the training's
           text-init prompt), flagged (P ≥ P_FLAG_SNAP) and bad-shape last;
           an unflagged current pick stays unless beaten by KEEP_MARGIN.
           → refine/picks.parquet, snap_ranked.parquet, changes.json, score.json
  sheets   contact sheets (Pillow) for the visual checks → refine/sheets/
  apply    re-encode only changed photos (long edge 512, AVIF q55 speed 6,
           build_refphotos._encode; the replaced AVIFs are kept in
           refine/replaced/), rewrite index.json + credits.json, append
           refine/changes.jsonl. Idempotent.

Environment:
  uv run --with duckdb --with pyarrow --with numpy --with 'pillow>=11.3' \\
      --with scikit-learn --with torch --with open_clip_torch \\
      python3 -I pipeline/plantid/refine_refphotos.py <subcommand>
"""
import argparse
import collections
import json
import os
import sys
import time

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_refphotos as BR  # noqa: E402

RF = os.path.join(BR.OUT, "refine")
HF = "hf-hub:imageomics/bioclip-2.5-vith14"
NEAR = 20  # train classes: photos nearest the class mean considered for a swap

# Quality prompts: (reason, bad prompt, matched neutral prompt). A reason's
# score is the mean of cos(photo, bad) − cos(photo, neutral) over its pairs,
# i.e. the projection of the photo onto a "concept direction" mean(T_bad −
# T_neutral): the plant content cancels, what is left is the hand / label /
# sheet. (Single prompts against a set of "good" prompts failed: "a hand"
# fired on every diffuse photo of small flowers that no good prompt covered.)
PAIRS = [
    ("hand", "a photo of a hand holding a plant.", "a photo of a plant."),
    ("hand", "a photo of a hand holding a flower.", "a photo of a flower."),
    ("hand", "a photo of a hand holding a leaf.", "a photo of a leaf."),
    ("hand", "a photo of a plant held between a person's fingers.", "a photo of a plant growing in the ground."),
    ("person", "a photo of a person standing next to a plant.", "a photo of a plant."),
    ("person", "a photo of a person's face.", "a photo of a flower."),
    ("person", "a photo of people in a field.", "a photo of plants in a field."),
    ("specimen", "a herbarium specimen of a plant.", "a photo of a plant."),
    ("specimen", "a pressed dried plant mounted on paper.", "a living plant in the wild."),
    ("label", "a photo of a plant with a label.", "a photo of a plant."),
    ("label", "a photo of a sign with text.", "a photo of a plant."),
    ("label", "a photo of a nursery plant tag.", "a photo of a leaf."),
    ("blur", "a blurry photo of a plant.", "a sharp photo of a plant."),
    ("blur", "an out of focus photo of a flower.", "a sharp photo of a flower."),
    ("dark", "a very dark photo of a plant.", "a well-lit photo of a plant."),
    ("screen", "a screenshot of a plant.", "a photo of a plant."),
    ("screen", "a drawing of a plant.", "a photo of a plant."),
    ("lab", "a plant cutting lying on a table.", "a plant growing in the ground."),
    ("lab", "a photo of a plant in a petri dish.", "a photo of a plant in the wild."),
    ("lab", "a plant on a plain white background.", "a plant in its natural habitat."),
]
REASONS = sorted({r for r, _, _ in PAIRS})


def load_model(device="mps"):
    import open_clip
    import torch
    model, _, tf = open_clip.create_model_and_transforms(HF)
    tok = open_clip.get_tokenizer(HF)
    model = model.to(device).to(torch.float16 if device != "cpu" else torch.float32).eval()
    return model, tf, tok


def cmd_qtext(a):
    """Text vectors of the quality prompts (cheap; re-run after editing PAIRS)."""
    model, _, tok = load_model(a.device)
    Tb = text_vectors(model, tok, [b for _, b, _ in PAIRS], a.device)
    Tn = text_vectors(model, tok, [n for _, _, n in PAIRS], a.device)
    rs = np.array([r for r, _, _ in PAIRS])
    D = np.stack([(Tb - Tn)[rs == r].mean(0) for r in REASONS])
    np.savez(os.path.join(RF, "qtext.npz"), D=D, reasons=np.array(REASONS), Tb=Tb, Tn=Tn, pair_reason=rs)
    print(f"{len(PAIRS)} prompt pairs → {len(REASONS)} directions")


# ------------------------------------------------------------------ gather

def snap_classes():
    t = pq.read_table(os.path.join(BR.OUT, "candidates.parquet"), columns=["u", "via"]).to_pydict()
    return sorted({u for u, v in zip(t["u"], t["via"]) if v == "snapshot"})


def cmd_gather(a):
    os.makedirs(RF, exist_ok=True)
    us = snap_classes()
    names = [x["name"] for x in BR.labels()]
    ev = BR.eval_photo_ids()
    w = BR.db()
    w.register("imap_v", pq.read_table(os.path.join(BR.AU, "inat_map.parquet")))
    w.register("us_v", pa.table({"u": pa.array(us, pa.int64())}))
    w.register("ev_v", pa.table({"photo_id": pa.array(sorted(ev), pa.int64())}))
    lic = ", ".join(f"'{x}'" for x in BR.USABLE)
    aus = BR.AUS.replace("lat", "o.lat").replace("lon", "o.lon")
    t0 = time.time()
    t = w.execute(f"""
        WITH c AS (
            SELECT p.photo_id, o.uuid::VARCHAR AS uuid, o.observer_id, m.u, p.ext, p.license,
                   CASE WHEN {aus} THEN 0 ELSE 1 END AS region, p.position,
                   p.photo_id IN (SELECT photo_id FROM shared) AS shared, o.role,
                   hash(p.photo_id::VARCHAR || 'izzy-ref') AS h
            FROM o JOIN imap_v m USING (species_id) JOIN pobs p USING (uuid)
            WHERE m.u IN (SELECT u FROM us_v) AND p.license IN ({lic})
              AND p.photo_id NOT IN (SELECT photo_id FROM ev_v)),
        d AS (SELECT *, row_number() OVER (PARTITION BY u, uuid ORDER BY shared, position, h) AS k,
                     count(*) OVER (PARTITION BY u) AS n_all FROM c)
        SELECT * EXCLUDE (h) FROM d QUALIFY row_number() OVER (
            PARTITION BY u ORDER BY k, shared, region, h) <= {a.per}
        ORDER BY u, photo_id""").to_arrow_table()
    t = t.append_column("name", pa.array([names[u] for u in t.column("u").to_pylist()]))
    pq.write_table(t, os.path.join(RF, "snap.parquet"))
    d = t.to_pydict()
    per = collections.Counter(d["u"])
    nall = dict(zip(d["u"], d["n_all"]))
    assert not ev & set(d["photo_id"])
    print(f"{len(per)} classes (expected {len(us)}), {t.num_rows:,} candidates in {time.time() - t0:.0f} s; "
          f"per class {dict(sorted(collections.Counter(per.values()).items()))}; "
          f"eligible before the cap: {sum(nall.values()):,} (max {max(nall.values())}); "
          f"roles {dict(collections.Counter(d['role']))}, licences {dict(collections.Counter(d['license']))}")


# ------------------------------------------------------------------ fetch

def cmd_fetch(a):
    os.makedirs(BR.SRC, exist_ok=True)
    if a.what == "snap":
        rows = pq.read_table(os.path.join(RF, "snap.parquet"), columns=["photo_id", "ext"]).to_pylist()
    else:
        rows = pq.read_table(os.path.join(RF, "picks.parquet"), columns=["photo_id", "ext"]).to_pylist()
    todo = sorted({(r["photo_id"], r["ext"]) for r in rows
                   if not os.path.exists(os.path.join(BR.SRC, f"{r['photo_id']}.{r['ext']}"))})
    print(f"{len(rows):,} photos, {len(todo):,} to fetch", flush=True)
    if not todo:
        return
    t0 = time.time()
    s = BR.fetch_many(todo, a.workers)
    dt = time.time() - t0
    print(f"  {s['ok']:,} ok ({s['bytes'] / 1e6:.0f} MB) in {dt:.1f} s; {s['missing']} gone upstream, "
          f"{s['failed']} failed", flush=True)
    if s["gone"]:
        p = os.path.join(BR.OUT, "unavailable.json")
        json.dump(sorted(BR.unavailable() | set(s["gone"])), open(p, "w"))


# ------------------------------------------------------------------ near

def cmd_near(a):
    """Training-photo classes: the NEAR photos nearest the class mean (the same
    mean and cosine as build_refphotos select), with their embeddings, so the
    audit never re-embeds anything. → refine/near.parquet + near_emb.npz"""
    import duckdb
    os.makedirs(RF, exist_ok=True)
    nU = len(BR.labels())
    con = duckdb.connect()
    con.register("imap_v", pq.read_table(os.path.join(BR.AU, "inat_map.parquet")))
    AU, CACHE = BR.AU, BR.CACHE
    tr = con.execute(f"""
        WITH a AS (SELECT photo_id, uuid::VARCHAR AS uuid, observer_id, u, ext, license, region
                   FROM '{AU}/plan/train.parquet'),
             b AS (SELECT t.photo_id, t.uuid::VARCHAR AS uuid, t.observer_id, m.u, t.ext, t.license,
                          t.region
                   FROM '{CACHE}/sets/train.parquet' t JOIN imap_v m USING (species_id)
                   WHERE t.photo_id NOT IN (SELECT photo_id FROM a))
        SELECT * FROM a UNION ALL SELECT * FROM b ORDER BY u, photo_id""").to_arrow_table().to_pydict()
    assert not BR.eval_photo_ids() & set(tr["photo_id"])
    t0 = time.time()
    ids, E = BR.all_embeddings()
    pid = np.array(tr["photo_id"], np.int64)
    i = np.searchsorted(ids, pid).clip(0, len(ids) - 1)
    has = ids[i] == pid
    u = np.array(tr["u"], np.int64)[has]
    X = E[i[has]].astype(np.float32)
    X /= np.linalg.norm(X, axis=1, keepdims=True)
    rows = np.flatnonzero(has)
    M = np.zeros((nU, X.shape[1]), np.float32)
    np.add.at(M, u, X)
    M /= np.maximum(np.linalg.norm(M, axis=1, keepdims=True), 1e-12)
    cos = (X * M[u]).sum(1)
    order = np.lexsort((-cos, u))
    u_o = u[order]
    start = np.r_[0, np.flatnonzero(u_o[1:] != u_o[:-1]) + 1]
    rk = np.arange(len(u_o)) - np.repeat(start, np.diff(np.r_[start, len(u_o)]))
    sel = order[rk < NEAR]
    out = {k: [tr[k][j] for j in rows[sel]] for k in ("photo_id", "uuid", "observer_id", "u", "ext", "license")}
    out["cos"] = cos[sel].tolist()
    out["near"] = rk[rk < NEAR].tolist()
    out["n_class"] = np.bincount(u, minlength=nU)[u[sel]].tolist()
    pq.write_table(pa.table(out), os.path.join(RF, "near.parquet"))
    cls = np.unique(u)
    np.savez(os.path.join(RF, "near_emb.npz"), photo_id=pid[rows[sel]], emb=X[sel].astype(np.float16),
             mean_u=cls, mean=M[cls].astype(np.float16))
    print(f"{len(sel):,} near photos over {len(set(u.tolist())):,} classes in {time.time() - t0:.0f} s")


# ------------------------------------------------------------------ embed

def text_vectors(model, tok, prompts, device="mps"):
    import torch
    import eval_open_vocab as OVm
    with torch.no_grad():
        e = OVm.encode_trunc(model, tok(prompts).to(device))
        return torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()


def cmd_embed(a):
    import torch
    from embed import Photos
    rows = pq.read_table(os.path.join(RF, "snap.parquet"), columns=["photo_id", "ext"]).to_pylist()
    gone = BR.unavailable()
    items = sorted({(r["photo_id"], r["ext"]) for r in rows if r["photo_id"] not in gone
                    and os.path.exists(os.path.join(BR.SRC, f"{r['photo_id']}.{r['ext']}"))})
    t0 = time.time()
    model, tf, tok = load_model()
    print(f"model loaded in {time.time() - t0:.0f} s; {len(items):,} images on disk", flush=True)
    if a.limit:
        items = items[:a.limit]
    dl = torch.utils.data.DataLoader(Photos(items, BR.SRC, tf), batch_size=a.batch, num_workers=4)
    ids, es, bad = [], [], 0
    t0 = time.time()
    with torch.no_grad():
        for n, (pid, x, ok) in enumerate(dl):
            e = model.encode_image(x.to("mps", torch.float16))
            e = torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()
            k = ok.numpy()
            bad += int((~k).sum())
            ids += pid[k].tolist()
            es.append(e[k])
            if n % 10 == 0:
                print(f"  {len(ids):,}/{len(items):,} {len(ids) / (time.time() - t0):.1f} img/s", flush=True)
    dt = time.time() - t0
    print(f"{len(ids):,} images in {dt:.0f} s = {len(ids) / dt:.1f} img/s, {bad} unreadable", flush=True)
    if not a.limit:
        np.savez(os.path.join(RF, "snap_emb.npz"), photo_id=np.array(ids, np.int64),
                 emb=np.concatenate(es).astype(np.float16))


# ------------------------------------------------------------------ score

LABELS_Q = os.path.join(HERE, "notes", "refphotos_quality_labels.json")
# The probe's labels are ~40 % bad, the training-photo picks perhaps a few % → its
# probabilities are far too high there; thresholds are set on the logit by eye
# (contact sheets of the top-ranked picks), not as probabilities.
LOGIT_FLAG_TRAIN = 3.0  # logit that flags a current (training-photo) pick (~55 % hands at 3–6)
LOGIT_OK = 0.0          # a replacement must have logit ≤ this …
LOGIT_GAIN = 4.0        # … and at least this much below the flagged pick's
SWAP_NEAR = 10        # … and be among the class's 10 photos nearest the mean
P_FLAG_SNAP = 0.50    # snapshot candidates above this go last
W_LEAD = 0.5          # snapshot ranking: −logit P(bad) + W_LEAD·(observer's lead photo) + W_TEXT·z(text cos)
W_TEXT = 0.5
KEEP_MARGIN = 2.0     # an unflagged current snapshot pick stays unless the best beats it by this
                      # (tuning round 1: unforced re-ranks were neutral or worse as often as better)


def quality_model(emb):
    """Linear probe P(bad photo) on BioCLIP 2.5 image embeddings, fitted to the
    hand-set labels (ok vs hand/lab/label). 5-fold CV AUC is printed."""
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import roc_auc_score
    from sklearn.model_selection import StratifiedKFold, cross_val_predict
    lab = {int(k): v for k, v in json.load(open(LABELS_Q))["labels"].items()}
    ids = [i for i in sorted(lab) if i in emb]
    assert len(ids) == len(lab), f"{len(lab) - len(ids)} labelled photos without an embedding"
    X = np.stack([emb[i] for i in ids])
    y = np.array([lab[i] != "ok" for i in ids], int)
    scale = 1 / float(X.std(0).mean())
    m = LogisticRegression(C=0.3, max_iter=5000)
    cv = cross_val_predict(m, X * scale, y, cv=StratifiedKFold(5, shuffle=True, random_state=0),
                           method="decision_function")
    auc = float(roc_auc_score(y, cv))
    m.fit(X * scale, y)
    print(f"quality probe: {len(y)} labels ({y.sum()} bad), 5-fold CV AUC {auc:.3f}", flush=True)
    return (lambda X_: m.decision_function(X_ * scale)), lab, auc


def medium_shape(r):
    """(long edge, bad shape) of the downloaded medium, None if not on disk.
    The medium is min(original, 500 px) → long < 500 ⇔ original < 500 px."""
    from PIL import Image
    p = BR.src_path(r)
    if not os.path.exists(p):
        return None
    with Image.open(p) as im:
        w, h = im.size
    return max(w, h), max(w, h) < 500 or max(w, h) > 2.5 * min(w, h)


def sigmoid(v):
    return 1 / (1 + np.exp(-v))


def cmd_score(a):
    L = BR.labels()
    gone = BR.unavailable()
    P = BR.picks()
    cand = pq.read_table(os.path.join(BR.OUT, "candidates.parquet")).to_pylist()
    key0 = {r["photo_id"]: r["rank"] for r in cand}
    dims = pq.read_table(os.path.join(BR.OUT, "dims.parquet")).to_pydict()
    D = {p: (w, h) for p, w, h in zip(dims["photo_id"], dims["width"], dims["height"])}
    near = pq.read_table(os.path.join(RF, "near.parquet")).to_pylist()
    z = np.load(os.path.join(RF, "near_emb.npz"))
    E = z["emb"].astype(np.float32)
    zs = np.load(os.path.join(RF, "snap_emb.npz"))
    se = dict(zip(zs["photo_id"].tolist(), zs["emb"].astype(np.float32)))
    emb = dict(se)
    emb.update(zip(z["photo_id"].tolist(), E))
    logit, qlab, auc = quality_model(emb)
    why_of = lambda pid: qlab.get(pid, "probe")  # noqa: E731

    out, log = [], []
    # ---- training-photo classes: audit the current pick, swap to a near-mean photo that passes
    lg = logit(E)
    by_u = collections.defaultdict(list)
    for k, r in enumerate(near):
        r["p"] = float(sigmoid(lg[k]))
        r["lg"] = float(lg[k])
        by_u[r["u"]].append(r)
    nflag = 0
    for u, rows in sorted(by_u.items()):
        cur = P[u]
        assert cur["via"] == "train"
        rc = next(r for r in rows if r["photo_id"] == cur["photo_id"])
        pick, why = cur, None
        if rc["lg"] >= LOGIT_FLAG_TRAIN or qlab.get(cur["photo_id"], "ok") != "ok":
            nflag += 1
            why = why_of(cur["photo_id"])
            alts = []
            for r in rows:
                if r["photo_id"] == cur["photo_id"] or r["photo_id"] in gone or r["near"] >= SWAP_NEAR:
                    continue
                if r["lg"] > min(LOGIT_OK, rc["lg"] - LOGIT_GAIN) or qlab.get(r["photo_id"], "ok") != "ok":
                    continue
                wh = D.get(r["photo_id"])
                if wh and wh[0] and (max(wh) < 500 or max(wh) > 2.5 * min(wh)):
                    continue
                ms = medium_shape(r)
                if ms and ms[1]:
                    continue
                alts.append(r)
            if alts:
                # nearest the mean first; among the original top-5, build_refphotos' order
                alt = min(alts, key=lambda r: (r["near"] >= BR.K, key0.get(r["photo_id"], 99), r["near"]))
                pick = {**{k: alt[k] for k in ("photo_id", "uuid", "observer_id", "u", "ext", "license")},
                        "via": "train", "name": L[u]["name"]}
                log.append({"u": u, "name": L[u]["name"], "via": "train", "reason": why,
                            "old": cur["photo_id"], "old_ext": cur["ext"], "old_logit": round(rc["lg"], 2),
                            "old_near": rc["near"], "new": alt["photo_id"], "new_ext": alt["ext"],
                            "new_logit": round(alt["lg"], 2), "new_near": alt["near"]})
        out.append({**{k: pick[k] for k in ("photo_id", "uuid", "observer_id", "u", "ext", "license", "via")},
                    "name": L[u]["name"], "changed": pick["photo_id"] != cur["photo_id"],
                    "old_photo_id": cur["photo_id"], "flag": why})
    n_tr = len(by_u)
    # ---- snapshot (text-only) classes: rank all candidates by quality, lead photo, text similarity
    T = np.load(os.path.join(BR.AU, "text.npz"))["emb"].astype(np.float32)
    snap = pq.read_table(os.path.join(RF, "snap.parquet")).to_pylist()
    sby = collections.defaultdict(list)
    for r in snap:
        if r["photo_id"] in se and r["photo_id"] not in gone:
            sby[r["u"]].append(r)
    allr = [r for rows in sby.values() for r in rows]
    Xs = np.stack([se[r["photo_id"]] for r in allr])
    ls = logit(Xs)
    ts = np.array([float(se[r["photo_id"]] @ T[r["u"]]) for r in allr])
    tz = (ts - ts.mean()) / ts.std()
    for r, l_, t_, tz_ in zip(allr, ls, ts, tz):
        r["p"], r["tsim"] = float(sigmoid(l_)), float(t_)
        r["score"] = float(-l_ + W_LEAD * (r["position"] == 0) + W_TEXT * tz_)
        ms = medium_shape(r)
        r["badshape"] = bool(ms and ms[1])
        r["flagged"] = r["p"] >= P_FLAG_SNAP or qlab.get(r["photo_id"], "ok") != "ok"
    snap_ranked = []
    for u, rows in sorted(sby.items()):
        cur = P[u]
        assert cur["via"] == "snapshot"
        rows.sort(key=lambda r: (r["flagged"], r["badshape"], -r["score"], r["photo_id"]))
        best = rows[0]
        keep = next((r for r in rows if r["photo_id"] == cur["photo_id"]), None)
        if keep is not None and not keep["flagged"] and not keep["badshape"] and \
                best["score"] - keep["score"] < KEEP_MARGIN:
            rows.remove(keep)
            rows.insert(0, keep)
            best = keep
        for k, r in enumerate(rows):
            snap_ranked.append({"u": u, "name": L[u]["name"], "rank": k, "photo_id": r["photo_id"],
                                "ext": r["ext"], "p_bad": round(r["p"], 3), "tsim": round(r["tsim"], 4),
                                "score": round(r["score"], 3), "flagged": r["flagged"],
                                "badshape": r["badshape"], "position": r["position"], "role": r["role"]})
        old = next((r for r in rows if r["photo_id"] == cur["photo_id"]), None)
        why = why_of(cur["photo_id"]) if old is not None and old["flagged"] else None
        out.append({**{k: best[k] for k in ("photo_id", "uuid", "observer_id", "u", "ext", "license")},
                    "via": "snapshot", "name": L[u]["name"], "changed": best["photo_id"] != cur["photo_id"],
                    "old_photo_id": cur["photo_id"], "flag": why})
        if best["photo_id"] != cur["photo_id"]:
            log.append({"u": u, "name": L[u]["name"], "via": "snapshot", "reason": why or "rank",
                        "old": cur["photo_id"], "old_ext": cur["ext"],
                        "old_p": round(old["p"], 3) if old else None,
                        "new": best["photo_id"], "new_ext": best["ext"], "new_p": round(best["p"], 3),
                        "candidates": len(rows)})
    assert len(out) == len(P), (len(out), len(P))
    pq.write_table(pa.Table.from_pylist(out), os.path.join(RF, "picks.parquet"))
    pq.write_table(pa.Table.from_pylist(snap_ranked), os.path.join(RF, "snap_ranked.parquet"))
    json.dump(log, open(os.path.join(RF, "changes.json"), "w"), indent=0)
    tr_sw = [x for x in log if x["via"] == "train"]
    sn_ch = [x for x in log if x["via"] == "snapshot"]
    first = [r for r in snap_ranked if r["rank"] == 0]
    s = {"probe_cv_auc": round(auc, 3), "train_classes": n_tr, "train_flagged": nflag,
         "train_swapped": len(tr_sw), "train_flagged_no_alternative": nflag - len(tr_sw),
         "train_swapped_by_label": dict(collections.Counter(x["reason"] for x in tr_sw)),
         "snap_classes": len(sby), "snap_changed": len(sn_ch),
         "snap_old_flagged": sum(1 for u, rows in sby.items()
                                 for r in rows if r["photo_id"] == P[u]["photo_id"] and r["flagged"]),
         "snap_pick_flagged": sum(1 for r in first if r["flagged"]),
         "snap_pick_lead_photo": sum(1 for r in first if r["position"] == 0),
         "snap_single_candidate": sum(1 for rows in sby.values() if len(rows) == 1),
         "thresholds": {"LOGIT_FLAG_TRAIN": LOGIT_FLAG_TRAIN, "LOGIT_OK": LOGIT_OK, "LOGIT_GAIN": LOGIT_GAIN,
                        "SWAP_NEAR": SWAP_NEAR,
                        "P_FLAG_SNAP": P_FLAG_SNAP, "W_LEAD": W_LEAD, "W_TEXT": W_TEXT,
                        "KEEP_MARGIN": KEEP_MARGIN}}
    json.dump(s, open(os.path.join(RF, "score.json"), "w"), indent=1)
    print(json.dumps(s, indent=1))
    pt = np.array([r["lg"] for r in near if r["photo_id"] == P[r["u"]]["photo_id"]])
    print("current training picks with logit ≥ 0/3/6/9:", [int((pt >= t).sum()) for t in (0, 3, 6, 9)])


# ------------------------------------------------------------------ sheets

def _thumb(pid, ext, cell):
    from PIL import Image
    im = Image.open(os.path.join(BR.SRC, f"{pid}.{ext}")).convert("RGB")
    im.thumbnail((cell - 4, cell - 4))
    return im


def _sheet(cells, path, cols, cell):
    """cells: [(caption, [(pid, ext), …])] — one or more photos per cell side by side."""
    from PIL import Image, ImageDraw
    per = max(len(c[1]) for c in cells)
    cw = cell * per
    rows = (len(cells) + cols - 1) // cols
    S = Image.new("RGB", (cols * cw + (cols - 1) * 8, rows * (cell + 16)), "white")
    d = ImageDraw.Draw(S)
    for k, (cap, ims) in enumerate(cells):
        cx, cy = (k % cols) * (cw + 8), (k // cols) * (cell + 16)
        for j, (pid, ext) in enumerate(ims):
            S.paste(_thumb(pid, ext, cell), (cx + j * cell + 2, cy + 2))
        d.text((cx + 2, cy + cell), cap[:int(cw / 6)], fill="black")
    S.save(path, quality=82)


def cmd_sheets(a):
    out = os.path.join(RF, "sheets")
    os.makedirs(out, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    picks_ = pq.read_table(os.path.join(RF, "picks.parquet")).to_pylist()
    log = json.load(open(os.path.join(RF, "changes.json")))
    snap = [p for p in picks_ if p["via"] == "snapshot"]
    s = [snap[i] for i in sorted(rng.choice(len(snap), min(48, len(snap)), replace=False))]
    _sheet([(f"{k}{'*' if p['changed'] else ''} {p['name']}", [(p["photo_id"], p["ext"])]) for k, p in enumerate(s)],
           os.path.join(out, "a_snap_new.jpg"), 8, 170)
    old_ext = {x["old"]: x["old_ext"] for x in log}
    ch = [p for p in s if p["changed"]]
    _sheet([(f"{k} {p['name']}", [(p["old_photo_id"], old_ext[p["old_photo_id"]]), (p["photo_id"], p["ext"])])
            for k, p in enumerate(ch)], os.path.join(out, "a_snap_before_after.jpg"), 4, 150)
    sw = [x for x in log if x["via"] == "train"]
    sw = [sw[i] for i in sorted(rng.choice(len(sw), min(48, len(sw)), replace=False))]
    for h in range(0, len(sw), 24):
        _sheet([(f"{h + k} {x['reason']} {x['name']}", [(x["old"], x["old_ext"]), (x["new"], x["new_ext"])])
                for k, x in enumerate(sw[h:h + 24])], os.path.join(out, f"b_swaps_{h // 24 + 1}.jpg"), 4, 150)
    un = [p for p in picks_ if not p["changed"]]
    un = [un[i] for i in sorted(rng.choice(len(un), 24, replace=False))]
    _sheet([(f"{k} {p['name']}", [(p["photo_id"], p["ext"])]) for k, p in enumerate(un)],
           os.path.join(out, "c_unchanged.jpg"), 6, 190)
    json.dump({"a": [p["name"] for p in s], "b": [x["name"] for x in sw], "c": [p["name"] for p in un]},
              open(os.path.join(out, "sheets.json"), "w"), indent=0)
    print(f"sheets in {out}: a {len(s)} ({len(ch)} changed), b {len(sw)}, c {len(un)}")


# ------------------------------------------------------------------ apply

def cmd_apply(a):
    import shutil
    from multiprocessing import Pool
    ip = os.path.join(BR.PACK, "index.json")
    index = json.load(open(ip))
    assert index["edge"] == a.edge and index["format"] == f"avif q{a.quality}", (index["edge"], index["format"])
    photos = index["photos"]
    picks_ = {p["name"]: p for p in pq.read_table(os.path.join(RF, "picks.parquet")).to_pylist()}
    reason = {x["name"]: x["reason"] for x in json.load(open(os.path.join(RF, "changes.json")))}
    assert set(picks_) == set(photos), "picks and index cover different labels"
    todo = [n for n, p in picks_.items() if photos[n]["photo"] != p["photo_id"]]
    print(f"{len(todo)} photos to replace", flush=True)
    if not todo:
        return
    bak = os.path.join(RF, "replaced")
    os.makedirs(bak, exist_ok=True)
    jobs = []
    for n in todo:
        f = os.path.join(BR.PACK, photos[n]["file"])
        b = os.path.join(bak, f"{photos[n]['photo']}-{photos[n]['file']}")
        if not os.path.exists(b):
            shutil.copy2(f, b)  # the replaced AVIF, kept for a rollback
        p = picks_[n]
        assert os.path.exists(BR.src_path(p)), p
        jobs.append((BR.src_path(p), f, a.edge, a.quality))
    t0 = time.time()
    with Pool(a.workers) as pool:
        res = {d: (wh, nb) for d, wh, nb in pool.imap_unordered(BR._encode, jobs, chunksize=8)}
    print(f"encoded {len(res)} in {time.time() - t0:.0f} s", flush=True)
    obs = BR.observers({picks_[n]["observer_id"] for n in todo})
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(os.path.join(RF, "changes.jsonl"), "a") as log:
        for n in todo:
            p, old = picks_[n], photos[n]
            (w, h), nb = res[os.path.join(BR.PACK, old["file"])]
            login, by = obs.get(p["observer_id"], ("?", "?"))
            lab, _ = BR.LIC_INFO[p["license"]]
            attr = (f"{by}, {lab} (no rights reserved), via iNaturalist" if p["license"] in ("CC0", "PD")
                    else f"© {by}, {lab}, via iNaturalist")
            new = {"u": old["u"], "file": old["file"], "w": w, "h": h, "bytes": nb, "license": p["license"],
                   "by": by, "login": login, "attribution": attr, "photo": p["photo_id"], "obs": p["uuid"],
                   "ext": p["ext"], "via": p["via"]}
            log.write(json.dumps({"at": stamp, "name": n, "via": p["via"], "reason": reason.get(n),
                                  "old": {k: old[k] for k in ("photo", "obs", "license", "login", "bytes")},
                                  "new": {k: new[k] for k in ("photo", "obs", "license", "login", "bytes")}},
                                 ensure_ascii=False) + "\n")
            photos[n] = new
    index["bytes"] = sum(p["bytes"] for p in photos.values())
    index["count"] = len(photos)
    json.dump(index, open(ip + ".part", "w"), ensure_ascii=False, separators=(",", ":"))
    os.replace(ip + ".part", ip)
    # credits from the whole index (same shape as build_refphotos encode)
    per, lic_tot = {}, collections.Counter()
    for p in photos.values():
        d = per.setdefault(p["login"], {"login": p["login"], "name": p["by"], "photos": 0, "licences": {}})
        d["photos"] += 1
        d["licences"][p["license"]] = d["licences"].get(p["license"], 0) + 1
        lic_tot[p["license"]] += 1
    cred = sorted(per.values(), key=lambda d: (-d["photos"], d["name"].lower()))
    cp = os.path.join(BR.PACK, "credits.json")
    old_c = json.load(open(cp))
    json.dump({**{k: old_c[k] for k in ("version", "about")}, "photos": len(photos), "observers": len(cred),
               "licences": dict(lic_tot), "credits": cred},
              open(cp + ".part", "w"), ensure_ascii=False, separators=(",", ":"))
    os.replace(cp + ".part", cp)
    avif = sum(os.path.getsize(os.path.join(BR.PACK, p["file"])) for p in photos.values())
    assert avif == index["bytes"], (avif, index["bytes"])
    s = {"replaced": len(todo), "via": dict(collections.Counter(picks_[n]["via"] for n in todo)),
         "photos": len(photos), "avif_bytes": avif, "index_bytes": os.path.getsize(ip),
         "credits_bytes": os.path.getsize(cp), "pack_bytes": avif + os.path.getsize(ip) + os.path.getsize(cp),
         "licences": dict(lic_tot), "observers": len(cred)}
    json.dump(s, open(os.path.join(RF, "apply.json"), "w"), indent=1)
    print(json.dumps(s, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("gather")
    p.add_argument("--per", type=int, default=10)
    p = sp.add_parser("fetch")
    p.add_argument("--what", choices=("snap", "picks"), required=True)
    p.add_argument("--workers", type=int, default=32)
    p = sp.add_parser("embed")
    p.add_argument("--limit", type=int)
    p.add_argument("--batch", type=int, default=32)
    sp.add_parser("near")
    p = sp.add_parser("qtext")
    p.add_argument("--device", default="mps")
    sp.add_parser("score")
    p = sp.add_parser("sheets")
    p.add_argument("--seed", type=int, default=1)
    p = sp.add_parser("apply")
    p.add_argument("--edge", type=int, default=512)
    p.add_argument("--quality", type=int, default=55)
    p.add_argument("--workers", type=int, default=os.cpu_count())
    a = ap.parse_args()
    {"gather": cmd_gather, "fetch": cmd_fetch, "embed": cmd_embed, "near": cmd_near,
     "qtext": cmd_qtext, "score": cmd_score, "sheets": cmd_sheets,
     "apply": cmd_apply}[a.cmd](a)


if __name__ == "__main__":
    main()

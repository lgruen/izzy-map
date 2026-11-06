#!/usr/bin/env python3
"""Encoder fine-tuning pilot — the plan (Mac). Picks a stratified, genus-
clustered class subset of the v2 label set and writes everything a RunPod pod
needs (no cloud credentials there) plus what the Mac-side evaluation needs.

Classes (each with ≥ 1 training photo in data-final and ≥ 1 AU-test/A-test
photo; merged twins excluded): genera are visited in a seeded random order and
up to 10 of a genus' species are taken while their training-count bucket
(1–9, 10–49, 50–199, 200+) still has room, so most classes have congeners in
the subset (the fine-grained case, and what the hard-negative arm needs);
eucalypts (labels `euc`) get their own quota. Training photos = ALL of a
class's data-final photos (iNat open data + ALA/Commons), val = AU-val ∪ A-val,
test = AU-test ∪ A-test photos of those classes — the SAME held-out observers
as the main protocol; training observers are asserted disjoint from every
evaluation observer. Probe = random AU-test/A-test photos of classes OUTSIDE
the subset (forgetting check: zero-shot against all 22,122 text rows).

Out: cache/plantid/finetune/plan/
  todo.parquet    photo_id, ext (iNat) | file (uploaded), role train/val/test/probe,
                  set, y (global class), ys (subset index, −1 for probe), w, lat, lon, tas
  classes.json    subset classes: global id, name, genus, euc, ship, n_train, bucket
  text_sub.npy    the subset's text rows (fp16, 1024) — the pods' head init / text anchors
  tmean.npy, mu.npy  text centring mean (all labels), production image train mean
  photos-NN.tar   ALA/Commons training photos (named <photo_id>.<ext>), ≤ 60 MB each

Env: uv run --with numpy --with pyarrow python3 -I pipeline/plantid/finetune/ft_plan.py [--n-euc 120 --per-bucket 130]
"""
import argparse
import collections
import io
import json
import os
import tarfile

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
V2 = os.path.join(AU, "v2")
OUT = os.path.join(CACHE, "finetune", "plan")
BUCKETS = ((1, 9), (10, 49), (50, 199), (200, 10 ** 9))


def bucket(n):
    return next(i for i, (lo, hi) in enumerate(BUCKETS) if lo <= n <= hi)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-euc", type=int, default=120)
    ap.add_argument("--per-bucket", type=int, default=130)
    ap.add_argument("--probe", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    Z = np.load(os.path.join(V2, "bank_analysis", "sets.npz"), allow_pickle=True)
    mapv, euc = Z["mapv"], Z["euc"]
    C = len(mapv)
    L = pq.read_table(os.path.join(AU, "labels.parquet"), columns=["name", "genus", "ship"]).to_pydict()
    D = np.load(os.path.join(V2, "data-final.npz"))
    ytr, pid, tas = D["ytr"].astype(np.int64), D["pid"].astype(np.int64), D["tas"]
    n_tr = np.bincount(ytr, minlength=C)
    # ---- evaluation sets (merged truths from sets.npz); AU-val pids recovered from eval.parquet
    pe = pq.read_table(os.path.join(AU, "plan", "eval.parquet"),
                       columns=["observer_id", "lat", "lon", "role", "u", "photo_id", "ext"]).to_pydict()
    key = collections.defaultdict(list)
    for o, la, lo, r, p in zip(pe["observer_id"], pe["lat"], pe["lon"], pe["role"], pe["photo_id"]):
        if r == "val":
            key[(int(o), round(float(la), 6), round(float(lo), 6))].append(int(p))
    auv_pid = []
    for o, la, lo in zip(Z["AU-val/obs"], Z["AU-val/lat"], Z["AU-val/lon"]):
        c = key.get((int(o), round(float(la), 6), round(float(lo), 6)), [])
        auv_pid.append(c[0] if len(set(c)) == 1 else -1)
    auv_pid = np.array(auv_pid, np.int64)
    print(f"AU-val pid recovered for {(auv_pid >= 0).sum():,} / {len(auv_pid):,} (ambiguous dropped)")
    ext = {int(p): e for p, e in zip(pe["photo_id"], pe["ext"])}
    st = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["photo_id", "ext", "observer_id"]).to_pydict()
    ext.update({int(p): e for p, e in zip(st["photo_id"], st["ext"])})
    eval_obs = set(int(o) for o in pe["observer_id"]) | set(int(o) for o in st["observer_id"])
    sets = {}
    for nm in ("AU-val", "A-val", "AU-test", "A-test"):
        p_ = auv_pid if nm == "AU-val" else Z[nm + "/pid"]
        sets[nm] = dict(pid=np.asarray(p_, np.int64), y=Z[nm + "/y"].astype(np.int64), w=Z[nm + "/w"],
                        lat=Z[nm + "/lat"], lon=Z[nm + "/lon"])
    n_test = np.zeros(C, np.int64)
    for nm in ("AU-test", "A-test"):
        y = sets[nm]["y"]
        np.add.at(n_test, y[y >= 0], 1)
    # ---- class selection
    active = (mapv == np.arange(C)) & (n_tr >= 1) & (n_test >= 1)
    cand = np.nonzero(active)[0]
    print(f"candidate classes: {len(cand):,}")
    chosen = set()
    eucs = cand[euc[cand]]
    chosen |= set(rng.permutation(eucs)[:a.n_euc].tolist())
    room = [a.per_bucket] * len(BUCKETS)
    byg = collections.defaultdict(list)
    for u in cand:
        if not euc[u]:
            byg[L["genus"][u]].append(int(u))
    genera = [g for g in byg if len(byg[g]) >= 2]
    for g in rng.permutation(genera):
        if not any(room):
            break
        sp = [u for u in rng.permutation(byg[g])[:10]]
        take = [u for u in sp if room[bucket(n_tr[u])] > 0]
        if len(take) < 2:
            continue
        for u in take:
            if room[bucket(n_tr[u])] > 0:
                chosen.add(int(u))
                room[bucket(n_tr[u])] -= 1
    # pass 2: fill buckets still open from genera already in the subset (keeps congeners)
    have_g = {L["genus"][u] for u in chosen}
    for g in rng.permutation(sorted(have_g)):
        for u in byg.get(g, []):
            if u not in chosen and room[bucket(n_tr[u])] > 0:
                chosen.add(int(u))
                room[bucket(n_tr[u])] -= 1
    cls = np.array(sorted(chosen), np.int64)
    sub = np.full(C, -1, np.int64)
    sub[cls] = np.arange(len(cls))
    gcount = collections.Counter(L["genus"][u] for u in cls)
    info = [{"u": int(u), "name": L["name"][u], "genus": L["genus"][u], "euc": bool(euc[u]),
             "ship": int(L["ship"][u]), "n_train": int(n_tr[u]), "bucket": bucket(n_tr[u]),
             "congeners": gcount[L["genus"][u]] - 1} for u in cls]
    bc = collections.Counter(i["bucket"] for i in info)
    print(f"subset: {len(cls)} classes, {sum(i['euc'] for i in info)} eucalypts, "
          f"{sum(i['ship'] >= 0 for i in info)} Tasmanian-shipped, buckets {dict(sorted(bc.items()))}, "
          f"{sum(i['congeners'] > 0 for i in info)} with a congener, {len(gcount)} genera")
    json.dump(info, open(os.path.join(OUT, "classes.json"), "w"), indent=0)
    T = np.load(os.path.join(AU, "text.npz"))["emb"].astype(np.float16)
    np.save(os.path.join(OUT, "text_sub.npy"), T[cls])
    np.save(os.path.join(OUT, "tmean.npy"), T.astype(np.float32).mean(0))   # centring = mean of ALL 22,122 rows
    np.save(os.path.join(OUT, "mu.npy"), Z["mu"].astype(np.float32))        # the production train mean
    # ---- training photos: every data-final photo of a subset class
    m = sub[ytr] >= 0
    tp, ty, tt = pid[m], ytr[m], tas[m]
    print(f"training photos: {len(tp):,} ({(tp >= 2 ** 61).sum():,} ALA/Commons)")
    obs = {}
    for f, cols in ((os.path.join(AU, "plan", "train.parquet"), ["photo_id", "ext", "observer_id"]),
                    (os.path.join(CACHE, "sets", "train.parquet"), ["photo_id", "ext", "observer_id"]),
                    (os.path.join(CACHE, "extra", "extra_photos_k1000.parquet"), ["photo_id", "ext", "observer_id"])):
        t = pq.read_table(f, columns=cols).to_pydict()
        want = set(tp.tolist())
        for p, e, o in zip(t["photo_id"], t["ext"], t["observer_id"]):
            p = int(p)
            if p in want:
                ext.setdefault(p, e)
                obs[p] = int(o) if o is not None else None
    leak = [p for p in tp if obs.get(int(p)) in eval_obs]
    assert not leak, f"{len(leak)} training photos by evaluation observers"
    src = pq.read_table(os.path.join(CACHE, "extra", "work", "src", "ids-src.parquet")).to_pydict()
    spath = {int(p): q for p, q in zip(src["photo_id"], src["path"])}
    rows = []
    files = []
    for p, y, t_ in zip(tp, ty, tt):
        p = int(p)
        if p >= 2 ** 61:
            q = spath[p]
            fp = q if os.path.isabs(q) else os.path.join(CACHE, "sources", "photos", q)
            if not os.path.exists(fp):
                fp = os.path.join(CACHE, "sources", q)
            assert os.path.exists(fp), q
            e = os.path.splitext(fp)[1].lstrip(".").lower() or "jpg"
            files.append((p, fp, e))
            rows.append(dict(photo_id=p, ext=e, file=f"{p}.{e}", role="train", set="train", y=int(y), ys=int(sub[y]),
                             w=1.0, lat=np.nan, lon=np.nan, tas=bool(t_)))
        else:
            assert p in ext, p
            rows.append(dict(photo_id=p, ext=ext[p], file="", role="train", set="train", y=int(y), ys=int(sub[y]),
                             w=1.0, lat=np.nan, lon=np.nan, tas=bool(t_)))
    seen_eval = set()
    for nm, S in sets.items():
        role = "val" if nm.endswith("val") else "test"
        for i, (p, y) in enumerate(zip(S["pid"], S["y"])):
            if p < 0 or y < 0 or sub[y] < 0:
                continue
            rows.append(dict(photo_id=int(p), ext=ext[int(p)], file="", role=role, set=nm, y=int(y), ys=int(sub[y]),
                             w=float(S["w"][i]), lat=float(S["lat"][i]), lon=float(S["lon"][i]), tas=False))
            seen_eval.add(int(p))
    # probe: outside-subset test photos
    for nm, k in (("AU-test", a.probe), ("A-test", a.probe // 3)):
        S = sets[nm]
        ok = np.nonzero((S["y"] >= 0) & (sub[np.maximum(S["y"], 0)] < 0))[0]
        for i in np.sort(rng.permutation(ok)[:k]):
            rows.append(dict(photo_id=int(S["pid"][i]), ext=ext[int(S["pid"][i])], file="", role="probe", set=nm,
                             y=int(S["y"][i]), ys=-1, w=float(S["w"][i]), lat=float(S["lat"][i]),
                             lon=float(S["lon"][i]), tas=False))
    trs = set(int(p) for p in tp)
    assert not (trs & seen_eval), "a photo in train and eval"
    T_ = pa.Table.from_pylist(rows)
    pq.write_table(T_, os.path.join(OUT, "todo.parquet"))
    print(collections.Counter((r["role"], r["set"]) for r in rows))
    # ---- ALA/Commons photos as tar chunks
    for f in os.listdir(OUT):
        if f.startswith("photos-") and f.endswith(".tar"):
            os.remove(os.path.join(OUT, f))
    k, size, tf = 0, 0, None
    for p, fp, e in files:
        if tf is None or size > 60e6:
            if tf:
                tf.close()
            tf = tarfile.open(os.path.join(OUT, f"photos-{k:02d}.tar"), "w")
            k, size = k + 1, 0
        tf.add(fp, arcname=f"{p}.{e}")
        size += os.path.getsize(fp) + 512
    if tf:
        tf.close()
    print(f"{len(files):,} uploaded photos in {k} tar(s); todo {len(rows):,} rows → {OUT}")


if __name__ == "__main__":
    main()

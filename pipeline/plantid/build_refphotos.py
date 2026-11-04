#!/usr/bin/env python3
"""Offline reference photos for the Australia-wide plant ID (README
"Reference photos"): one typical iNaturalist photo per label of
ship/au-labels.json (22,122 classes), resized + AVIF-encoded for a
Background Assets pack.

Subcommands (run in order; `all` = select → fetch → encode):

  select   pick one photo per class WITHOUT downloading candidates.
           Classes with training photos (plan train.parquet ∪ the Tasmanian
           sets/train.parquet — pool observers, first CC0/BY/BY-NC photo, no
           shared photo): the K photos whose BioCLIP 2.5 embedding is closest
           to the class mean (typical, clear views), then among those
           CC0/PD > CC BY > CC BY-NC, original ≥ 500 px long edge and not a
           panorama, larger original, closer to the mean. Classes without
           training photos ("text-only"): any research-grade observation in
           the local open-data snapshot (any observer role, anywhere) with a
           CC0/PD/BY/BY-NC photo — no embedding to judge by, so the
           observer's lead photo (position 0), unshared, in Australia,
           licence, size. Never an evaluation photo (plan eval.parquet =
           AU-val/AU-test/AU-tune, C.parquet, sets/test.parquet = A-val/A-test).
           Every class keeps up to K ranked candidates so a photo gone
           upstream falls through to the next. Original sizes come from one
           scan of meta/photos.csv.gz (cached in refphotos/dims.parquet).
           → refphotos/candidates.parquet
  fetch    download the current pick of every class (the 500 px "medium"),
           keep-alive HTTPS per worker, image magic checked, resumable
           (refphotos/src/<photo_id>.<ext>; 403/404 → refphotos/
           unavailable.json and the class moves to its next candidate).
           --limit N: timing run on the first N.
  measure  AVIF size / quality sweep on --n photos (default 50) at
           --qualities (default 45,55,65) → refphotos/measure/q<Q>/ + table.
  encode   resize to long edge --edge (default 512, never upscaled: the
           medium is ≤ 500 px), sRGB, AVIF q--quality speed 6, multiprocess →
           refphotos/pack/refphotos/<slug>.avif + index.json + credits.json.

Licences: only CC0 / PD / CC BY / CC BY-NC photos are ever selected (no ND —
resizing/re-encoding is an adaptation; no SA). The app must show the
attribution next to each photo ("© observer, licence, via iNaturalist");
BY-NC binds IzzyMap to non-commercial use (it is private, non-commercial).

Environment:
  uv run --with duckdb --with pyarrow --with numpy --with 'pillow>=11.3' \\
      python3 -I pipeline/plantid/build_refphotos.py <subcommand>
"""
import argparse
import collections
import glob
import gzip
import http.client
import io
import json
import os
import queue
import re
import threading
import time
import unicodedata
import warnings
from multiprocessing import Pool

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
OUT = os.path.join(CACHE, "refphotos")
SRC = os.path.join(OUT, "src")
PACK = os.path.join(OUT, "pack", "refphotos")  # pack namespace: "refphotos/…"
LABELS = os.path.join(CACHE, "ship", "au-labels.json")
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"GIF8", b"RIFF")
USABLE = ("CC0", "PD", "CC-BY", "CC-BY-NC")
LIC_RANK = {"CC0": 0, "PD": 0, "CC-BY": 1, "CC-BY-NC": 2}
LIC_INFO = {
    "CC0": ("CC0", "https://creativecommons.org/publicdomain/zero/1.0/"),
    "PD": ("Public domain", "https://creativecommons.org/publicdomain/mark/1.0/"),
    "CC-BY": ("CC BY", "https://creativecommons.org/licenses/by/4.0/"),
    "CC-BY-NC": ("CC BY-NC", "https://creativecommons.org/licenses/by-nc/4.0/"),
}
AUS = "lat BETWEEN -44.0 AND -9.5 AND lon BETWEEN 112.0 AND 154.5"
K = 5
warnings.filterwarnings("ignore", message="Arrow output")


def db():
    import duckdb
    return duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)


def labels():
    return json.load(open(LABELS))["labels"]


def slug(name):
    s = unicodedata.normalize("NFKD", name.replace("×", "x")).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def eval_photo_ids():
    ids = set()
    for f, col in ((os.path.join(AU, "plan", "eval.parquet"), "photo_id"),
                   (os.path.join(AU, "C.parquet"), "photo_id"),
                   (os.path.join(CACHE, "sets", "test.parquet"), "photo_id")):
        ids.update(pq.read_table(f, columns=[col]).column(0).to_pylist())
    return ids


def all_embeddings():
    """Every BioCLIP 2.5 fp16 embedding we have (Tasmanian run + the
    Australia-wide shards), sorted by photo id (same as train_australia)."""
    ids, es = [], []
    for f in sorted(glob.glob(os.path.join(CACHE, "emb", "bioclip25", "img-*.npz"))) + \
            sorted(glob.glob(os.path.join(AU, "train", "emb", "shard-*.npz"))):
        z = np.load(f)
        ids.append(z["photo_id"].astype(np.int64))
        es.append(z["emb"].astype(np.float16))
    ids, E = np.concatenate(ids), np.concatenate(es)
    o = np.argsort(ids, kind="stable")
    ids, E = ids[o], E[o]
    keep = np.r_[True, ids[1:] != ids[:-1]]
    return ids[keep], E[keep]


def scan_dims(photo_ids):
    """Original width/height for these photo ids from meta/photos.csv.gz (one
    ~3–4 min pass; cached, extended only when new ids are asked for)."""
    path = os.path.join(OUT, "dims.parquet")
    have = pq.read_table(path) if os.path.exists(path) else None
    known = set(have.column("photo_id").to_pylist()) if have is not None else set()
    want = sorted(set(photo_ids) - known)
    if not want:
        return have
    import duckdb
    print(f"scanning photos.csv.gz for {len(want):,} photo sizes …", flush=True)
    t0 = time.time()
    con = duckdb.connect()
    con.register("want_v", pa.table({"photo_id": pa.array(want, pa.int32())}))
    src = os.path.join(CACHE, "meta", "photos.csv.gz")
    t = con.execute(f"""
        SELECT photo_id, any_value(width) AS width, any_value(height) AS height
        FROM read_csv('{src}', delim='\t', header=true, quote='', escape='',
             columns={{'photo_uuid': 'VARCHAR', 'photo_id': 'INTEGER', 'observation_uuid': 'VARCHAR',
                       'observer_id': 'INTEGER', 'extension': 'VARCHAR', 'license': 'VARCHAR',
                       'width': 'INTEGER', 'height': 'INTEGER', 'position': 'SMALLINT'}})
        WHERE photo_id IN (SELECT photo_id FROM want_v) GROUP BY photo_id""").to_arrow_table()
    print(f"  {t.num_rows:,} sizes in {time.time() - t0:.0f} s", flush=True)
    if have is not None:
        t = pa.concat_tables([have, t.cast(have.schema)])
    # remember asked-for ids that had no row (width/height null) so we don't rescan
    got = set(t.column("photo_id").to_pylist())
    miss = [p for p in want if p not in got]
    if miss:
        t = pa.concat_tables([t, pa.table({"photo_id": pa.array(miss, t.schema.field("photo_id").type),
                                           "width": pa.nulls(len(miss), t.schema.field("width").type),
                                           "height": pa.nulls(len(miss), t.schema.field("height").type)})])
    pq.write_table(t, path)
    return t


def observers(ids):
    """observer_id → (login, display name as iNat shows it: name, else login)."""
    out = {}
    with gzip.open(os.path.join(CACHE, "meta", "observers.csv.gz"), "rt") as f:
        next(f)
        for line in f:
            i, login, *name = line.rstrip("\n").split("\t")
            i = int(i)
            if i in ids:
                nm = " ".join((name[0] if name else "").split())
                out[i] = (login, nm or login)
    return out


# ------------------------------------------------------------------ select

def cmd_select(a):
    import duckdb
    os.makedirs(OUT, exist_ok=True)
    L = labels()
    nU = len(L)
    assert nU == 22122, nU
    names = [x["name"] for x in L]
    ev = eval_photo_ids()
    con = duckdb.connect()
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    tr = con.execute(f"""
        WITH a AS (SELECT photo_id, uuid::VARCHAR AS uuid, observer_id, u, ext, license, region
                   FROM '{AU}/plan/train.parquet'),
             b AS (SELECT t.photo_id, t.uuid::VARCHAR AS uuid, t.observer_id, m.u, t.ext, t.license,
                          t.region
                   FROM '{CACHE}/sets/train.parquet' t JOIN imap_v m USING (species_id)
                   WHERE t.photo_id NOT IN (SELECT photo_id FROM a))
        SELECT * FROM a UNION ALL SELECT * FROM b ORDER BY u, photo_id""").to_arrow_table().to_pydict()
    n_tr = len(tr["photo_id"])
    assert set(tr["license"]) <= set(USABLE), set(tr["license"])
    bad = ev & set(tr["photo_id"])
    assert not bad, f"{len(bad)} training photos are evaluation photos"
    print(f"training photos: {n_tr:,} over {len(set(tr['u'])):,} classes", flush=True)

    t0 = time.time()
    ids, E = all_embeddings()
    pid = np.array(tr["photo_id"], np.int64)
    i = np.searchsorted(ids, pid).clip(0, len(ids) - 1)
    has = ids[i] == pid
    print(f"embeddings: {len(ids):,} loaded in {time.time() - t0:.0f} s; {has.sum():,} of {n_tr:,} "
          f"training photos embedded ({(~has).sum():,} gone upstream)", flush=True)
    u = np.array(tr["u"], np.int64)[has]
    X = E[i[has]].astype(np.float32)
    X /= np.linalg.norm(X, axis=1, keepdims=True)
    rows = np.flatnonzero(has)
    M = np.zeros((nU, X.shape[1]), np.float32)
    np.add.at(M, u, X)
    M /= np.maximum(np.linalg.norm(M, axis=1, keepdims=True), 1e-12)
    cos = (X * M[u]).sum(1)
    # top-K per class by cosine to the class mean (u sorted)
    order = np.lexsort((-cos, u))
    u_o = u[order]
    start = np.r_[0, np.flatnonzero(u_o[1:] != u_o[:-1]) + 1]
    rk = np.arange(len(u_o)) - np.repeat(start, np.diff(np.r_[start, len(u_o)]))
    sel = order[rk < K]
    cand_tr = {k: [tr[k][j] for j in rows[sel]] for k in ("photo_id", "uuid", "observer_id", "u", "ext",
                                                           "license", "region")}
    cand_tr["cos"] = cos[sel].tolist()
    # rank of each selected row by cosine within its class
    rk_sel = np.empty(len(order), np.int64)
    rk_sel[order] = rk
    cand_tr["near"] = rk_sel[sel].tolist()
    cand_tr["position"] = [0] * len(sel)
    cand_tr["shared"] = [False] * len(sel)
    cand_tr["via"] = ["train"] * len(sel)
    with_tr = set(u.tolist())
    print(f"classes with an embedded training photo: {len(with_tr):,}; candidates {len(sel):,}", flush=True)

    # text-only classes: anything usable in the snapshot
    notr = [k for k in range(nU) if k not in with_tr]
    w = db()
    w.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    w.register("notr_v", pa.table({"u": pa.array(notr, pa.int64())}))
    w.register("ev_v", pa.table({"photo_id": pa.array(sorted(ev), pa.int64())}))
    q = lambda c: c.replace("lat", "o.lat").replace("lon", "o.lon")  # noqa: E731
    lic = ", ".join(f"'{x}'" for x in USABLE)
    fb = w.execute(f"""
        WITH c AS (
            SELECT p.photo_id, o.uuid::VARCHAR AS uuid, o.observer_id, m.u, p.ext, p.license,
                   CASE WHEN {q(AUS)} THEN 0 ELSE 1 END AS region, p.position,
                   p.photo_id IN (SELECT photo_id FROM shared) AS shared, o.role,
                   hash(p.photo_id::VARCHAR || 'izzy-ref') AS h
            FROM o JOIN imap_v m USING (species_id) JOIN pobs p USING (uuid)
            WHERE m.u IN (SELECT u FROM notr_v) AND p.license IN ({lic})
              AND p.photo_id NOT IN (SELECT photo_id FROM ev_v))
        SELECT * EXCLUDE (h) FROM c QUALIFY row_number() OVER (
            PARTITION BY u ORDER BY position > 0, shared, region, h) <= {4 * K}""").to_arrow_table().to_pydict()
    print(f"text-only classes: {len(notr):,}; {len(set(fb['u'])):,} have a usable research-grade photo "
          f"in the snapshot ({len(fb['photo_id']):,} candidates; roles "
          f"{dict(zip(*np.unique(fb['role'], return_counts=True)))})", flush=True)

    dims = scan_dims(cand_tr["photo_id"] + fb["photo_id"]).to_pydict()
    D = {p: (wd, ht) for p, wd, ht in zip(dims["photo_id"], dims["width"], dims["height"])}

    def quality(p):
        wd, ht = D.get(p, (None, None))
        if not wd or not ht:
            return 1, 0, 0
        long, short = max(wd, ht), min(wd, ht)
        badshape = long < 500 or long > 2.5 * short
        return int(badshape), -int(long >= 1000), long

    recs = []
    for j in range(len(cand_tr["photo_id"])):
        p = cand_tr["photo_id"][j]
        bs, big, long = quality(p)
        recs.append({**{k: cand_tr[k][j] for k in cand_tr}, "width": D.get(p, (None,))[0],
                     "height": D.get(p, (None, None))[1],
                     "key": (cand_tr["u"][j], bs, LIC_RANK[cand_tr["license"][j]], big, -cand_tr["cos"][j])})
    for j in range(len(fb["photo_id"])):
        p = fb["photo_id"][j]
        bs, big, long = quality(p)
        recs.append({"photo_id": p, "uuid": fb["uuid"][j], "observer_id": fb["observer_id"][j],
                     "u": fb["u"][j], "ext": fb["ext"][j], "license": fb["license"][j],
                     "region": fb["region"][j], "cos": None, "near": None,
                     "position": int(fb["position"][j]), "shared": bool(fb["shared"][j]), "via": "snapshot",
                     "width": D.get(p, (None,))[0], "height": D.get(p, (None, None))[1],
                     "key": (fb["u"][j], int(fb["position"][j] > 0), int(fb["shared"][j]), bs,
                             int(fb["region"][j]), LIC_RANK[fb["license"][j]], big, -long, j)})
    recs.sort(key=lambda r: r["key"])
    rank, last = 0, None
    for r in recs:
        rank = rank + 1 if r["u"] == last else 0
        last = r["u"]
        r["rank"] = rank
        r["name"] = names[r["u"]]
        del r["key"]
    recs = [r for r in recs if r["via"] == "train" or r["rank"] < 2 * K]
    t = pa.Table.from_pylist(recs)
    pq.write_table(t, os.path.join(OUT, "candidates.parquet"))
    first = [r for r in recs if r["rank"] == 0]
    cnt = lambda xs: dict(sorted(collections.Counter(xs).items()))  # noqa: E731
    s = {"classes": nU, "with_train": len(with_tr), "text_only": len(notr),
         "text_only_with_snapshot_photo": len({r["u"] for r in recs if r["via"] == "snapshot"}),
         "picks": len(first), "pick_licences": cnt(r["license"] for r in first),
         "pick_via": cnt(r["via"] for r in first),
         "pick_near_rank": cnt(r["near"] for r in first if r["near"] is not None),
         "pick_badshape": sum(quality(r["photo_id"])[0] for r in first)}
    json.dump(s, open(os.path.join(OUT, "select.json"), "w"), indent=1)
    print(json.dumps(s, indent=1))


# ------------------------------------------------------------------ fetch

def unavailable():
    p = os.path.join(OUT, "unavailable.json")
    return set(json.load(open(p))) if os.path.exists(p) else set()


def picks():
    """Current pick per class: first candidate not gone upstream."""
    t = pq.read_table(os.path.join(OUT, "candidates.parquet")).to_pylist()
    gone = unavailable()
    out = {}
    for r in sorted(t, key=lambda r: (r["u"], r["rank"])):
        if r["u"] not in out and r["photo_id"] not in gone:
            out[r["u"]] = r
    return out


def src_path(r):
    return os.path.join(SRC, f"{r['photo_id']}.{r['ext']}")


def fetch_many(items, workers):
    q = queue.Queue()
    for it in items:
        q.put(it)
    stats = {"ok": 0, "missing": 0, "failed": 0, "bytes": 0, "gone": []}
    lock = threading.Lock()

    def work():
        conn = None
        while True:
            try:
                pid, ext = q.get_nowait()
            except queue.Empty:
                return
            path = os.path.join(SRC, f"{pid}.{ext}")
            key, n = "failed", 0
            for attempt in range(4):
                try:
                    if conn is None:
                        conn = http.client.HTTPSConnection(HOST, timeout=30)
                    conn.request("GET", f"/photos/{pid}/medium.{ext}", headers=UA)
                    resp = conn.getresponse()
                    body = resp.read()
                    if resp.status == 200 and body.startswith(MAGIC):
                        with open(path + ".part", "wb") as f:
                            f.write(body)
                        os.replace(path + ".part", path)
                        key, n = "ok", len(body)
                    elif resp.status in (403, 404):
                        key = "missing"
                    else:
                        raise IOError(f"HTTP {resp.status}")
                    break
                except Exception:
                    conn = None
                    time.sleep(1 + 2 * attempt)
            with lock:
                stats[key] += 1
                stats["bytes"] += n
                if key == "missing":
                    stats["gone"].append(pid)

    ths = [threading.Thread(target=work, daemon=True) for _ in range(workers)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    return stats


def cmd_fetch(a):
    os.makedirs(SRC, exist_ok=True)
    t0 = time.time()
    tot = {"ok": 0, "missing": 0, "failed": 0, "bytes": 0}
    while True:
        P = picks()
        todo = sorted({(r["photo_id"], r["ext"]) for r in P.values() if not os.path.exists(src_path(r))})
        if a.limit:
            todo = todo[:a.limit]
        print(f"{len(P):,} classes with a pick, {len(todo):,} photos to fetch", flush=True)
        if not todo:
            break
        t1 = time.time()
        s = fetch_many(todo, a.workers)
        dt = time.time() - t1
        print(f"  {s['ok']:,} ok ({s['bytes'] / 1e6:.0f} MB) in {dt:.1f} s = {s['ok'] / dt:.0f} photos/s, "
              f"{s['bytes'] / dt / 1e6:.1f} MB/s; {s['missing']} gone upstream, {s['failed']} failed", flush=True)
        for k in tot:
            tot[k] += s[k]
        if s["gone"]:
            p = os.path.join(OUT, "unavailable.json")
            json.dump(sorted(unavailable() | set(s["gone"])), open(p, "w"))
        if a.limit or (not s["gone"] and s["failed"]):
            break
        if not s["gone"]:
            continue
    print(f"fetch total {time.time() - t0:.0f} s: {tot}", flush=True)


# ------------------------------------------------------------------ encode

def _load(path, edge):
    from PIL import Image, ImageCms, ImageOps
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    icc = im.info.get("icc_profile")
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    if icc:
        try:
            src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
            im = ImageCms.profileToProfile(im.convert("RGB"), src, ImageCms.createProfile("sRGB"),
                                           outputMode="RGB")
        except Exception:
            pass
    im = im.convert("RGB")
    w, h = im.size
    s = edge / max(w, h)
    if s < 1:
        im = im.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    return im


def _encode(job):
    src, dst, edge, q = job
    im = _load(src, edge)
    b = io.BytesIO()
    im.save(b, "AVIF", quality=q, speed=6)
    with open(dst + ".part", "wb") as f:
        f.write(b.getvalue())
    os.replace(dst + ".part", dst)
    return dst, im.size, b.tell()


def cmd_measure(a):
    P = picks()
    have = [r for r in P.values() if os.path.exists(src_path(r))]
    rng = np.random.default_rng(1)
    sample = [have[i] for i in rng.choice(len(have), min(a.n, len(have)), replace=False)]
    print(f"{len(sample)} photos; source JPEG mean {np.mean([os.path.getsize(src_path(r)) for r in sample]) / 1e3:.1f} KB")
    for q in a.qualities:
        d = os.path.join(OUT, "measure", f"q{q}")
        os.makedirs(d, exist_ok=True)
        jobs = [(src_path(r), os.path.join(d, f"{slug(r['name'])}.avif"), a.edge, q) for r in sample]
        t0 = time.time()
        with Pool(a.workers) as pool:
            res = pool.map(_encode, jobs)
        sz = np.array([r[2] for r in res])
        print(f"  q{q}: mean {sz.mean() / 1e3:.1f} KB, median {np.median(sz) / 1e3:.1f}, max {sz.max() / 1e3:.1f}; "
              f"× {len(P):,} = {sz.mean() * len(P) / 1e6:.0f} MB; {time.time() - t0:.1f} s", flush=True)


def cmd_encode(a):
    P = picks()
    L = labels()
    os.makedirs(PACK, exist_ok=True)
    slugs = {}
    for k in sorted(P):
        s = slug(L[k]["name"])
        assert s not in slugs, (s, L[k]["name"], L[slugs[s]]["name"])
        slugs[s] = k
    jobs, keep = [], {}
    for s, k in slugs.items():
        r = P[k]
        if not os.path.exists(src_path(r)):
            continue
        dst = os.path.join(PACK, f"{s}.avif")
        keep[k] = (s, dst)
        jobs.append((src_path(r), dst, a.edge, a.quality))
    missing = len(P) - len(jobs)
    t0 = time.time()
    with Pool(a.workers) as pool:
        res = {d: (wh, n) for d, wh, n in pool.imap_unordered(_encode, jobs, chunksize=16)}
    print(f"encoded {len(res):,} in {time.time() - t0:.0f} s ({missing} picks not fetched)", flush=True)
    for f in glob.glob(os.path.join(PACK, "*.avif")):  # stale files from an earlier selection
        if f not in res:
            os.remove(f)
    obs = observers({P[k]["observer_id"] for k in keep})
    photos, per, lic_tot = {}, {}, {}
    for k in sorted(keep):
        r, (s, dst) = P[k], keep[k]
        (w, h), n = res[dst]
        login, by = obs.get(r["observer_id"], ("?", "?"))
        lab, _ = LIC_INFO[r["license"]]
        attr = (f"{by}, {lab} (no rights reserved), via iNaturalist" if r["license"] in ("CC0", "PD")
                else f"© {by}, {lab}, via iNaturalist")
        photos[L[k]["name"]] = {"u": k, "file": f"{s}.avif", "w": w, "h": h, "bytes": n,
                                "license": r["license"], "by": by, "login": login, "attribution": attr,
                                "photo": r["photo_id"], "obs": r["uuid"], "ext": r["ext"], "via": r["via"]}
        d = per.setdefault(r["observer_id"], {"login": login, "name": by, "photos": 0, "licences": {}})
        d["photos"] += 1
        d["licences"][r["license"]] = d["licences"].get(r["license"], 0) + 1
        lic_tot[r["license"]] = lic_tot.get(r["license"], 0) + 1
    total = sum(p["bytes"] for p in photos.values())
    index = {
        "version": 1,
        "about": "One reference photo per plant-ID label (key = au-labels.json name; u = its index). "
                 "iNaturalist Open Dataset (2026-10 snapshot), research grade; each photo © its observer "
                 "under the licence given (CC0, CC BY or CC BY-NC), resized and re-encoded (AVIF). Show "
                 "'attribution' next to the photo. CC BY-NC: non-commercial use only.",
        "labels": "au-labels.json", "count": len(photos), "classes": len(L), "edge": a.edge,
        "format": f"avif q{a.quality}", "bytes": total,
        "licences": {k: {"label": v[0], "url": v[1]} for k, v in LIC_INFO.items()},
        "photo_url": "https://www.inaturalist.org/photos/{photo}",
        "observation_url": "https://www.inaturalist.org/observations/{obs}",
        "source_url": f"https://{HOST}/photos/{{photo}}/medium.{{ext}}",
        "photos": photos}
    json.dump(index, open(os.path.join(PACK, "index.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    cred = sorted(per.values(), key=lambda d: (-d["photos"], d["name"].lower()))
    json.dump({"version": 1, "about": "Reference photos by these iNaturalist observers (name as iNaturalist "
               "shows it, login), with the number of photos and their licences.",
               "photos": len(photos), "observers": len(cred), "licences": lic_tot, "credits": cred},
              open(os.path.join(PACK, "credits.json"), "w"), ensure_ascii=False, separators=(",", ":"))
    ix = os.path.getsize(os.path.join(PACK, "index.json"))
    cr = os.path.getsize(os.path.join(PACK, "credits.json"))
    via = {}
    for p in photos.values():
        via[p["via"]] = via.get(p["via"], 0) + 1
    s = {"photos": len(photos), "classes": len(L), "via": via, "licences": lic_tot, "observers": len(cred),
         "avif_bytes": total, "mean_kb": round(total / max(len(photos), 1) / 1e3, 1),
         "index_bytes": ix, "credits_bytes": cr, "pack_bytes": total + ix + cr, "edge": a.edge,
         "quality": a.quality}
    json.dump(s, open(os.path.join(OUT, "encode.json"), "w"), indent=1)
    print(json.dumps(s, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("select")
    p = sp.add_parser("fetch")
    p.add_argument("--workers", type=int, default=48)
    p.add_argument("--limit", type=int)
    p = sp.add_parser("measure")
    p.add_argument("--n", type=int, default=50)
    p.add_argument("--qualities", type=lambda s: [int(x) for x in s.split(",")], default=[45, 55, 65])
    p.add_argument("--edge", type=int, default=512)
    p.add_argument("--workers", type=int, default=os.cpu_count())
    for nm in ("encode", "all"):
        p = sp.add_parser(nm)
        p.add_argument("--edge", type=int, default=512)
        p.add_argument("--quality", type=int, default=55)
        p.add_argument("--workers", type=int, default=os.cpu_count())
    a = ap.parse_args()
    if a.cmd == "all":
        cmd_select(a)
        cmd_fetch(argparse.Namespace(limit=None, workers=48))
        cmd_encode(a)
    else:
        {"select": cmd_select, "fetch": cmd_fetch, "measure": cmd_measure, "encode": cmd_encode}[a.cmd](a)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Reference-photo gap fill (notes/refphotos_gap.md): candidates for the plant-ID
species the refphotos pack has no photo for — the ~3,500 without training
photos and the 125 Opus rejected every candidate of — from sources outside the
training set:

  * iNaturalist, research grade AND "needs ID" observations (open licences only;
    evaluation photos excluded), by taxon id, else by name (iNat's taxon search
    matches synonyms: older names find the current taxon);
  * ALA field photos (APII and other providers; not ALA's iNaturalist copy
    dr1411, not NatureMapr dr19123 — no per-image licence), by species name,
    else ALA's accepted name;
  * ALA herbarium specimen images (BRI, MEL, Te Papa, QVM … — the image's own
    licence must be CC/PD with a creator, so the NSW AVH feed's UNSPECIFIED
    images stay out).

Up to 5 candidates per species, field photos first (≤ 4 when specimens exist,
so a specimen can stand in when Opus rejects every field photo — the
build's fallback rule). Each photo's own licence decides (REF_OK, never ND).

Stages (resumable; cache/plantid/refphotos/v2/gap/):

  find     query iNat + ALA per species → gap/raw/<u>.json
  fetch    download the chosen candidates (500 px JPEG) + 384 px thumbnails
           (v2/thumb/) → gap/cands.parquet (cands.parquet's columns)
  report   what each source adds, overall and for the species with ALA
           records in Tasmania

Then the usual v2 stages pick and build: `build_refphotos_v2.py submit
--approve-spend` (re-asks Opus for exactly the species whose candidate set
the gap changed), `collect --wait`, `build`. cand_table() in
build_refphotos_v2.py reads gap/cands.parquet: for a species listed there
its gap candidates REPLACE the old set (the old one was judged already).

  uv run --with duckdb --with pyarrow --with pandas --with numpy \\
      --with 'pillow>=11.3' python3 -I pipeline/plantid/refphotos_gap.py <stage>
"""
import argparse
import collections
import concurrent.futures as cf
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_refphotos as BR  # noqa: E402
import sources_pull as SP  # noqa: E402

GAP = os.path.join(BR.OUT, "v2", "gap")
RAW = os.path.join(GAP, "raw")
IMG = os.path.join(GAP, "img")
THUMB = os.path.join(BR.OUT, "v2", "thumb")
PACK_INDEX = os.path.join(BR.OUT, "pack-v2", "refphotos", "index.json")
NO_PHOTO = os.path.join(BR.OUT, "v2", "no_photo.json")
ALA_COUNTS = os.path.join(BR.CACHE, "sources", "ala_counts", "ala_counts.parquet")
CANDS = os.path.join(GAP, "cands.parquet")
V2_LABELS = os.path.join(BR.CACHE, "ship", "v2-labels.json")
INAT = "https://api.inaturalist.org/v1/"
INAT_LIC = "cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nc-sa"
INAT_CODE = {"cc0": "CC0", "cc-by": "CC-BY", "cc-by-nc": "CC-BY-NC", "cc-by-sa": "CC-BY-SA",
             "cc-by-nc-sa": "CC-BY-NC-SA"}
SPECIMEN_BOR = ("PRESERVED_SPECIMEN", "MATERIAL_SAMPLE")
K = 5
POOL = 8                # chosen before download: the size gate may drop some, the best 5 stay
FIELD_MAX_WITH_SPECIMENS = 4
MIN_EDGE = 400          # build_refphotos_v2's source size gate
MAX_ASPECT = 2.5
KIND_ALA = 2            # build_refphotos_v2 kinds: 0/1 iNat training, 2 ALA, 3 Commons
KIND_INAT_GAP = 4       # iNat outside the training set
PID_ALA = 2 ** 62       # ALA image pids: above every iNat photo id and the v2 source hashes (2^61 …)
# Tasmania in the prior grid (PRIOR_GRID cell 0.05°, lat0 −44, lon0 112)
TAS_CY, TAS_CX = (0, 95), (630, 740)


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Pace:
    """One request per `gap` seconds across threads (iNat asks for ≤ 1/s)."""

    def __init__(self, gap):
        self.gap, self.last, self.lock = gap, 0.0, threading.Lock()

    def wait(self):
        with self.lock:
            t = max(0.0, self.last + self.gap - time.time())
            time.sleep(t)
            self.last = time.time()


INAT_PACE = Pace(1.0)


def inat(path, **q):
    INAT_PACE.wait()
    return SP.getj(INAT + path + "?" + urllib.parse.urlencode(q))


def labels():
    """au-labels.json (what the pack index is keyed by) with `merged_into` from the shipped
    v2-labels.json (same indices): au-labels has no twin marks, and a twin merged at
    training is never shown, so it needs no photo."""
    L = BR.labels()
    V = json.load(open(V2_LABELS))["labels"]
    assert len(V) == len(L), (len(V), len(L))
    for l, v in zip(L, V):
        if v.get("merged_into") is not None:
            l["merged_into"] = v["merged_into"]
    return L


def targets(L, index, no_photo):
    """Unmerged labels without a pack photo (incl. Opus-rejected ones)."""
    have = {p["u"] for p in index.values() if p.get("u") is not None}
    rejected = set(no_photo.get("none_acceptable", []))
    out = [u for u, l in enumerate(L) if u not in have and l.get("merged_into") is None]
    return out, {u for u in out if L[u]["name"] in rejected}


def tas_species():
    try:
        import duckdb
        q = (f"SELECT DISTINCT u FROM '{ALA_COUNTS}' WHERE cy BETWEEN {TAS_CY[0]} AND {TAS_CY[1]} "
             f"AND cx BETWEEN {TAS_CX[0]} AND {TAS_CX[1]}")
        return {int(u) for (u,) in duckdb.connect().execute(q).fetchall()}
    except Exception as e:  # noqa: BLE001
        say(f"no Tasmania list ({e}); order by index only")
        return set()


# ------------------------------------------------------------------ names

_ENDINGS = (("us", "a", "um"), ("is", "e"), ("er", "ra", "rum"))


def _stem(ep):
    for group in _ENDINGS:
        for e in group:
            if ep.endswith(e) and len(ep) > len(e) + 2:
                return ep[: -len(e)]
    return ep


def same_taxon(name, target, labels):
    """May `target` (an iNat synonym match or ALA's accepted name) stand for label `name`?
    Only a genus transfer of the same species: the same epithet (gender endings
    allowed), and `target` not itself another label — a lump (Acacia centrinervia →
    A. lineata, Hibbertia mathinnicola → H. calycina) would show another class's
    photo. An infraspecific label never takes a species-level stand-in."""
    if target == name:
        return True
    a, b = name.split(), (target or "").split()
    if len(a) != 2 or len(b) != 2 or a[0] == b[0]:
        return False
    if target in labels:
        return False
    return _stem(a[1]) == _stem(b[1])


# ------------------------------------------------------------------ find

def inat_taxon(l, labels):
    """(taxon id, how) — the label's id, else an exact name match, else a synonym match
    that is the same species under another genus (same_taxon)."""
    if l.get("inat"):   # au-labels: a list of ids (first = the main one); older files: one int
        ids = l["inat"] if isinstance(l["inat"], list) else [l["inat"]]
        return int(ids[0]), "id"
    d = inat("taxa", q=l["name"], rank="species,subspecies,variety", per_page=10, all_names="true")
    for t in d.get("results", []):
        if t.get("iconic_taxon_name") not in (None, "Plantae"):
            continue
        if t.get("name") == l["name"]:
            return int(t["id"]), "name"
        if (t.get("matched_term") or "").lower() == l["name"].lower() and same_taxon(l["name"], t.get("name"), labels):
            return int(t["id"]), f"synonym of {t.get('name')}"
    return None, None


def inat_photos(taxon):
    """Observations with an open-licence photo, research grade first, most-faved first."""
    out = []
    # one request for both grades (iNat asks for ≤ 1 request/s); research first below
    d = inat("observations", taxon_id=taxon, photos="true", photo_license=INAT_LIC,
             quality_grade="research,needs_id", per_page=50, order_by="votes")
    for o in sorted(d.get("results", []), key=lambda o: o.get("quality_grade") != "research"):
        grade = o.get("quality_grade")
        if grade not in ("research", "needs_id"):
            continue
        for p in o.get("photos") or []:
            code = INAT_CODE.get((p.get("license_code") or "").lower())
            if not code or p.get("hidden") or not p.get("url"):
                continue
            dims = p.get("original_dimensions") or {}
            out.append({"photo": int(p["id"]), "obs": o["uuid"], "grade": grade,
                        "taxon": (o.get("taxon") or {}).get("name"),
                        "user": (o.get("user") or {}).get("login"), "name": (o.get("user") or {}).get("name"),
                        "attr": p.get("attribution"), "licence": code, "url": p.get("url"),
                        "w": dims.get("width"), "h": dims.get("height")})
            break   # one photo per observation (its first: the observer's lead photo)
    return out


def ala_records(name):
    fq = [f'species:"{name}"', "kingdom:Plantae", "multimedia:Image",
          "-data_resource_uid:(" + " OR ".join(SP.EXCL_DR) + ")"]
    d = SP.search(fq, pageSize=100, sort="id", dir="asc")   # raises on an ALA error inside a 200
    recs = []
    for o in d.get("occurrences", []):
        if "inaturalist" in (o.get("dataResourceName") or "").lower():
            continue
        recs.append({k: o.get(k) for k in ("uuid", "dataResourceUid", "dataResourceName", "basisOfRecord",
                                            "images", "license", "recordedBy", "institutionName", "scientificName")})
    return d.get("totalRecords", 0), recs


def image_info(ids):
    info = {}
    for k in range(0, len(ids), 100):
        chunk = ids[k:k + 100]
        d = SP.getj("https://images.ala.org.au/ws/getImageInfoForIdList",
                    data=json.dumps({"imageIds": chunk}).encode(), headers={"Content-Type": "application/json"})
        for i in chunk:
            m = (d.get("results") or {}).get(i)
            info[i] = {x: (m or {}).get(x) for x in ("license", "creator", "rightsHolder", "width", "height")} \
                if m else None
    return info


def ala_photos(name, labels):
    """Licensed ALA images: field first, then specimens (≤ 12 + 12 looked up)."""
    total, recs = ala_records(name)
    query = name
    if total == 0:
        nm = SP.namematch(name)
        if "error" in (nm or {}):
            raise RuntimeError(f"name matching: {nm['error']}")   # retried next run, never filed as "none"
        acc = (nm or {}).get("speciesName") or (nm or {}).get("scientificName")
        if acc and acc != name and same_taxon(name, acc, labels):
            query = acc
            total, recs = ala_records(acc)
    field, spec = [], []
    for r in recs:
        bor = r.get("basisOfRecord") or ""
        for im in r.get("images") or []:
            (spec if bor in SPECIMEN_BOR else field if bor in SP.FIELD_BOR else []).append((im, r))
    field.sort(key=lambda x: x[1]["dataResourceUid"] != SP.APII)   # APII first
    look = field[:12] + spec[:12]
    info = image_info([im for im, _ in look]) if look else {}
    out = []
    for im, r in look:
        m = info.get(im) or {}
        lic = SP.norm_lic(m.get("license"))   # the IMAGE's licence only (never the record's)
        dr = r["dataResourceUid"]
        spec = r.get("basisOfRecord") in SPECIMEN_BOR
        # a herbarium image's creator is often its database ("Herbrecs"): credit the rights holder
        names = [m.get("rightsHolder"), m.get("creator")] if spec else [m.get("creator"), m.get("rightsHolder")]
        names = [x.strip() for x in names if x and x.strip().lower() not in SP.NO_NAME]
        who = names[0] if names else None
        if lic not in SP.REF_OK or not (who or dr == SP.APII):
            continue
        if dr == SP.APII and lic != "CC-BY":   # apii_credit says CC BY 3.0 AU (sources_pull.apii_fix)
            continue
        via = r.get("dataResourceName") or "Atlas of Living Australia"
        attr = (SP.apii_credit(who) if dr == SP.APII else
                f"{who}, {SP.LIC_LABEL[lic]} (no rights reserved), via {via} (Atlas of Living Australia)"
                if lic in ("CC0", "PD") else
                f"© {who}, {SP.LIC_LABEL[lic]}, via {via} (Atlas of Living Australia)")
        # the National Seed Bank's APII photos are seed/lab images: specimen tier, never a field photo
        seedbank = "seed bank" in (who or "").lower()
        out.append({"image": im, "occ": r["uuid"], "dr": dr, "dr_name": r.get("dataResourceName"),
                    "basis": r.get("basisOfRecord"), "specimen": spec or seedbank,
                    "licence": lic, "by": who, "attr": attr, "w": m.get("width"), "h": m.get("height")})
    return {"query": query, "total": total, "photos": out}


def find_one(u, l):
    path = os.path.join(RAW, f"{u:05d}.json")
    if os.path.exists(path):
        return False
    rec = {"u": u, "name": l["name"]}
    try:
        taxon, how = inat_taxon(l, LABEL_NAMES)
        rec["inat_taxon"], rec["inat_how"] = taxon, how
        rec["inat"] = inat_photos(taxon) if taxon else []
        rec["ala"] = ala_photos(l["name"], LABEL_NAMES)
    except Exception as e:  # noqa: BLE001
        say(f"  {l['name']}: {str(e)[:100]} (retried next run)")
        return False
    SP.wjson(path, rec)
    return True


LABEL_NAMES = set()


def set_labels(L):
    LABEL_NAMES.clear()
    LABEL_NAMES.update(l["name"] for l in L if l.get("merged_into") is None)


def cmd_find(a):
    L = labels()
    set_labels(L)
    index = json.load(open(a.index))["photos"]
    no_photo = json.load(open(NO_PHOTO)) if os.path.exists(NO_PHOTO) else {}
    us, rejected = targets(L, index, no_photo)
    tas = tas_species()
    us.sort(key=lambda u: (u not in tas, u not in rejected, u))
    if a.only_tas:
        us = [u for u in us if u in tas]
    if a.limit:
        us = us[:a.limit]
    os.makedirs(RAW, exist_ok=True)
    todo = [u for u in us if not os.path.exists(os.path.join(RAW, f"{u:05d}.json"))]
    say(f"{len(us):,} species without a reference photo ({len(rejected)} Opus-rejected, "
        f"{len(tas & set(us))} recorded in Tasmania); {len(todo):,} to look up")
    t0, n = time.time(), [0]

    def one(u):
        find_one(u, L[u])
        n[0] += 1
        if n[0] % 100 == 0:
            say(f"  {n[0]:,}/{len(todo):,} in {time.time() - t0:.0f} s")
    with cf.ThreadPoolExecutor(a.workers) as ex:
        list(ex.map(one, todo))
    say(f"find done: {sum(os.path.exists(os.path.join(RAW, f'{u:05d}.json')) for u in us):,}/{len(us):,} looked up")


# ------------------------------------------------------------------ choose + fetch

def eval_ids(a):
    try:
        return BR.eval_photo_ids()
    except FileNotFoundError:
        if a.test:
            return set()
        raise


def shown_before():
    """pids and ALA image ids Opus has already seen per species (cands.parquet): never
    offered again (the old ALA rows carry source-hash pids, so the image id is the key)."""
    import pyarrow.parquet as pq
    p = os.path.join(BR.OUT, "v2", "cands.parquet")
    out = collections.defaultdict(set)
    if not os.path.exists(p):
        return out
    t = pq.read_table(p, columns=["u", "pid", "image_id"]).to_pydict()
    for u, pid, im in zip(t["u"], t["pid"], t["image_id"]):
        out[int(u)].add(int(pid))
        if im:
            out[int(u)].add(im)
    return out


def ala_pid(image_id):
    return PID_ALA + int(hashlib.sha1(image_id.encode()).hexdigest()[:15], 16)


def inat_name(p):
    m = re.match(r"\(c\)\s*(.+?),\s*(?:some|no) rights reserved", p.get("attr") or "")
    return (m.group(1).strip() if m else None) or p.get("name") or p.get("user")


def choose(rec, ev, seen, k=K):
    """≤ k candidate dicts in order: field (iNat research, ALA field, iNat needs-ID), then specimens."""
    u = rec["u"]
    cands, seen_obs, seen_who = [], set(), collections.Counter()
    how = rec.get("inat_how") or ""
    inat_ok = not how.startswith("synonym of ") or same_taxon(rec["name"], how[len("synonym of "):], LABEL_NAMES)
    ala_q = (rec.get("ala") or {}).get("query") or rec["name"]
    ala_ok = same_taxon(rec["name"], ala_q, LABEL_NAMES)
    for p in (rec.get("inat") or []) if inat_ok else []:
        if not p.get("url"):
            continue
        if p["photo"] in ev or p["photo"] in seen[u] or p["obs"] in seen_obs:
            continue
        if p["w"] and p["h"] and max(p["w"], p["h"]) / max(1, min(p["w"], p["h"])) > MAX_ASPECT:
            continue
        seen_obs.add(p["obs"])
        who = inat_name(p)
        cands.append({"field": True, "rank": 0 if p["grade"] == "research" else 2, "kind": KIND_INAT_GAP,
                      "pid": p["photo"], "photo_id": p["photo"], "image_id": "", "licence": p["licence"],
                      "by": who, "login": p.get("user"), "who_key": ("inat", p.get("user")),
                      "attribution": (f"{who}, CC0 (no rights reserved), via iNaturalist" if p["licence"] == "CC0"
                                      else f"© {who}, {SP.LIC_LABEL[p['licence']]}, via iNaturalist"),
                      "page_url": f"https://www.inaturalist.org/photos/{p['photo']}",
                      "obs_url": f"https://www.inaturalist.org/observations/{p['obs']}", "obs": p["obs"],
                      "url": p["url"].replace("/square.", "/medium."), "basis": "iNat " + p["grade"]})
    for p in ((rec.get("ala") or {}).get("photos") or []) if ala_ok else []:
        if "seed bank" in (p.get("by") or "").lower():
            p = dict(p, specimen=True)
        pid = ala_pid(p["image"])
        if pid in seen[u] or p["image"] in seen[u]:
            continue
        if p.get("w") and p.get("h") and (max(p["w"], p["h"]) < MIN_EDGE
                                          or max(p["w"], p["h"]) / max(1, min(p["w"], p["h"])) > MAX_ASPECT):
            continue
        cands.append({"field": not p["specimen"], "rank": 1 if not p["specimen"] else 3, "kind": KIND_ALA,
                      "pid": pid, "photo_id": pid, "image_id": p["image"], "licence": p["licence"],
                      "by": p["by"], "login": p["by"], "who_key": ("ala", p["by"]),
                      "attribution": p["attr"], "page_url": f"https://biocache.ala.org.au/occurrences/{p['occ']}",
                      "obs_url": f"https://biocache.ala.org.au/occurrences/{p['occ']}", "obs": p["occ"],
                      "url": "https://images-assets.ala.org.au/store/{0}/{1}/{2}/{3}/{4}/thumbnail_large".format(
                          p["image"][-1], p["image"][-2], p["image"][-3], p["image"][-4], p["image"]),
                      "basis": p["basis"]})
    cands.sort(key=lambda c: c["rank"])   # stable: source order within a rank
    # spread over photographers: a second photo by the same person goes after everyone's first
    for c in cands:
        c["dup"] = seen_who[c["who_key"]]
        seen_who[c["who_key"]] += 1
    field = sorted([c for c in cands if c["field"]], key=lambda c: (c["dup"] > 0, c["rank"]))
    spec = sorted([c for c in cands if not c["field"]], key=lambda c: c["dup"] > 0)
    nf = min(len(field), k if not spec else max(FIELD_MAX_WITH_SPECIMENS, k - len(spec)))
    return field[:nf] + spec[:k - nf], len(field), len(spec)


def cmd_fetch(a):
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq
    import build_refphotos_v2 as V
    L = labels()
    set_labels(L)
    ev = eval_ids(a)
    seen = shown_before()
    os.makedirs(IMG, exist_ok=True)
    os.makedirs(THUMB, exist_ok=True)
    recs = [SP.rjson(os.path.join(RAW, f)) for f in sorted(os.listdir(RAW)) if f.endswith(".json")]
    plan = {}
    for rec in recs:
        c, _, _ = choose(rec, ev, seen, POOL)
        plan[rec["u"]] = c
    jobs = []
    for u, cs in plan.items():
        for c in cs:
            c["local"] = os.path.join(IMG, f"{c['pid']}.jpg")
            jobs.append((c["pid"], c["url"], c["local"]))
    say(f"{len(plan):,} species, {len(jobs):,} candidate photos to have")
    t0, got, bad = time.time(), {}, collections.Counter()
    with cf.ThreadPoolExecutor(a.workers) as ex:
        for i, (key, size, st) in enumerate(ex.map(_fetch_threadsafe, jobs), 1):
            if size:
                got[key] = size
            else:
                bad[st.split(" ")[0] + (" " + st.split(" ")[1] if st.startswith("http") else "")] += 1
            if i % 1000 == 0:
                say(f"  {i:,}/{len(jobs):,} in {time.time() - t0:.0f} s")
    say(f"photos: {len(got):,} ok; failed {dict(bad)}")
    rows = []
    for u, cs in plan.items():
        ok = [c for c in cs if (wh := got.get(c["pid"])) and max(wh) >= MIN_EDGE
              and max(wh) / max(1, min(wh)) <= MAX_ASPECT]
        field = [c for c in ok if c["field"]]
        spec = [c for c in ok if not c["field"]]
        nf = min(len(field), K if not spec else max(FIELD_MAX_WITH_SPECIMENS, K - len(spec)))
        for k, c in enumerate(field[:nf] + spec[:K - nf]):
            wh = got[c["pid"]]
            rows.append({"u": u, "name": L[u]["name"], "cand": k, "kind": c["kind"], "pid": int(c["pid"]),
                         "photo_id": int(c["photo_id"]), "image_id": c["image_id"], "ext": "jpg",
                         "licence": c["licence"], "by": c["by"], "login": c["login"], "attribution": c["attribution"],
                         "page_url": c["page_url"], "obs_url": c["obs_url"], "local": c["local"], "w": wh[0],
                         "h": wh[1], "cos": np.nan, "probe": np.nan, "flagged": not c["field"], "tier": 0,
                         "obs": c["obs"], "v1": False, "basis": c["basis"]})
    jobs = [(r["local"], V.thumb_path(r["pid"])) for r in rows if not os.path.exists(V.thumb_path(r["pid"]))]
    from multiprocessing import Pool
    with Pool(os.cpu_count()) as pool:
        ok = pool.map(V._thumb, jobs, chunksize=32)
    say(f"thumbnails: {sum(ok):,} made, {len(ok) - sum(ok)} failed")
    rows = [r for r in rows if os.path.exists(V.thumb_path(r["pid"]))]
    assert not ({r["photo_id"] for r in rows if r["kind"] == KIND_INAT_GAP} & ev), "evaluation photo offered"
    old = {x for v in seen.values() for x in v if isinstance(x, int)}
    assert not ({r["pid"] for r in rows if r["kind"] == KIND_ALA} & old), "gap ALA pid collides with an old candidate"
    t = pa.Table.from_pylist(rows) if rows else pa.table({"u": pa.array([], pa.int64())})
    pq.write_table(t, CANDS)
    # provenance (CLAUDE.md: no output we can't regenerate): when, from what, with which rules
    import subprocess
    commit = subprocess.run(["git", "-C", HERE, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    raw_dates = sorted(time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(os.path.join(RAW, f))))
                       for f in os.listdir(RAW))
    SP.wjson(os.path.join(GAP, "run.json"), {
        "script": "pipeline/plantid/refphotos_gap.py", "commit": commit, "argv": sys.argv,
        "fetched": time.strftime("%Y-%m-%dT%H:%M:%S"), "lookups": [raw_dates[0], raw_dates[-1]] if raw_dates else None,
        "species": len(plan), "candidates": len(rows), "rules": {"K": K, "pool": POOL, "min_edge": MIN_EDGE,
                                                                 "max_aspect": MAX_ASPECT, "inat_licences": INAT_LIC,
                                                                 "ala_licences": sorted(SP.REF_OK)}})
    per = collections.Counter(collections.Counter(r["u"] for r in rows).values())
    say(f"gap/cands.parquet: {len(rows):,} candidates over {len({r['u'] for r in rows}):,} species; "
        f"per species {dict(sorted(per.items()))}; kinds {dict(collections.Counter(r['kind'] for r in rows))}")


_tl = threading.local()


def _fetch_threadsafe(job):
    """(key, url, dest) → (key, (w, h) or None, status); one keep-alive connection per thread."""
    if not hasattr(_tl, "ka"):
        _tl.ka = SP.KeepAlive()
    key, url, dest = job
    if os.path.exists(dest):
        from PIL import Image
        with Image.open(dest) as im:
            return key, im.size, "cached"
    st, raw = _tl.ka.get(url)
    if st != 200 or not raw.startswith(BR.MAGIC):
        return key, None, f"http {st}" if st != 200 else "not an image"
    try:
        body, size = SP.to_jpeg500(raw)
    except Exception as e:  # noqa: BLE001
        return key, None, f"decode {str(e)[:40]}"
    with open(dest + ".part", "wb") as f:
        f.write(body)
    os.replace(dest + ".part", dest)
    return key, size, "ok"


# ------------------------------------------------------------------ report

def cmd_report(a):
    L = labels()
    set_labels(L)
    index = json.load(open(a.index))["photos"]
    no_photo = json.load(open(NO_PHOTO)) if os.path.exists(NO_PHOTO) else {}
    us, rejected = targets(L, index, no_photo)
    tas = tas_species()
    ev = eval_ids(a)
    seen = shown_before()

    def first(u):
        p = os.path.join(RAW, f"{u:05d}.json")
        if not os.path.exists(p):
            return "not looked up"
        rec = SP.rjson(p)
        c, nf, ns = choose(rec, ev, seen)
        if not c:
            return "nothing licensed"
        top = c[0]
        if not top["field"]:
            return "specimen only"
        return {0: "iNat research grade", 1: "ALA field photo", 2: "iNat needs ID"}[top["rank"]]
    for title, S in (("all", us), ("Opus-rejected", [u for u in us if u in rejected]),
                     ("recorded in Tasmania", [u for u in us if u in tas])):
        c = collections.Counter(first(u) for u in S)
        say(f"{title}: {len(S):,} species — " + ", ".join(f"{k} {v:,}" for k, v in c.most_common()))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", choices=["find", "fetch", "report"])
    ap.add_argument("--index", default=PACK_INDEX, help="the current pack's index.json")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only-tas", action="store_true", help="only species with ALA records in Tasmania")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--test", action="store_true", help="no evaluation-id files needed (a dry run elsewhere)")
    a = ap.parse_args()
    os.makedirs(GAP, exist_ok=True)
    {"find": cmd_find, "fetch": cmd_fetch, "report": cmd_report}[a.stage](a)


if __name__ == "__main__":
    main()

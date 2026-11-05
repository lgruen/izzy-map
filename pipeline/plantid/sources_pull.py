#!/usr/bin/env python3
"""Pull the extra data sources Leo approved on 2026-11-05 (notes/photo_sources.md):

  counts         ALA occurrence COUNTS for the national location prior: one
                 biocache facet query per label (point-0.001), the filters of
                 build_records.py (CLAUDE.md "Atlas of Living Australia
                 occurrences") minus the Tasmania limits: kingdom Plantae,
                 ABSENT out, dataGeneralizations/sensitive out, fossils out,
                 coordinateUncertainty > 1 km out (missing kept), bbox = the
                 prior grid (lat −44…−9, lon 112…154). Query key = ALA's
                 `species` field (species-rank parent, like build_records); a
                 label with 0 records is re-tried with ALA name matching
                 (accepted name ≠ label → relation "ala-accepted").
                 Resumable: one gz JSON per label in sources/ala_counts/occ/.
  counts-table   → sources/ala_counts/ala_counts.parquet (u, cy, cx, n on the
                 0.05° prior grid, prior_v2.py `build --counts`) and
                 ala_points.parquet (u, lat, lon, n at 0.001°); whole-arc-minute
                 and 0.1°-grid points dropped (coarse georeferences).
  ala-list       labels with < 20 training photos: non-iNat FIELD photos
                 (basis HUMAN_OBSERVATION/OBSERVATION/MACHINE_OBSERVATION/
                 LIVING_SPECIMEN; NatureMapr dr19123 — no per-image licence —
                 and any iNaturalist resource excluded; no herbarium sheets)
                 ≤ 100 images per label → sources/ala_photos/recs/<u>.json
  ala-info       image licence/creator via getImageInfoForIdList → candidates
  ala-fetch      thumbnail_large (650 px) → EXIF-transposed, ≤ 500 px long
                 edge, JPEG q90 → sources/photos/ala/<imageId>.jpg + hashes
  commons-list   Wikidata (QLever mirror; WDQS was rate-limiting) P225 → P18,
                 P373 for ALL labels (crosswalk QID/APNI/GBIF/iNat saved);
                 Commons species category (+ one level of non-specimen
                 subcategories) + P18 files for labels with < 20 photos;
                 JPEG only, herbarium/illustration/map files out, iNat mirrors
                 out, CC/PD licences only, ≤ 100 per label
  commons-fetch  500 px thumbs → EXIF-transposed, JPEG q90 →
                 sources/photos/commons/<pageid>.jpg + hashes
  dedup          dedup.py stage 1 (pHash ≤ 8 AND dHash ≤ 10, calibration.json)
                 vs every evaluation photo, vs the iNat extra candidates, and
                 within → sources/extra_photos_sources.parquet (+ dropped)
                 with train_ok / ref_ok flags. Stage 2 (embedding cosine vs the
                 680k existing training photos) needs the cloud embeddings.

Licence rules (Leo, 2026-11-05): training = any CC (incl. SA/ND) or PD;
reference photo = CC0/PD/BY/BY-NC/BY-SA/BY-NC-SA (re-encoded), ND only
byte-for-byte (never here: we resize) → ref_ok False; APII (dr413) training
only until the ANBG curator confirms; a licence known only from the
occurrence record (image licence empty) → training only.

Env: uv run --with pillow --with imagehash --with numpy --with pyarrow \\
       python3 -I pipeline/plantid/sources_pull.py <cmd> [--limit N]
"""
import collections
import concurrent.futures as cf
import glob
import gzip
import html
import http.client
import io
import json
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
SRC = os.path.join(CACHE, "sources")
CNT = os.path.join(SRC, "ala_counts")
APH = os.path.join(SRC, "ala_photos")
CMS = os.path.join(SRC, "commons")
PH = os.path.join(SRC, "photos")
LABELS = os.path.join(CACHE, "ship", "au-labels.json")
UA = "izzymap-plantid-eval/1"
HDR = {"User-Agent": UA, "Accept-Encoding": "gzip"}
# Wikimedia throttles unidentified clients hard (429, Retry-After 600 on thumbnail
# misses at 3 workers, 2026-11-05): identify with the public repo URL (no email).
UA_WM = UA + " (https://github.com/lgruen/izzy-map; non-commercial research)"


def ua_for(url):
    return UA_WM if ("wikimedia.org" in url or "wikidata.org" in url) else UA
BIOCACHE = "https://biocache-ws.ala.org.au/ws/occurrences/search"
NAMEMATCH = "https://namematching-ws.ala.org.au/api/search?q="
FQ = ["kingdom:Plantae", "-occurrenceStatus:ABSENT", "-dataGeneralizations:*", "-sensitive:*",
      "-basisOfRecord:FOSSIL_SPECIMEN", "-coordinateUncertaintyInMeters:[1000.001 TO *]",
      "decimalLatitude:[-44.0 TO -9.0] AND decimalLongitude:[112.0 TO 154.0]"]
NOINAT = "--noinat" in sys.argv  # variant: ALA's iNaturalist Australia copy (dr1411) excluded
if NOINAT:  # (it leaks iNat val/test observations into the prior)
    FQ = FQ + ["-data_resource_uid:dr1411"]
SUF = "_noinat" if NOINAT else ""
FQ_SIG = "|".join(FQ)
EXCL_DR = {"dr1411": "iNaturalist Australia", "dr19123": "NatureMapr (no per-image licence)"}
APII = "dr413"
FIELD_BOR = ("HUMAN_OBSERVATION", "OBSERVATION", "MACHINE_OBSERVATION", "LIVING_SPECIMEN")
TOTAL = 1000  # Leo: ≤ 1,000 training photos per label over ALL sources; non-iNat first


def room(train_photos):
    """Non-iNat photos a label may take: TOTAL minus its existing training photos."""
    return max(0, TOTAL - int(train_photos))
EDGE = 500
for d in (CNT, APH, CMS, PH):
    os.makedirs(d, exist_ok=True)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def labels():
    return json.load(open(LABELS))["labels"]


def http_get(url, timeout=120, tries=4, data=None, headers=None):
    h = dict(HDR, **{"User-Agent": ua_for(url)})
    h.update(headers or {})
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=h)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                b = r.read()
                if r.headers.get("Content-Encoding") == "gzip":
                    b = gzip.decompress(b)
                return b
        except urllib.error.HTTPError as e:
            if e.code in (400, 403, 404, 410) or i == tries - 1:
                raise
            time.sleep(5 * (i + 1) * (6 if e.code == 429 else 1))
        except Exception:  # noqa: BLE001
            if i == tries - 1:
                raise
            time.sleep(5 * (i + 1))


def getj(url, **kw):
    return json.loads(http_get(url, **kw))


def wjson(path, obj, gz=False):
    tmp = path + ".part"
    b = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
    with open(tmp, "wb") as f:
        f.write(gzip.compress(b) if gz else b)
    os.replace(tmp, path)


def rjson(path):
    with open(path, "rb") as f:
        b = f.read()
    return json.loads(gzip.decompress(b) if path.endswith(".gz") else b)


def search(fq, **params):
    q = [("q", "*:*")] + [("fq", f) for f in fq] + list(params.items())
    d = getj(BIOCACHE + "?" + urllib.parse.urlencode(q))
    if d.get("status") not in (None, "OK"):
        raise RuntimeError(f"ALA error {d.get('status')} {d.get('errorMessage')}")
    return d


_nm_lock = threading.Lock()


def namematch(name):
    """ALA name matching (cached): accepted species-rank name or None."""
    path = os.path.join(CNT, "namematch.json")
    with _nm_lock:
        cache = rjson(path) if os.path.exists(path) else {}
    if name in cache:
        return cache[name]
    try:
        d = getj(NAMEMATCH + urllib.parse.quote(name))
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)[:80]}
    r = {"success": d.get("success"), "scientificName": d.get("scientificName"), "rank": d.get("rank"),
         "matchType": d.get("matchType"), "speciesName": d.get("species"),
         "taxonConceptID": d.get("taxonConceptID"), "issues": d.get("issues")}
    with _nm_lock:
        cache = rjson(path) if os.path.exists(path) else {}
        cache[name] = r
        wjson(path, cache)
    return r


# ------------------------------------------------------------------ counts
def count_one(u, name):
    path = os.path.join(CNT, "occ" + SUF, f"{u:05d}.json.gz")
    if os.path.exists(path):
        return False
    rel, qn = "exact", name
    main = os.path.join(CNT, "occ", f"{u:05d}.json.gz")
    if NOINAT and os.path.exists(main):  # same query name as the main pull (no fresh name matching)
        m = rjson(main)
        rel, qn = m["relation"], m["query"]
    d = search(FQ + [f'species:"{qn}"'], pageSize=0, facets="point-0.001,dataResourceUid", flimit=-1)
    nm = None
    if d["totalRecords"] == 0 and not (NOINAT and os.path.exists(main)):
        nm = namematch(name)
        alt = nm.get("speciesName") if nm and nm.get("success") else None
        if alt and alt != name:
            rel, qn = "ala-accepted", alt
            d = search(FQ + [f'species:"{alt}"'], pageSize=0, facets="point-0.001,dataResourceUid", flimit=-1)
        else:
            rel = "none"
    fac = {f["fieldName"]: f["fieldResult"] for f in d.get("facetResults", [])}
    pts = {x["label"]: x["count"] for x in fac.get("point-0.001", []) if x["label"] != "Not supplied"}
    dr = {}
    for x in fac.get("dataResourceUid", []):
        m = re.search(r'"(dr\d+)"', x.get("fq", ""))
        dr[m.group(1) if m else x["label"]] = x["count"]
    out = {"fq": FQ_SIG, "u": u, "name": name, "query": qn, "relation": rel, "total": d["totalRecords"],
           "points": pts, "dr": dr, "namematch": nm, "complete": sum(pts.values()) == d["totalRecords"]}
    wjson(path, out, gz=True)
    return True


def cmd_counts(limit=None):
    os.makedirs(os.path.join(CNT, "occ" + SUF), exist_ok=True)
    L = labels()
    todo = [(u, l["name"]) for u, l in enumerate(L)
            if not os.path.exists(os.path.join(CNT, "occ" + SUF, f"{u:05d}.json.gz"))]
    if limit:
        todo = todo[:limit]
    log(f"counts: {len(L) - len(todo) if not limit else '?'} cached, {len(todo)} to fetch, 3 workers")
    t0, done, err = time.time(), [0], []

    def one(a):
        try:
            count_one(*a)
        except Exception as e:  # noqa: BLE001
            err.append((a, str(e)[:120]))
        done[0] += 1
        if done[0] % 250 == 0:
            el = time.time() - t0
            log(f"  {done[0]}/{len(todo)} in {el:.0f} s ({el / done[0]:.2f} s/label wall), errors {len(err)}")
    with cf.ThreadPoolExecutor(3) as ex:
        list(ex.map(one, todo))
    log(f"counts done: {done[0]} in {time.time() - t0:.0f} s, errors {len(err)}")
    if err:
        wjson(os.path.join(CNT, f"errors{SUF}.json"), err)


def on_minute(k):
    import numpy as np
    k = np.asarray(k, dtype=np.int64)
    m = np.rint(k * 60 / 1000).astype(np.int64)
    return np.abs(60 * k - 1000 * m) <= 30


def cmd_counts_table(limit=None):
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq
    L = labels()
    files = sorted(glob.glob(os.path.join(CNT, "occ" + SUF, "*.json.gz")))
    U, LA, LO, N = [], [], [], []
    rel, incomplete, zero, by_query = collections.Counter(), [], 0, collections.defaultdict(list)
    for f in files:
        d = rjson(f)
        assert d["fq"] == FQ_SIG
        rel[d["relation"]] += 1
        if not d["complete"]:
            incomplete.append(d["name"])
        if d["total"] == 0:
            zero += 1
        by_query[d["query"]].append(d["u"])
        for lab, n in d["points"].items():
            la, lo = lab.split(",")
            U.append(d["u"]); LA.append(round(float(la) * 1000)); LO.append(round(float(lo) * 1000)); N.append(n)
    U, LA, LO, N = (np.array(x, np.int64) for x in (U, LA, LO, N))
    minute = on_minute(LA) & on_minute(LO)
    deci = (LA % 100 == 0) & (LO % 100 == 0)
    drop = minute | deci
    k = ~drop
    pq.write_table(pa.table({"u": U[k], "lat": LA[k] / 1000.0, "lon": LO[k] / 1000.0, "n": N[k]}),
                   os.path.join(CNT, f"ala_points{SUF}.parquet"))
    cy = np.floor_divide(LA[k] + 44000, 50)
    cx = np.floor_divide(LO[k] - 112000, 50)
    key = (cy * 1000 + cx) * 100000 + U[k]
    uk, inv = np.unique(key, return_inverse=True)
    n = np.bincount(inv, weights=N[k]).astype(np.int64)
    pq.write_table(pa.table({"u": uk % 100000, "cy": (uk // 100000) // 1000, "cx": (uk // 100000) % 1000, "n": n}),
                   os.path.join(CNT, f"ala_counts{SUF}.parquet"))
    shared = {q: us for q, us in by_query.items() if len(us) > 1}
    summ = {"labels_queried": len(files), "labels_total": len(L), "relation": rel, "labels_zero_records": zero,
            "labels_with_records": len(files) - zero, "incomplete_facets": incomplete[:50],
            "points": int(len(U)), "records": int(N.sum()), "dropped_minute_grid_points": int(minute.sum()),
            "dropped_deci_grid_points": int((deci & ~minute).sum()),
            "dropped_records": int(N[drop].sum()), "kept_records": int(N[k].sum()),
            "cells_x_classes": int(len(uk)),
            "labels_sharing_an_ala_species": {q: [L[u]["name"] for u in us] for q, us in list(shared.items())[:200]},
            "n_shared_queries": len(shared), "filters": FQ, "accessed": time.strftime("%Y-%m-%d")}
    wjson(os.path.join(CNT, f"summary{SUF}.json"), summ)
    print(json.dumps({k2: v for k2, v in summ.items() if k2 not in ("labels_sharing_an_ala_species",)}, indent=1,
                     default=int)[:3000])


# ------------------------------------------------------------------ licences
def norm_lic(s):
    """Licence string/URL → code (CC0, PD, CC-BY, CC-BY-NC, CC-BY-SA,
    CC-BY-NC-SA, CC-BY-ND, CC-BY-NC-ND) or None (not CC/PD/unknown)."""
    if not s:
        return None
    t = s.lower().replace("_", "-").replace(" ", "-")
    if "publicdomain/zero" in t or t.startswith("cc0") or "cc-0" in t or "cc-by-0" in t or "cc0" in t:
        return "CC0"
    if "publicdomain/mark" in t or "public-domain" in t or t in ("pd", "no-restrictions") or t.startswith("pd-"):
        return "PD"
    m = re.search(r"licenses/(by(?:-nc)?(?:-sa|-nd)?)/", t)
    if m:
        return "CC-" + m.group(1).upper()
    m = re.search(r"(?:^|[^a-z])(?:cc-)?(by(?:-nc)?(?:-sa|-nd)?)(?:-\d|$|[^a-z])", t)
    if m and ("cc" in t or "creative" in t or "attribution" in t):
        return "CC-" + m.group(1).upper()
    if "attribution" in t:
        code = "CC-BY"
        if "noncommercial" in t or "non-commercial" in t:
            code += "-NC"
        if "sharealike" in t or "share-alike" in t:
            code += "-SA"
        if "noderiv" in t or "no-deriv" in t:
            code += "-ND"
        return code
    return None


REF_OK = {"CC0", "PD", "CC-BY", "CC-BY-NC", "CC-BY-SA", "CC-BY-NC-SA"}
LIC_LABEL = {"CC0": "CC0", "PD": "public domain", "CC-BY": "CC BY", "CC-BY-NC": "CC BY-NC",
             "CC-BY-SA": "CC BY-SA", "CC-BY-NC-SA": "CC BY-NC-SA", "CC-BY-ND": "CC BY-ND",
             "CC-BY-NC-ND": "CC BY-NC-ND"}


# ------------------------------------------------------------------ ALA photos
def ala_target_labels():
    """Every label (Leo, 2026-11-05), most-needed first (0, 1–9, 10–19, rest)."""
    L = labels()
    b = lambda n: 0 if n == 0 else 1 if n < 10 else 2 if n < 20 else 3  # noqa: E731
    return sorted(((u, l["name"]) for u, l in enumerate(L)), key=lambda a: (b(L[a[0]]["train_photos"]), a[0]))


def ala_list_one(u, name):
    path = os.path.join(APH, "recs", f"{u:05d}.json")
    want = room(labels_cache()[u]["train_photos"])
    if os.path.exists(path):
        d = rjson(path)
        n_img = sum(len(r.get("images") or []) for r in d["recs"])
        # first run stopped at 300 images / 1,000 records; redo only if that cut it short
        cpath = os.path.join(CNT, "occ" + SUF, f"{u:05d}.json.gz")
        stale = os.path.exists(cpath) and rjson(cpath)["query"] != d["query"]  # listed before name matching
        if not stale and (d.get("full") or d["total"] <= len(d["recs"]) or n_img >= want):
            return False
    qn = name
    cpath = os.path.join(CNT, "occ" + SUF, f"{u:05d}.json.gz")
    if os.path.exists(cpath):
        c = rjson(cpath)
        if c["relation"] == "ala-accepted":
            qn = c["query"]
    fq = [f'species:"{qn}"', "multimedia:Image",
          "basis_of_record:(" + " OR ".join(FIELD_BOR) + ")",
          "-data_resource_uid:(" + " OR ".join(EXCL_DR) + ")"]
    recs, start, total = [], 0, None
    while True:
        d = search(fq, pageSize=100, startIndex=start, sort="id", dir="asc")
        total = d["totalRecords"]
        for o in d.get("occurrences", []):
            drn = o.get("dataResourceName") or ""
            if "inaturalist" in drn.lower():
                continue
            recs.append({k: o.get(k) for k in ("uuid", "dataResourceUid", "dataResourceName", "basisOfRecord",
                                                "images", "license", "decimalLatitude", "decimalLongitude",
                                                "eventDate", "recordedBy", "scientificName", "raw_scientificName",
                                                "occurrenceID")})
        start += 100  # pageSize 300 answers 503 (nginx, 2026-11-05)
        if start >= total or sum(len(r.get("images") or []) for r in recs) >= want + 200:
            break
    wjson(path, {"u": u, "name": name, "query": qn, "total": total, "recs": recs, "full": True})
    return True


def cmd_ala_list(limit=None):
    os.makedirs(os.path.join(APH, "recs"), exist_ok=True)
    todo = [a for a in ala_target_labels() if not os.path.exists(os.path.join(APH, "recs", f"{a[0]:05d}.json"))]
    if limit:
        todo = todo[:limit]
    todo = [a for a in ala_target_labels() if not os.path.exists(os.path.join(APH, "recs", f"{a[0]:05d}.json"))
            or not rjson(os.path.join(APH, "recs", f"{a[0]:05d}.json")).get("full")]
    if limit:
        todo = todo[:limit]
    log(f"ala-list: {len(todo)} labels to (re)check (2 workers)")
    t0, err, cnt = time.time(), [], [0]

    def one(a):
        try:
            ala_list_one(*a)
        except Exception as e:  # noqa: BLE001
            err.append((a, str(e)[:120]))
        cnt[0] += 1
        if cnt[0] % 500 == 0:
            log(f"  {cnt[0]}/{len(todo)} in {time.time() - t0:.0f} s, errors {len(err)}")
    with cf.ThreadPoolExecutor(2) as ex:
        list(ex.map(one, todo))
    log(f"ala-list done in {time.time() - t0:.0f} s, errors {len(err)}")
    if err:
        wjson(os.path.join(APH, "list_errors.json"), err)


def cmd_ala_info(limit=None):
    """Pick ≤ room(label) images per label (APII first, then others, record order),
    fetch per-image metadata, write candidates."""
    import pyarrow as pa
    import pyarrow.parquet as pq
    L = labels()
    want = []
    drn = {}
    for f in sorted(glob.glob(os.path.join(APH, "recs", "*.json"))):
        d = rjson(f)
        imgs = []
        for r in d["recs"]:
            drn[r["dataResourceUid"]] = r["dataResourceName"]
            for i, im in enumerate(r.get("images") or []):
                imgs.append((0 if r["dataResourceUid"] == APII else 1, i, im, r))
        imgs.sort(key=lambda x: (x[0], x[1]))
        for k, (_, _, im, r) in enumerate(imgs[:room(L[d["u"]]["train_photos"])]):
            want.append((d["u"], d["name"], d["query"], k, im, r))
    if limit:
        want = want[:limit]
    ipath = os.path.join(APH, "imageinfo.json")
    info = rjson(ipath) if os.path.exists(ipath) else {}
    need = sorted({w[4] for w in want} - set(info))
    log(f"ala-info: {len(want)} images over {len({w[0] for w in want})} labels; {len(need)} infos to fetch")
    for k in range(0, len(need), 100):
        chunk = need[k:k + 100]
        d = getj("https://images.ala.org.au/ws/getImageInfoForIdList",
                 data=json.dumps({"imageIds": chunk}).encode(), headers={"Content-Type": "application/json"})
        for i in chunk:
            m = (d.get("results") or {}).get(i)
            info[i] = {x: (m or {}).get(x) for x in ("license", "creator", "rightsHolder", "rights", "title",
                                                     "width", "height", "imageUrl", "mimetype")} if m else None
        if (k // 100) % 50 == 0:
            wjson(ipath, info)
            log(f"  {k + len(chunk)}/{len(need)}")
        time.sleep(0.2)
    wjson(ipath, info)
    rows = []
    for u, name, qn, k, im, r in want:
        m = info.get(im) or {}
        lic_img = norm_lic(m.get("license"))
        lic_rec = norm_lic(r.get("license"))
        lic, lic_src = (lic_img, "image") if lic_img else (lic_rec, "record") if lic_rec else (None, None)
        who = m.get("creator") or m.get("rightsHolder") or ", ".join(r.get("recordedBy") or []) or None
        if who in ("not_supplied", ""):
            who = None
        dr = r["dataResourceUid"]
        train_ok = lic is not None
        ref_ok = bool(lic in REF_OK and lic_src == "image" and dr != APII and who)
        note = ("APII: training only until the ANBG curator confirms" if dr == APII else
                "licence from the occurrence record, not the image" if lic_src == "record" else
                "ND: byte-for-byte only" if lic and "ND" in lic else
                "no creator to attribute" if lic and not who else None)
        lat, lon = r.get("decimalLatitude"), r.get("decimalLongitude")
        rows.append({"u": u, "name": name, "source": "ala-field", "image_id": im, "ext": "jpg",
                     "observation_uuid": r.get("uuid"), "data_resource": dr, "dr_name": drn.get(dr),
                     "basis": r.get("basisOfRecord"), "login": who,
                     "license": lic, "licence_source": lic_src, "licence_raw": m.get("license") or r.get("license"),
                     "attribution": (f"© {who}, {LIC_LABEL[lic]}, via {drn.get(dr)} (Atlas of Living Australia)"
                                     if lic and who else None),
                     "url": f"https://images.ala.org.au/image/{im}",
                     "src_url": None, "page_url": f"https://biocache.ala.org.au/occurrences/{r.get('uuid')}",
                     "rk": k + 1, "ntr": L[u]["train_photos"], "lat": lat, "lon": lon,
                     "observed_on": (time.strftime("%Y-%m-%d", time.gmtime(r["eventDate"] / 1000))
                                     if isinstance(r.get("eventDate"), (int, float)) else None),
                     "name_relation": "exact" if qn == name else "ala-accepted", "query_name": qn,
                     "w": m.get("width"), "h": m.get("height"), "train_ok": train_ok, "ref_ok": ref_ok,
                     "ref_note": note})
    pq.write_table(pa.Table.from_pylist(rows), os.path.join(APH, "candidates.parquet"))
    c = collections.Counter((r["license"], r["licence_source"]) for r in rows)
    log(f"candidates: {len(rows)}, labels {len({r['u'] for r in rows})}, train_ok {sum(r['train_ok'] for r in rows)}, "
        f"ref_ok {sum(r['ref_ok'] for r in rows)}; licences {c.most_common(12)}")


# ------------------------------------------------------------------ fetch + hash
class KeepAlive:
    def __init__(self, min_interval=0.0):
        self.c = {}
        self.min_interval = min_interval
        self.last = 0.0

    def get(self, url, timeout=60):
        p = urllib.parse.urlsplit(url)
        if self.min_interval:
            time.sleep(max(0.0, self.last + self.min_interval - time.time()))
            self.last = time.time()
        for i in range(4):
            conn = self.c.get(p.netloc)
            if conn is None:
                conn = self.c[p.netloc] = http.client.HTTPSConnection(p.netloc, timeout=timeout)
            try:
                conn.request("GET", p.path + ("?" + p.query if p.query else ""), headers={"User-Agent": ua_for(url)})
                r = conn.getresponse()
                b = r.read()
                if r.status == 429:
                    ra = r.getheader("Retry-After")
                    wait = min(int(ra), 900) if ra and ra.isdigit() else 60 * (i + 1)
                    log(f"  429 from {p.netloc}, waiting {wait} s")
                    time.sleep(wait)
                    continue
                if r.status in (301, 302, 303, 307, 308):
                    return self.get(urllib.parse.urljoin(url, r.getheader("Location")), timeout)
                if r.status == 429 or r.status >= 500:
                    time.sleep(10 * (i + 1))
                    continue
                return r.status, b
            except Exception:  # noqa: BLE001
                conn.close()
                self.c.pop(p.netloc, None)
                time.sleep(3 * (i + 1))
        return -1, b""


def to_jpeg500(body):
    from PIL import Image, ImageOps
    im = Image.open(io.BytesIO(body))
    im = ImageOps.exif_transpose(im)
    if im.mode != "RGB":
        im = im.convert("RGB")
    if max(im.size) > EDGE:
        im.thumbnail((EDGE, EDGE), Image.LANCZOS)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=90, optimize=True)
    return out.getvalue(), im.size


def fetch_hash(items, outdir, part_prefix, workers, min_interval=0.0):
    """items: [(key, url)] → photos/<outdir>/<key>.jpg + hash parts."""
    import dedup
    import pyarrow as pa
    import pyarrow.parquet as pq
    os.makedirs(os.path.join(PH, outdir), exist_ok=True)
    done = set()
    for f in glob.glob(os.path.join(SRC, f"{part_prefix}-part*.parquet")):
        done |= set(pq.read_table(f, columns=["key"]).column(0).to_pylist())
    todo = [x for x in items if x[0] not in done]
    log(f"fetch {outdir}: {len(done)} done, {len(todo)} to fetch, {workers} workers")
    tl = threading.local()
    lock = threading.Lock()
    recs = []
    part = [len(glob.glob(os.path.join(SRC, f"{part_prefix}-part*.parquet")))]
    t0 = time.time()
    n = [0]

    def flush():
        if recs:
            pq.write_table(pa.Table.from_pylist(recs, schema=pa.schema([
                ("key", pa.string()), ("status", pa.string()), ("bytes", pa.int64()), ("w", pa.int32()),
                ("h", pa.int32()), ("phash", pa.uint64()), ("dhash", pa.uint64()), ("local_path", pa.string())])),
                os.path.join(SRC, f"{part_prefix}-part{part[0]:04d}.parquet"))
            part[0] += 1
            recs.clear()

    def one(x):
        key, url = x
        if not hasattr(tl, "ka"):
            tl.ka = KeepAlive(min_interval)
        path = os.path.join(PH, outdir, f"{key}.jpg")
        rec = {"key": key, "status": "ok", "bytes": None, "w": None, "h": None, "phash": None, "dhash": None,
               "local_path": None}
        try:
            if os.path.exists(path):
                body = open(path, "rb").read()
                from PIL import Image
                size = Image.open(io.BytesIO(body)).size
            else:
                st, raw = tl.ka.get(url)
                if st != 200 or not raw.startswith(dedup.MAGIC):
                    rec["status"] = f"http {st}" if st != 200 else "not an image"
                    raw = None
                if raw is not None:
                    body, size = to_jpeg500(raw)
                    with open(path + ".part", "wb") as f:
                        f.write(body)
                    os.replace(path + ".part", path)
            if rec["status"] == "ok":
                rec.update(dedup.hashes(body))
                rec.update(bytes=len(body), w=size[0], h=size[1], local_path=path)
        except Exception as e:  # noqa: BLE001
            rec["status"] = "error " + str(e)[:60]
        with lock:
            recs.append(rec)
            n[0] += 1
            if len(recs) >= 1000:
                flush()
            if n[0] % 2000 == 0:
                el = time.time() - t0
                log(f"  {n[0]}/{len(todo)} in {el:.0f} s ({n[0] / el:.1f}/s)")
    with cf.ThreadPoolExecutor(workers) as ex:
        list(ex.map(one, todo))
    with lock:
        flush()
    log(f"fetch {outdir} done: {n[0]} in {time.time() - t0:.0f} s")


def cmd_ala_fetch(limit=None):
    import pyarrow.parquet as pq
    C = pq.read_table(os.path.join(APH, "candidates.parquet"), columns=["image_id", "train_ok", "ntr", "rk"]).to_pydict()
    need = {}  # most-needed first: 0, 1–9, 10–19, rest; then rank within the label
    for i, ok, n, r in zip(C["image_id"], C["train_ok"], C["ntr"], C["rk"]):
        if ok:
            need[i] = min(need.get(i, (9, 0)), (0 if n == 0 else 1 if n < 10 else 2 if n < 20 else 3, r))
    ids = sorted(need, key=lambda i: (need[i], i))
    if limit:
        ids = ids[:limit]
    # images.ala.org.au store path: /store/<last 4 hex chars reversed>/<id>/thumbnail_large
    # The CDN host first (measured 2026-11-05: ~half are cache hits at ~0.09 s; misses 302 back to
    # images.ala.org.au?nr, ~0.3–0.6 s). Latency-bound, no 429/503 seen: 6 → 12 → 16 workers gave
    # 20 → 40 → 52 /s with flat latency. ALA publishes no image rate limit; 12 = a modest choice.
    items = [(i, f"https://images-assets.ala.org.au/store/{i[-1]}/{i[-2]}/{i[-3]}/{i[-4]}/{i}/thumbnail_large")
             for i in ids]
    fetch_hash(items, "ala", "ala_photos/hashes", workers=12)


# ------------------------------------------------------------------ Commons
QLEVER = "https://qlever.dev/api/wikidata"
WDQS = "https://query.wikidata.org/sparql"
CAPI = "https://commons.wikimedia.org/w/api.php?"
BAD = re.compile(r"herbari|specimen|illustrat|drawing|\bplate\b|tafel|\bmap\b|distribution|range map|botanical art|"
                 r"diagram|\bscan|stamp|\blabel|\btype\b|holotype|isotype|lectotype|syntype|sketch|painting|"
                 r"engraving|lithograph|watercolou?r|botanical magazine|flora .*plate|seed bank|pollen|microscop|"
                 r"\bsem\b|logo|icon", re.I)


def capi(params, tries=4):
    params = dict(params, format="json", formatversion=2, maxlag=5)
    for i in range(tries):  # POST: 50 long file titles overflow a GET URL (414)
        d = getj(CAPI.rstrip("?"), data=urllib.parse.urlencode(params).encode(),
                 headers={"Content-Type": "application/x-www-form-urlencoded"})
        if d.get("error", {}).get("code") == "maxlag":
            time.sleep(5 * (i + 1))
            continue
        return d
    return d


def cmd_commons_list(limit=None):
    L = labels()
    wpath = os.path.join(CMS, "wikidata.json")
    wd = rjson(wpath) if os.path.exists(wpath) else {}
    names = [l["name"] for l in L if l["name"] not in wd]
    log(f"wikidata: {len(wd)} cached, {len(names)} to query")
    for k in range(0, len(names), 250):
        chunk = names[k:k + 250]
        vals = " ".join('"%s"' % n.replace('"', "") for n in chunk)
        q = f"""PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        SELECT ?name ?item ?img ?cat ?gbif ?inat ?apni WHERE {{ VALUES ?name {{ {vals} }} ?item wdt:P225 ?name .
          OPTIONAL {{ ?item wdt:P18 ?img }} OPTIONAL {{ ?item wdt:P373 ?cat }} OPTIONAL {{ ?item wdt:P846 ?gbif }}
          OPTIONAL {{ ?item wdt:P3151 ?inat }} OPTIONAL {{ ?item wdt:P5984 ?apni }} }}"""
        try:  # WDQS (answering again after the 2026-11-05 outage rule), QLever mirror as fallback
            d = getj(WDQS + "?" + urllib.parse.urlencode({"query": q}),
                     headers={"Accept": "application/sparql-results+json"}, tries=2)
        except Exception:  # noqa: BLE001
            d = getj(QLEVER + "?" + urllib.parse.urlencode({"query": q}),
                     headers={"Accept": "application/sparql-results+json"}, tries=10)
        for n in chunk:
            wd.setdefault(n, {"item": [], "img": [], "cat": [], "gbif": [], "inat": [], "apni": []})
        for b in d["results"]["bindings"]:
            e = wd[b["name"]["value"]]
            for kk in ("item", "img", "cat", "gbif", "inat", "apni"):
                if kk in b and b[kk]["value"] not in e[kk]:
                    e[kk].append(b[kk]["value"])
        wjson(wpath, wd)
        time.sleep(2)  # QLever answered 429 to back-to-back heavy queries
    log(f"wikidata: {sum(1 for v in wd.values() if v['item'])} of {len(L)} names have an item")
    # Leo (2026-11-05): every label, no per-label cap
    targets = [(u, l["name"]) for u, l in enumerate(L)]
    if limit:
        targets = targets[:limit]
    # category existence + file counts
    cpath = os.path.join(CMS, "categories.json")
    cats = rjson(cpath) if os.path.exists(cpath) else {}
    titles = {}
    for u, n in targets:
        c = (wd.get(n) or {}).get("cat") or []
        titles[u] = "Category:" + (c[0] if c else n)
    need = sorted({t for t in titles.values() if t not in cats})
    log(f"categories: {len(need)} to check")
    for k in range(0, len(need), 50):
        d = capi({"action": "query", "prop": "categoryinfo", "titles": "|".join(need[k:k + 50])})
        norm = {x["from"]: x["to"] for x in d["query"].get("normalized", [])}
        byt = {p["title"]: p for p in d["query"]["pages"]}
        for t in need[k:k + 50]:
            p = byt.get(norm.get(t, t), {})
            ci = p.get("categoryinfo") or {}
            cats[t] = {"files": ci.get("files", 0), "subcats": ci.get("subcats", 0), "missing": bool(p.get("missing"))}
        if (k // 50) % 20 == 0:
            wjson(cpath, cats)
    wjson(cpath, cats)
    # members: files of the species category + one level of non-specimen subcategories
    mpath = os.path.join(CMS, "members.json")
    mem = rjson(mpath) if os.path.exists(mpath) else {}
    # entries from the first (capped) listing: redo those the caps could have cut
    for t in [t for t, v in mem.items() if not v.get("full") and
              (len(v["files"]) >= 500 or len([x for x in v["subcats"] if not BAD.search(x)]) > 8)]:
        del mem[t]
    todo = sorted({t for t in titles.values() if t not in mem and not cats[t]["missing"]
                   and (cats[t]["files"] or cats[t]["subcats"])})
    log(f"members: {len(todo)} categories to list (3 workers, all non-specimen subcategories one level deep)")
    t0 = time.time()
    lock = threading.Lock()
    cnt = [0]

    def members(t):
        files, subs = [], []
        cont = {}
        while True:
            d = capi(dict({"action": "query", "list": "categorymembers", "cmtitle": t, "cmtype": "file|subcat",
                           "cmlimit": 500}, **cont))
            for m in d["query"]["categorymembers"]:
                (subs if m["ns"] == 14 else files).append(m["title"])
            if "continue" in d:
                cont = d["continue"]
            else:
                break
        for sc in [x for x in subs if not BAD.search(x)]:
            cont = {}
            while True:
                d = capi(dict({"action": "query", "list": "categorymembers", "cmtitle": sc, "cmtype": "file",
                               "cmlimit": 500}, **cont))
                files += [m["title"] for m in d["query"]["categorymembers"]]
                if "continue" not in d:
                    break
                cont = d["continue"]
        with lock:
            mem[t] = {"files": files, "subcats": subs, "full": True}
            cnt[0] += 1
            if cnt[0] % 200 == 0:
                wjson(mpath, mem)
                log(f"  {cnt[0]}/{len(todo)} in {time.time() - t0:.0f} s")
    with cf.ThreadPoolExecutor(3) as ex:
        list(ex.map(members, todo))
    wjson(mpath, mem)
    # candidate files per label: P18 first, then category files
    want = {}
    for u, n in targets:
        fl = [("File:" + urllib.parse.unquote(x.rsplit("/", 1)[-1])) for x in (wd.get(n) or {}).get("img", [])]
        fl += (mem.get(titles[u]) or {}).get("files", [])
        seen, out = set(), []
        for f in fl:
            f = f.replace("_", " ")
            if f not in seen and not BAD.search(f) and re.search(r"\.jpe?g$", f, re.I):
                seen.add(f)
                out.append(f)
        if out:
            want[u] = out
    allf = sorted({f for v in want.values() for f in v})
    ipath = os.path.join(CMS, "imageinfo.json")
    info = rjson(ipath) if os.path.exists(ipath) else {}
    need = [f for f in allf if f not in info]
    log(f"imageinfo: {len(allf)} files over {len(want)} labels, {len(need)} to fetch")
    for k in range(0, len(need), 50):
        d = capi({"action": "query", "prop": "imageinfo", "iiprop": "extmetadata|size|url|mime|sha1",
                  "iiurlwidth": EDGE, "titles": "|".join(need[k:k + 50]),
                  "iiextmetadatafilter": "LicenseShortName|LicenseUrl|Artist|Credit|ImageDescription|Categories|"
                                         "UsageTerms|AttributionRequired|DateTimeOriginal|GPSLatitude|GPSLongitude"})
        norm = {x["from"]: x["to"] for x in d["query"].get("normalized", [])}
        byt = {p["title"]: p for p in d["query"]["pages"]}
        for f in need[k:k + 50]:
            p = byt.get(norm.get(f, f), {})
            ii = (p.get("imageinfo") or [None])[0]
            if not ii:
                info[f] = None
                continue
            em = {kk: (v or {}).get("value") for kk, v in (ii.get("extmetadata") or {}).items()}
            info[f] = {"pageid": p.get("pageid"), "sha1": ii.get("sha1"), "w": ii.get("width"), "h": ii.get("height"), "mime": ii.get("mime"),
                       "url": ii.get("url"), "thumb": ii.get("thumburl"), "page": ii.get("descriptionurl"), **em}
        if (k // 50) % 20 == 0:
            wjson(ipath, info)
            log(f"  {k + 50}/{len(need)}")
    wjson(ipath, info)
    # candidates
    import pyarrow as pa
    import pyarrow.parquet as pq

    def strip(h):
        return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", h or ""))).strip()
    rows, reasons = [], collections.Counter()
    for u, fl in want.items():
        rk = 0
        for f in fl:
            m = info.get(f)
            if not m or m.get("mime") != "image/jpeg" or not m.get("thumb"):
                reasons["not a jpeg / gone"] += 1
                continue
            blob = " ".join(str(m.get(x) or "") for x in ("Categories", "ImageDescription", "Credit"))
            if BAD.search(m.get("Categories") or "") or re.search(r"herbari|specimen", blob, re.I):
                reasons["herbarium/illustration/map"] += 1
                continue
            mi = re.search(r"inaturalist\.org/(?:photos|observations)/(\d+)", blob, re.I)
            if mi or "inaturalist" in blob.lower():
                reasons["iNaturalist mirror"] += 1
                continue
            lic = norm_lic(m.get("LicenseShortName")) or norm_lic(m.get("LicenseUrl"))
            if not lic:
                reasons[f"licence not CC/PD: {(m.get('LicenseShortName') or '')[:20]}"] += 1
                continue
            if min(m.get("w") or 0, m.get("h") or 0) < 200:
                reasons["too small"] += 1
                continue
            rk += 1
            who = strip(m.get("Artist"))[:120] or None
            rows.append({"u": u, "name": labels_cache()[u]["name"], "source": "commons",
                         "image_id": str(m["pageid"]), "ext": "jpg", "observation_uuid": None,
                         "data_resource": "commons", "dr_name": "Wikimedia Commons", "basis": "commons",
                         "login": who, "license": lic, "licence_source": "image",
                         "licence_raw": m.get("LicenseShortName"),
                         "attribution": f"{'© ' + who + ', ' if who and lic not in ('PD', 'CC0') else (who + ', ' if who else '')}"
                                        f"{LIC_LABEL[lic]}, via Wikimedia Commons",
                         "url": m["thumb"], "src_url": m["url"], "page_url": m["page"], "rk": rk,
                         "ntr": labels_cache()[u]["train_photos"], "lat": _f(m.get("GPSLatitude")),
                         "lon": _f(m.get("GPSLongitude")), "observed_on": (m.get("DateTimeOriginal") or "")[:10] or None,
                         "name_relation": "wikidata-p225" if f in [("File:" + urllib.parse.unquote(x.rsplit('/', 1)[-1])).replace("_", " ")
                                                                  for x in (wd.get(labels_cache()[u]['name']) or {}).get('img', [])]
                         else "commons-category", "query_name": titles[u],
                         "w": m.get("w"), "h": m.get("h"), "train_ok": True,
                         "ref_ok": bool(lic in REF_OK and who), "ref_note": None if who else "no author to attribute",
                         "title": f})
    pq.write_table(pa.Table.from_pylist(rows), os.path.join(CMS, "candidates.parquet"))
    log(f"commons candidates: {len(rows)} over {len({r['u'] for r in rows})} labels; skipped {reasons.most_common(12)}; "
        f"licences {collections.Counter(r['license'] for r in rows).most_common()}")


_LC = []


def labels_cache():
    if not _LC:
        _LC.append(labels())
    return _LC[0]


def _f(x):
    try:
        return float(x)
    except Exception:  # noqa: BLE001
        return None


def cmd_commons_fetch(limit=None):
    import pyarrow.parquet as pq
    C = pq.read_table(os.path.join(CMS, "candidates.parquet"), columns=["image_id", "url", "ntr", "rk", "u"]).to_pydict()
    # the 1,000-per-label total: Commons takes what ALA leaves of room(label)
    n_ala = collections.Counter()
    ap = os.path.join(APH, "candidates.parquet")
    if os.path.exists(ap):
        A = pq.read_table(ap, columns=["u", "train_ok"]).to_pydict()
        n_ala.update(u for u, ok in zip(A["u"], A["train_ok"]) if ok)
    L = labels()
    keep = [r <= room(L[u]["train_photos"]) - n_ala[u] for u, r in zip(C["u"], C["rk"])]
    C = {k: [x for x, m in zip(v, keep) if m] for k, v in C.items()}
    # most-needed first: labels with 0 training photos, then 1–9, 10–19, the rest; rank within
    need = {}
    for i, u, n, r in zip(C["image_id"], C["url"], C["ntr"], C["rk"]):
        b = 0 if n == 0 else 1 if n < 10 else 2 if n < 20 else 3
        need[(i, u)] = min(need.get((i, u), (9, 0)), (b, r))
    items = sorted(need, key=lambda x: (need[x], x[0]))
    if limit:
        items = items[:limit]
    items = [(k, re.sub(r"\?utm_[^#]*$", "", u)) for k, u in items]
    # Wikimedia robot policy (wikitech Robot_policy, read 2026-11-05): total
    # concurrency ≤ 2, ≤ 25 Mbps, identifying UA, standard thumbnail sizes (500)
    # total ≤ 2 across Wikimedia: 1 fetch worker while a commons-list (API) job runs, else 2
    busy = os.popen("pgrep -f 'sources_pull.py commons-list'").read().strip()
    fetch_hash(items, "commons", "commons/hashes", workers=1 if busy else 2)


# ------------------------------------------------------------------ dedup
def cmd_dedup(limit=None):
    import numpy as np
    import pandas as pd
    import pyarrow.parquet as pq
    import dedup
    W = os.path.join(CACHE, "extra", "work")
    th = json.load(open(os.path.join(W, "calibration.json")))["chosen"]
    tp, td = th["phash"], th["dhash"]

    def parts(pat):
        fs = sorted(glob.glob(pat))
        return pd.concat([pq.read_table(f).to_pandas() for f in fs]) if fs else pd.DataFrame()
    frames = []
    for cand, hp in ((os.path.join(APH, "candidates.parquet"), os.path.join(APH, "hashes-part*.parquet")),
                     (os.path.join(CMS, "candidates.parquet"), os.path.join(CMS, "hashes-part*.parquet"))):
        if not os.path.exists(cand):
            continue
        C = pq.read_table(cand).to_pandas()
        H = parts(hp).drop_duplicates("key", keep="last").rename(columns={"key": "image_id"})
        C = C.merge(H, on="image_id", how="left", suffixes=("", "_img"))
        frames.append(C)
    X = pd.concat(frames, ignore_index=True)
    X["fetched"] = X["status"].eq("ok")
    dropped = [X[~X["fetched"] & X["train_ok"]].assign(reason="not fetched: " + X["status"].fillna("not attempted"))]
    # Site photos: habitat-restoration / nest-box projects attach ONE site photo to every species
    # recorded there (eyeballed 2026-11-05: paddocks, tree guards, forest views). Resources where
    # > 20 % of images sit under several species are dropped whole; any image filed under several
    # labels is dropped everywhere (which species would it show?).
    nlab = X.groupby("image_id")["u"].nunique()
    X["multi"] = X["image_id"].map(nlab) > 1
    share = X[X["source"].eq("ala-field")].groupby("data_resource")["multi"].mean()
    site = set(share[share > 0.2].index)
    log(f"site-photo resources dropped: {len(site)}; images under several labels: {int(X['multi'].sum())}")
    bad = X["data_resource"].isin(site) | X["multi"]
    dropped.append(X[bad].assign(reason=np.where(X[bad]["data_resource"].isin(site), "site-photo resource",
                                                 "same image filed under several species")))
    X = X[~bad & X["fetched"]].copy()
    # rank for keeping one of near-identical copies: label, reference-eligible first (a CC BY Commons
    # copy of an APII photo beats the training-only APII row), then ALA before Commons, then rank
    X["src_order"] = X["source"].map({"ala-field": 0, "commons": 1})
    X["nref"] = ~X["ref_ok"]
    X = X.sort_values(["u", "nref", "src_order", "rk"]).reset_index(drop=True)
    E = parts(os.path.join(W, "hashes-eval-part*.parquet"))
    E = E[E["status"].eq("ok")]
    I = parts(os.path.join(W, "hashes-cand-part*.parquet"))
    I = I[I["status"].eq("ok")]
    pc, dc = X["phash"].astype("uint64").to_numpy(), X["dhash"].astype("uint64").to_numpy()
    t = time.time()
    he, je = dedup.near_any(pc, dc, E["phash"].to_numpy(), E["dhash"].to_numpy(), tp, td)
    log(f"vs eval ({len(E):,}): {he.sum()} hits, {time.time() - t:.0f} s")
    t = time.time()
    hi, ji = dedup.near_any(pc, dc, I["phash"].to_numpy(), I["dhash"].to_numpy(), tp, td)
    log(f"vs iNat extras ({len(I):,}): {hi.sum()} hits, {time.time() - t:.0f} s")
    hw, jw = dedup.near_within(pc, dc, tp, td)
    log(f"within: {hw.sum()} hits")
    X["dup_eval"] = he
    X["dup_eval_photo_id"] = np.where(he, E["photo_id"].to_numpy()[np.maximum(je, 0)], -1)
    X["dup_inat_extra_photo_id"] = np.where(hi, I["photo_id"].to_numpy()[np.maximum(ji, 0)], -1)
    X["dup_within"] = np.where(hw, X["image_id"].to_numpy()[np.maximum(jw, 0)], None)
    # near-identical copies under DIFFERENT labels: drop the whole group (union-find over the pairs)
    par = np.arange(len(X))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a
    for i in np.flatnonzero(hw):
        ra, rb = find(i), find(jw[i])
        if ra != rb:
            par[max(ra, rb)] = min(ra, rb)
    root = np.array([find(i) for i in range(len(X))])
    nl = pd.Series(X["u"].to_numpy()).groupby(root).nunique()
    cross = nl.reindex(root).to_numpy() > 1
    log(f"near-identical photos across labels: {int(cross.sum())}")
    reason = np.where(he, "near-duplicate of an evaluation photo",
                      np.where(hi, "near-duplicate of an iNat extra photo",
                               np.where(cross, "near-identical photo under several species",
                                        np.where(hw, "near-duplicate within ALA/Commons", ""))))
    X["reason"] = reason
    dropped.append(X[reason != ""])
    K = X[reason == ""].copy()
    K = K[K["train_ok"] | K["ref_ok"]]
    # the 1,000-per-label total (existing training photos count against it; iNat extras fill what is left)
    Lb = labels()
    K = K.sort_values(["u", "src_order", "rk"])  # the total keeps ALA (new photographers) before Commons
    over = K.groupby("u").cumcount().to_numpy() >= np.array([room(Lb[u]["train_photos"]) for u in K["u"]])
    D2 = K[over].assign(reason="over the 1,000-per-label total")
    K = K[~over]
    dropped.append(D2)
    D = pd.concat(dropped, ignore_index=True)
    K = K.drop(columns=["status", "fetched", "src_order", "reason", "nref", "multi"], errors="ignore")
    K["k"] = K.groupby("u").cumcount() + 1
    K["via_name_map"] = False
    K["grade"] = K["basis"]
    K.to_parquet(os.path.join(SRC, "extra_photos_sources.parquet"), index=False)
    D.to_parquet(os.path.join(SRC, "dropped_sources.parquet"), index=False)
    L = labels()
    ntr = np.array([l["train_photos"] for l in L])

    def bucket(n):
        return "0" if n == 0 else "1-19" if n < 20 else "20+"
    summ = {"kept": len(K), "dropped": D["reason"].value_counts().to_dict(),
            "by_source": K["source"].value_counts().to_dict(),
            "by_source_train_ok": K[K["train_ok"]]["source"].value_counts().to_dict(),
            "by_source_ref_ok": K[K["ref_ok"]]["source"].value_counts().to_dict(),
            "by_licence": K["license"].value_counts().to_dict(),
            "by_resource": K["dr_name"].value_counts().head(25).to_dict(),
            "labels_gaining_train": {b: int(len({u for u in K[K["train_ok"]]["u"] if bucket(ntr[u]) == b}))
                                     for b in ("0", "1-19")},
            "labels_gaining_train_ge5": {b: int(sum(1 for u, c in K[K["train_ok"]].groupby("u").size().items()
                                                    if bucket(ntr[u]) == b and c >= 5)) for b in ("0", "1-19")},
            "labels_gaining_ref": {b: int(len({u for u in K[K["ref_ok"]]["u"] if bucket(ntr[u]) == b}))
                                   for b in ("0", "1-19")},
            "thresholds": th, "disk_bytes": int(K["bytes"].sum()),
            "note": "stage 1 only (hashes vs eval, iNat extras, within); stage 2 = embedding cosine vs the 680k "
                    "existing training photos after the cloud embedding (their hashes were never computed)"}
    wjson(os.path.join(SRC, "extra_photos_sources-summary.json"), summ)
    print(json.dumps(summ, indent=1, default=int))


# ------------------------------------------------------------------ generalised supplement
FQ_GEN = ["kingdom:Plantae", "-occurrenceStatus:ABSENT", "-basisOfRecord:FOSSIL_SPECIMEN",
          "sensitive:* OR dataGeneralizations:*",
          "decimalLatitude:[-44.0 TO -9.0] AND decimalLongitude:[112.0 TO 154.0]"] + (
              ["-data_resource_uid:dr1411"] if NOINAT else [])


def cmd_counts_generalised(limit=None):
    """OPTIONAL supplement, not part of ala_counts.parquet: for labels with NO
    record under the standard filters (mostly threatened species whose ALA
    points are generalised to ~10 km or withheld), their generalised/sensitive
    records only → ala_counts_generalised.parquet (u, cy, cx, n). ~10 km
    accuracy is coarse for 100 m TASVEG joins (why build_records drops them)
    but on the scale of a 0.05° prior with a 10–25 km kernel."""
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq
    zero = []
    for f in sorted(glob.glob(os.path.join(CNT, "occ" + SUF, "*.json.gz"))):
        d = rjson(f)
        if d["total"] == 0:
            zero.append((d["u"], d["query"]))
    if limit:
        zero = zero[:limit]
    os.makedirs(os.path.join(CNT, "gen" + SUF), exist_ok=True)

    def one(a):
        u, qn = a
        path = os.path.join(CNT, "gen" + SUF, f"{u:05d}.json.gz")
        if os.path.exists(path):
            return
        d = search(FQ_GEN + [f'species:"{qn}"'], pageSize=0, facets="point-0.001", flimit=-1)
        pts = {x["label"]: x["count"] for f in d.get("facetResults", []) for x in f["fieldResult"]
               if x["label"] != "Not supplied"}
        wjson(path, {"u": u, "query": qn, "total": d["totalRecords"], "points": pts}, gz=True)
    t0 = time.time()
    with cf.ThreadPoolExecutor(3) as ex:
        list(ex.map(one, zero))
    U, CY, CX, N = [], [], [], []
    got = 0
    for u, _ in zero:
        d = rjson(os.path.join(CNT, "gen" + SUF, f"{u:05d}.json.gz"))
        got += d["total"] > 0
        for lab, n in d["points"].items():
            la, lo = (round(float(x) * 1000) for x in lab.split(","))
            U.append(u); CY.append((la + 44000) // 50); CX.append((lo - 112000) // 50); N.append(n)
    U, CY, CX, N = (np.array(x, np.int64) for x in (U, CY, CX, N))
    key = (CY * 1000 + CX) * 100000 + U
    uk, inv = np.unique(key, return_inverse=True)
    n = np.bincount(inv, weights=N).astype(np.int64)
    pq.write_table(pa.table({"u": uk % 100000, "cy": (uk // 100000) // 1000, "cx": (uk // 100000) % 1000, "n": n}),
                   os.path.join(CNT, f"ala_counts_generalised{SUF}.parquet"))
    log(f"generalised supplement: {len(zero)} zero labels queried in {time.time() - t0:.0f} s, {got} have "
        f"generalised records ({int(N.sum())} records, {len(uk)} cell×class pairs)")


if __name__ == "__main__":
    lim = None
    sys.argv = [a for a in sys.argv if a != "--noinat"]
    if "--limit" in sys.argv:
        lim = int(sys.argv[sys.argv.index("--limit") + 1])
    {"counts": cmd_counts, "counts-table": cmd_counts_table, "ala-list": cmd_ala_list, "ala-info": cmd_ala_info,
     "ala-fetch": cmd_ala_fetch, "commons-list": cmd_commons_list, "commons-fetch": cmd_commons_fetch,
     "dedup": cmd_dedup, "counts-generalised": cmd_counts_generalised}[sys.argv[1]](lim)

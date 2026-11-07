#!/usr/bin/env python3
"""Do herbarium SHEETS help name FIELD photos of species without training photos?
(Leo approved the test 2026-11-07; notes/photo_sources.md: ALA holds sheets for
~57 % of the photo-less labels, GBIF's overseas herbaria for more.)

Classes (fixed by hash, final-cb50-s1 head and its training counts):
  Z  every class with NO training photo that has AU-test photos (the CLEAN check:
     those photos come from held-out observers; ~75 classes)
  S  300 classes with ≥ 20 training photos and AU-val/AU-test photos — a
     SIMULATED photo-less set: their head rows are replaced, their field photos
     are never used (leak caveat as zeroshot_rows.py: the other rows saw S's
     photos as negatives). Split by hash into S-tune and S-report.
  F  600 classes with ≥ 50 training photos (not S): fit a map from a class's
     sheets (+ text, + genus shift) to its trained row.
Sheets: ALA biocache, basis PRESERVED_SPECIMEN with images, iNat resources out,
≤ 16 per Z/S class, ≤ 8 per F class; ALA's 650 px "large" thumbnail → JPEG
≤ 500 px (sources_pull.fetch_hash, same hosts/workers as the field pull).
Licences: herbaria CC BY 4.0 (NSW, BRI…) or BY-NC-SA (MEL…) — training only;
nothing is redistributed. Embedded with the SHIPPED w8 Core ML encoder and the
production preprocessing (build_ship.preprocess).

Rows for a replaced class (then scale-kept τ-norm 0.5, main prior λ 1, as
zeroshot_rows.py):
  text      s0 · t_c                                (today)
  genus     s0 · (t_c + mean Δ of trained congeners)   (zeroshot_rows' winner)
  sheets    s0 · α · unit(mean centred sheet embedding)
  map       s0 · (t_c + Δ̂), Δ̂ = ridge([t_c, sheet proto, genus Δ]) fitted on F
  blend     s0 · unit((1 − γ) · genus row + γ · sheet proto) · α
α, β (bias), γ, ridge λ chosen on S-tune per-species top-1 (+ the rest of
AU-val); reported on S-report (AU-val ∪ AU-test photos) and Z (AU-test).

  select | list | fetch | embed | eval      (or `all`)
Env: uv run --python 3.12 --with 'torch==2.7.*' --with 'numpy<2.3' --with pyarrow
     --with pillow --with imagehash --with coremltools python3 -I pipeline/plantid/herbarium_test.py all
"""
import concurrent.futures as cf
import glob
import hashlib
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
V2 = os.path.join(CACHE, "australia", "v2")
OUT = os.path.join(CACHE, "herbarium")
RUN = "final-cb50-s1"
N_S, N_F, PER_ZS, PER_F = 300, 600, 16, 8
# sheet source: "ala" (images.ala.org.au — its sheet thumbnails timed out with HTTP 504 on
# 2026-11-07) or "gbif" (GBIF occurrence search + GBIF's image cache, incl. overseas herbaria)
SRC = os.environ.get("HB_SRC", "gbif")
RECS = os.path.join(OUT, "recs" if SRC == "ala" else "recs-gbif")
PHOTO_DIR = "herbarium" if SRC == "ala" else "herbarium-gbif"
TN = 0.5


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def h01(s):
    return int.from_bytes(hashlib.sha256(s.encode()).digest()[:4], "big") / 2 ** 32


def unit(x):
    return x / np.linalg.norm(x, axis=-1, keepdims=True).clip(1e-9)


def taunorm(W, tn=TN):
    nr = np.linalg.norm(W, axis=-1, keepdims=True).clip(1e-6)
    return W * (nr.mean() / nr) ** tn


def cmd_select():
    import pyarrow.parquet as pq
    os.makedirs(OUT, exist_ok=True)
    n = np.load(os.path.join(V2, "runs", RUN + ".npz"))["n_c"]
    Zs = np.load(os.path.join(V2, "bank_analysis", "sets.npz"), allow_pickle=True)
    yt, yv = Zs["AU-test/y"], Zs["AU-val/y"]
    merged = np.load(os.path.join(V2, "head_capacity", "vm", "val.npz"))["cm"] < -1
    names = pq.read_table(os.path.join(CACHE, "australia", "labels.parquet"), columns=["name"]).column(0).to_pylist()
    in_t = np.zeros(len(n), bool)
    in_t[yt[yt >= 0]] = True
    in_v = np.zeros(len(n), bool)
    in_v[yv[yv >= 0]] = True
    Z = np.where((n == 0) & in_t & ~merged)[0]
    cand = np.where((n >= 20) & (in_t | in_v) & ~merged)[0]
    S = sorted(cand, key=lambda c: h01(f"hS{c}"))[:N_S]
    candF = np.setdiff1d(np.where((n >= 50) & ~merged)[0], S)
    F = sorted(candF, key=lambda c: h01(f"hF{c}"))[:N_F]
    sel = {"Z": [int(c) for c in Z], "S": [int(c) for c in S], "F": [int(c) for c in F],
           "names": {int(c): names[c] for c in list(Z) + list(S) + list(F)}}
    json.dump(sel, open(os.path.join(OUT, "classes.json"), "w"), indent=1)
    log(f"Z {len(Z)}, S {len(S)}, F {len(F)}")


def cmd_list():
    import sources_pull as SP
    sel = json.load(open(os.path.join(OUT, "classes.json")))
    rd = os.path.join(OUT, "recs")
    os.makedirs(rd, exist_ok=True)
    todo = [(c, PER_ZS) for c in sel["Z"] + sel["S"]] + [(c, PER_F) for c in sel["F"]]

    def one(a):
        c, k = a
        p = os.path.join(rd, f"{c:05d}.json")
        if os.path.exists(p):
            return
        name = sel["names"][str(c)]
        qn = name
        cp = os.path.join(SP.CNT, "occ", f"{c:05d}.json.gz")
        if os.path.exists(cp):
            cc = SP.rjson(cp)
            if cc.get("relation") == "ala-accepted":
                qn = cc["query"]
        fq = [f'species:"{qn}"', "multimedia:Image", "basis_of_record:PRESERVED_SPECIMEN",
              "-data_resource_uid:dr1411"]
        d = SP.search(fq, pageSize=100, startIndex=0, sort="id", dir="asc")
        imgs = []
        for o in d.get("occurrences", []):
            if "inaturalist" in (o.get("dataResourceName") or "").lower():
                continue
            for im in (o.get("images") or [])[:1]:  # one sheet per specimen
                imgs.append({"image_id": im, "dr": o.get("dataResourceUid"), "drn": o.get("dataResourceName"),
                             "occ": o.get("uuid"), "license": o.get("license")})
        # spread over herbaria/records deterministically, ≤ k
        imgs.sort(key=lambda r: h01(r["image_id"]))
        SP.wjson(p, {"u": c, "name": name, "query": qn, "total": d.get("totalRecords"), "images": imgs[:k]})
    t0 = time.time()
    with cf.ThreadPoolExecutor(3) as ex:
        list(ex.map(one, todo))
    have = [json.load(open(f)) for f in glob.glob(os.path.join(rd, "*.json"))]
    got = {g: sum(1 for h in have if h["u"] in set(sel[g]) and h["images"]) for g in ("Z", "S", "F")}
    log(f"list done in {time.time() - t0:.0f} s; classes with ≥ 1 sheet: {got}; "
        f"images {sum(len(h['images']) for h in have)}")


def cmd_select_ship():
    """Every class still WITHOUT a training photo after the rare-heldout move (and not
    merged) → classes-ship.json (as group "Z"); `HB_CLASSES=classes-ship.json` makes
    list/fetch/embed work on it (recs and photos shared with the test)."""
    import pyarrow.parquet as pq
    n = np.load(os.path.join(V2, "runs", RUN + ".npz"))["n_c"].copy()
    merged = np.load(os.path.join(V2, "head_capacity", "vm", "val.npz"))["cm"] < -1
    ex = pq.read_table(os.path.join(CACHE, "rare_heldout", "extras.parquet"), columns=["u"]).column(0).to_numpy()
    n += np.bincount(ex, minlength=len(n))
    names = pq.read_table(os.path.join(CACHE, "australia", "labels.parquet"), columns=["name"]).column(0).to_pylist()
    Z = np.where((n == 0) & ~merged)[0]
    json.dump({"Z": [int(c) for c in Z], "S": [], "F": [], "names": {int(c): names[c] for c in Z}},
              open(os.path.join(OUT, "classes-ship.json"), "w"), indent=1)
    log(f"ship: {len(Z)} classes without a training photo after the move")


def cmd_list_gbif():
    """GBIF: strict name match (kingdom Plantae; synonyms → accepted key), then
    occurrence search basisOfRecord PRESERVED_SPECIMEN + StillImage (300 per page,
    one page), one CC/PD-licensed image per specimen, iNat datasets out, spread over
    institutions (round-robin), ≤ k per class. Image key g<occurrence key>-<md5(url)>."""
    import hashlib as H
    import urllib.parse
    import sources_pull as SP
    sel = json.load(open(os.path.join(OUT, os.environ.get("HB_CLASSES", "classes.json"))))
    os.makedirs(RECS, exist_ok=True)
    todo = [(c, PER_ZS) for c in sel["Z"] + sel["S"]] + [(c, PER_F) for c in sel["F"]]
    st = {"no_match": 0, "no_images": 0}

    def one(a):
        c, k = a
        p = os.path.join(RECS, f"{c:05d}.json")
        if os.path.exists(p):
            return
        name = sel["names"][str(c)]
        m = SP.getj("https://api.gbif.org/v1/species/match?" + urllib.parse.urlencode(
            {"name": name, "kingdom": "Plantae", "strict": "true"}))
        key = m.get("acceptedUsageKey") or m.get("usageKey")
        imgs = []
        if key and m.get("rank") in ("SPECIES", "SUBSPECIES", "VARIETY", "FORM"):
            d = SP.getj("https://api.gbif.org/v1/occurrence/search?" + urllib.parse.urlencode(
                {"taxonKey": key, "mediaType": "StillImage", "basisOfRecord": "PRESERVED_SPECIMEN", "limit": 300}))
            by_inst = {}
            for r in d.get("results", []):
                if "inaturalist" in (r.get("datasetName") or "").lower():
                    continue
                for med in r.get("media") or []:
                    url, lic = med.get("identifier") or "", (med.get("license") or r.get("license") or "")
                    if med.get("type") not in (None, "StillImage") or not url:
                        continue
                    if not any(x in lic.lower() for x in ("creativecommons", "cc0", "cc_by", "cc-by", "publicdomain")):
                        continue
                    md5 = H.md5(url.encode()).hexdigest()
                    by_inst.setdefault(r.get("institutionCode") or "?", []).append(
                        {"image_id": f"g{r['key']}-{md5}", "occ": r["key"], "url": url, "md5": md5, "license": lic,
                         "inst": r.get("institutionCode"), "dataset": r.get("datasetName"), "country": r.get("country")})
                    break  # one sheet per specimen
            # round-robin over institutions (deterministic order) → spread
            queues = [sorted(v, key=lambda x: h01(x["image_id"])) for _, v in sorted(by_inst.items())]
            while len(imgs) < k and any(queues):
                for q in queues:
                    if q and len(imgs) < k:
                        imgs.append(q.pop(0))
        else:
            st["no_match"] += 1
        if not imgs:
            st["no_images"] += 1
        SP.wjson(p, {"u": c, "name": name, "gbif_key": key, "match": m.get("matchType"), "images": imgs})
    t0 = time.time()
    err = []

    def safe(a_):  # GBIF answered 429 at 3 workers (2026-11-08): 1 worker, pause, skip + retry later
        try:
            one(a_)
        except Exception as e:  # noqa: BLE001
            err.append((a_[0], str(e)[:80]))
            time.sleep(30)
        time.sleep(float(os.environ.get("HB_PAUSE", 0.5)))
    with cf.ThreadPoolExecutor(int(os.environ.get("HB_WORKERS", 1))) as ex:
        list(ex.map(safe, todo))
    if err:
        log(f"gbif list: {len(err)} classes failed (re-run to retry): {err[:5]}")
    have = [json.load(open(f)) for f in glob.glob(os.path.join(RECS, "*.json"))]
    got = {g: sum(1 for h in have if h["u"] in set(sel[g]) and h["images"]) for g in ("Z", "S", "F")}
    log(f"gbif list done in {time.time() - t0:.0f} s ({st}); classes with ≥ 1 sheet: {got}; "
        f"images {sum(len(h['images']) for h in have)}")


def cmd_fetch():
    import sources_pull as SP
    recs = [im for f in glob.glob(os.path.join(RECS, "*.json")) for im in json.load(open(f))["images"]]
    if SRC == "ala":
        ids = sorted({im["image_id"] for im in recs})
        items = [(i, f"https://images-assets.ala.org.au/store/{i[-1]}/{i[-2]}/{i[-3]}/{i[-4]}/{i}/thumbnail_large")
                 for i in ids]
        SP.fetch_hash(items, PHOTO_DIR, "herbarium-hashes", workers=12)
    else:  # GBIF's image cache (resized copies; measured 2–5 s per uncached image)
        items = sorted({(im["image_id"], f"https://api.gbif.org/v1/image/cache/fit-in/500x/occurrence/"
                                         f"{im['occ']}/media/{im['md5']}") for im in recs})
        SP.fetch_hash(items, PHOTO_DIR, "herbarium-gbif-hashes", workers=8)


def cmd_embed():
    import coremltools as ct
    import build_ship as BS
    import sources_pull as SP
    ids = sorted({im["image_id"] for f in glob.glob(os.path.join(RECS, "*.json"))
                  for im in json.load(open(f))["images"]})
    paths = [(i, os.path.join(SP.PH, PHOTO_DIR, f"{i}.jpg")) for i in ids]
    paths = [(i, p) for i, p in paths if os.path.exists(p)]
    out = os.path.join(OUT, f"emb-{SRC}.npz")
    done = {}
    if os.path.exists(out):
        z = np.load(out)
        done = dict(zip(z["image_id"].tolist(), z["emb"]))
    todo = [(i, p) for i, p in paths if i not in done]
    m = ct.models.MLModel(os.path.join(BS.SHIP, "encoder", "PlantEncoder-w8.mlpackage"),
                          compute_units=ct.ComputeUnit.ALL)
    log(f"embed: {len(todo)} sheets (w8 Core ML), {len(done)} cached")
    t0 = time.time()
    with cf.ThreadPoolExecutor(4) as pool:
        for k in range(0, len(todo), 512):
            chunk = todo[k:k + 512]
            for (i, _), x in zip(chunk, pool.map(lambda ip: BS.preprocess(ip[1]), chunk)):
                done[i] = m.predict({"pixel_values": x})["embedding"].reshape(-1).astype(np.float32)
            np.savez(out + ".tmp.npz", image_id=np.array(list(done)), emb=np.stack(list(done.values())))
            os.replace(out + ".tmp.npz", out)
            log(f"  {k + len(chunk)}/{len(todo)} ({(time.time() - t0) / (k + len(chunk)):.3f} s/sheet)")


def cmd_eval():
    import torch
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    sel = json.load(open(os.path.join(OUT, "classes.json")))
    r = np.load(os.path.join(V2, "runs", RUN + ".npz"))
    W0, b0, n = r["W"].astype(np.float32), r["b"].astype(np.float32), r["n_c"]
    D = np.load(os.path.join(V2, "data-final.npz"), mmap_mode="r")
    T, s0, genus, mu = D["T"].astype(np.float32), float(D["s0"]), D["genus"], D["mu"].astype(np.float32)
    C = len(n)
    z = np.load(os.path.join(V2, "head_capacity", "vm", "val.npz"))
    cm, lam = z["cm"], float(z["lam"])
    Zs = np.load(os.path.join(V2, "bank_analysis", "sets.npz"), allow_pickle=True)
    # evaluation photos: AU-val (prior from head_capacity's pack) + AU-test (bank_analysis prior)
    qv = z["AU-val/q"].astype(np.float32)
    Pv = np.load(os.path.join(V2, "head_capacity", "vm", "prior-main-AU-val.npy"), mmap_mode="r")
    qt = unit(unit(Zs["AU-test/emb"].astype(np.float32)) - mu)
    Pt = np.load(os.path.join(V2, "bank_analysis", "prior-main-AU-test.npy"), mmap_mode="r")
    sets = {"val": (qv, z["AU-val/y"], Pv), "test": (qt, Zs["AU-test/y"], Pt)}
    # sheet prototypes (centred like photos)
    E = np.load(os.path.join(OUT, f"emb-{SRC}.npz"))
    emb = dict(zip(E["image_id"].tolist(), unit(unit(E["emb"]) - mu)))
    proto, nsh = np.zeros_like(T), np.zeros(C, int)
    for f in glob.glob(os.path.join(RECS, "*.json")):
        d = json.load(open(f))
        v = [emb[im["image_id"]] for im in d["images"] if im["image_id"] in emb]
        if v:
            proto[d["u"]] = unit(np.mean(v, 0))
            nsh[d["u"]] = len(v)
    Z = np.array([c for c in sel["Z"] if nsh[c]])
    S = np.array([c for c in sel["S"] if nsh[c]])
    F = np.array([c for c in sel["F"] if nsh[c]])
    St = np.array([c for c in S if h01(f"st{c}") < 0.5])
    Sr = np.setdiff1d(S, St)
    log(f"with sheets: Z {len(Z)}/{len(sel['Z'])}, S {len(S)} (tune {len(St)}, report {len(Sr)}), "
        f"F {len(F)}; median sheets per class {int(np.median(nsh[nsh > 0]))}")
    # how close are sheets to the class's own trained row / field photos? (F)
    Delta = W0 / s0 - T
    fit = np.setdiff1d(np.where((n >= 10) & (cm > -1))[0], S)
    G = genus.max() + 1
    gs, gc = np.zeros((G, T.shape[1]), np.float32), np.zeros(G)
    np.add.at(gs, genus[fit], Delta[fit])
    np.add.at(gc, genus[fit], 1)
    gm = np.where(gc[:, None] > 0, gs / np.maximum(gc, 1)[:, None], Delta[fit].mean(0))
    genus_row = unit(T + gm[genus])
    cosF = (unit(W0[F]) * proto[F]).sum(1)
    cosFt = (unit(W0[F]) * unit(T[F])).sum(1)
    log(f"F: cos(trained row, sheet proto) {cosF.mean():.3f}; cos(trained row, text) {cosFt.mean():.3f}")

    def ridge(X, Y, l):
        return np.linalg.solve(X.T @ X + l * np.eye(X.shape[1], dtype=np.float32), X.T @ Y)

    def feats(cl):
        return np.concatenate([T[cl], proto[cl], gm[genus[cl]]], 1)
    # ridge λ by an inner split of F (cosine of predicted vs true Δ)
    fa = F[[h01(f"fa{c}") < 0.8 for c in F]]
    fb = np.setdiff1d(F, fa)
    cosr = {}
    for l in (1.0, 10.0, 100.0, 1000.0):
        pr = feats(fb) @ ridge(feats(fa), Delta[fa], l)
        cosr[l] = float(((unit(pr)) * unit(Delta[fb])).sum(1).mean())
    lr = max(cosr, key=cosr.get)
    A = ridge(feats(F), Delta[F], lr)
    log(f"map: ridge λ {lr} (inner cos {cosr})")

    def rows(kind, cl, alpha, gamma):
        if kind == "text":
            return alpha * T[cl]
        if kind == "genus":
            return alpha * (T[cl] + gm[genus[cl]])
        if kind == "sheets":
            return alpha * proto[cl]
        if kind == "map":
            return alpha * (T[cl] + feats(cl) @ A)
        if kind == "blend":
            return alpha * unit((1 - gamma) * genus_row[cl] + gamma * proto[cl]) * \
                np.linalg.norm(T[cl] + gm[genus[cl]], axis=1, keepdims=True)
        raise ValueError(kind)
    Wcache = {}

    def run(kind, alpha, beta, gamma, rep, nm):
        W, b = W0.copy(), b0.copy()
        W[rep] = s0 * rows(kind, rep, alpha, gamma)
        b[rep] = beta
        q, y, P = sets[nm]
        key = (kind, alpha, beta, gamma, tuple(rep[:3]), len(rep))
        if key not in Wcache:
            Wcache.clear()
            Wcache[key] = (torch.from_numpy(taunorm(W)).to(dev), torch.from_numpy(b + cm).to(dev))
        Wt, bt = Wcache[key]
        top = []
        for i in range(0, len(q), 4096):
            L = torch.log_softmax(torch.from_numpy(q[i:i + 4096]).to(dev) @ Wt.T + bt, 1) + \
                lam * torch.from_numpy(np.asarray(P[i:i + 4096], np.float32)).to(dev)
            top.append(L.topk(5, 1).indices.cpu().numpy())
        return np.concatenate(top), y

    def sp(top, y, grp, k=1):
        m = np.isin(y, grp)
        if not m.any():
            return None
        h = (top[m, :k] == y[m, None]).any(1)
        _, inv = np.unique(y[m], return_inverse=True)
        return float((np.bincount(inv, h) / np.bincount(inv)).mean())

    def rest(top, y, excl):
        m = (y >= 0) & ~np.isin(y, excl)
        return sp(top, y, np.unique(y[m]))
    grid = []
    for kind, alphas, gammas in (("text", (1.0, 1.15, 1.3), (0,)), ("genus", (1.0, 1.15, 1.3), (0,)),
                                 ("sheets", (0.8, 1.0, 1.15, 1.3), (0,)), ("map", (1.0, 1.15, 1.3), (0,)),
                                 ("blend", (1.0, 1.15, 1.3), (0.25, 0.5, 0.75))):
        for a in alphas:
            for be in (-1.0, 0.0, 1.0):
                for g in gammas:
                    top, y = run(kind, a, be, g, S, "val")
                    grid.append({"kind": kind, "alpha": a, "beta": be, "gamma": g, "St": sp(top, y, St),
                                 "rest": rest(top, y, S)})
    best = {}
    for kind in ("text", "genus", "sheets", "map", "blend"):
        rows_ = [g for g in grid if g["kind"] == kind]
        base_rest = max(g["rest"] for g in rows_)
        ok = [g for g in rows_ if g["rest"] >= base_rest - 0.003]  # guard: the other species ≤ 0.3 pt
        best[kind] = max(ok, key=lambda g: g["St"])
    res = {"n": {"Z": int(len(Z)), "S": int(len(S)), "St": int(len(St)), "Sr": int(len(Sr)), "F": int(len(F))},
           "cos_F": {"row_sheet": float(cosF.mean()), "row_text": float(cosFt.mean())}, "ridge": cosr,
           "grid": grid, "best": best, "report": {}}
    # report: S-report on val ∪ test photos (S rows replaced), Z on test (Z rows replaced; untouched S)
    for kind, bst in best.items():
        a, be, g = bst["alpha"], bst["beta"], bst["gamma"]
        out = {}
        for nm in ("val", "test"):
            top, y = run(kind, a, be, g, S, nm)
            out[f"Sr_{nm}_top1"], out[f"Sr_{nm}_top5"] = sp(top, y, Sr), sp(top, y, Sr, 5)
            out[f"rest_{nm}"] = rest(top, y, S)
        top, y = run(kind, a, be, g, Z, "test")
        out["Z_top1"], out["Z_top5"] = sp(top, y, Z), sp(top, y, Z, 5)
        out["Z_photos"] = int(np.isin(y, Z).sum())
        res["report"][kind] = dict(out, alpha=a, beta=be, gamma=g)
        log(kind, json.dumps({k: (round(v, 3) if isinstance(v, float) else v) for k, v in res["report"][kind].items()}))
    # upper bound: S with their real trained rows
    for nm in ("val", "test"):
        top, y = run("text", 1.0, 0.0, 0, np.array([], int), nm)
        res["report"].setdefault("trained (upper bound)", {})[f"Sr_{nm}_top1"] = sp(top, y, Sr)
        res["report"]["trained (upper bound)"][f"Sr_{nm}_top5"] = sp(top, y, Sr, 5)
    log("trained rows (upper bound):", res["report"]["trained (upper bound)"])
    json.dump(res, open(os.path.join(OUT, f"eval-{SRC}.json"), "w"), indent=1)


if __name__ == "__main__":
    cmds = {"select-ship": cmd_select_ship, "select": cmd_select, "list": cmd_list_gbif if SRC == "gbif" else cmd_list, "fetch": cmd_fetch, "embed": cmd_embed, "eval": cmd_eval}
    for c in (list(cmds) if sys.argv[1] == "all" else sys.argv[1:]):
        cmds[c]()

#!/usr/bin/env python3
"""Hugging Face model release of the Australia-wide plant identifier (the app's v3
configuration WITHOUT the Tasmanian kNN bank) → pipeline/cache/plantid/hf-release/.
Prepared only: nothing here logs in to or uploads to Hugging Face.

What the folder holds (and what it deliberately does not):
  heads-fp16.safetensors / heads-int8.safetensors  the two multi-prototype heads
      (τ-norm baked, merged twins' bias −1e4); int8 = byte-identical rows/scales to
      the app's v3-head.bin (asserted)
  prior.safetensors + prior.json                   the adaptive location prior, ALL-data
      counts (= the app's v3-prior.bin arrays, asserted), σ-code raster, frequencies
  labels.json, config.json, predict.py, README.md (model card), LICENSE.md,
  credits/ (per source + per creator + per photo)
  NOT included: photos, the Tasmanian kNN bank (embeddings of individual photos), the
  BioCLIP 2.5 encoder (linked at its pinned revision), Understorey Network content
  (UN slugs / profile links / descriptors; asserted absent), anything all-rights-reserved.

Subcommands:
  eval    no-bank numbers: T + ladder re-chosen on val (final_sweep protocol), report
          sets read once → WORK/eval-nobank.json. Env: eval_v2's (V2DATA=…/data-final.npz),
          torch + MPS; ~5 min on the M4.
  build   writes the release folder from ship/ + the head runs + WORK/eval-nobank.json
          (numpy, safetensors). Asserts consistency with the shipped pack.
  check   predict.py (the release's own code, imported from the folder) on CC0 evaluation
          photos vs the pipeline's reference scorer build_ship.V3Ship with the bank off →
          WORK/check.json (+ the README's reproduction paragraph on the next build).
          Needs open_clip + the pinned BioCLIP 2.5 in the HF cache.

Run:
  E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch==3.3.0 \
     --with numpy<2.3 --with scipy --with pyarrow --with pillow --with duckdb --with safetensors python3 -I"
  V2DATA=pipeline/cache/plantid/australia/v2/data-final.npz $E pipeline/plantid/hf_release.py eval
  $E pipeline/plantid/hf_release.py build
  $E pipeline/plantid/hf_release.py check && $E pipeline/plantid/hf_release.py build
"""
import argparse
import collections
import csv
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
CACHE = os.path.join(ROOT, "pipeline", "cache", "plantid")
SHIP = os.path.join(CACHE, "ship")
V2DIR = os.path.join(CACHE, "australia", "v2")
FSDIR = os.environ.get("HF_FSDIR") or os.path.join(V2DIR, "final_sweep")   # r2: final_sweep3
OUT = os.path.join(CACHE, "hf-release")
WORK = os.path.join(CACHE, "hf-release-work")
APC_CSV = os.path.join(CACHE, "australia", "apc", "taxon.csv")
ACK = os.path.join(ROOT, "ios", "IzzyMap", "Resources", "Data", "acknowledgements.json")
PREDICT_SRC = os.path.join(HERE, "hf_predict.py")
V3_CFG = "mpA01|adaptive|box"
HEAD_RUNS = [os.path.join(os.environ.get("HF_HEADS_DIR") or os.path.join(V2DIR, "head_capacity", "runs"),
                          f"hc-mpAc-s{s}.npz") for s in (0, 1)]   # r2: HF_HEADS_DIR=…/hc_sheets_r2
BIOCLIP_REPO = "imageomics/bioclip-2.5-vith14"
BIOCLIP_REV = "6e3d04e3d6522012c88181085c5ae666e14c45cd"
CODE_REPO = "https://github.com/lgruen/izzy-map"
HF_REPO = "leonhard-gruenschloss/bioclip-2.5-vith14-australian-plants"
AUTHOR = "Leonhard Gruenschloss"
os.makedirs(WORK, exist_ok=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 22), b""):
            h.update(b)
    return h.hexdigest()


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ eval (no bank)

def cmd_eval(a):
    """final_sweep's Sweep with every photo on the 'outside the box' path: for the
    adaptive prior that is exactly λ·prior everywhere + the heads alone (nat = False →
    L_img = L_head), i.e. the release's scorer. T and the ladder are re-chosen on val
    (cmd_calib's grid and ladder_search); the report sets are read once."""
    import torch
    os.environ["FS_WORK"] = WORK   # the adaptive-prior caches (prior-adF2-*.npy, ~3 GB) go here, deleted at the end
    import eval_v2 as E2
    import final_sweep as FSW
    import bank_analysis as BA
    import build_ship as BS

    class NoBank(FSW.Sweep):
        noloc = None

        def parts(self, nm):
            return {False: np.arange(len(self.Z[nm + "/y"]))}

        def prior_rows(self, nm, rows, kind):
            if self.noloc is None:
                return super().prior_rows(nm, rows, kind)
            return self.noloc.expand(len(rows), -1)

    te = json.load(open(os.path.join(FSDIR, "test.json")))[V3_CFG]
    cal_app = json.load(open(os.path.join(FSDIR, "calib.json")))[V3_CFG]
    c = dict(te["cfg"])
    assert c["prior"] == "adaptive" and not c["nat"] and c["ens"] == "mpA01", c
    t0 = time.time()
    assert os.path.abspath(FSW.FS) == os.path.abspath(WORK)
    FSW.cmd_prep()
    sw = NoBank()
    Z = sw.Z
    Ts = [float(x) for x in np.exp(np.linspace(np.log(0.7), np.log(3.0), 30))]
    nll = sw.tlogits_val(c, sorted(set(Ts) | {cal_app["T"]}))   # a set: a repeated T would be summed twice
    T = min(nll, key=nll.get)
    log(f"val NLL: T {T:.3f} → {nll[T]:.4f} (the app's T {cal_app['T']:.3f} → {nll[cal_app['T']]:.4f})")
    F = FSW.add_feats(sw.feats("AU-val", c, T, Z["genus"]), Z)
    wv = FSW.val_wcls(Z)
    lad = FSW.ladder_search(Z["AU-val/y"], Z["AU-val/w"], F, Z["genus"], wv)
    rv = FSW.ladder_rates(Z["AU-val/y"], Z["AU-val/w"], F, lad, Z["genus"], wv)
    log(f"ladder {lad}, val re-weighted species {rv['species']:.3f} wrong {rv['species_wrong']:.3f} "
        f"({time.time() - t0:.0f} s)")
    out = {"cfg": c, "note": "the app's v3 configuration with the Tasmanian kNN bank off (L_img = L_head "
                             "everywhere); T and ladder re-chosen on val; leak-free EVAL prior counts",
           "T": T, "val_nll": nll[T], "T_app": cal_app["T"], "val_nll_T_app": nll[cal_app["T"]],
           "ladder": lad, "val_ladder": rv, "ladder_app": cal_app["ladder"]}
    top5s, feats = {}, {}
    for s in ("AU-test", "A-test", "C-report"):
        Fs = FSW.add_feats(sw.feats(s, c, T, Z["genus"]), Z)
        feats[s], top5s[s] = Fs, Fs["top5"]
    rep = sw.sc.report(top5s)
    ntr = sw.sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
    rep["AU-test 1-9"] = sw.sc.metrics("AU-test", top5s["AU-test"], (ntr >= 1) & (ntr <= 9))
    ntr0 = sw.sc.n_tr[np.maximum(Z["AU-test/y"], 0)]
    rep["AU-test 0 photos"] = sw.sc.metrics("AU-test", top5s["AU-test"], ntr0 == 0)
    rep["A-test strict 0.2 km"] = sw.sc.metrics("A-test", top5s["A-test"], BA.strict_mask(Z, "A-test", 0.2))
    out["metrics"] = rep
    lr = {}
    for s, sub, key in (("A-test", None, "A-test"), ("AU-test", None, "AU-test"), ("C-report", "main", "C-main"),
                        ("C-report", "euc", "C-euc"), ("AU-test", "euc_y", "AU-test-euc")):
        y, w, Fs = Z[s + "/y"], Z[s + "/w"], feats[s]
        m = None if sub is None else (Z[s + "/sub"] == sub if sub != "euc_y" else Z["euc"][np.maximum(y, 0)] & (y >= 0))
        lr[key] = {"chosen": FSW.ladder_rates(y, w, Fs, lad, Z["genus"], mask=m),
                   "app-ladder": FSW.ladder_rates(y, w, Fs, cal_app["ladder"], Z["genus"], mask=m)}
    out["ladder_test"] = lr
    ec = {}
    for s in ("AU-test", "A-test"):
        y, Fs = Z[s + "/y"], feats[s]
        m = y >= 0
        _, inv = np.unique(y[m], return_inverse=True)
        corr = (Fs["named"] == y)[m].astype(float)
        ec[s] = {"natural": E2.ece(Fs["p1"][m], corr, Z[s + "/w"][m])[0],
                 "per_species": E2.ece(Fs["p1"][m], corr, 1.0 / np.bincount(inv)[inv])[0],
                 "nll_nat": float(-(Fs["lpy"][m] * Z[s + "/w"][m]).sum() / Z[s + "/w"][m].sum())}
    out["ece"] = ec
    # no location: K = 0 → λ·log f (the country-wide frequency of the eval counts), same T
    P2 = BS.V2Prior(BS.V2_PRIOR_EVAL)
    assert FSW.F2["t"] == "log1p"
    sw.noloc = c["lam"] * torch.from_numpy(np.log(P2.freqs["log1p"])[None].astype(np.float32)).to(FSW.DEV)
    sw.memo.clear()
    nl = {}
    for s in ("AU-test", "A-test", "C-report"):
        nl[s] = sw.top5(s, c)
    out["metrics_no_location"] = sw.sc.report(nl)
    sw.noloc = None
    out["seconds"] = round(time.time() - t0)
    json.dump(out, open(os.path.join(WORK, "eval-nobank.json"), "w"), indent=1)
    for f in os.listdir(WORK):
        if f.startswith("prior-adF2-"):
            os.remove(os.path.join(WORK, f))
    log(json.dumps({k: (round(100 * v["top1_sp"], 1), round(100 * v["top1_nat"], 1)) for k, v in rep.items()}))
    log("no location:", json.dumps({k: (round(100 * v["top1_sp"], 1), round(100 * v["top1_nat"], 1))
                                    for k, v in out["metrics_no_location"].items()}))




# ------------------------------------------------------------------ build

def read_blob(path):
    import build_ship as BS
    return BS.read_blob(path)


def apc_ids():
    """APC (NSL taxon export, CC BY 3.0 AU): accepted canonical name → (taxon id, name id)."""
    csv.field_size_limit(10 ** 9)
    out = {}
    with open(APC_CSV, encoding="utf-8") as f:
        for x in csv.DictReader(f):
            if x["taxonomicStatus"] != "accepted" or x["nameType"] != "scientific":
                continue
            n = x["canonicalName"]
            if n not in out or x["taxonRank"] == "Species":
                out[n] = (x["taxonID"], x["scientificNameID"], x["taxonRank"])
    return out


def build_heads(lab):
    """Both heads from the head_capacity runs (as build_ship.cmd_v3): τ-norm 0.5 baked, merged
    twins' bias −1e4. fp16 weights; int8 per prototype row × float32 scale — asserted
    identical to ship/v3-head.bin."""
    import build_ship as BS
    from safetensors.numpy import save_file
    h3, a3 = read_blob(os.path.join(SHIP, "v3-head.bin"))
    sc = h3["scoring"]
    mf = np.array([i for i, l in enumerate(lab) if "merged_into" in l], np.int64)
    f16, i8, meta = {}, {}, []
    for j, (path, hh) in enumerate(zip(HEAD_RUNS, h3["heads"])):
        assert sha256(path) == hh["sha256"], f"{path}: not the shipped head"
        W, b, Kc, row0, T, n_c, hcfg = BS.v3_load_head(path, sc["tau_norm"])
        b = b.copy()
        b[mf] = -1e4
        r0, r1 = hh["rows"]
        q8, s8 = BS.int8_rows32(W)
        assert np.array_equal(q8, a3["weight"][r0:r1]) and np.array_equal(s8, a3["scale"][r0:r1]), "int8 ≠ v3-head.bin"
        assert np.array_equal(b, a3["bias"][j]) and np.array_equal(Kc, a3["kc"][j]) and \
            np.array_equal(row0 + r0, a3["row0"][j]) and abs(T - hh["pool_temperature"]) < 1e-12
        p = f"head{j}."
        common = {p + "bias": b.astype(np.float32), p + "kc": Kc.astype(np.uint8), p + "row0": row0.astype(np.int32)}
        f16.update({p + "weight": W.astype(np.float16), **common})
        i8.update({p + "weight": q8, p + "scale": s8.astype(np.float32), **common})
        meta.append({"pool_temperature": T, "rows": int(len(W)), "seed": hcfg["seed"], "kbreaks": hcfg["kbreaks"],
                     "k_histogram": hh["k_histogram"], "source_run": os.path.basename(path), "source_sha256": hh["sha256"]})
    centre = a3["centre"].astype(np.float32)
    f16["centre"] = i8["centre"] = centre
    md = {"format": "izzymap-plantid-heads", "version": "1", "heads": "2", "classes": str(len(lab)),
          "embedding_dim": str(centre.shape[0]), "see": "config.json scoring.heads and recipe"}
    save_file(f16, os.path.join(OUT, "heads-fp16.safetensors"), {**md, "weights": "float16"})
    save_file(i8, os.path.join(OUT, "heads-int8.safetensors"), {**md, "weights": "int8 per row x float32 scale (max|w|/127)"})
    return meta, sc


def build_prior():
    """ship/v3-prior.bin's arrays (all-data counts) → prior.safetensors + prior.json."""
    from safetensors.numpy import save_file
    h, a = read_blob(os.path.join(SHIP, "v3-prior.bin"))
    keep = ("rowptr", "species", "count", "species_total", "freq_log1p", "sigma_code", "sigma_km", "alpha")
    save_file({k: np.ascontiguousarray(a[k]) for k in keep}, os.path.join(OUT, "prior.safetensors"),
              {"format": "izzymap-plantid-prior", "version": "3", "see": "prior.json"})
    ad = h["adaptive"]
    srcs = json.loads(h["about"].split(": ", 1)[1])
    names = {"inat_all_counts.parquet": "iNaturalist (open-data snapshot 2026-10): research-grade AU records of every observer",
             "ala_counts_noinat.parquet": "Atlas of Living Australia occurrences WITHOUT iNaturalist Australia (dr1411 excluded = de-duplicated)",
             "ala_counts_generalised_noinat.parquet": "ALA generalised (sensitive-species) records, labels without precise records, no iNaturalist"}
    pj = {
        "format": "izzymap-plantid-prior v3 (safetensors arrays + this header)",
        "grid": {k: h[k] for k in ("cell_deg", "lat0", "lon0", "ny", "nx", "km_per_deg_lat", "km_per_deg_lon", "radius_sigmas")},
        "arrays": {
            "rowptr": "uint32 (ny·nx + 1): CSR row pointer; row r = iy·nx + ix, iy = floor((lat − lat0)/cell_deg), ix = floor((lon − lon0)/cell_deg)",
            "species / count": "uint16: class index and record count of each (cell, class) pair, rows rowptr[r] … rowptr[r+1] − 1",
            "species_total": "uint32 per class: records over all cells",
            "freq_log1p": "float64 per class: f = (Σ_cells log1p(count) + 1) / Σ — the no-location prior and the shrinkage target",
            "sigma_code": "uint8 (ny × nx): kernel level k of each cell → sigma_km[k], alpha[k]",
            "sigma_km / alpha": "float64 per level: σ = smin·2^(k/steps_per_octave); α = a0·(σ/s0)^δ",
        },
        "transform": "log1p",
        "kernel": ("K[c] = Σ over cells whose centre is within radius_sigmas·σ of the photo of log1p(count[cell, c])·exp(−d²/2σ²), "
                   "d in km with dy = Δlat·km_per_deg_lat, dx = Δlon·km_per_deg_lon·cos(photo lat); "
                   "(σ, α) from sigma_code of the photo's cell (indices clipped to the grid); "
                   "log prior = log((K + α·f) / (ΣK + α)); no location: K = 0 → log f"),
        "adaptive_fit": ad,
        "records": h["records"],
        "sources": [{"source": names.get(os.path.basename(s["table"]), os.path.basename(s["table"])), "records": int(s["records"]),
                     "cell_class_rows": int(s["kept"])} for s in srcs],
        "builds": {
            "shipped (this file)": "ALL data: iNat records of every observer + ALA without iNat + generalised — 19.8M records, 5.58M (cell, class) pairs; σ raster from these counts",
            "evaluation (not included)": ("leak-free: iNat records of TRAINING-POOL observers only + ALA without iNat (dr1411) + generalised without iNat "
                                          "(16.9M ALA records) — val/test observations never in the counts; σ raster recomputed from those counts "
                                          "(same σ code on 95.6 % of record cells). All reported numbers use it; parameters were chosen with it on val."),
        },
        "filters": "ALA: ABSENT, generalised/sensitive (separate table), coordinate uncertainty > 1 km and fossils out; Australia box",
        "licence_note": "aggregate counts per 0.05° cell (facts); the underlying records are under mixed licences (CC0 / CC BY / CC BY-NC …)",
    }
    assert int(a["sigma_code"].max()) < len(a["sigma_km"]) and ad["levels"] == len(a["sigma_km"])
    json.dump(pj, open(os.path.join(OUT, "prior.json"), "w"), indent=1, ensure_ascii=False)
    return pj


def build_labels():
    """labels.json: names are facts; no Understorey Network fields (un), no app row ids (ship)."""
    v2 = json.load(open(os.path.join(SHIP, "v2-labels.json")))["labels"]
    au = json.load(open(os.path.join(SHIP, "au-labels.json")))["labels"]
    assert len(v2) == len(au) == 22122
    apc = apc_ids()
    twins = collections.defaultdict(list)
    for i, l in enumerate(v2):
        if "merged_into" in l:
            twins[l["merged_into"]].append(i)
    out, n_apc = [], 0
    for i, (l, u) in enumerate(zip(v2, au)):
        name = l.get("apc_name") or l["name"]
        r = {"index": i, "name": name}
        if l.get("apc_name") and l["apc_name"] != l["name"]:
            r["alt_name"] = l["name"]
        r.update({"genus": l["genus"], "family": l.get("family")})
        if l.get("common"):
            r["common_name"] = l["common"]
        r["inat_taxon_ids"] = [int(t) for t in (u.get("inat") or [])]
        if name in apc:
            r["apc"] = {"taxon_id": apc[name][0], "name_id": apc[name][1], "rank": apc[name][2]}
            n_apc += 1
        r["native"] = bool(l["native"])
        r["tasmanian_list"] = "ship" in l
        r["training_photos"] = int(l["photos"])
        if "merged_into" in l:
            r["merged_into"] = int(l["merged_into"])
        if twins.get(i):
            r["merged_twins"] = twins[i]
            r["inat_taxon_ids"] = sorted(set(r["inat_taxon_ids"]) | {t for k in twins[i] for t in (au[k].get("inat") or [])})
        out.append(r)
    doc = {"version": 1, "count": len(out),
           "classes_with_photos": int(sum(1 for r in out if r["training_photos"] > 0)),
           "about": ("index = class column of the heads and the prior. name = accepted APC name (Australian Plant Census) where "
                     "the label is an APC species, else the label's name; alt_name = the spelling of the Tasmanian label list; "
                     "common_name = iNaturalist's preferred English name (place Australia); apc = APC taxon / APNI name identifiers "
                     "(CC BY 3.0 AU); native = APC native in a mainland state/territory or Tasmania; tasmanian_list = one of the "
                     "2,675 labels of the Tasmanian list (incl. naturalised weeds, mosses); training_photos = after merges (the "
                     "ladder's bucket); merged_into = a duplicate class merged at training (bias −1e4, never predicted)."),
           "labels": out}
    s = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    assert "understorey" not in s.lower() and '"un"' not in s and '"ship"' not in s
    open(os.path.join(OUT, "labels.json"), "w").write(s)
    return doc, n_apc


def build_credits():
    """CREDITS (aggregate by source) + creators.json.gz (per creator) + photos.tsv.gz (per photo, as shipped)."""
    c = json.load(open(os.path.join(SHIP, "credits.json")))
    d = os.path.join(OUT, "credits")
    os.makedirs(d, exist_ok=True)
    shutil.copyfile(os.path.join(SHIP, "credits-photos.tsv.gz"), os.path.join(d, "photos.tsv.gz"))
    creators = [{k: o[k] for k in ("name", "login", "photos", "licences", "source") if k in o} for o in c["observers"]]
    for o in creators:
        o.setdefault("source", "inat")
    with gzip.open(os.path.join(d, "creators.json.gz"), "wt", encoding="utf-8") as f:
        json.dump({"about": "every creator of a training photo: display name (if any), account / attribution name, "
                            "photo count and licences; source inat = iNaturalist, ala = Atlas of Living Australia "
                            "(incl. APII), commons = Wikimedia Commons, herbarium = herbarium specimen images via GBIF behind the "
                            "rows of labels without training photos (not training photos)", "creators": creators}, f, ensure_ascii=False)
    # APII share of the ALA photos (attribution string names it)
    apii = 0
    with gzip.open(os.path.join(SHIP, "credits-photos.tsv.gz"), "rt", encoding="utf-8") as f:
        next(f)
        for line in f:
            if "\tala\t" in line and "(APII)" in line:
                apii += 1
    return c, apii


def fmt(x, nd=1):
    return "–" if x is None else f"{100 * x:.{nd}f}"


def short_lic(x):
    """GBIF media licences arrive as URLs: …/licenses/by-nc/4.0/ → CC-BY-NC-4.0, …/zero/1.0 → CC0."""
    import re
    m = re.search(r"creativecommons\.org/(licenses|publicdomain)/([a-z-]+)/([\d.]+)", x or "")
    if not m:
        return x
    k = m.group(2)
    return "CC0" if k == "zero" else ("PD" if k == "mark" else f"CC-{k.upper()}-{m.group(3)}")


def lic_sum(d):
    out = {}
    for k, v in d.items():
        out[short_lic(k)] = out.get(short_lic(k), 0) + v
    return out


def sheet_classes():
    """How many labels got herbarium-specimen weights (sheet_rows.py's note in the head run's meta)."""
    z = np.load(HEAD_RUNS[0])
    return int(json.loads(str(z["meta"])).get("sheet_rows", {}).get("classes", 0))


def card(ev, te_bank, cfgj, lab, n_apc, credits, apii, pj, check, commit):
    m, lt, ec = ev["metrics"], ev["ladder_test"], ev["ece"]
    nl = ev["metrics_no_location"]
    S = credits["sources"]
    L = dict(credits["licences"])   # training photos only: the herbarium sheets are counted separately
    for k_, v_ in S.get("herbarium", {}).get("licences", {}).items():
        L[k_] -= v_
        if not L[k_]:
            del L[k_]
    H = S.get("herbarium")
    lic_tot = sum(L.values())

    def tail_rows():
        """Rows for the rare buckets only when the test set still has photos there (r2: none —
        their held-out photos moved into training by construction, see Changes)."""
        out = [row(nm, k) for nm, k in (("AU-test, classes with 1–9 training photos", "AU-test 1-9"),
                                        ("AU-test, classes with 0 training photos", "AU-test 0 photos")) if m[k]["n"]]
        return "\n".join(out) + ("\n\nThe 1–9- and 0-photo buckets of AU-test are empty in r2: their held-out photos now "
                                 "train the model (Changes)." if len(out) < 2 else "")

    def row(name, k, note=""):
        r = m[k]
        return (f"| {name} | {r['n']:,} | **{fmt(r['top1_sp'])}** | {fmt(r['top5_sp'])} | {fmt(r['top1_nat'])} | "
                f"{fmt(r.get('top1_sp_rw'))} |{note}")

    def lrow(name, k):
        r = lt[k]["chosen"]
        return (f"| {name} | {fmt(r['species'])} | {fmt(r['species_right'])} | {fmt(r['species_wrong'])} | "
                f"{fmt(r['genus'])} ({fmt(r['genus_wrong'])}) | {fmt(r['not_sure'])} | {fmt(r['species_w'])} / {fmt(r['species_wrong_w'])} |")

    bm = te_bank["metrics"]
    lad = cfgj["scoring"]["ladder"]
    chk = ""
    if check:
        chk = (f"\n**Reproduction check** (`predict.py`'s own code vs the pipeline's reference scorer, {check['n_photos']} CC0 "
               f"evaluation photos, each at its own location, without one, and at two mainland points): stored pipeline embedding → int8 heads: max |Δ log p| "
               f"{check['int8_vs_ref']['max_abs_dlogp_top10']:.1e} over each photo's top 10, top-5 identical "
               f"{check['int8_vs_ref']['top5_identical']}/{check['n_cases']}, ladder identical "
               f"{check['int8_vs_ref']['ladder_identical']}/{check['n_cases']}; fp16 heads: max |Δ p| "
               f"{check['fp16_vs_ref']['max_abs_dp']:.1e}, top-1 identical {check['fp16_vs_ref']['top1_identical']}/{check['n_cases']}; "
               f"re-embedding the JPEG on CPU fp32 with open_clip: cosine to the stored embedding ≥ "
               f"{check['fresh']['min_cos']:.5f}, max |Δ p| {check['fresh']['max_abs_dp']:.1e}, top-1 identical "
               f"{check['fresh']['top1_identical']}/{check['n_cases']}.\n")
    cite = json.load(open(ACK))
    bib = next(x for x in cite["components"] if x["id"] == "bioclip")["citations"]
    bibs = "\n\n".join(b["text"] for b in bib)
    short = commit[:10]
    return f"""---
license: cc-by-nc-4.0
base_model: {BIOCLIP_REPO}
base_model_relation: adapter
library_name: open_clip
pipeline_tag: image-classification
tags:
- plants
- biology
- australia
- eucalyptus
- inaturalist
- species-identification
- location-prior
---

# IzzyMap plant identifier (Australia)

Photo (+ optional location) → one of **{lab['count']:,} Australian plant labels** ({lab['classes_with_photos']:,} with training
photos). A small model that sits on top of the **frozen** [BioCLIP 2.5 ViT-H/14](https://huggingface.co/{BIOCLIP_REPO})
image encoder: two multi-prototype classification heads and an adaptive location prior built from occurrence records,
combined and calibrated into probabilities with an answer ladder (species / genus / not sure).

By {AUTHOR}. It is the plant identifier of IzzyMap, a private offline vegetation map for Tasmania (code:
[{CODE_REPO}]({CODE_REPO}/tree/{commit}), commit `{short}`), released here without the app's Tasmanian
photo bank.

**This repository does not contain the encoder.** `predict.py` downloads BioCLIP 2.5 (MIT) from Hugging Face at the
pinned revision `{BIOCLIP_REV}`. Nor does it contain any training photo or per-photo embedding.

## Files

| file | what |
|---|---|
| `heads-fp16.safetensors` | the two heads: prototype weights (fp16, τ-norm baked), per-class bias, prototypes per class `kc`, first row `row0`, the embedding centre |
| `heads-int8.safetensors` | the same, int8 per row × float32 scale — byte-identical to what the app ships (top-1 agreement with fp32 99.85 %) |
| `prior.safetensors`, `prior.json` | occurrence counts per 0.05° cell × class (CSR), per-cell kernel width code, class frequencies; format and formula in `prior.json` |
| `labels.json` | class index → name, genus, family, iNaturalist taxon ids, APC ids, iNaturalist common name, native flag, training-photo count, merged twins |
| `config.json` | every scoring parameter, the encoder id/revision and preprocessing, the formulas |
| `predict.py` | minimal inference (numpy + open_clip) |
| `credits/` | photographer attribution: `photos.tsv.gz` (one row per training photo), `creators.json.gz` (per creator) — see Credits |

## Quick start

```bash
pip install torch open_clip_torch safetensors pillow huggingface_hub "numpy<2.3"   # tested: torch 2.7, open_clip_torch 3.3.0
python predict.py photo.jpg --lat -42.88 --lon 147.33
python predict.py photo.jpg            # no location: the country-wide frequency replaces the local prior
```

```python
from predict import PlantID, Encoder
m, enc = PlantID(), Encoder()
logp, logp_image = m.logp(enc("photo.jpg"), lat=-42.88, lon=147.33)   # (1 × {lab['count']:,}) calibrated log p
print(m.ladder(logp[0], logp_image[0]))
```

## How it scores

1. `e` = BioCLIP 2.5 image embedding (1024-d; shortest side → 224 bicubic, centre crop 224, CLIP mean/std; RGB, embedded
   colour profile ignored). `q = normalise(normalise(e) − centre)`.
2. Per head: class *c* has K_c ∈ {{1, 2, 4, 8}} prototypes (1 / 2 / 4 / 8 at 0 / 50 / 150 / 300 training photos);
   s_c = T_h·(logsumexp(z/T_h) − log K_c) + b_c with z = W·q over its prototypes, T_h learned (4.19 / 4.20).
   The two heads (seeds 0 and 1) are averaged; L_img = log_softmax(mean / {cfgj['scoring']['image_temperature']}).
3. Location prior: a Gaussian kernel density of log1p(record counts) around the photo, with a **per-cell bandwidth** σ
   from 2 km (dense records) to 20 km (sparse) — σ = clip(14 km·(ρ0/ρ)^0.25, 2, 20) with ρ the smoothed record
   density — shrunk towards the country-wide frequency f: log((K + α f)/(ΣK + α)), α = 32. Weight λ = {cfgj['scoring']['prior']['lambda']}.
4. p = softmax(log_softmax(L_img + λ·prior) / T), T = {cfgj['scoring']['calibration_temperature']:.3f} (fitted on val NLL).
5. Ladder: name the top species if p ≥ {lad['species_threshold_by_bucket']} for a named class with 0 / 1–9 / 10–49 / 50+
   training photos; else the genus with the most summed p if ≥ {lad['genus_threshold']} (with its top 3); else "not sure".

No location → K = 0, i.e. λ·log f. Full formulas: `config.json` → `recipe`.

## Intended use

Non-commercial identification of plants photographed in **Australia** — a field aid for naturalists, students and
land managers that suggests names to check against a flora or an expert. **Not** for decisions where a mistake can
hurt: edibility, medicinal use, poisoning, allergy, weed-control or legal/biosecurity determinations.

## Changes

- **r2 (2026-11-08)**: rare species no longer lose their only photos to the evaluation split — a species with < 10
  training photos takes its held-out observers' observations into training until it has 10 (2,237 observations,
  5,255 photos, 1,226 species, 257 of them previously photo-less); heads retrained (same recipe and seeds);
  photo-less labels get herbarium-specimen weights (see Labels). Per-species top-1 on identical test sets with the app's
  configuration: Australia 86.6 → 86.3, Tasmania 89.8 → 90.1 (the specimen weights cost ≈ 0.2 pt on photographed
  species in exchange for naming photo-less ones). The test sets lost the moved observations, so numbers are not
  comparable with r1's card.
- r1 (2026-11-06): first release.

## Labels

The Australian Plant Census (APC, NSL export 2026-11-04): accepted species native in at least one state/territory
(21,204) ∪ a Tasmanian list of 2,675 labels (incl. naturalised weeds, mosses and a few algae), merged → 22,122 labels;
19 duplicate classes (twins sharing an iNaturalist taxon, or merged APC/iNat names) are kept as columns but never
predicted (`merged_into`). {n_apc:,} labels carry APC identifiers. **{lab['count'] - lab['classes_with_photos']:,} labels have no
training photo**: their weights are BioCLIP's text embedding of the name""" + (f""", moved by the mean shift their genus's
trained classes made and, for {sheet_classes():,} of them, blended 3 : 1 with the mean embedding of up to 16
herbarium specimen images of the species ({H['photos']:,} images via GBIF, CC/PD only; `sheet_rows` in the code) — on a
held-out check these labels went from 23 % to 39 % top-1""" if H else "") + f""" (plus the location prior).

## Training data

- **{credits['photos']:,} photos** by {len(credits['observers']):,} creators: iNaturalist open-data snapshot 2026-10
  ({S['inat']['photos']:,}; research-grade observations plus, for classes with < 20 photos, needs-ID observations of
  observers with ≥ 5 research-grade observations in that genus), Atlas of Living Australia field photos ({S['ala']['photos']:,}, of
  which {apii:,} from the Australian Plant Image Index, Australian National Botanic Gardens) and Wikimedia Commons
  ({S['commons']['photos']:,}). Photos from anywhere in the world for the label species. Heads trained on frozen
  embeddings: initialised from BioCLIP text embeddings of the names (prototypes: text + k-means offsets), class-balanced
  sampling (50 draws per class per epoch, 12 epochs) with logit adjustment by the data's class frequencies (τ 1.5),
  AdamW lr 1e-3 with decay towards the text initialisation (0.01), Tasmanian photos × 3; seeds 0 and 1.
- Licences of the training photos: {", ".join(f"{k} {v:,}" for k, v in sorted(L.items(), key=lambda kv: -kv[1]))}
  ({fmt(L.get('CC-BY-NC', 0) / lic_tot)} % CC BY-NC). No all-rights-reserved photo was used.
- **Observer-disjoint splits**: observers are hashed into pool (training, prior, labels), val and test; evaluation photos
  only from val/test observers, never a photo shared between observations; a perceptual-hash guard (pHash ≤ 8 and
  dHash ≤ 10) on the photos added in the last data expansion dropped copies of evaluation photos (2) and
  near-duplicates (832). Tasmanian and set-C evaluation photos were observed on/after 2024-09-01, after BioCLIP's training snapshot.
- Location prior (shipped): {pj['records']:,} records — iNaturalist research-grade records of all observers, ALA
  occurrences with iNaturalist Australia removed (no double counting), ALA generalised records for labels without
  precise ones. The **evaluation used a leak-free build** (iNaturalist records of pool observers only + ALA without
  iNaturalist), see `prior.json`.

## Evaluation (this release: no Tasmanian photo bank)

Top-1/top-5 accuracy in %, **per species** (each species weighted equally — the long tail counts) and in the
**natural** mix of photos people take; "re-weighted" = per species with species weighted to the training-photo mix of
all Australian species with a record. All parameters were chosen on val; each test set was read once for this
configuration. Leak-free evaluation prior. Photos whose species is not in the label set are left out of the counts
below.

| set | photos | top-1 per species | top-5 per species | top-1 natural | top-1 re-weighted |
|---|---|---|---|---|---|
{row("AU-test — Australia-wide test observers (≤ 8 photos per class)", "AU-test")}
{row("AU-test eucalypts (*Eucalyptus*, *Corymbia*, *Angophora*)", "AU-test-euc")}
{row("A-test — Tasmania", "A-test")}
{row("A-test, strict: no training photo of the class within 200 m", "A-test strict 0.2 km")}
{row("C-main — mainland, one photo each of 1,411 random native species", "C-main")}
{row("C-euc — mainland eucalypts (270 species)", "C-euc")}
{tail_rows()}

Without a location (country-wide frequency instead of the local prior): AU-test {fmt(nl['AU-test']['top1_sp'])} per
species / {fmt(nl['AU-test']['top1_nat'])} natural, A-test {fmt(nl['A-test']['top1_sp'])} / {fmt(nl['A-test']['top1_nat'])},
C-main {fmt(nl['C-main']['top1_sp'])}, C-euc {fmt(nl['C-euc']['top1_sp'])} — the location prior is worth a lot.

Calibration (expected calibration error of the top-1 probability, 15 bins): AU-test {fmt(ec['AU-test']['per_species'])} %
per species / {fmt(ec['AU-test']['natural'])} % natural; A-test {fmt(ec['A-test']['per_species'])} % /
{fmt(ec['A-test']['natural'])} %.

Answer ladder (% of photos, per species; the last column natural mix): species named, of which right / wrong; genus
answers (wrong genus); not sure.

| set | species | right | wrong | genus (wrong) | not sure | natural: species / wrong |
|---|---|---|---|---|---|---|
{lrow("AU-test", "AU-test")}
{lrow("AU-test eucalypts", "AU-test-euc")}
{lrow("A-test (Tasmania)", "A-test")}
{lrow("C-main", "C-main")}
{lrow("C-euc", "C-euc")}

*In the app* (not in this release) a kNN vote over ~83k Tasmanian training-photo embeddings is added inside a
Tasmania box: A-test {fmt(bm['A-test']['top1_sp'])} per species / {fmt(bm['A-test']['top1_nat'])} natural (strict 200 m:
{fmt(bm['A-test strict 0.2 km']['top1_sp'])}); outside Tasmania the two are the same model.
{chk}
## Limitations

- **Photo-less species** (~{(lab['count'] - lab['classes_with_photos']) / lab['count'] * 100:.0f} % of labels) are rarely named correctly
  ({fmt(m['AU-test 0 photos']['top1_sp'])} % top-1 on the {m['AU-test 0 photos']['n']} AU-test photos of such species — a small sample,
  and only species someone photographed); species with 1–9 photos ({fmt(m['AU-test 1-9']['top1_sp'])} %) are much weaker than
  well-photographed ones.
- **Eucalypts** are often right only to genus: bark, distant canopy or a sterile sprig rarely identify a species; the
  ladder answers "genus" for about half of eucalypt photos by design.
- **Location-dependent**: the prior lifts locally common species; a wrong or missing location costs accuracy, and a
  plant far outside its recorded range (garden plantings, new incursions) is pushed down. In a by-eye review of 74
  confident errors (earlier single-head model), the largest groups were close congeners, photos that do not show
  identifying parts, and species with < 10 training photos; about a quarter had been lifted to high confidence by
  the prior.
- Plants outside the label set (most cultivated exotics, hybrids, most mainland weeds) cannot be named and will be
  matched to the nearest label.
- **Label noise**: needs-ID observations admitted for rare classes are unreviewed (≥ ~3 % wrong-or-contested when
  measured; the rest unknown); research-grade labels also contain errors.
- Evaluation photos are iNaturalist observations: their framing and species mix are those of iNaturalist users.
- Multi-modal species: a linear softmax head gives each class one direction, so the region where a class wins is
  convex (an intersection of half-spaces); a species whose photos form several distinct looks (flowers, bark, juvenile
  foliage, habit) plausibly fits that poorly. The multi-prototype heads (up to 8 directions per class, soft-max pooled)
  address part of it, but a dense kNN over local training photos still added +1.4–1.6 points per species in Tasmania
  on top of every head tried, and still helps on the strict ≤ 200 m place-disjoint split (here {fmt(m['A-test strict 0.2 km']['top1_sp'])} → {fmt(bm['A-test strict 0.2 km']['top1_sp'])}),
  so it is not just near-duplicate leakage. That bank is not released (it consists of per-photo embeddings), so this
  release is about 1.5 points weaker in Tasmania than the app.

## What was tried (ablations, summary)

Measured on val, confirmed on test (`{CODE_REPO}/blob/{commit}/pipeline/plantid/README.md`): text initialisation beats
random init (+1.6 per species, +3.7 in the 1–9 bucket); logit adjustment (balanced softmax or post-hoc) beats plain
cross-entropy (+3.5); the location prior is the largest single term (this release without a location: −9.0 per species
on AU-test, −18.5 on mainland eucalypts); adding ALA occurrences (without iNaturalist's copies) to iNaturalist's
records lifted AU-test by +2.7 and the 1–9 bucket by +8; the adaptive-bandwidth prior plus the two-head
multi-prototype ensemble, chosen on val, gained +1.2 per species on AU-test over a fixed-σ prior and one linear head
(paired bootstrap 95 % CI +0.9 … +1.3); longer training, adapters,
residual/dense stacks and Tip-Adapter caches did not help (they memorise common classes at the tail's expense);
a national kNN bank over all 3.9M photos gave +0.9 on AU-test but costs ~4 GB; a LoRA / partial encoder
fine-tuning pilot improved image-only accuracy by ~2 points but only ≤ 0.3 with the location prior and eroded the
1–9 bucket, so the encoder stays frozen.

## Licence

**CC BY-NC 4.0** (weights, prior counts, labels, code in this folder), © {AUTHOR}.
Why non-commercial: {fmt(L.get('CC-BY-NC', 0) / lic_tot, 0)} % of the training photos are CC BY-NC, the Australian National
Botanic Gardens' terms for Australian Plant Image Index photos allow non-commercial use only, and part of the occurrence data is CC BY-NC. The weights are statistics
learned from millions of photos and are not, in the author's view, a copy or adaptation of any individual photo; no
photo or per-photo embedding is distributed. Training photos also include CC BY-SA / BY-NC-SA ({L.get('CC-BY-SA', 0) + L.get('CC-BY-NC-SA', 0):,})
and BY-ND / BY-NC-ND ({L.get('CC-BY-ND', 0) + L.get('CC-BY-NC-ND', 0):,}) works, attributed like all others. Users must respect
the licences of any source data they obtain themselves. BioCLIP 2.5 (downloaded separately) is MIT.

## Credits

Every training photo is credited in `credits/photos.tsv.gz` (photo id, creator, licence, source, attribution; iNat
photo page `https://www.inaturalist.org/photos/<id>`, ALA image `https://images.ala.org.au/image/<id>`, Commons page id)
and per creator in `credits/creators.json.gz`. By source:

| source | photos | creators | licences |
|---|---|---|---|
""" + "\n".join(
        f"| {nm} | {S[k]['photos']:,} | {S[k]['credited']:,} | " + ", ".join(f"{a} {b:,}" for a, b in sorted(lic_sum(S[k]['licences']).items(), key=lambda kv: -kv[1])) + " |"
        for k, nm in (("inat", "iNaturalist (open-data snapshot 2026-10)"), ("ala", f"Atlas of Living Australia (incl. {apii:,} APII photos, © the photographers · Australian National Botanic Gardens)"),
                      ("commons", "Wikimedia Commons"), ("herbarium", "Herbarium specimen images via GBIF (weights of photo-less labels, not training photos; `https://www.gbif.org/occurrence/<id>`)"))
        if k in S) + f"""

Occurrence data (aggregated into the prior): iNaturalist (records CC0 / CC BY / CC BY-NC), the Atlas of Living Australia
and its data providers (records CC BY 3.0 AU / 4.0, CC BY-NC and others), including ALA's generalised records of
sensitive species. Names: the Australian Plant Census (CC BY 3.0 AU, Council of Heads of Australasian Herbaria) and
iNaturalist taxa. Encoder: BioCLIP 2.5 by the Imageomics Institute (MIT):

```bibtex
{bibs}
```

## Citation

```bibtex
@misc{{gruenschloss2026izzymap_plantid,
  author = {{Leonhard Gruenschloss}},
  title  = {{IzzyMap plant identifier (Australia): multi-prototype heads and an adaptive location prior on BioCLIP 2.5}},
  year   = {{2026}},
  howpublished = {{Hugging Face model, https://huggingface.co/{HF_REPO}}},
  note   = {{Code: {CODE_REPO}, commit {short}}}
}}
```
"""


def cmd_build(a):
    commit = a.commit or subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()
    ev_p = os.path.join(WORK, "eval-nobank.json")
    ev = json.load(open(ev_p))
    te = json.load(open(os.path.join(FSDIR, "test.json")))[V3_CFG]
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    lab, n_apc = build_labels()
    meta, sc = build_heads(lab["labels"])
    pj = build_prior()
    credits, apii = build_credits()
    pipe = json.load(open(os.path.join(SHIP, "pipeline.json")))
    assert sc["prior"]["fit"]["t"] == "log1p" and sc["lam"] == ev["cfg"]["lam"] and sc["image_temperature"] == ev["cfg"]["t"]
    lad = ev["ladder"]
    cfgj = {
        "model": {"name": "IzzyMap plant identifier (Australia)", "author": AUTHOR, "licence": "CC-BY-NC-4.0",
                  "id": pipe["v3"]["id"] + "-nobank", "built": time.strftime("%Y-%m-%d"),
                  "code": f"{CODE_REPO}/tree/{commit}", "classes": lab["count"], "classes_with_photos": lab["classes_with_photos"]},
        "encoder": {"hf_repo": BIOCLIP_REPO, "revision": BIOCLIP_REV, "open_clip": f"hf-hub:{BIOCLIP_REPO}", "arch": "ViT-H-14",
                    "embedding_dim": 1024, "weights_included": False, "licence": "MIT", "output": "encode_image, not normalised (the scorer normalises)",
                    "preprocess": pipe["encoder"]["preprocess"]},
        "scoring": {
            "heads": meta,
            "combine": "mean of the two heads' logits",
            "tau_norm": f"{sc['tau_norm']} (scale-kept, on the per-class mean prototype norm) — baked into the weights",
            "pooling": "s_c = T_h·(logsumexp(z/T_h) − log K_c), z = the class's K_c prototype logits (= z for K_c = 1)",
            "image_temperature": sc["image_temperature"],
            "prior": {"kind": "adaptive Gaussian kernel density, per-cell bandwidth", "transform": "log1p", "lambda": sc["lam"],
                      "file": "prior.safetensors + prior.json", "fit": sc["prior"]["fit"]},
            "calibration_temperature": ev["T"],
            "calibration": "T minimising ½ AU-val class-balanced NLL + ½ A-val natural NLL (grid 0.7–3.0)",
            "ladder": {"species_threshold_by_bucket": lad["s"], "bucket_edges": "0 | 1–9 | 10–49 | 50+ training photos of the NAMED class",
                       "genus_threshold": lad["g"], "image_floor": lad["f"], "congener_ratio": lad["r"],
                       "chosen": "greedy on AU-val re-weighted to the training-count mix of all Australian species: ≤ 7 % stated-wrong per species"},
            "no_location": "K = 0 → prior = λ·log f (the country-wide class frequency, freq_log1p); same T and ladder",
            "tasmania_bank": "not included (the app adds a kNN over Tasmanian training-photo embeddings inside 143.5–149 E, 44–39.2 S)",
        },
        "app_configuration_for_reference": {"calibration_temperature": sc["temperature"], "ladder": sc["ladder"],
                                            "tasmania": {k: sc["tasmania"][k] for k in ("box", "omega", "knn_floor")}},
        "recipe": [
            "q = normalise(normalise(embedding) − centre)",
            "per head h: z = W_h · q (int8: weight · scale per row); class c's prototypes are rows row0[c] … row0[c] + kc[c] − 1; "
            "s_c = T_h·(logsumexp(z/T_h) − log kc[c]) + bias[c]",
            "L_img = log_softmax(mean_h s / image_temperature)",
            "prior = λ · log((K + α f) / (ΣK + α)) — prior.json kernel",
            "L = log_softmax(log_softmax(L_img + prior) / calibration_temperature); image-only = log_softmax(L_img / calibration_temperature)",
            "ladder: named = argmax L; species if p[named] ≥ species_threshold_by_bucket[bucket(training_photos[named])] and image-only "
            "p[named] ≥ image_floor and not (congener_ratio < 1 and top-2 share a genus and p2 ≥ ratio·p1); else the genus with the "
            "largest summed p if ≥ genus_threshold (with its top 3); else not sure",
        ],
        "evaluation": {"file": "README.md", "val_nll": ev["val_nll"]},
    }
    json.dump(cfgj, open(os.path.join(OUT, "config.json"), "w"), indent=1, ensure_ascii=False)
    shutil.copyfile(PREDICT_SRC, os.path.join(OUT, "predict.py"))
    open(os.path.join(OUT, "LICENSE.md"), "w").write(
        f"Copyright (c) 2026 {AUTHOR}\n\nThe model weights, location-prior counts, label table, configuration and code in "
        "this repository are licensed under the Creative Commons Attribution-NonCommercial 4.0 International licence "
        "(CC BY-NC 4.0): https://creativecommons.org/licenses/by-nc/4.0/legalcode\n\n"
        "Attribution for the training photos: credits/. BioCLIP 2.5 (not included; downloaded by predict.py) is MIT-licensed "
        f"by the Imageomics Institute: https://huggingface.co/{BIOCLIP_REPO}\n")
    ck = os.path.join(WORK, "check.json")
    check = json.load(open(ck)) if os.path.exists(ck) else None
    open(os.path.join(OUT, "README.md"), "w").write(card(ev, te, cfgj, lab, n_apc, credits, apii, pj, check, commit))
    # guards: nothing from the Understorey Network, no e-mail address, no bank, no photos
    for d_, _, fs in os.walk(OUT):
        for f in fs:
            p = os.path.join(d_, f)
            assert not f.lower().endswith((".jpg", ".jpeg", ".png", ".webp")) and "bank" not in f, p
            if f.endswith((".json", ".md", ".py")):
                t = open(p, encoding="utf-8").read().lower()
                assert "@gruenschloss" not in t and "understorey" not in t and "leonhard@" not in t, p
    compile(open(os.path.join(OUT, "predict.py"), encoding="utf-8").read(), "predict.py", "exec")   # parse check, no .pyc
    for d_, _, fs in os.walk(OUT):
        for f in sorted(fs):
            p = os.path.join(d_, f)
            print(f"{os.path.relpath(p, OUT):32s} {os.path.getsize(p) / 1e6:9.2f} MB")


# ------------------------------------------------------------------ check

CHECK_PHOTOS = [("A-test", 474507720), ("A-test", 452374918), ("A-test", 452974629), ("AU-test", 474507904),
                ("AU-test", 473574962), ("A-test", 436777826)]


def cmd_check(a):
    """predict.py (imported from the release folder) vs build_ship.V3Ship with the bank switched off,
    on CC0 evaluation photos (with their location and without)."""
    import duckdb
    import build_ship as BS
    sys.dont_write_bytecode = True   # no __pycache__ in the release folder
    sys.path.insert(0, OUT)
    import predict as PR
    Z = np.load(os.path.join(V2DIR, "bank_analysis", "sets.npz"))
    con = duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)
    BS.in_tas = lambda lat, lon: np.zeros(np.shape(np.atleast_1d(lat)), bool)   # bank off: L_img = L_head everywhere
    ref = BS.V3Ship(SHIP)
    rel = {"release T": json.load(open(os.path.join(OUT, "config.json")))["scoring"]["calibration_temperature"]}
    ref.sc = dict(ref.sc, temperature=rel["release T"],
                  ladder=dict(ref.sc["ladder"], **{"species": PR_cfg_ladder()["s"], "genus": PR_cfg_ladder()["g"],
                                                   "image_floor": PR_cfg_ladder()["f"], "congener_ratio": PR_cfg_ladder()["r"]}))
    m8, m16 = PR.PlantID(OUT, int8=True), PR.PlantID(OUT, int8=False)
    enc = PR.Encoder(OUT, device="cpu")
    res = {"cases": []}
    for s, pid in CHECK_PHOTOS:
        i = int(np.nonzero(Z[s + "/pid"] == pid)[0][0])
        lic = con.sql(f"select license from photo where photo_id = {pid}").fetchall()[0][0]
        assert lic == "CC0", (pid, lic)
        path = next(p for p in (os.path.join(CACHE, "photos", f"{pid}.jpeg"), os.path.join(CACHE, "australia", "photos", f"{pid}.jpeg"))
                    if os.path.exists(p))
        e_st = Z[s + "/emb"][i].astype(np.float32)
        e_new = enc(path)
        cos = float(e_new @ e_st / np.linalg.norm(e_new) / np.linalg.norm(e_st))
        # the photo's own location, none, and two mainland points (Sydney, Darwin: other σ levels and cos(lat))
        for loc in ((float(Z[s + "/lat"][i]), float(Z[s + "/lon"][i])), (None, None), (-33.87, 151.21), (-12.46, 130.84)):
            L, Li, _ = ref.logp(e_st[None], None if loc[0] is None else np.array([loc[0]]), None if loc[1] is None else np.array([loc[1]]))
            L, Li = L[0], Li[0]
            a8, a8i = (x[0] for x in m8.logp(e_st, *loc))
            a16, _ = (x[0] for x in m16.logp(e_st, *loc))
            an, ani = (x[0] for x in m8.logp(e_new, *loc))
            top = np.argsort(-L)[:10]
            r_l, p_l = ref.ladder(L, Li), m8.ladder(a8, a8i)
            same_lad = r_l["kind"] == p_l["kind"].replace("not sure", "notSure") and \
                (r_l["kind"] != "species" or r_l["label"] == p_l["label"]) and (r_l["kind"] != "genus" or r_l["genus"] == p_l["genus"])
            res["cases"].append({
                "set": s, "photo_id": pid, "truth": m8.labels[int(Z[s + "/y"][i])]["name"] if Z[s + "/y"][i] >= 0 else None,
                "location": None if loc[0] is None else [round(loc[0], 3), round(loc[1], 3)], "cos_fresh_vs_stored": cos,
                "ref_top5": [[m8.labels[c]["name"], round(float(np.exp(L[c])), 5)] for c in top[:5]],
                "int8_max_abs_dlogp_top10": float(np.abs(a8[top] - L[top]).max()),
                "int8_top5_identical": bool(np.array_equal(np.argsort(-a8)[:5], top[:5])),
                "ladder_ref": r_l["kind"], "ladder_identical": bool(same_lad),
                "fp16_max_abs_dp": float(np.abs(np.exp(a16) - np.exp(L)).max()),
                "fp16_top1_identical": bool(a16.argmax() == L.argmax()),
                "fresh_max_abs_dp": float(np.abs(np.exp(an) - np.exp(L)).max()),
                "fresh_top1_identical": bool(an.argmax() == L.argmax()),
            })
            print(json.dumps(res["cases"][-1], ensure_ascii=False)[:400], flush=True)
    C = res["cases"]
    res.update({"n_photos": len(CHECK_PHOTOS), "n_cases": len(C),
                "int8_vs_ref": {"max_abs_dlogp_top10": max(c["int8_max_abs_dlogp_top10"] for c in C),
                                "top5_identical": sum(c["int8_top5_identical"] for c in C),
                                "ladder_identical": sum(c["ladder_identical"] for c in C)},
                "fp16_vs_ref": {"max_abs_dp": max(c["fp16_max_abs_dp"] for c in C), "top1_identical": sum(c["fp16_top1_identical"] for c in C)},
                "fresh": {"min_cos": min(c["cos_fresh_vs_stored"] for c in C), "max_abs_dp": max(c["fresh_max_abs_dp"] for c in C),
                          "top1_identical": sum(c["fresh_top1_identical"] for c in C)},
                "reference": "build_ship.V3Ship(ship/) with in_tas → False (no bank), the release's T and ladder; stored = the pipeline's embedding"})
    json.dump(res, open(os.path.join(WORK, "check.json"), "w"), indent=1, ensure_ascii=False)
    print(json.dumps({k: v for k, v in res.items() if k != "cases"}, indent=1))
    assert res["int8_vs_ref"]["max_abs_dlogp_top10"] < 1e-3 and res["int8_vs_ref"]["top5_identical"] == len(C) \
        and res["int8_vs_ref"]["ladder_identical"] == len(C), "predict.py ≠ the reference scorer"


def PR_cfg_ladder():
    return json.load(open(os.path.join(WORK, "eval-nobank.json")))["ladder"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("eval")
    p = sub.add_parser("build")
    p.add_argument("--commit", help="code commit to link (default: HEAD)")
    sub.add_parser("check")
    a = ap.parse_args()
    {"eval": cmd_eval, "build": cmd_build, "check": cmd_check}[a.cmd](a)


if __name__ == "__main__":
    main()

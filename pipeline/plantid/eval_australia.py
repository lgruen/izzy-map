#!/usr/bin/env python3
"""Australia-wide plant-ID evaluation (EVALUATION ONLY — nothing here ships):
how far does a cheap zero-shot extension of the shipped Tasmanian scorer get
on Australian native plants (in particular eucalypts), and what would a
properly trained Australia-wide model cost?

Subcommands (run in order; outputs under pipeline/cache/plantid/australia/,
gitignored):

  labels   label universe U = accepted native vascular species of Australia
           from the Australian Plant Census (APC, NSL taxon export CSV,
           CC BY 3.0 AU) — species rank, scientific names (no phrase names /
           hybrids), native in at least one state or territory of the
           mainland + Tasmania — ∪ the 2,675 shipped Tasmanian labels (their
           weeds stay). APC synonyms map iNat / TreeOfLife names onto APC
           species. Coverage in BioCLIP 2.5's own training taxonomy
           (TreeOfLife-200M taxa list) and in iNat; per-species research-
           grade iNat counts (Australia, usable licence) for the cost
           estimate → labels.parquet, inat_map.parquet, labels.json.
  text     one text vector per U class, the eval's prompt "a photo of
           <kingdom phylum class order family genus epithet>.": local labels
           reuse the eval's text.npz, ToL names among the open-vocab eval's
           89,823 reuse its shards, the rest are embedded here (MPS fp16;
           names not in ToL borrow the upper ranks of a ToL genus/family).
  testset  test set C from the local iNat open-data snapshot (sets/
           work.duckdb): research-grade, Australia minus Tasmania, observed
           on/after 2024-09-01 (after BioCLIP's training-data snapshot), val/
           test-role observers only (never a training or prior observer), no
           shared photo, licence CC0/BY/BY-NC, species = an APC native.
           C-main: one photo per species over --main species; C-euc: eucalypts
           (Eucalyptus / Corymbia / Angophora) round-robin over species up to
           --euc photos; observer-hash halves tune / report; ≤ --obs-cap
           photos per observer. Photos (500 px medium) → australia/photos/,
           credits TSV with observer logins.
  embed    C embeddings with the shipped w8 Core ML encoder (compute units ALL).
  prior    Australia-wide location prior: research-grade iNat pool-observer
           records (no val/test observer) as counts per (0.1° cell, U class).
  score    z0 (zero-shot over U), z1 (+ location prior), h (Ship for the 2,675
           + z1 for the rest), tuned on C-tune (+ A-val guard for h), reported
           on C-report and A-test → results.json / results.md.
  bench    PyTorch MPS fp16 image-tower throughput on 200 photos.
  plan     the trained-model data plan, ready to run: label list, observer-
           disjoint train / val / test manifests (cap per species) and counts
           → australia/plan/ (no download, no compute beyond DuckDB).

Environment (coremltools needs numpy < 2.3; same as build_ship.py):

  uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*' \\
      --with open_clip_torch --with coremltools --with 'numpy<2.3' \\
      --with scipy --with pyarrow --with pillow --with duckdb \\
      python3 -I pipeline/plantid/eval_australia.py <subcommand>
"""
import argparse
import collections
import csv
import glob
import gzip
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.request

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402

CACHE = BS.CACHE
AU = os.path.join(CACHE, "australia")
OV = os.path.join(CACHE, "openvocab")
APC_URL = "https://biodiversity.org.au/nsl/services/export/taxonCsv"
APC_CSV = os.path.join(AU, "apc", "taxon.csv")
TOL_JSON = os.path.join(OV, "tol", "txt_emb_bioclip-2.5-vith14.json")
UA = {"User-Agent": "izzymap-plantid-eval/1"}
USABLE_DB = ("CC0", "PD", "CC-BY", "CC-BY-NC")
STATES = {"WA", "NT", "SA", "Qld", "NSW", "ACT", "Vic", "Tas"}
EUC = ("Eucalyptus", "Corymbia", "Angophora")
TAS = "lat BETWEEN -44.0 AND -39.2 AND lon BETWEEN 143.5 AND 149.0"
AUS = "lat BETWEEN -44.0 AND -9.5 AND lon BETWEEN 112.0 AND 154.5"
CUTOFF = "2024-09-01"
SYN_OK = {"taxonomic synonym", "nomenclatural synonym", "basionym", "orthographic variant",
          "replaced synonym", "doubtful taxonomic synonym", "pro parte taxonomic synonym",
          "pro parte nomenclatural synonym"}


def h01(s):
    return int(hashlib.sha256(s.encode()).hexdigest()[:8], 16) / 2 ** 32


def db():
    import duckdb
    return duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)


# --------------------------------------------------------------- labels

def apc_natives():
    """APC accepted species → (natives dict, synonym map, stats)."""
    if not os.path.exists(APC_CSV):
        os.makedirs(os.path.dirname(APC_CSV), exist_ok=True)
        req = urllib.request.Request(APC_URL, headers=UA)
        with urllib.request.urlopen(req, timeout=600) as r, open(APC_CSV + ".tmp", "wb") as f:
            f.write(r.read())
        os.replace(APC_CSV + ".tmp", APC_CSV)
    csv.field_size_limit(10 ** 9)
    rows = list(csv.DictReader(open(APC_CSV, encoding="utf-8")))
    st = collections.Counter()
    nat, acc_names = {}, set()
    for x in rows:
        if x["taxonomicStatus"] != "accepted" or x["taxonRank"] != "Species":
            continue
        st["accepted species"] += 1
        acc_names.add(x["canonicalName"])
        if x["nameType"] != "scientific":
            st[f"skipped {x['nameType']}"] += 1
            continue
        toks = [t.strip() for t in x["taxonDistribution"].split(",") if t.strip()]
        native_in = set()
        for t in toks:
            m = re.match(r"([A-Za-z]+)\s*(?:\((.*)\))?", t)
            s, q = m.group(1), (m.group(2) or "")
            if not q or "native" in q or "presumed extinct" in q:
                native_in.add(s)
        if not native_in:
            st["naturalised / uncertain only"] += 1
            continue
        if not native_in & STATES:
            st["native only on external territories"] += 1
            continue
        n = x["canonicalName"]
        if len(n.split()) != 2:
            st["skipped odd name"] += 1
            continue
        nat[n] = {"name": n, "genus": n.split()[0], "family": x["family"],
                  "states": ",".join(sorted(native_in & STATES)),
                  "dist": x["taxonDistribution"]}
    # synonyms (species rank) → accepted species binomial; drop ambiguous ones
    syn = collections.defaultdict(set)
    for x in rows:
        if x["taxonomicStatus"] in SYN_OK and x["taxonRank"] == "Species" and x["acceptedNameUsage"]:
            a = " ".join(x["acceptedNameUsage"].split()[:2])
            if x["canonicalName"] != a:
                syn[x["canonicalName"]].add(a)
    synmap = {s: next(iter(a)) for s, a in syn.items()
              if len(a) == 1 and s not in acc_names and next(iter(a)) in nat}
    st["natives"] = len(nat)
    st["synonym names usable"] = len(synmap)
    return nat, synmap, st


def cmd_labels(a):
    t0 = time.time()
    nat, synmap, st = apc_natives()
    print("APC:", dict(st))
    aliases = collections.defaultdict(list)  # accepted → its synonym names
    for s, acc in synmap.items():
        aliases[acc].append(s)
    tol = json.load(open(TOL_JSON))
    tol_taxo = {}
    tol_genus, tol_family = {}, {}
    for r, _ in tol:
        if r[0] != "Plantae" or not all(r):
            continue
        b = f"{r[5]} {r[6]}"
        tol_taxo.setdefault(b, " ".join(r))
        tol_genus.setdefault(r[5], r[:6])
        tol_family.setdefault(r[4], r[:5])
    con = db()
    inat = dict(con.execute("SELECT name, species_id FROM species WHERE active").fetchall())
    itaxo = dict(con.execute("SELECT species_id, taxo FROM species WHERE active").fetchall())
    L = pq.read_table(os.path.join(CACHE, "sets", "labels.parquet")).to_pydict()
    local_of_id = {s: i for i, s in enumerate(L["species_id"])}
    # shipped label order = labels.json (same as labels.parquet? check)
    lj = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    ship_idx = {l["inat"]: i for i, l in enumerate(lj)}
    assert len(lj) == len(L["species_id"])

    U, inat_rows = [], []
    for n in sorted(nat):
        d = nat[n]
        names = [n] + sorted(aliases.get(n, []))
        tn = next((x for x in names if x in tol_taxo), None)
        ids = sorted({inat[x] for x in names if x in inat})
        U.append(dict(d, tol_name=tn, tol_via=("accepted" if tn == n else "synonym" if tn else "none"),
                      inat_ids=ids, inat_via=("accepted" if n in inat else "synonym" if ids else "none"),
                      aliases=names[1:]))
    # iNat species id → U index (an iNat name equal to an APC accepted name wins)
    i2u = {}
    for ui, u in enumerate(U):
        if u["name"] in inat:
            i2u[inat[u["name"]]] = ui
    for ui, u in enumerate(U):
        for i in u["inat_ids"]:
            i2u.setdefault(i, ui)
    # local labels: attach to their APC class, or add as extra classes (weeds,
    # name mismatches); a U class holds at most one local label
    for u in U:
        u["ship"] = -1
    extra, dup = 0, 0
    for sid in [l["inat"] for l in lj]:
        ui = i2u.get(sid)
        if ui is not None and U[ui]["ship"] < 0:
            U[ui]["ship"] = ship_idx[sid]
        else:
            dup += ui is not None
            l = lj[ship_idx[sid]]
            U.append({"name": l["name"], "genus": l["genus"], "family": l.get("family") or "",
                      "states": "", "dist": "", "tol_name": l["name"] if l["name"] in tol_taxo else None,
                      "tol_via": "accepted" if l["name"] in tol_taxo else "none", "inat_ids": [sid],
                      "inat_via": "accepted", "aliases": [], "ship": ship_idx[sid]})
            extra += 1
    for ui, u in enumerate(U):
        u["native"] = bool(u["dist"])
        u["euc"] = u["genus"] in EUC
        # prompt: ToL's own 7 ranks, else iNat's lineage, else borrowed upper ranks
        if u["tol_name"]:
            u["taxo"], u["taxo_src"] = tol_taxo[u["tol_name"]], "tol"
        elif any(i in itaxo and len(itaxo[i].split()) == 7 for i in u["inat_ids"]):
            i = next(i for i in u["inat_ids"] if i in itaxo and len(itaxo[i].split()) == 7)
            g, e = u["name"].split()
            u["taxo"], u["taxo_src"] = " ".join(itaxo[i].split()[:5] + [g, e]), "inat"
        elif u["genus"] in tol_genus:
            u["taxo"], u["taxo_src"] = " ".join(list(tol_genus[u["genus"]]) + [u["name"].split()[1]]), "tol-genus"
        elif u["family"] in tol_family:
            u["taxo"], u["taxo_src"] = " ".join(list(tol_family[u["family"]]) + u["name"].split()), "tol-family"
        else:
            u["taxo"], u["taxo_src"] = "Plantae Tracheophyta " + u["family"] + " " + u["name"], "bare"
    # every iNat species id → U index (for test truths and prior records)
    imap = [{"species_id": int(i), "u": int(ui)} for i, ui in i2u.items()]
    for ui, u in enumerate(U):
        for i in u["inat_ids"]:
            if i not in i2u:
                imap.append({"species_id": int(i), "u": ui})
    con.register("imap_v", pa.Table.from_pylist(imap))
    # per-class research-grade counts (Australia box incl. Tasmania; world)
    lic = ", ".join(f"'{x}'" for x in USABLE_DB)
    cnt = con.execute(f"""
        WITH x AS (SELECT o.uuid, o.observer_id, o.lat, o.lon, m.u, o.role,
                          p.photo_id IS NOT NULL AS usable
                   FROM o JOIN imap_v m USING (species_id) LEFT JOIN photo p USING (uuid))
        SELECT u, count(*) FILTER ({AUS}) AS rg_au,
               count(*) FILTER ({AUS} AND usable) AS rg_au_usable,
               count(*) FILTER ({AUS} AND usable AND role = 'pool') AS rg_au_usable_pool,
               count(DISTINCT observer_id) FILTER ({AUS} AND usable) AS obs_au_usable,
               count(*) FILTER (usable) AS rg_world_usable,
               count(*) FILTER (usable AND role = 'pool') AS rg_world_usable_pool
        FROM x GROUP BY u""").fetchall()
    ph = dict(con.execute(f"""
        SELECT m.u, count(*) FROM o JOIN imap_v m USING (species_id)
        JOIN pobs p USING (uuid) WHERE {AUS.replace('lat', 'o.lat').replace('lon', 'o.lon')}
          AND p.license IN ({lic}) GROUP BY 1""").fetchall())
    C = {r[0]: r[1:] for r in cnt}
    keys = ("rg_au", "rg_au_usable", "rg_au_usable_pool", "obs_au_usable", "rg_world_usable",
            "rg_world_usable_pool")
    for ui, u in enumerate(U):
        for k, v in zip(keys, C.get(ui, (0,) * len(keys))):
            u[k] = int(v)
        u["photos_au_usable"] = int(ph.get(ui, 0))
        u["inat_ids"] = [int(i) for i in u["inat_ids"]]
        u["aliases"] = "|".join(u["aliases"])
    pq.write_table(pa.Table.from_pylist(U), os.path.join(AU, "labels.parquet"))
    pq.write_table(pa.Table.from_pylist(imap), os.path.join(AU, "inat_map.parquet"))

    nv = [u for u in U if u["native"]]

    def summ(rows):
        n = len(rows)
        return {"n": n,
                "tol_accepted": sum(r["tol_via"] == "accepted" for r in rows),
                "tol_synonym": sum(r["tol_via"] == "synonym" for r in rows),
                "tol_pct": round(100 * sum(r["tol_via"] != "none" for r in rows) / max(n, 1), 1),
                "inat_pct": round(100 * sum(r["inat_via"] != "none" for r in rows) / max(n, 1), 1),
                "with_rg_au": sum(r["rg_au"] > 0 for r in rows),
                "ge5_usable_au": sum(r["rg_au_usable"] >= 5 for r in rows),
                "ge20_usable_au": sum(r["rg_au_usable"] >= 20 for r in rows),
                "ge5_usable_world": sum(r["rg_world_usable"] >= 5 for r in rows),
                "ge20_usable_world": sum(r["rg_world_usable"] >= 20 for r in rows)}
    out = {"apc": dict(st), "U": len(U), "local_attached": sum(u["ship"] >= 0 and u["native"] for u in U),
           "local_extra": extra, "local_dup_dropped_into_extra": dup,
           "natives": summ(nv)}
    for g in EUC + ("Acacia",):
        out[g] = summ([u for u in nv if u["genus"] == g])
    out["eucalypts"] = summ([u for u in nv if u["euc"]])
    out["taxo_src"] = dict(collections.Counter(u["taxo_src"] for u in U))
    json.dump(out, open(os.path.join(AU, "labels.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))
    print(f"{time.time() - t0:.0f} s")


# ----------------------------------------------------------------- text

def cmd_text(a):
    import open_clip
    import torch
    import eval_open_vocab as OVm
    U = pq.read_table(os.path.join(AU, "labels.parquet")).to_pylist()
    lj = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    z = np.load(os.path.join(CACHE, "emb", BS.MODEL, "text.npz"))
    loc = dict(zip(z["species_id"].tolist(), z["emb"].astype(np.float32)))
    G = pq.read_table(os.path.join(OV, "global_labels.parquet"), columns=["binomial", "local"]).to_pydict()
    gpos = {b: i for i, b in enumerate([b for b, l in zip(G["binomial"], G["local"]) if not l])}
    Tg = OVm.load_text()
    T = np.zeros((len(U), 1024), np.float32)
    src, todo = [], []
    for ui, u in enumerate(U):
        if u["ship"] >= 0:
            T[ui] = loc[lj[u["ship"]]["inat"]]
            src.append("local")
        elif u["tol_name"] in gpos:
            T[ui] = Tg[gpos[u["tol_name"]]]
            src.append("openvocab")
        else:
            todo.append(ui)
            src.append("embedded")
    print(f"{len(U):,} classes: {collections.Counter(src)}")
    model, _, _ = open_clip.create_model_and_transforms(BS.HF)
    model.visual = None
    tok = open_clip.get_tokenizer(BS.HF)
    model = model.to("mps").to(torch.float16).eval()
    t0 = time.time()
    with torch.no_grad():
        # same pipeline as the reused vectors? (64 open-vocab rows re-embedded)
        chk = [ui for ui, s in enumerate(src) if s == "openvocab"][:64]
        e = torch.nn.functional.normalize(OVm.encode_trunc(model, tok(
            [f"a photo of {U[ui]['taxo']}." for ui in chk]).to("mps")).float(), dim=-1).cpu().numpy()
        print(f"re-embedded open-vocab rows: min cos {min(float(e[i] @ T[ui]) for i, ui in enumerate(chk)):.5f}")
        prompts = [f"a photo of {U[ui]['taxo']}." for ui in todo]
        ids = tok(prompts)
        order = np.argsort(-(ids != 0).sum(1).numpy())
        for i in range(0, len(todo), 256):
            sel = order[i:i + 256]
            e = OVm.encode_trunc(model, ids[sel].to("mps"))
            T[np.array(todo)[sel]] = torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()
    print(f"embedded {len(todo):,} prompts in {time.time() - t0:.0f} s")
    np.savez(os.path.join(AU, "text.npz"), emb=T.astype(np.float16), src=np.array(src))


# ----------------------------------------------------------------- C set

def fetch_photos(rows, d, workers=8):
    """500 px "medium" from the iNat open-data bucket, keep-alive per worker."""
    from concurrent.futures import ThreadPoolExecutor
    os.makedirs(d, exist_ok=True)
    todo = [r for r in rows if not os.path.exists(os.path.join(d, f"{r['photo_id']}.{r['ext']}"))]

    def work(chunk):
        conn, ok, bad = None, 0, 0
        for r in chunk:
            for attempt in range(3):
                try:
                    if conn is None:
                        conn = http.client.HTTPSConnection("inaturalist-open-data.s3.amazonaws.com",
                                                           timeout=30)
                    conn.request("GET", f"/photos/{r['photo_id']}/medium.{r['ext']}", headers=UA)
                    resp = conn.getresponse()
                    body = resp.read()
                    if resp.status == 200 and body[:3] in (b"\xff\xd8\xff", b"\x89PN"):
                        p = os.path.join(d, f"{r['photo_id']}.{r['ext']}")
                        open(p + ".tmp", "wb").write(body)
                        os.replace(p + ".tmp", p)
                        ok += 1
                    else:
                        bad += 1
                    break
                except Exception:
                    conn = None
                    time.sleep(1)
        return ok, bad
    t0 = time.time()
    with ThreadPoolExecutor(workers) as pool:
        res = list(pool.map(work, [todo[i::workers] for i in range(workers)]))
    print(f"photos: {sum(r[0] for r in res)} fetched in {time.time() - t0:.0f} s, "
          f"{sum(r[1] for r in res)} unavailable, {len(rows) - len(todo)} cached")


def cmd_testset(a):
    U = pq.read_table(os.path.join(AU, "labels.parquet"),
                      columns=["name", "genus", "native", "euc", "ship"]).to_pylist()
    con = db()
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    q = lambda c: c.replace("lat", "o.lat").replace("lon", "o.lon")  # noqa: E731
    rows = con.execute(f"""
        SELECT o.uuid::VARCHAR AS uuid, o.observer_id, o.species_id, m.u, o.lat, o.lon,
               o.pacc, o.observed_on::VARCHAR AS observed_on, p.photo_id, p.ext, p.license
        FROM o JOIN imap_v m USING (species_id) JOIN photo p USING (uuid)
        WHERE o.role IN ('val', 'test') AND {q(AUS)} AND NOT ({q(TAS)})
          AND o.observed_on >= DATE '{CUTOFF}'
          AND p.photo_id NOT IN (SELECT photo_id FROM shared)""").to_arrow_table().to_pylist()
    rows = [r for r in rows if U[r["u"]]["native"]]
    tr_obs = set(pq.read_table(os.path.join(CACHE, "sets", "train.parquet"),
                               columns=["observer_id"]).column(0).to_pylist())
    tr_ph = set(pq.read_table(os.path.join(CACHE, "sets", "train.parquet"),
                              columns=["photo_id"]).column(0).to_pylist())
    assert not any(r["observer_id"] in tr_obs or r["photo_id"] in tr_ph for r in rows)
    nat_n = collections.Counter(r["u"] for r in rows)  # natural count per species
    print(f"eligible: {len(rows):,} observations of {len(nat_n):,} native species "
          f"({sum(U[u]['euc'] for u in nat_n)} eucalypt species), "
          f"{len({r['observer_id'] for r in rows}):,} observers")
    by = collections.defaultdict(list)
    for r in rows:
        by[r["u"]].append(r)
    for u in by:
        by[u].sort(key=lambda r: h01(r["uuid"] + "C"))
    per_obs, used = collections.Counter(), set()

    def take(u):
        for r in by[u]:
            if r["uuid"] not in used and per_obs[r["observer_id"]] < a.obs_cap:
                used.add(r["uuid"])
                per_obs[r["observer_id"]] += 1
                return r
        return None
    keep = []
    # eucalypts first (round-robin over species: breadth before depth)
    eu = sorted([u for u in by if U[u]["euc"]], key=lambda u: h01(f"{u}euc"))
    n_eu, rnd = 0, 0
    while n_eu < a.euc and rnd < 10:
        for u in eu:
            if n_eu >= a.euc:
                break
            r = take(u)
            if r:
                keep.append(dict(r, subset="euc"))
                n_eu += 1
        rnd += 1
    sp = sorted(by, key=lambda u: h01(f"{u}main"))
    n_m = 0
    for u in sp:
        if n_m >= a.main:
            break
        r = take(u)
        if r:
            keep.append(dict(r, subset="main"))
            n_m += 1
    samp = collections.Counter((r["subset"], r["u"]) for r in keep)
    for r in keep:
        r["w"] = nat_n[r["u"]] / samp[(r["subset"], r["u"])]
        r["species"] = U[r["u"]]["name"]
        r["genus"] = U[r["u"]]["genus"]
        r["in_ship"] = U[r["u"]]["ship"] >= 0
        r["half"] = "tune" if h01(f"{r['observer_id']}izzy-au") < 0.5 else "report"
    want = {r["observer_id"] for r in keep}
    logins = {}
    with gzip.open(os.path.join(CACHE, "meta", "observers.csv.gz"), "rt") as f:
        next(f)
        for line in f:
            i, login, *_ = line.rstrip("\n").split("\t")
            if int(i) in want:
                logins[int(i)] = login
    for r in keep:
        r["observer"] = logins.get(r["observer_id"], "?")
    for sub_ in ("main", "euc"):
        for h in ("tune", "report"):
            k = [r for r in keep if r["subset"] == sub_ and r["half"] == h]
            print(f"  {sub_}/{h}: {len(k):,} photos, {len({r['u'] for r in k}):,} species, "
                  f"{len({r['observer_id'] for r in k}):,} observers, "
                  f"{sum(r['in_ship'] for r in k)} in the 2,675")
    pq.write_table(pa.Table.from_pylist(keep), os.path.join(AU, "C.parquet"))
    with open(os.path.join(AU, "C-credits.tsv"), "w") as f:
        f.write("photo_id\tobservation_uuid\tlogin\tlicence\n")
        for r in keep:
            f.write(f"{r['photo_id']}\t{r['uuid']}\t{r['observer']}\t{r['license']}\n")
    json.dump({"eligible_obs": len(rows), "eligible_species": len(nat_n),
               "eligible_euc_species": sum(U[u]["euc"] for u in nat_n),
               "licences": dict(collections.Counter(r["license"] for r in keep))},
              open(os.path.join(AU, "C-summary.json"), "w"), indent=1)
    fetch_photos(keep, os.path.join(AU, "photos"))


def c_rows():
    C = pq.read_table(os.path.join(AU, "C.parquet")).to_pylist()
    d = os.path.join(AU, "photos")
    return [r for r in C if os.path.exists(os.path.join(d, f"{r['photo_id']}.{r['ext']}"))]


def cmd_embed(a):
    import coremltools as ct
    from concurrent.futures import ThreadPoolExecutor
    rows = c_rows()
    out = os.path.join(AU, "emb-w8")
    os.makedirs(out, exist_ok=True)
    t = time.time()
    m = ct.models.MLModel(os.path.join(BS.SHIP, "encoder", "PlantEncoder-w8.mlpackage"),
                          compute_units=ct.ComputeUnit.ALL)
    print(f"w8 loaded in {time.time() - t:.1f} s; {len(rows):,} photos")
    d = os.path.join(AU, "photos")
    t0, n = time.time(), 0
    with ThreadPoolExecutor(4) as pool:
        for part in range(0, len(rows), 512):
            f = os.path.join(out, f"part-{part // 512:04d}.npz")
            if os.path.exists(f):
                continue
            chunk = rows[part:part + 512]
            embs = [m.predict({"pixel_values": x})["embedding"].reshape(-1) for x in pool.map(
                lambda r: BS.preprocess(os.path.join(d, f"{r['photo_id']}.{r['ext']}")), chunk)]
            np.savez(f + ".tmp.npz", photo_id=np.array([r["photo_id"] for r in chunk]),
                     emb=np.stack(embs).astype(np.float32))
            os.replace(f + ".tmp.npz", f)
            n += len(chunk)
            print(f"  {part + len(chunk):,}/{len(rows):,}  {(time.time() - t0) / n:.3f} s/photo",
                  flush=True)


# ----------------------------------------------------------------- prior

CELL = 0.1  # degrees


def cmd_prior(a):
    """Pool-observer research-grade records (aggregate counts only) per
    (0.1° cell, U class); records with positional accuracy > 5 km dropped."""
    con = db()
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    q = lambda c: c.replace("lat", "o.lat").replace("lon", "o.lon")  # noqa: E731
    t = con.execute(f"""
        SELECT floor((o.lat + 44.0) / {CELL})::INTEGER AS cy,
               floor((o.lon - 112.0) / {CELL})::INTEGER AS cx, m.u, count(*)::INTEGER AS n
        FROM o JOIN imap_v m USING (species_id)
        WHERE o.role = 'pool' AND {q(AUS)} AND (o.pacc IS NULL OR o.pacc <= 5000)
        GROUP BY ALL""").to_arrow_table()
    pq.write_table(t, os.path.join(AU, "prior_counts.parquet"))
    n = np.array(t.column("n"))
    print(f"prior: {int(n.sum()):,} records, {len(n):,} (cell, class) pairs, "
          f"{len(set(zip(t.column('cy').to_pylist(), t.column('cx').to_pylist()))):,} cells")


class AuPrior:
    def __init__(self, nU):
        t = pq.read_table(os.path.join(AU, "prior_counts.parquet")).to_pydict()
        import scipy.sparse as sp
        self.ny, self.nx = int(round(34.5 / CELL)) + 1, int(round(42.5 / CELL)) + 1
        cell = np.array(t["cy"]) * self.nx + np.array(t["cx"])
        self.Cm = sp.csr_matrix((np.array(t["n"], np.float32), (cell, np.array(t["u"]))),
                                shape=(self.ny * self.nx, nU))
        tot = np.asarray(self.Cm.sum(0)).ravel().astype(np.float64) + 1.0
        self.freq = (tot / tot.sum()).astype(np.float32)

    def density(self, lat, lon, sigma_km):
        """Σ over cells within 3σ of exp(−d²/2σ²) · counts (cell centres)."""
        import scipy.sparse as sp
        lat, lon = np.asarray(lat, float), np.asarray(lon, float)
        r = 3 * sigma_km
        wy = int(np.ceil(r / (110.57 * CELL))) + 1
        rows, cols, vals = [], [], []
        for i, (la, lo) in enumerate(zip(lat, lon)):
            kx = 111.32 * np.cos(np.radians(la))
            wx = int(np.ceil(r / (kx * CELL))) + 1
            cy0, cx0 = int(np.floor((la + 44.0) / CELL)), int(np.floor((lo - 112.0) / CELL))
            dy = np.arange(-wy, wy + 1)
            dx = np.arange(-wx, wx + 1)
            cy, cx = np.meshgrid(cy0 + dy, cx0 + dx, indexing="ij")
            yy = ((cy + 0.5) * CELL - 44.0 - la) * 110.57
            xx = ((cx + 0.5) * CELL + 112.0 - lo) * kx
            d2 = xx ** 2 + yy ** 2
            ok = (d2 <= r * r) & (cy >= 0) & (cy < self.ny) & (cx >= 0) & (cx < self.nx)
            rows.append(np.full(ok.sum(), i))
            cols.append((cy * self.nx + cx)[ok])
            vals.append(np.exp(-d2[ok] / (2 * sigma_km ** 2)).astype(np.float32))
        W = sp.csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))),
                          shape=(len(lat), self.ny * self.nx))
        return (W @ self.Cm).toarray().astype(np.float32)


# ----------------------------------------------------------------- score

KAPPAS = (50.0, 70.0, 100.0)
SIGMAS = (10.0, 25.0, 50.0)
ALPHAS = (4.0, 16.0, 64.0)
LAMS = (0.0, 0.25, 0.5, 0.75, 1.0)


class Set:
    """One photo set, precomputed: cosines to the U text vectors (raw and
    centred), Ship log p over the 2,675, AU-prior kernel counts per σ."""

    def __init__(self, name, emb, lat, lon, y, w, sub, ship, T, centre_t, prior, dev):
        import torch
        self.name, self.n, self.y, self.w, self.sub = name, len(emb), y, w, sub
        raw = BS.unit(np.asarray(emb, np.float32))
        self.cos = {}
        for cen in ("raw", "centred"):
            x = raw if cen == "raw" else BS.unit(raw - ship.mu[None, :])
            t = T if cen == "raw" else BS.unit(T - centre_t)
            self.cos[cen] = torch.from_numpy(x).to(dev) @ torch.from_numpy(t.astype(np.float32)).to(dev).T
        self.lp_ship = torch.from_numpy(ship.logp(emb, lat, lon).astype(np.float32)).to(dev)
        self.K = {s: torch.from_numpy(prior.density(lat, lon, s)).to(dev) for s in SIGMAS}


def log_prior(S, prior_freq, sigma, alpha):
    K = S.K[sigma]
    return torch_log((K + alpha * prior_freq[None, :]) / (K.sum(1, keepdim=True) + alpha))


def torch_log(x):
    import torch
    return torch.log(x)


def final_P(S, v, prm, ctx):
    """Full probability matrix over U (n × |U|), temperature prm["T"] (default
    1) applied to the final log p (ranking unchanged)."""
    import torch
    T = prm.get("T", 1.0)
    if v == "v0":  # Ship as shipped (2,675 labels)
        P = torch.zeros(S.n, len(ctx["nonlocal_np"]), device=S.lp_ship.device)
        P[:, ctx["ship2u"]] = torch.softmax(S.lp_ship / T, dim=1)
        return P
    Z = prm["kappa"] * S.cos[prm["centring"]]
    if v in ("z1", "h") and prm["lam"] > 0:
        Z = Z + prm["lam"] * log_prior(S, ctx["freq"], prm["sigma"], prm["alpha"])
    if v in ("z0", "z1"):
        return torch.softmax(Z / T, dim=1)
    # hybrid: rest-of-Australia penalty b; local mass redistributed by Ship
    Z = Z - prm["b"] * ctx["nonlocal_f"][None, :]
    P = torch.softmax(Z, dim=1)
    p_out = (P * ctx["nonlocal_f"][None, :]).sum(1)
    P = P * ctx["nonlocal_f"][None, :]  # non-local classes keep their z1 mass
    P[:, ctx["ship2u"]] = (1 - p_out).clamp_min(0)[:, None] * S.lp_ship.exp()
    if T != 1.0:  # (clamp: fp32 p_out can exceed 1 by an ulp → log of a negative = NaN)
        P = torch.softmax(torch.log(P.clamp_min(1e-30)) / T, dim=1)
    return P


def predict(S, v, prm, ctx):
    """→ (top-5 U indices, p of the top-1). v ∈ z0 / z1 / h / v0."""
    P = final_P(S, v, prm, ctx)
    o = P.topk(5, dim=1)
    top, pv = o.indices.cpu().numpy(), o.values.cpu().numpy()
    if v != "h" or prm["m"] <= 0:
        return top, pv[:, 0].copy()
    # margin m: a non-local class is named first only if it beats the best local by e^m
    best_loc_p, best_loc = P[:, ctx["ship2u"]].max(1)
    best_loc_p, bl = best_loc_p.cpu().numpy(), ctx["ship2u_np"][best_loc.cpu().numpy()]
    keep_local = ctx["nonlocal_np"][top[:, 0]] & (
        np.log(pv[:, 0] + 1e-30) - np.log(best_loc_p + 1e-30) <= prm["m"])
    p1 = pv[:, 0].copy()
    for j in np.nonzero(keep_local)[0]:
        rest = [x for x in top[j] if x != bl[j]]
        top[j] = [bl[j]] + rest[:4]
        p1[j] = best_loc_p[j]
    return top, p1


def fit_T(S, v, prm, ctx):
    """Temperature on the final log p minimising NLL of the truth (C-tune)."""
    import torch
    best = None
    y = torch.from_numpy(S.y).to(S.lp_ship.device)
    for T in (0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 6.0):
        P = final_P(S, v, dict(prm, T=T), ctx)
        nll = float(-torch.log(P[torch.arange(S.n), y] + 1e-12).mean())
        if best is None or nll < best[1]:
            best = (T, nll)
    return best[0]


def metrics(S, top, p1, ctx, mask=None):
    m = np.ones(S.n, bool) if mask is None else mask
    y, w = S.y, S.w
    inl = (y >= 0) & m
    yy = np.maximum(y, 0)
    r1 = top[:, 0] == yy
    r5 = (top == yy[:, None]).any(1)
    g1 = ctx["genus"][top[:, 0]] == ctx["genus"][yy]
    conf = p1 >= 0.5
    cw = conf & ~r1  # confidently wrong (over all photos incl. not-in-label)
    cw_all = conf & ~(r1 & (y >= 0))

    def wavg(h, mm):
        return float((h[mm] * w[mm]).sum() / w[mm].sum()) if mm.any() else None

    def savg(h, mm):
        per = collections.defaultdict(list)
        for k, x in zip(y[mm], h[mm]):
            per[k].append(x)
        return float(np.mean([np.mean(v) for v in per.values()])) if per else None
    out = {"n": int(m.sum()), "species": int(len(set(y[inl]))),
           "top1": float(r1[inl].mean()), "top5": float(r5[inl].mean()), "genus1": float(g1[inl].mean()),
           "conf_wrong": float(cw_all[m].mean()), "confident": float(conf[m].mean()),
           "right_when_conf": float(r1[inl & conf].mean()) if (inl & conf).any() else None,
           "top1_w": wavg(r1, inl), "top5_w": wavg(r5, inl), "genus1_w": wavg(g1, inl),
           "conf_wrong_w": wavg(cw_all, m),
           "top1_sp": savg(r1, inl), "genus1_sp": savg(g1, inl)}
    return out


def cmd_score(a):
    import torch
    t0 = time.time()
    dev = "mps"
    U = pq.read_table(os.path.join(AU, "labels.parquet"),
                      columns=["name", "genus", "ship", "native", "euc"]).to_pydict()
    nU = len(U["name"])
    T = np.load(os.path.join(AU, "text.npz"))["emb"].astype(np.float32)
    centre_t = T.mean(0)
    ship = BS.Ship(BS.SHIP, "bank-int8.bin")
    lj = json.load(open(os.path.join(BS.SHIP, "labels.json")))["labels"]
    ship2u = np.full(len(lj), -1)
    for ui, s_ in enumerate(U["ship"]):
        if s_ >= 0:
            ship2u[s_] = ui
    assert (ship2u >= 0).all()
    gnames = {g: i for i, g in enumerate(sorted(set(U["genus"])))}
    nonlocal_ = np.array([s_ < 0 for s_ in U["ship"]])
    prior = AuPrior(nU)
    ctx = {"ship2u": torch.from_numpy(ship2u).to(dev), "freq": torch.from_numpy(prior.freq).to(dev),
           "nonlocal_f": torch.from_numpy(nonlocal_.astype(np.float32)).to(dev),
           "nonlocal_b": torch.from_numpy(nonlocal_).to(dev),
           "genus": np.array([gnames[g] for g in U["genus"]]), "ship2u_np": ship2u,
           "nonlocal_np": nonlocal_}
    ctx_np_ship2u = ship2u
    # ---- A (Tasmanian wild): val = eval's cloud fp16 embeddings, test = shipped w8
    SS = BS.load_sets()
    L = SS["L"]
    assert list(L["species_id"]) == [l["inat"] for l in lj]
    ev = SS["ev"]
    ids_w8, E_w8 = BS.load_parts(os.path.join(BS.SHIP, "eval", "coreml-w8"))
    pos = {int(p): i for i, p in enumerate(ids_w8)}
    sets = {}
    for nm, X, e in (("A-val", ev["val"]["X"].astype(np.float32), ev["val"]),
                     ("A-test", E_w8[[pos[int(p)] for p in ev["test"]["photo_id"]]], ev["test"])):
        y = np.where(e["y"] >= 0, ctx_np_ship2u[np.maximum(e["y"], 0)], -1)
        sets[nm] = Set(nm, X, e["lat"], e["lon"], y, e["w"], None, ship, T, centre_t, prior, dev)
        print(f"{nm}: {len(X):,} photos ({time.time() - t0:.0f} s)", flush=True)
    rows = c_rows()
    ids_c, E_c = BS.load_parts(os.path.join(AU, "emb-w8"))
    cpos = {int(p): i for i, p in enumerate(ids_c)}
    for h in ("tune", "report"):
        rr = [r for r in rows if r["half"] == h and r["photo_id"] in cpos]
        sets["C-" + h] = Set("C-" + h, E_c[[cpos[r["photo_id"]] for r in rr]],
                             np.array([r["lat"] for r in rr]), np.array([r["lon"] for r in rr]),
                             np.array([r["u"] for r in rr]), np.array([r["w"] for r in rr], float),
                             np.array([r["subset"] for r in rr]), ship, T, centre_t, prior, dev)
        sets["C-" + h].rows = rr
        print(f"C-{h}: {len(rr):,} photos ({time.time() - t0:.0f} s)", flush=True)

    def ev_(nm, v, prm):
        S = sets[nm]
        top, p1 = predict(S, v, prm, ctx)
        if nm.startswith("A"):
            return metrics(S, top, p1, ctx)
        out = {}
        for sub_ in ("main", "euc"):
            out[sub_] = metrics(S, top, p1, ctx, S.sub == sub_)
        eu = np.array([U["euc"][u] for u in S.y])
        out["main_euc"] = metrics(S, top, p1, ctx, (S.sub == "main") & eu)
        ins = np.array([U["ship"][u] >= 0 for u in S.y])
        out["main_in2675"] = metrics(S, top, p1, ctx, (S.sub == "main") & ins)
        out["main_not2675"] = metrics(S, top, p1, ctx, (S.sub == "main") & ~ins)
        return out

    def util(r):  # C-tune: species-averaged main + per-photo eucalypts
        return 0.5 * r["main"]["top1_sp"] + 0.5 * r["euc"]["top1"]

    res = {"sizes": {"U": nU, "natives": int(sum(U["native"])), "ship": len(lj)}}
    names = ("A-val", "A-test", "C-tune", "C-report")
    res["v0"] = {nm: ev_(nm, "v0", {}) for nm in names}
    print("v0 A-test top1_w", res["v0"]["A-test"]["top1_w"], flush=True)
    for v, grid in (("z0", [{"centring": c, "kappa": k, "lam": 0.0} for c in ("raw", "centred")
                             for k in KAPPAS]),
                    ("z1", [{"centring": c, "kappa": k, "sigma": s_, "alpha": al, "lam": lm}
                            for c in ("raw", "centred") for k in KAPPAS for s_ in SIGMAS
                            for al in ALPHAS for lm in LAMS[1:]])):
        sw = [{"prm": p, "C-tune": ev_("C-tune", v, p)} for p in grid]
        best = max(sw, key=lambda r: util(r["C-tune"]))
        res[v] = {"chosen": best["prm"], "sweep": sw}
        res[v].update({nm: ev_(nm, v, best["prm"]) for nm in names})
        print(f"{v}: {len(sw)} settings, chosen {best['prm']} ({time.time() - t0:.0f} s)", flush=True)
    # hybrid: z1's prior settings and centring; κ, λ, b, m re-tuned under the A-val guard
    z1 = res["z1"]["chosen"]
    base = res["v0"]["A-val"]
    grid = [{"centring": z1["centring"], "kappa": k, "sigma": z1["sigma"], "alpha": z1["alpha"],
             "lam": lm, "b": b, "m": m} for k in KAPPAS for lm in LAMS for b in (0, 2, 4, 6, 8)
            for m in (0.0, 1.0, 2.0)]
    sw = []
    for p in grid:
        rA, rC = ev_("A-val", "h", p), ev_("C-tune", "h", p)
        ok = rA["top1_w"] >= base["top1_w"] - a.max_top1_drop and \
            rA["conf_wrong_w"] <= base["conf_wrong_w"] + a.max_wrong_rise
        sw.append({"prm": p, "A-val": rA, "C-tune": rC, "ok": ok})
    good = [r for r in sw if r["ok"]]
    for tag, pool_ in (("h", good), ("h_unconstrained", sw)):
        best = max(pool_, key=lambda r: util(r["C-tune"]))
        res[tag] = {"chosen": best["prm"], "n_ok": len(good), "n": len(sw)}
        res[tag].update({nm: ev_(nm, "h", best["prm"]) for nm in names})
        print(f"{tag}: chosen {best['prm']} ({len(good)}/{len(sw)} pass the A-val guard)", flush=True)
    res["h_sweep"] = sw
    # strict guard: A-val top-1 and confidently-wrong within 0.05 pt of v0
    strict = [r for r in sw if r["A-val"]["top1_w"] >= base["top1_w"] - 0.0005 and
              r["A-val"]["conf_wrong_w"] <= base["conf_wrong_w"] + 0.0005]
    best = max(strict, key=lambda r: util(r["C-tune"]))
    res["h_strict"] = {"chosen": best["prm"], "n_ok": len(strict)}
    res["h_strict"].update({nm: ev_(nm, "h", best["prm"]) for nm in names})
    print(f"h_strict: chosen {best['prm']} ({len(strict)} pass)", flush=True)
    # calibrated variants: temperature fitted on C-tune (ranking unchanged, so only
    # the confidence numbers move)
    for v in ("z0", "z1", "h", "h_strict"):
        vv = "h" if v.startswith("h") else v
        T = fit_T(sets["C-tune"], vv, res[v]["chosen"], ctx)
        prm = dict(res[v]["chosen"], T=T)
        res[v + "_cal"] = {"chosen": prm}
        res[v + "_cal"].update({nm: ev_(nm, vv, prm) for nm in names})
        print(f"{v}_cal: T {T}", flush=True)
    # paired A-test change of h vs v0
    S = sets["A-test"]
    t0_, _ = predict(S, "v0", {}, ctx)
    inl = S.y >= 0
    r0 = inl & (t0_[:, 0] == S.y)
    for v in ("h", "h_strict"):
        th, _ = predict(S, "h", res[v]["chosen"], ctx)
        rh = inl & (th[:, 0] == S.y)
        res[v + "_A_paired"] = {"lost": int((r0 & ~rh).sum()), "gained": int((~r0 & rh).sum()),
                                "photos": int(inl.sum())}
    # eucalypt examples (C-report) under h
    S = sets["C-report"]
    th, ph = predict(S, "h", res["h_strict_cal"]["chosen"], ctx)
    ex = [{"truth": U["name"][S.y[j]], "said": [U["name"][i] for i in th[j][:3]], "p": round(float(ph[j]), 2)}
          for j in range(S.n) if S.sub[j] == "euc"][:40]
    res["euc_examples"] = ex
    json.dump(res, open(os.path.join(AU, "results.json"), "w"), indent=1, default=str)
    write_md(res, os.path.join(AU, "results.md"))
    print(open(os.path.join(AU, "results.md")).read())
    print(f"total {time.time() - t0:.0f} s")


def write_md(res, path):
    P = lambda x: "–" if x is None else f"{100 * x:.1f}"  # noqa: E731
    out = ["| variant | A-test top-1 (w) | A conf. wrong | C-main top-1 (sp.) | C-main top-1 (w) | "
           "C-main top-5 (sp.) | C-main genus (sp.) | C-main conf. wrong | C-main right when conf. | "
           "euc top-1 | euc top-5 | euc genus | euc conf. wrong | euc right when conf. | euc top-1 (sp.) |",
           "|" + "---|" * 15]
    for v in ("v0", "z0", "z1", "h", "h_strict", "z0_cal", "z1_cal", "h_cal", "h_strict_cal"):
        A, M, E = res[v]["A-test"], res[v]["C-report"]["main"], res[v]["C-report"]["euc"]
        out.append(f"| {v} {json.dumps(res[v].get('chosen', ''))} | {P(A['top1_w'])} | {P(A['conf_wrong_w'])} | "
                   f"{P(M['top1_sp'])} | {P(M['top1_w'])} | {P(M['top5'])} | {P(M['genus1_sp'])} | "
                   f"{P(M['conf_wrong'])} | {P(M['right_when_conf'])} | {P(E['top1'])} | {P(E['top5'])} | "
                   f"{P(E['genus1'])} | {P(E['conf_wrong'])} | {P(E['right_when_conf'])} | {P(E['top1_sp'])} |")
    out.append("")
    out.append("C-main split by whether the species is one of the shipped 2,675 (top-1 per photo):")
    for v in ("v0", "z0", "z1", "h", "h_strict"):
        r = res[v]["C-report"]
        out.append(f"- {v}: in 2,675 {P(r['main_in2675']['top1'])} (n {r['main_in2675']['n']}), "
                   f"not {P(r['main_not2675']['top1'])} (n {r['main_not2675']['n']}); "
                   f"eucalypts in C-main {P(r['main_euc']['top1'])} (n {r['main_euc']['n']})")
    open(path, "w").write("\n".join(out) + "\n")


# ----------------------------------------------------------------- bench

def cmd_bench(a):
    """PyTorch MPS fp16 image tower on 200 C photos (pre-decoded: GPU only)."""
    import open_clip
    import torch
    rows = c_rows()[:200]
    d = os.path.join(AU, "photos")
    X = torch.from_numpy(np.concatenate([BS.preprocess(os.path.join(d, f"{r['photo_id']}.{r['ext']}"))
                                         for r in rows]))
    t = time.time()
    for r in rows:
        BS.preprocess(os.path.join(d, f"{r['photo_id']}.{r['ext']}"))
    dec = (time.time() - t) / len(rows)
    model, _, _ = open_clip.create_model_and_transforms(BS.HF)
    model = model.visual.to("mps").to(torch.float16).eval()
    out = {}
    with torch.no_grad():
        for bs in (32, 64):
            model(X[:bs].to("mps", torch.float16))
            torch.mps.synchronize()
            t = time.time()
            for i in range(0, len(X), bs):
                model(X[i:i + bs].to("mps", torch.float16))
            torch.mps.synchronize()
            out[f"mps_fp16_bs{bs}_img_s"] = round(len(X) / (time.time() - t), 1)
    out["decode_preprocess_ms_per_photo_1core"] = round(1000 * dec, 1)
    sz = [os.path.getsize(os.path.join(d, f"{r['photo_id']}.{r['ext']}")) for r in c_rows()]
    out["medium_photo_kb_mean"] = round(np.mean(sz) / 1000, 1)
    print(out)
    json.dump(out, open(os.path.join(AU, "bench.json"), "w"), indent=1)


# ----------------------------------------------------------------- plan

def cmd_plan(a):
    """Manifests for a trained Australia-wide model (no download here)."""
    con = db()
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    U = pq.read_table(os.path.join(AU, "labels.parquet"), columns=["name", "native", "euc", "ship"]).to_pydict()
    con.register("uinfo", pa.table({"u": np.arange(len(U["name"])), "native": U["native"],
                                    "euc": U["euc"], "ship": U["ship"]}))
    q = lambda c: c.replace("lat", "o.lat").replace("lon", "o.lon")  # noqa: E731
    out = os.path.join(AU, "plan")
    os.makedirs(out, exist_ok=True)
    have = set(pq.read_table(os.path.join(CACHE, "sets", "train.parquet"),
                             columns=["photo_id"]).column(0).to_pylist()) | set(
        pq.read_table(os.path.join(CACHE, "sets", "test.parquet"), columns=["photo_id"]).column(0).to_pylist())
    con.register("have_v", pa.table({"photo_id": sorted(have)}))
    base = f"""
        SELECT o.uuid, o.observer_id, o.lat, o.lon, o.observed_on, o.role, m.u,
               p.photo_id, p.ext, p.license,
               CASE WHEN {q(AUS)} THEN 0 ELSE 1 END AS region,
               p.photo_id NOT IN (SELECT photo_id FROM have_v) AS new_photo,
               hash(o.uuid::VARCHAR || 'izzy-au') AS h
        FROM o JOIN imap_v m USING (species_id) JOIN photo p USING (uuid)
        WHERE p.photo_id NOT IN (SELECT photo_id FROM shared)"""
    con.execute(f"""CREATE TEMP TABLE tr AS
        WITH c AS ({base} AND o.role = 'pool'),
        c2 AS (SELECT *, row_number() OVER (PARTITION BY u, observer_id ORDER BY region, new_photo, h) AS rk_obs FROM c),
        c3 AS (SELECT *, row_number() OVER (PARTITION BY u ORDER BY rk_obs > 3, region, new_photo, h)
                   AS rk FROM c2)
        SELECT * EXCLUDE (h, rk_obs, new_photo) FROM c3 WHERE rk <= {a.cap}""")
    con.execute(f"""CREATE TEMP TABLE te AS
        WITH c AS ({base} AND o.role IN ('val', 'test') AND {q(AUS)}
                   AND o.observed_on >= DATE '{CUTOFF}'),
        c2 AS (SELECT *, row_number() OVER (PARTITION BY u, observer_id ORDER BY h) AS rk_obs FROM c),
        c3 AS (SELECT *, row_number() OVER (PARTITION BY role, u ORDER BY rk_obs > 2, h) AS rk,
                         count(*) OVER (PARTITION BY role, u) AS n_split FROM c2)
        SELECT * EXCLUDE (h, rk_obs, new_photo) FROM c3 WHERE rk <= 8""")
    for t in ("tr", "te"):
        con.execute(f"COPY {t} TO '{os.path.join(out, 'train' if t == 'tr' else 'eval')}.parquet' (FORMAT parquet)")
    r = {}
    r["train_photos"], r["train_classes"], r["train_aus_share"], r["train_already_embedded"] = con.execute(
        "SELECT count(*), count(DISTINCT u), avg((region = 0)::INT), "
        "count(*) FILTER (photo_id IN (SELECT photo_id FROM have_v)) FROM tr").fetchone()
    r["train_licences"] = dict(con.execute("SELECT license, count(*) FROM tr GROUP BY 1").fetchall())
    tiers = con.execute("""
        SELECT CASE WHEN n >= 100 THEN '100' WHEN n >= 20 THEN '20-99' WHEN n >= 5 THEN '5-19'
                    ELSE '1-4' END, count(*), sum(n) FROM (SELECT u, count(*) n FROM tr GROUP BY u) GROUP BY 1""").fetchall()
    r["train_tiers"] = {k: {"classes": n, "photos": int(p)} for k, n, p in tiers}
    nat = con.execute("""SELECT count(*) FILTER (n >= 5), count(*) FILTER (n >= 20), sum(n),
                         count(*) FILTER (n >= 5 AND euc), count(*) FILTER (n >= 20 AND euc)
                         FROM (SELECT u, count(*) n FROM tr GROUP BY u) JOIN uinfo USING (u)
                         WHERE native""").fetchone()
    r["natives_ge5_train"], r["natives_ge20_train"], r["natives_train_photos"], \
        r["euc_ge5_train"], r["euc_ge20_train"] = [int(x) for x in nat]
    r["eval"] = {k: {"photos": n, "classes": c, "already_embedded": e} for k, n, c, e in con.execute(
        "SELECT role, count(*), count(DISTINCT u), count(*) FILTER (photo_id IN (SELECT photo_id FROM have_v)) "
        "FROM te GROUP BY 1").fetchall()}
    r["cap"] = a.cap
    json.dump(r, open(os.path.join(out, "summary.json"), "w"), indent=1, default=str)
    print(json.dumps(r, indent=1, default=str))


# ----------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("labels", "text", "embed", "prior", "bench"):
        sub.add_parser(c)
    p = sub.add_parser("plan")
    p.add_argument("--cap", type=int, default=100)
    p = sub.add_parser("score")
    p.add_argument("--max-top1-drop", type=float, default=0.003)
    p.add_argument("--max-wrong-rise", type=float, default=0.003)
    p = sub.add_parser("testset")
    p.add_argument("--main", type=int, default=2400)
    p.add_argument("--euc", type=int, default=600)
    p.add_argument("--obs-cap", type=int, default=10)
    a = ap.parse_args()
    os.makedirs(AU, exist_ok=True)
    {"labels": cmd_labels, "text": cmd_text, "testset": cmd_testset, "embed": cmd_embed,
     "prior": cmd_prior, "score": cmd_score, "bench": cmd_bench, "plan": cmd_plan}[a.cmd](a)


if __name__ == "__main__":
    main()

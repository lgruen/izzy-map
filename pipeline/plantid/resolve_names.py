#!/usr/bin/env python3
"""APC ↔ iNaturalist name resolution for the Australia-wide plant-ID labels
(EVALUATION / DATA PREP ONLY — nothing here ships).

Problem: of the 22,122 Australia-wide labels (ship/au-labels.json), 6,354
have no training photo; 1,733 of those have no iNat taxon at all. Some are
name mismatches — iNat uses another accepted name, another genus, an
orthographic variant, keeps the APC species as an infraspecies, or lumps
it — and each mismatch costs a species its photos.

Subcommands (outputs under pipeline/cache/plantid/names/, gitignored):

  fetch    API pass, cached one file per request (resumable; re-runs read
           the cache): iNat /v1/taxa/{ids} for every photo-less label's iNat
           ids and every INACTIVE snapshot taxon named like a label or one of
           its APC synonyms (→ current_synonymous_taxon_ids, observations_
           count); GBIF backbone species/match (verbose, kingdom Plantae) +
           /species/{key}/synonyms for every label without an iNat taxon
           (--gbif-all: every photo-less label); iNat
           /v1/taxa?q=<APC name> (synonym search, `matched_term`) for every
           label still without an iNat candidate. iNat ≤ 1 req/s, GBIF 3
           threads; User-Agent "izzymap-plantid-eval/1".
  resolve  candidates from (1) APC synonyms of ALL ranks (the eval used
           species-rank, unambiguous ones only; misapplied/excluded never),
           (2) iNat taxon swaps (inactive → current), (3) iNat synonym search,
           (4) orthographic keys within the genus (gender endings, -i/-ii,
           -ae/-iae, hyphens), (5) GBIF accepted name + synonyms, (6) same
           epithet in the same family (genus transfers) → deterministic rules
           (below), the rest from names/adjudication.json (hand decisions,
           every one pointing at a taxon id an API returned, with evidence),
           the residue → names/residue.json. Photo payoff from the local iNat
           open-data snapshot (sets/work.duckdb; research grade, CC0/BY/BY-NC
           photo, not shared, role 'pool' = train-eligible) →
           names/apc_inat_map.json + names/summary.json.
  verify   re-queries 40 random new mappings live (no cache) and checks
           taxon id, name, active flag, kingdom and family.

Deterministic rules (a candidate = an ACTIVE snapshot taxon, species or
infraspecies rank): exactly one distinct candidate taxon from the strong
sources (APC non-pro-parte synonym, iNat swap, iNat synonym search,
same-genus orthographic key), not already feeding another label → mapped;
already feeding another label → `lump` (iNat merges the APC species into
another APC species: photos cannot be attributed, no flow); an iNat swap to
several current taxa none of which feeds another label → `split` (all
flow). Everything else (GBIF-only, pro-parte, genus transfers, several
candidates) is adjudicated or left `none`.

Relations: exact (same name, existing mapping), synonym (iNat accepts
another name for the same concept; `inat_rank` says when iNat keeps it as an
infraspecies — then only observations identified to that infraspecies
flow, and they should leave the parent APC class), orthographic, split (one
APC species ↔ several iNat taxa; all flow), lump (several APC species ↔ one
iNat taxon; nothing flows), none.

Environment: uv run --with duckdb --with pyarrow python3 -I \\
    pipeline/plantid/resolve_names.py {fetch|resolve|verify}
"""
import argparse
import collections
import concurrent.futures as cf
import csv
import gzip
import hashlib
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
NAMES = os.path.join(CACHE, "names")
LABELS = os.path.join(CACHE, "ship", "au-labels.json")
APC_CSV = os.path.join(CACHE, "australia", "apc", "taxon.csv")
INAT_MAP = os.path.join(CACHE, "australia", "inat_map.parquet")
DB = os.path.join(CACHE, "sets", "work.duckdb")
ADJ = os.path.join(NAMES, "adjudication.json")
UA = {"User-Agent": "izzymap-plantid-eval/1", "Accept-Encoding": "gzip"}
INAT = "https://api.inaturalist.org/v1"
GBIF = "https://api.gbif.org/v1"
PLANTAE = 47126
SYN_OK = {"taxonomic synonym", "nomenclatural synonym", "basionym", "orthographic variant",
          "replaced synonym", "doubtful taxonomic synonym", "pro parte taxonomic synonym",
          "pro parte nomenclatural synonym", "doubtful pro parte taxonomic synonym",
          "doubtful nomenclatural synonym", "alternative name"}
RANK_WORDS = {"subsp.", "var.", "f.", "forma", "subvar.", "nothosubsp.", "nothovar.", "ssp.", "subf."}
AUS = "lat BETWEEN -44.0 AND -9.5 AND lon BETWEEN 112.0 AND 154.5"
STRONG = ("apc-syn", "inat-swap", "inat-q", "ortho")


# ------------------------------------------------------------- helpers

def to_inat(name):
    """APC canonical name → iNat's form (no rank words; × kept)."""
    return " ".join(t for t in name.replace("×", " × ").split() if t not in RANK_WORDS)


def norm(name):
    return " ".join(to_inat(name).lower().replace("×", " ").split())


def anorm(a):
    return re.sub(r"[\s.]", "", (a or "").lower())


def okeys(ep):
    """Orthographic keys of an epithet: two epithets of ONE genus that share a
    key differ only by gender ending, -i/-ii, -ae/-iae or a hyphen."""
    e = ep.lower().replace("-", "").replace("ë", "e").replace("ï", "i")
    bases = {e}
    if e.endswith("ii"):
        bases.add(e[:-1])
    elif e.endswith("i"):
        bases.add(e + "i")
    if e.endswith("iae"):
        bases.add(e[:-3] + "ae")
    elif e.endswith("ae"):
        bases.add(e[:-2] + "iae")
    keys = set(bases)
    for b in bases:
        for suf, cls in (("us", "U"), ("um", "U"), ("a", "U"), ("is", "I"), ("e", "I"),
                         ("er", "R"), ("ra", "R"), ("rum", "R"),
                         ("ris", "S"), ("re", "S"), ("er", "S")):
            if b.endswith(suf) and len(b) > len(suf) + 2:
                keys.add(b[: -len(suf)] + "|" + cls)
    return keys


def cpath(kind, key):
    h = hashlib.sha1(key.encode()).hexdigest()
    return os.path.join(NAMES, kind, h[:2], h + ".json.gz")


def cget(kind, key):
    p = cpath(kind, key)
    if os.path.exists(p):
        with gzip.open(p, "rt") as f:
            return json.load(f)
    return None


def cput(kind, key, obj):
    p = cpath(kind, key)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with gzip.open(p + ".tmp", "wt") as f:
        json.dump(obj, f)
    os.replace(p + ".tmp", p)


def http_json(url, tries=5):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                b = r.read()
                if r.headers.get("Content-Encoding") == "gzip":
                    b = gzip.decompress(b)
                return {"status": r.status, "body": json.loads(b)}
        except urllib.error.HTTPError as e:
            if e.code in (404, 422):
                return {"status": e.code, "body": None}
            time.sleep(60 if e.code == 429 else 5 * (k + 1))
        except Exception:  # noqa: BLE001 — network hiccup, retry
            time.sleep(5 * (k + 1))
    raise RuntimeError(f"giving up on {url}")


class Pace:
    """≥ `gap` s between request starts (iNat asks for ≤ 1 req/s)."""

    def __init__(self, gap):
        self.gap, self.t, self.lock = gap, 0.0, threading.Lock()

    def wait(self):
        with self.lock:
            d = self.t + self.gap - time.time()
            if d > 0:
                time.sleep(d)
            self.t = time.time()


INAT_PACE = Pace(1.05)


def inat_get(kind, key, url):
    c = cget(kind, key)
    if c is not None:
        return c, False
    INAT_PACE.wait()
    r = http_json(url)
    cput(kind, key, r)
    return r, True


def gbif_get(kind, key, url):
    c = cget(kind, key)
    if c is not None:
        return c
    r = http_json(url)
    cput(kind, key, r)
    return r


# ------------------------------------------------------------- data

def load_labels():
    L = json.load(open(LABELS))["labels"]
    cnt = collections.Counter(l["name"] for l in L)
    for i, l in enumerate(L):
        l["i"] = i
        l["key"] = l["name"] if cnt[l["name"]] == 1 else f"{l['name']} [{i}]"
    return L


def load_apc():
    """accepted species name → {author, family, syn: [(name, rank, status, author)]},
    plus every APC accepted name (any rank) and, per name, the accepted
    species it is a synonym of (to spot names that belong elsewhere)."""
    csv.field_size_limit(10 ** 9)
    rows = list(csv.DictReader(open(APC_CSV, encoding="utf-8")))
    acc_by_id, acc_names = {}, set()
    for x in rows:
        if x["taxonomicStatus"] == "accepted":
            acc_by_id[x["taxonID"]] = x
            acc_names.add(x["canonicalName"])
    sp = {}
    for x in acc_by_id.values():
        if x["taxonRank"] == "Species":
            sp.setdefault(x["canonicalName"], {"author": x["scientificNameAuthorship"],
                                               "family": x["family"], "syn": []})
    syn_of = collections.defaultdict(set)  # synonym name → accepted names (any rank)
    for x in rows:
        st = x["taxonomicStatus"]
        if st == "accepted" or not x["acceptedNameUsageID"]:
            continue
        a = acc_by_id.get(x["acceptedNameUsageID"])
        if a is None:
            continue
        if st in SYN_OK:
            syn_of[x["canonicalName"]].add(a["canonicalName"])
            if a["taxonRank"] == "Species" and a["canonicalName"] in sp and x["canonicalName"] != a["canonicalName"]:
                sp[a["canonicalName"]]["syn"].append(
                    (x["canonicalName"], x["taxonRank"], st, x["scientificNameAuthorship"]))
    return sp, acc_names, syn_of


def load_snapshot():
    import duckdb
    con = duckdb.connect(DB, read_only=True)
    taxa = {}
    for tid, anc, rank, name, active in con.execute(
            "SELECT taxon_id, ancestry, rank, name, active FROM taxa").fetchall():
        taxa[tid] = {"id": tid, "anc": anc or "", "rank": rank, "name": name, "active": bool(active)}
    fam = {t["id"]: t["name"] for t in taxa.values() if t["rank"] == "family"}
    gen = {t["id"]: t["name"] for t in taxa.values() if t["rank"] == "genus"}
    for t in taxa.values():
        a = [int(x) for x in t["anc"].split("/") if x]
        t["family"] = next((fam[x] for x in a if x in fam), None)
        t["genus_id"] = next((x for x in a if x in gen), None)
        t["species_id"] = next((x for x in a if x in taxa and taxa[x]["rank"] == "species"), None) \
            if t["rank"] != "species" else t["id"]
    sql = f"""
        SELECT {{k}}, count(*), count(*) FILTER ({AUS}),
               count(p.photo_id) FILTER (s.photo_id IS NULL),
               count(p.photo_id) FILTER (o.role = 'pool' AND s.photo_id IS NULL),
               count(p.photo_id) FILTER (o.role = 'pool' AND s.photo_id IS NULL AND {AUS})
        FROM o LEFT JOIN photo p USING (uuid) LEFT JOIN shared s ON s.photo_id = p.photo_id
        GROUP BY 1"""
    direct = {r[0]: r[1:] for r in con.execute(sql.format(k="o.taxon_id")).fetchall()}
    rollup = {r[0]: r[1:] for r in con.execute(sql.format(k="o.species_id")).fetchall()}
    return taxa, direct, rollup


def subtree_counts(tid, taxa, direct, kids):
    tot = [0] * 5
    stack = [tid]
    while stack:
        x = stack.pop()
        for k, v in enumerate(direct.get(x, (0,) * 5)):
            tot[k] += v
        stack.extend(kids.get(x, ()))
    return tuple(tot)


def load_owner():
    import pyarrow.parquet as pq
    own = collections.defaultdict(set)
    for r in pq.read_table(INAT_MAP).to_pylist():
        own[r["species_id"]].add(r["u"])
    return own


# ------------------------------------------------------------- fetch

def photoless(L):
    return [l for l in L if l["train_photos"] == 0]


def cmd_fetch(a):
    t0 = time.time()
    L = load_labels()
    P = photoless(L)
    sp, _, _ = load_apc()
    taxa, _, _ = load_snapshot()
    by_name = collections.defaultdict(list)
    for t in taxa.values():
        by_name[t["name"]].append(t)
    # 1. iNat ids: photo-less labels' own ids + inactive snapshot taxa named
    #    like the label or one of its APC synonyms
    ids = set()
    for l in P:
        ids.update(l["inat"])
        for n in [l["name"]] + [s[0] for s in sp.get(l["name"], {}).get("syn", [])]:
            ids.update(t["id"] for t in by_name.get(to_inat(n), []) if not t["active"])
    ids = sorted(ids)
    batches = [ids[k:k + 30] for k in range(0, len(ids), 30)]
    q_todo = [l for l in P if not l["inat"]]
    # GBIF (~0.9-2 s per request): labels without an iNat taxon; --gbif-all
    # adds the photo-less labels that have one (only fills gbif_taxon_key)
    gb = [l for l in P if a.gbif_all or not l["inat"]]
    print(f"photo-less {len(P)}; iNat id batches {len(batches)} ({len(ids)} ids); "
          f"GBIF match {len(gb)}; iNat q ≤ {len(q_todo)}", flush=True)

    def gbif_one(l):
        n = l["name"]
        m = gbif_get("gbif_match", n, f"{GBIF}/species/match?" + urllib.parse.urlencode(
            {"name": n, "kingdom": "Plantae", "verbose": "true"}))
        b = m["body"] or {}
        # synonyms only where they can help: no iNat taxon yet, or GBIF calls
        # the APC name a synonym (~0.9 s per GBIF request, so not for all)
        if b.get("matchType") in ("EXACT", "FUZZY") and b.get("usageKey") and (
                not l["inat"] or b.get("status") != "ACCEPTED"):
            for k in {b.get("acceptedUsageKey") or b["usageKey"], b["usageKey"]}:
                gbif_get("gbif_syn", str(k), f"{GBIF}/species/{k}/synonyms?limit=500")
        return n

    gb.sort(key=lambda l: bool(l["inat"]))  # labels without an iNat taxon first
    ex = cf.ThreadPoolExecutor(6)
    gfut = [ex.submit(gbif_one, l) for l in gb]
    new = 0
    for k, b in enumerate(batches):
        _, fresh = inat_get("inat_ids", ",".join(map(str, b)), f"{INAT}/taxa/{','.join(map(str, b))}")
        new += fresh
        if k % 20 == 0:
            print(f"  ids {k}/{len(batches)}  {time.time() - t0:.0f} s", flush=True)
    # 2. synonym search for no-iNat labels without a strong offline candidate
    swaps = inat_swaps(ids)
    skip = 0
    for k, l in enumerate(q_todo):
        c = offline_candidates(l, sp, by_name, swaps)
        if any(x["src"] in ("apc-syn", "inat-swap") and not x.get("pro_parte") for x in c):
            skip += 1
            continue
        inat_get("inat_q", l["name"], f"{INAT}/taxa?" + urllib.parse.urlencode(
            {"q": l["name"], "rank": "species,subspecies,variety,form", "per_page": 30}))
        if k % 100 == 0:
            print(f"  q {k}/{len(q_todo)} (skipped {skip})  {time.time() - t0:.0f} s", flush=True)
    for f in cf.as_completed(gfut):
        f.result()
    ex.shutdown()
    print(f"done in {time.time() - t0:.0f} s (q skipped {skip})")


def inat_records(ids):
    """id → iNat taxon record from the cached /v1/taxa/{ids} batches."""
    out = {}
    for k in range(0, len(ids), 30):
        b = ids[k:k + 30]
        c = cget("inat_ids", ",".join(map(str, b)))
        if c and c["body"]:
            for r in c["body"]["results"]:
                out[r["id"]] = {"id": r["id"], "name": r["name"], "rank": r["rank"],
                                "active": r["is_active"], "obs": r.get("observations_count"),
                                "current": r.get("current_synonymous_taxon_ids") or [],
                                "anc": r.get("ancestor_ids") or []}
    return out


def inat_swaps(ids):
    return {i: r["current"] for i, r in inat_records(ids).items() if not r["active"] and r["current"]}


def offline_candidates(l, sp, by_name, swaps, ortho_index=None):
    """Candidate iNat taxa (active, from the snapshot) for one label."""
    out = []
    names = [(l["name"], "label", "", "")] + [(s[0], s[1], s[2], s[3]) for s in sp.get(l["name"], {}).get("syn", [])]
    for n, rank, st, auth in names:
        for t in by_name.get(to_inat(n), []):
            if t["active"] and rank != "label":
                out.append({"tid": t["id"], "src": "apc-syn", "via": n, "status": st, "apc_rank": rank, "author": auth,
                            "pro_parte": "pro parte" in st or "doubtful" in st})
            if not t["active"]:
                seen, todo = set(), list(swaps.get(t["id"], []))
                while todo:  # follow swap chains (inactive → inactive → current)
                    c = todo.pop()
                    if c in seen or len(seen) > 20:
                        continue
                    seen.add(c)
                    if c in swaps:
                        todo.extend(swaps[c])
                    else:
                        out.append({"tid": c, "src": "inat-swap", "via": f"{n} (iNat {t['id']} inactive)"})
    if ortho_index is not None:
        g, ep = l["name"].split()[:2]
        for k in okeys(ep):
            for tid in ortho_index.get((g, k), ()):
                out.append({"tid": tid, "src": "ortho", "via": f"key {k}"})
    return out


# ------------------------------------------------------------- resolve

def cmd_resolve(a):
    t0 = time.time()
    L = load_labels()
    P = photoless(L)
    sp, acc_names, syn_of = load_apc()
    taxa, direct, rollup = load_snapshot()
    own = load_owner()
    kids = collections.defaultdict(list)
    by_name = collections.defaultdict(list)
    ortho_index = collections.defaultdict(set)
    by_family_ep = collections.defaultdict(set)
    for t in taxa.values():
        by_name[t["name"]].append(t)
        a_ = [int(x) for x in t["anc"].split("/") if x]
        if a_:
            kids[a_[-1]].append(t["id"])
        if t["active"] and t["rank"] == "species" and len(t["name"].split()) == 2:
            g, ep = t["name"].split()
            for k in okeys(ep):
                ortho_index[(g, k)].add(t["id"])
            by_family_ep[(t["family"], ep)].add(t["id"])
    acc_inat = {to_inat(x): x for x in acc_names}
    syn_inat = collections.defaultdict(set)
    for k, v in syn_of.items():
        syn_inat[to_inat(k)] |= v
    label_of_name = collections.defaultdict(set)
    for l in L:
        label_of_name[l["name"]].add(l["i"])
    # every iNat species id already feeding a label
    ids_all = sorted({i for l in P for i in l["inat"]} |
                     {t["id"] for l in P for n in [l["name"]] + [s[0] for s in sp.get(l["name"], {}).get("syn", [])]
                      for t in by_name.get(to_inat(n), []) if not t["active"]})
    recs = inat_records(ids_all)
    swaps = {i: r["current"] for i, r in recs.items() if not r["active"] and r["current"]}
    adj = json.load(open(ADJ)) if os.path.exists(ADJ) else {}

    def tinfo(tid):
        t = taxa.get(tid)
        if t is None or not t["active"] or t["rank"] not in ("species", "subspecies", "variety", "form", "hybrid"):
            return None
        if t["rank"] == "species":
            c, flow = rollup.get(tid, (0,) * 5), "species"
        else:
            c, flow = subtree_counts(tid, taxa, direct, kids), "subtree"
        sid = t["species_id"]
        owners = sorted(own.get(sid, set())) if sid else []
        return {"tid": tid, "sid": sid, "name": t["name"], "rank": t["rank"], "active": t["active"],
                "family": t["family"], "flow": flow, "rg": c[0], "rg_au": c[1], "usable": c[2],
                "pool": c[3], "pool_au": c[4], "owners": owners,
                "owner_names": sorted({L[u]["name"] for u in owners})}

    def gbif_info(l):
        m = cget("gbif_match", l["name"])
        b = (m or {}).get("body") or {}
        info = {"key": b.get("usageKey"), "status": b.get("status"), "match": b.get("matchType"),
                "conf": b.get("confidence"), "name": b.get("canonicalName"),
                "accepted_key": b.get("acceptedUsageKey"), "accepted": b.get("species") if b.get("status") == "SYNONYM" else None,
                "family": b.get("family"), "syn": []}
        if b.get("usageKey") and b.get("matchType") in ("EXACT", "FUZZY"):
            for k in {b.get("acceptedUsageKey") or b["usageKey"], b["usageKey"]}:
                s = cget("gbif_syn", str(k))
                for r in ((s or {}).get("body") or {}).get("results", []):
                    if r.get("canonicalName"):
                        info["syn"].append(r["canonicalName"])
        return info

    def inat_q(l):
        c = cget("inat_q", l["name"])
        out = []
        for r in (((c or {}).get("body") or {}).get("results") or []):
            if PLANTAE not in (r.get("ancestor_ids") or []) or not r.get("is_active"):
                continue
            mt = r.get("matched_term") or ""
            out.append({"tid": r["id"], "name": r["name"], "rank": r["rank"], "matched": mt,
                        "obs": r.get("observations_count")})
        return out, c is not None

    # genus-transfer pattern: (APC genus, iNat genus) pairs already linked by
    # a mapping whose epithet agrees (evidence for same-epithet candidates)
    gpair = collections.Counter()
    for l in L:
        g0, e0 = l["name"].split()[:2]
        for i in l["inat"]:
            t = taxa.get(i)
            if t and t["rank"] == "species" and len(t["name"].split()) == 2:
                g1, e1 = t["name"].split()
                if g1 != g0 and okeys(e1) & okeys(e0):
                    gpair[(g0, g1)] += 1
    for l in P:  # … and by iNat's own swaps of photo-less labels' names
        g0, e0 = l["name"].split()[:2]
        for c in offline_candidates(l, sp, by_name, swaps):
            t = taxa.get(c["tid"])
            if c["src"] == "inat-swap" and t and len(t["name"].split()) == 2:
                g1, e1 = t["name"].split()
                if g1 != g0 and okeys(e1) & okeys(e0):
                    gpair[(g0, g1)] += 1
    entries, residue = {}, {}
    st = collections.Counter()
    for l in P:
        n = l["name"]
        g, ep = n.split()[:2]
        apc = sp.get(n, {})
        syn_norm = {norm(s[0]): s for s in apc.get("syn", [])}
        cands = offline_candidates(l, sp, by_name, swaps, ortho_index) if True else []
        # iNat synonym search
        qres, q_done = inat_q(l)
        for r in qres:
            mt = norm(r["matched"])
            if mt == norm(n) and norm(r["name"]) != norm(n):
                cands.append({"tid": r["tid"], "src": "inat-q", "via": f"iNat lists '{r['matched']}' under {r['name']}"})
            elif mt in syn_norm and norm(r["name"]) != norm(n):
                cands.append({"tid": r["tid"], "src": "inat-q", "via": f"iNat lists APC synonym '{r['matched']}' under {r['name']}"})
            elif mt.split()[:1] == [g.lower()] and len(mt.split()) == 2 and okeys(mt.split()[1]) & okeys(ep.lower()) \
                    and mt != norm(n):
                cands.append({"tid": r["tid"], "src": "inat-q-ortho", "via": f"iNat matched '{r['matched']}' ({r['name']})"})
            elif mt == norm(n) and norm(r["name"]) == norm(n) and r["tid"] not in taxa:
                cands.append({"tid": r["tid"], "src": "inat-new", "via": f"active on iNat since the snapshot ({r['obs']} obs)"})
        # GBIF
        gi = gbif_info(l)
        gnames = set()
        if gi["accepted"] and gi["accepted"] != n:
            gnames.add(("gbif-acc", gi["accepted"]))
        for s in gi["syn"]:
            if s != n:
                gnames.add(("gbif-syn", s))
        for src, gn in gnames:
            for t in by_name.get(to_inat(gn), []):
                if t["active"]:
                    cands.append({"tid": t["id"], "src": src, "via": gn})
        # genus transfer (same epithet, same family)
        fam = apc.get("family") or l.get("family")
        for tid in by_family_ep.get((fam, ep), ()):
            g1 = taxa[tid]["name"].split()[0]
            if g1 != g and not l["inat"]:
                cands.append({"tid": tid, "src": "epithet-family", "via": taxa[tid]["name"],
                              "genus_pair_support": gpair[(g, g1)]})
        # drop the label's own ids, ortho hits on the label's exact name, unknown ids
        own_ids = set(l["inat"])
        C = collections.OrderedDict()
        for c in cands:
            ti = tinfo(c["tid"])
            if c["tid"] in own_ids or (ti is None and c["src"] != "inat-new"):
                continue
            if ti and ti["name"] == n:
                continue
            e = C.setdefault(c["tid"], {"info": ti, "src": []})
            e["src"].append({k: v for k, v in c.items() if k != "tid"})
        # does the candidate's name belong to ANOTHER APC accepted species?
        for tid, e in C.items():
            ti = e["info"]
            if ti is None:
                e["other_apc"] = []
                continue
            nm = ti["name"]
            other = set()
            if nm in acc_inat and acc_inat[nm] != n:
                other.add(acc_inat[nm])
            for x in syn_inat.get(nm, ()):
                if x != n:
                    other.add(x)
            e["other_apc"] = sorted(other)
        ex_rec = [recs.get(i) for i in l["inat"] if recs.get(i)]
        base = {"label": n, "index": l["i"], "family": fam, "native": l["native"],
                "existing_inat_ids": l["inat"],
                "existing_inat_obs": sum((r["obs"] or 0) for r in ex_rec) if ex_rec else None,
                "gbif_taxon_key": gi["key"] if gi["match"] == "EXACT" else None,
                "gbif": {k: gi[k] for k in ("key", "status", "match", "conf", "name", "accepted")}}

        def emit(rel, kind, method, tids, flow, ev):
            infos = [C[t]["info"] if t in C else tinfo(t) for t in tids]
            ph = {k: sum((i or {}).get(k, 0) for i in infos) for k in ("rg", "rg_au", "usable", "pool", "pool_au")}
            entries[l["key"]] = dict(base, inat_taxon_id=tids[0] if tids else None, inat_taxon_ids=tids,
                                     inat_name=(infos[0] or {}).get("name") if infos else None,
                                     inat_rank=(infos[0] or {}).get("rank") if infos else None,
                                     relation=rel, kind=kind, method=method, photo_flow=flow,
                                     new=bool(tids) and rel not in ("exact",), evidence=ev, photos=ph)
            st[(rel, kind, method)] += 1

        if l["key"] in adj:
            d = adj[l["key"]]
            tids = d.get("inat_taxon_ids") or ([d["inat_taxon_id"]] if d.get("inat_taxon_id") else [])
            for t in tids:
                assert t in C or tinfo(t) or d["relation"] in ("none", "lump"), (n, t)
            flow = d.get("photo_flow") or ("none" if d["relation"] in ("lump", "none") else
                                           (tinfo(tids[0]) or {}).get("flow", "none"))
            emit(d["relation"], d.get("kind", "adjudicated"), "adjudicated", tids, flow,
                 [d["evidence"]] + [f"candidate {t}: {C[t]['src']}" for t in tids if t in C])
            continue
        strong = {t: e for t, e in C.items()
                  if any(s["src"] in STRONG and not s.get("pro_parte") for s in e["src"])}
        useful = {t: e for t, e in C.items() if e["info"] and e["info"]["rg"] > 0}

        def evid(t):
            e = C[t]
            i = e["info"] or {}
            return (f"{i.get('name')} [{t}] {i.get('rank')} {i.get('family')}: rg {i.get('rg')} "
                    f"(AU {i.get('rg_au')}), pool photos {i.get('pool')}; via " +
                    "; ".join(f"{s['src']} {s.get('via', '')}" + (f" ({s['status']})" if s.get("status") else "")
                              for s in e["src"]) +
                    (f"; owned by {e['info']['owner_names']}" if i.get("owners") else "") +
                    (f"; name is APC {e['other_apc']}" if e.get("other_apc") else ""))

        decided = False
        # candidates inside the label's own iNat species add nothing
        strong = {t: e for t, e in strong.items() if e["info"] and e["info"]["sid"] not in own_ids}

        def owner_kind(e):
            i = e["info"]
            others = [u for u in i["owners"] if u != l["i"]]
            if not others:
                return None
            if all(not L[u]["native"] for u in others):
                return "duplicate"  # a shipped extra class already holds this iNat taxon
            nm = i["name"]
            if nm in sp and nm != n:
                auths = {anorm(x.get("author")) for x in e["src"] if x["src"] == "apc-syn" and to_inat(x["via"]) == nm}
                if auths and anorm(sp[nm]["author"]) not in auths:
                    return "homonym"
            return "lump"

        if len(strong) == 1:
            t, e = next(iter(strong.items()))
            i = e["info"]
            src = {x["src"] for x in e["src"]}
            kind = ("inat-swap" if "inat-swap" in src else "inat-q" if "inat-q" in src
                    else "apc-syn" if "apc-syn" in src else "ortho")
            rel = "orthographic" if "ortho" in src or any(
                x.get("status") == "orthographic variant" for x in e["src"]) else "synonym"
            ow = owner_kind(e) if i["rank"] == "species" else None
            # iNat's own swap of the APC name itself needs no range check (a
            # widespread species is mostly observed outside Australia)
            own_swap = any(x["src"] == "inat-swap" and x["via"].startswith(n + " (iNat") for x in e["src"])
            ok_au = own_swap or i["rg"] == 0 or i["rg_au"] / i["rg"] >= 0.5
            if ow == "duplicate":
                emit(rel, kind + "/duplicate", "deterministic", [t], "merge",
                     [evid(t), "the same iNat taxon already feeds the shipped extra label(s) "
                      + ", ".join(i["owner_names"]) + ": one species twice in U — merge them (photos already flow there)"])
                decided = True
            elif ow == "homonym":
                emit("none", "homonym", "deterministic", [], "none",
                     [evid(t), f"the APC synonym '{i['name']}' is a homonym (other author) of the APC accepted "
                      f"species {i['name']} ({sp[i['name']]['author']}), which the iNat taxon is"])
                decided = True
            elif ow == "lump":
                emit("lump", kind, "deterministic", [t], "none",
                     [evid(t), "iNat taxon already feeds " + ", ".join(i["owner_names"]) +
                      ": iNat lumps this APC species into it, photos cannot be attributed"])
                decided = True
            elif not e["other_apc"] and (ok_au or (i["rank"] != "species" and i["rg_au"] >= 0.25 * i["rg"])):
                tids, flow = [t], i["flow"]
                if l["inat"]:
                    rel, tids, flow = "split", [t] + list(l["inat"]), "species+" + i["flow"]
                ev = [evid(t)]
                if i["rank"] == "hybrid":
                    ev.append("iNat treats this APC species as a hybrid (nothotaxon); same concept, its own observations flow")
                elif i["rank"] != "species":
                    ev.append(f"iNat keeps it as a {i['rank']} of {', '.join(i['owner_names']) or 'a species'}: only "
                              "observations identified to that infraspecies flow (and should leave the parent class)")
                if l["inat"]:
                    ev.append("APC species = its existing iNat taxon + this one (all flow)")
                emit(rel, kind + ("" if i["rank"] == "species" else "/hybrid" if i["rank"] == "hybrid"
                                  else "/infraspecies"), "deterministic", tids, flow, ev)
                decided = True
        if not decided:
            sw = {t: e for t, e in strong.items() if any(x["src"] == "inat-swap" for x in e["src"])}
            if len(strong) > 1 and len(sw) == len(strong) and all(
                    not e["info"]["owners"] and not e["other_apc"] for e in sw.values()):
                # parts mostly observed outside Australia are another continent's share of the old concept
                # (parts with no Australian record or mostly observed elsewhere
                # are another region's share of the old concept; an
                # infraspecies of another part is already in its roll-up)
                tids = sorted(t for t, e in sw.items() if e["info"]["rg_au"] > 0 and e["info"]["rg_au"] >= 0.5 * e["info"]["rg"])
                tids = [t for t in tids if C[t]["info"]["sid"] == t or C[t]["info"]["sid"] not in tids]
            else:
                tids = []
            if len(tids) == 1:
                t = tids[0]
                rel = "orthographic" if any(x["src"] == "ortho" for x in C[t]["src"]) else "synonym"
                emit(rel, "inat-swap", "deterministic", tids + list(l["inat"]), C[t]["info"]["flow"],
                     [evid(x) for x in sorted(sw)] + [f"only {C[t]['info']['name']} of iNat's parts is Australian"])
                decided = True
            elif tids:
                emit("split", "inat-swap", "deterministic", tids + list(l["inat"]), "species",
                     [evid(t) for t in tids] + ["iNat split the APC concept: every part flows to this label"])
                decided = True
        if decided:
            continue
        # nothing decisive: keep the residue (with evidence) and record what exists
        if C:
            residue[l["key"]] = dict(base, apc_author=apc.get("author"),
                                     apc_syn=[s[0] + f" ({s[2]})" for s in apc.get("syn", [])][:40],
                                     gbif_syn=gi["syn"][:40], inat_q=qres[:10], q_done=q_done,
                                     candidates=[dict(**(e["info"] or {"tid": t}), src=e["src"],
                                                      other_apc=e["other_apc"]) for t, e in C.items()])
        if l["inat"]:
            rel_ex = "exact" if any((recs.get(i) or {}).get("name") == n for i in l["inat"]) or \
                any((taxa.get(i) or {}).get("name") == n for i in l["inat"]) else "synonym"
            obs = base["existing_inat_obs"]
            emit(rel_ex, "existing", "deterministic", list(l["inat"]), "species",
                 [f"existing mapping; iNat observations_count {obs} (all grades), no research-grade "
                  "pool photo in the snapshot"] + ([f"{len(C)} other candidate(s) in residue"] if C else []))
            entries[l["key"]]["new"] = False
        else:
            emit("none", "unresolved" if C else "no-candidate", "deterministic", [], "none",
                 [f"{len(C)} candidate(s) → residue.json" if C else
                  "no iNat taxon by name, APC synonym, orthography, iNat synonym search or GBIF"])
    # two labels newly mapped onto ONE iNat taxon: the label whose name is the
    # taxon's (ignoring "×" / orthography) keeps it, the others become lumps
    claim = collections.defaultdict(list)
    for k, e in entries.items():
        if e["new"] and e["photo_flow"] not in ("none", "merge"):
            for t in e["inat_taxon_ids"]:
                if t not in set(e["existing_inat_ids"]):
                    claim[t].append(k)
    for t, ks in claim.items():
        if len(ks) < 2:
            continue
        nm = (taxa.get(t) or {}).get("name", "")

        def same(k):
            a, b = norm(entries[k]["label"]).split(), norm(nm).split()
            return len(a) == 2 and len(b) == 2 and a[0] == b[0] and bool(okeys(a[1]) & okeys(b[1]))
        keep = [k for k in ks if same(k)]
        for k in ks:
            if len(keep) == 1 and k == keep[0]:
                continue
            e = entries[k]
            st[(e["relation"], e["kind"], e["method"])] -= 1
            e.update(relation="lump", photo_flow="none", kind=e["kind"] + "/collision",
                     evidence=e["evidence"] + [f"iNat taxon {t} ({nm}) is also claimed by " +
                                               ", ".join(x for x in ks if x != k) + ": photos cannot be attributed"])
            st[(e["relation"], e["kind"], e["method"])] += 1
    # payoff
    FLOW = ("species", "subtree", "species+species", "species+subtree")
    gain = [e for e in entries.values() if e["new"] and e["photo_flow"] in FLOW and e["photos"]["pool"] > 0]
    summary = {
        "photoless_labels": len(P), "photoless_no_inat": sum(not l["inat"] for l in P),
        "by_relation": dict(collections.Counter(e["relation"] for e in entries.values())),
        "by_relation_kind_method": {" / ".join(k): v for k, v in sorted(st.items())},
        "new_mappings": sum(e["new"] for e in entries.values()),
        "new_mappings_with_flow": sum(e["new"] and e["photo_flow"] in FLOW for e in entries.values()),
        "duplicates_to_merge": sum(e["photo_flow"] == "merge" for e in entries.values()),
        "labels_gaining_pool_photos": len(gain),
        "pool_photos_gained": sum(e["photos"]["pool"] for e in gain),
        "pool_photos_gained_cap100": sum(min(100, e["photos"]["pool"]) for e in gain),
        "pool_photos_gained_AU": sum(e["photos"]["pool_au"] for e in gain),
        "labels_gaining_ge5": sum(e["photos"]["pool"] >= 5 for e in gain),
        "labels_gaining_ge20": sum(e["photos"]["pool"] >= 20 for e in gain),
        "labels_gaining_any_usable_photo": sum(e["new"] and e["photo_flow"] in FLOW and e["photos"]["usable"] > 0
                                               for e in entries.values()),
        "residue": len(residue), "adjudicated": sum(e["method"] == "adjudicated" for e in entries.values()),
        "existing_with_zero_inat_obs": sum(e["kind"] == "existing" and e["existing_inat_obs"] == 0
                                           for e in entries.values()),
        "existing_with_some_inat_obs": sum(e["kind"] == "existing" and (e["existing_inat_obs"] or 0) > 0
                                           for e in entries.values()),
    }
    os.makedirs(NAMES, exist_ok=True)
    json.dump(entries, open(os.path.join(NAMES, "apc_inat_map.json"), "w"), indent=1, ensure_ascii=False)
    json.dump(residue, open(os.path.join(NAMES, "residue.json"), "w"), indent=1, ensure_ascii=False)
    json.dump(summary, open(os.path.join(NAMES, "summary.json"), "w"), indent=1, ensure_ascii=False)
    print(json.dumps(summary, indent=1, ensure_ascii=False))
    print(f"{time.time() - t0:.0f} s")


# ------------------------------------------------------------- verify

def cmd_verify(a):
    M = json.load(open(os.path.join(NAMES, "apc_inat_map.json")))
    new = sorted(k for k, e in M.items() if e["new"] and e["inat_taxon_id"])
    rnd = random.Random(a.seed)
    pick = rnd.sample(new, min(a.n, len(new)))
    out = []
    for k in pick:
        e = M[k]
        INAT_PACE.wait()
        r = http_json(f"{INAT}/taxa/{e['inat_taxon_id']}?all_names=true")
        b = (r["body"] or {}).get("results") or [{}]
        b = b[0]
        names = [x["name"] for x in b.get("names", []) if x.get("lexicon") == "scientific-names"]
        fam = next((x["name"] for x in b.get("ancestors", []) if x.get("rank") == "family"), None)
        chk = {"label": k, "relation": e["relation"], "kind": e["kind"], "method": e["method"],
               "tid": e["inat_taxon_id"], "recorded_name": e["inat_name"], "live_name": b.get("name"),
               "live_active": b.get("is_active"), "plantae": PLANTAE in (b.get("ancestor_ids") or []),
               "live_family": fam, "apc_family": e["family"],
               "label_in_inat_names": any(norm(x) == norm(e["label"]) for x in names),
               "inat_names": names[:12], "obs": b.get("observations_count")}
        chk["auto_ok"] = bool(chk["live_name"] == chk["recorded_name"] and chk["live_active"] and chk["plantae"])
        out.append(chk)
        print(json.dumps(chk, ensure_ascii=False), flush=True)
    json.dump(out, open(os.path.join(NAMES, "verify.json"), "w"), indent=1, ensure_ascii=False)
    print(f"auto_ok {sum(c['auto_ok'] for c in out)}/{len(out)}, family equal "
          f"{sum(c['live_family'] == c['apc_family'] for c in out)}, label among iNat names "
          f"{sum(c['label_in_inat_names'] for c in out)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fetch")
    p.add_argument("--gbif-all", action="store_true")
    sub.add_parser("resolve")
    p = sub.add_parser("verify")
    p.add_argument("--n", type=int, default=40)
    p.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    {"fetch": cmd_fetch, "resolve": cmd_resolve, "verify": cmd_verify}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

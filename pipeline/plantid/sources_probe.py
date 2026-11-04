#!/usr/bin/env python3
"""Probe additional photo sources for the Australia-wide plant ID
(notes/photo_sources.md). Investigation only: per-species COUNT queries and
a handful of metadata/thumbnail samples, never a bulk download.

Subcommands:
  sample   ~200 random photo-less labels (train_photos == 0) + ~200 with
           1–19 training photos from ship/au-labels.json, with the APC
           taxonID (ALA's taxon concept LSID) → sources/sample.json
  ala      biocache: occurrences WITH an image per species (q=lsid:<APC id>,
           fq=multimedia:Image), facets dataResourceUid + basis_of_record;
           image ids of the first 20 records → sources/ala.json
  ala-lic  licence/creator of a sample of those image ids
           (images.ala.org.au/ws/getImageInfoForIdList) → sources/ala_lic.json
  gbif     species/match (kingdom Plantae) → usageKey; occurrence/search
           mediaType=StillImage, facets datasetKey + basisOfRecord, the
           first 20 records' media licences → sources/gbif.json
  wikidata SPARQL by taxon name (P225): P18 image, P373 Commons category,
           P846 GBIF, P3151 iNat, P5984 APNI, P7051 ALA → sources/wikidata.json
  commons  categoryinfo file counts for Category:<name> / P373, licences of
           the P18 files (extmetadata) → sources/commons.json
  inat     iNat API v1 species_counts for the sample's iNat ids, by
           quality grade (needs_id, casual), ≤ 1 req/s → sources/inat.json
  report   tables for the notes (stdout)
  thumbs   fetch a few thumbnails per source type into sources/thumbs/
           for eyeballing (≤ 40 files)

Env: uv run python3 -I pipeline/plantid/sources_probe.py <cmd>  (stdlib only)
User-Agent "izzymap-plantid-eval/1"; ≤ 4 concurrent requests per host.
"""
import collections
import concurrent.futures as cf
import csv
import json
import os
import random
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
OUT = os.path.join(CACHE, "sources")
LABELS = os.path.join(CACHE, "ship", "au-labels.json")
APC = os.path.join(CACHE, "australia", "apc", "taxon.csv")
UA = "izzymap-plantid-eval/1"
INAT_DATASETS = {
    "50c9509d-22c7-4a22-a47d-8c48425ef4a7",  # GBIF: iNaturalist research-grade
}
ALA_INAT = {"dr1411"}  # iNaturalist Australia
os.makedirs(OUT, exist_ok=True)


def get(url, data=None, headers=None, tries=3, timeout=60):
    h = {"User-Agent": UA}
    h.update(headers or {})
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, headers=h)
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            if i == tries - 1:
                raise
            time.sleep(2 * (i + 1))


def getj(url, **kw):
    return json.loads(get(url, **kw))


def save(name, obj):
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(obj, f, indent=0, ensure_ascii=False)


def load(name):
    with open(os.path.join(OUT, name)) as f:
        return json.load(f)


# ---------------------------------------------------------------- sample
def cmd_sample():
    labels = json.load(open(LABELS))["labels"]
    apc = {}
    with open(APC, newline="") as f:
        for r in csv.DictReader(f):
            if r["taxonomicStatus"] == "accepted" and r["taxonRank"] == "Species":
                apc.setdefault(r["canonicalName"], r["taxonID"])
    rng = random.Random(20261105)
    zero = [i for i, l in enumerate(labels) if l["train_photos"] == 0]
    low = [i for i, l in enumerate(labels) if 0 < l["train_photos"] < 20]
    pick = {"zero": sorted(rng.sample(zero, 200)), "low": sorted(rng.sample(low, 200))}
    out = []
    for b, ix in pick.items():
        for u in ix:
            l = labels[u]
            out.append(dict(u=u, bucket=b, name=l["name"], family=l["family"],
                            native=l["native"], inat=l["inat"],
                            train=l["train_photos"], apc=apc.get(l["name"])))
    save("sample.json", {"n_zero": len(zero), "n_low": len(low), "species": out})
    print(len(zero), len(low), "sampled", len(out),
          "with APC id", sum(1 for s in out if s["apc"]))


# ---------------------------------------------------------------- ALA
def ala_one(s):
    base = "https://biocache-ws.ala.org.au/ws/occurrences/search?"
    q = f'lsid:"{s["apc"]}"' if s["apc"] else f'taxon_name:"{s["name"]}"'
    p = dict(q=q, fq="multimedia:Image", pageSize=20,
             facets="dataResourceUid,basis_of_record", flimit=-1)
    d = getj(base + urllib.parse.urlencode(p))
    fac = {f["fieldName"]: {x.get("i18nCode", x["label"]).split(".")[-1] if f["fieldName"] == "dataResourceUid" else x["label"]: x["count"]
                            for x in f["fieldResult"]} for f in d.get("facetResults", [])}
    recs = [dict(dr=o.get("dataResourceUid"), bor=o.get("basisOfRecord"),
                 images=o.get("images", []), uuid=o.get("uuid"))
            for o in d.get("occurrences", [])]
    return dict(u=s["u"], total=d.get("totalRecords", 0), facets=fac, recs=recs, q=q)


def cmd_ala():
    S = load("sample.json")["species"]
    t = time.time()
    with cf.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(ala_one, S))
    save("ala.json", res)
    print(f"{len(res)} species in {time.time() - t:.0f} s")


def cmd_ala_lic():
    res = load("ala.json")
    rng = random.Random(1)
    ids = []
    for r in res:
        for rec in r["recs"]:
            if rec["dr"] not in ALA_INAT:
                ids += [(i, rec["dr"], rec["bor"]) for i in rec["images"][:1]]
    rng.shuffle(ids)
    ids = ids[:600]
    info = {}
    for k in range(0, len(ids), 100):
        chunk = [i for i, _, _ in ids[k:k + 100]]
        d = getj("https://images.ala.org.au/ws/getImageInfoForIdList",
                 data=json.dumps({"imageIds": chunk}).encode(),
                 headers={"Content-Type": "application/json"})
        info.update(d.get("results", {}))
    out = []
    for i, dr, bor in ids:
        m = info.get(i) or {}
        out.append(dict(id=i, dr=dr, bor=bor, license=m.get("license"),
                        rights=m.get("rights"), creator=m.get("creator"),
                        w=m.get("width"), h=m.get("height"), url=m.get("thumbUrl")))
    # names of the contributing data resources
    drs = collections.Counter()
    for r in res:
        for dr, n in r["facets"].get("dataResourceUid", {}).items():
            drs[dr] += n
    names = {}
    for dr, _ in drs.most_common(40):
        try:
            names[dr] = getj(f"https://collections.ala.org.au/ws/dataResource/{dr}").get("name")
        except Exception:  # noqa: BLE001
            names[dr] = None
    save("ala_lic.json", {"images": out, "dr_names": names})
    print(len(out), "image infos;", len(names), "resource names")


# ---------------------------------------------------------------- GBIF
def gbif_one(s):
    m = getj("https://api.gbif.org/v1/species/match?" + urllib.parse.urlencode(
        dict(name=s["name"], kingdom="Plantae", strict="true")))
    key = m.get("usageKey") if m.get("matchType") in ("EXACT", "FUZZY") and m.get("rank") == "SPECIES" else None
    if key and m.get("status") != "ACCEPTED" and m.get("acceptedUsageKey"):
        key = m["acceptedUsageKey"]
    out = dict(u=s["u"], match=m.get("matchType"), status=m.get("status"), key=key)
    if not key:
        return out
    d = getj("https://api.gbif.org/v1/occurrence/search?" + urllib.parse.urlencode(
        [("taxonKey", key), ("mediaType", "StillImage"), ("limit", 20),
         ("facet", "datasetKey"), ("facet", "basisOfRecord"), ("facet", "country"),
         ("facetLimit", 100)]))
    out["total"] = d.get("count", 0)
    out["facets"] = {f["field"]: {c["name"]: c["count"] for c in f["counts"]} for f in d.get("facets", [])}
    out["recs"] = [dict(ds=o.get("datasetKey"), bor=o.get("basisOfRecord"),
                        country=o.get("countryCode"), key=o.get("key"),
                        media=[dict(lic=x.get("license"), url=x.get("identifier"),
                                    holder=x.get("rightsHolder") or x.get("creator"))
                               for x in o.get("media", []) if x.get("type") == "StillImage"])
                   for o in d.get("results", [])]
    return out


def cmd_gbif():
    S = load("sample.json")["species"]
    t = time.time()
    with cf.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(gbif_one, S))
    dsk = collections.Counter()
    for r in res:
        for k, n in (r.get("facets") or {}).get("DATASET_KEY", {}).items():
            dsk[k] += n
    names = {}
    for k, _ in dsk.most_common(40):
        try:
            d = getj(f"https://api.gbif.org/v1/dataset/{k}")
            names[k] = [d.get("title"), d.get("license")]
        except Exception:  # noqa: BLE001
            names[k] = None
    save("gbif.json", {"species": res, "datasets": names})
    print(f"{len(res)} species in {time.time() - t:.0f} s")


# ---------------------------------------------------------------- Wikidata / Commons
def cmd_wikidata():
    S = load("sample.json")["species"]
    rows = []
    for k in range(0, len(S), 100):
        vals = " ".join('"%s"' % s["name"].replace('"', "") for s in S[k:k + 100])
        q = f"""PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        SELECT ?name ?item ?img ?cat ?gbif ?inat ?apni ?ala WHERE {{
          VALUES ?name {{ {vals} }} ?item wdt:P225 ?name .
          OPTIONAL {{ ?item wdt:P18 ?img }} OPTIONAL {{ ?item wdt:P373 ?cat }}
          OPTIONAL {{ ?item wdt:P846 ?gbif }} OPTIONAL {{ ?item wdt:P3151 ?inat }}
          OPTIONAL {{ ?item wdt:P5984 ?apni }} OPTIONAL {{ ?item wdt:P7051 ?ala }} }}"""
        # query.wikidata.org answered 429 "1 req / min" (WDQS outage rule,
        # 2026-11-05) → the QLever mirror of Wikidata (same data, weekly).
        d = getj("https://qlever.dev/api/wikidata?" + urllib.parse.urlencode(dict(query=q)),
                 headers={"Accept": "application/sparql-results+json"})
        for b in d["results"]["bindings"]:
            rows.append({k2: v["value"] for k2, v in b.items()})
        time.sleep(1)
    save("wikidata.json", rows)
    print(len(rows), "rows for", len({r["name"] for r in rows}), "names")


def cmd_commons():
    S = load("sample.json")["species"]
    wd = load("wikidata.json")
    cat = {}
    p18 = collections.defaultdict(set)
    for r in wd:
        if r.get("cat"):
            cat[r["name"]] = r["cat"]
        if r.get("img"):
            p18[r["name"]].add(urllib.parse.unquote(r["img"].rsplit("/", 1)[-1]))
    api = "https://commons.wikimedia.org/w/api.php?"
    titles = {s["name"]: "Category:" + cat.get(s["name"], s["name"]) for s in S}
    files = {}
    tl = list(titles.values())
    for k in range(0, len(tl), 50):
        d = getj(api + urllib.parse.urlencode(dict(action="query", prop="categoryinfo",
                                                   titles="|".join(tl[k:k + 50]), format="json", formatversion=2)))
        norm = {n["from"]: n["to"] for n in d["query"].get("normalized", [])}
        byt = {p["title"]: p for p in d["query"]["pages"]}
        for t in tl[k:k + 50]:
            p = byt.get(norm.get(t, t), {})
            files[t] = (p.get("categoryinfo") or {}).get("files", 0) if not p.get("missing") else None
        time.sleep(0.5)
    # licences of the P18 images
    lic = {}
    fl = sorted({f for v in p18.values() for f in v})
    for k in range(0, len(fl), 50):
        d = getj(api + urllib.parse.urlencode(dict(
            action="query", prop="imageinfo", iiprop="extmetadata|size|url", iiurlwidth=500,
            iiextmetadatafilter="LicenseShortName|Artist|ImageDescription|Categories",
            titles="|".join("File:" + f for f in fl[k:k + 50]), format="json", formatversion=2)))
        for p in d["query"]["pages"]:
            ii = (p.get("imageinfo") or [{}])[0]
            em = ii.get("extmetadata", {})
            lic[p["title"]] = dict(lic=(em.get("LicenseShortName") or {}).get("value"),
                                   w=ii.get("width"), h=ii.get("height"), url=ii.get("url"),
                                   thumb=ii.get("thumburl"),
                                   cats=(em.get("Categories") or {}).get("value", "")[:300])
        time.sleep(0.5)
    out = [dict(u=s["u"], name=s["name"], cat=titles[s["name"]], cat_files=files.get(titles[s["name"]]),
                p18=sorted(p18.get(s["name"], [])))
           for s in S]
    save("commons.json", {"species": out, "p18_files": lic})
    print("done", sum(1 for o in out if o["cat_files"]), "with category files;",
          sum(1 for o in out if o["p18"]), "with P18")


# ---------------------------------------------------------------- iNat API
def cmd_inat():
    S = load("sample.json")["species"]
    ids = sorted({i for s in S for i in s["inat"]})
    res = {}
    for grade in ("needs_id", "casual", "research"):
        cnt = {}
        for k in range(0, len(ids), 100):
            d = getj("https://api.inaturalist.org/v1/observations/species_counts?" + urllib.parse.urlencode(
                dict(taxon_id=",".join(map(str, ids[k:k + 100])), quality_grade=grade,
                     photos="true", per_page=500)))
            for r in d["results"]:
                cnt[r["taxon"]["id"]] = r["count"]
            time.sleep(1.1)
        res[grade] = cnt
    # all-rights-reserved share: photo_license filter, research grade
    cc = {}
    for k in range(0, len(ids), 100):
        d = getj("https://api.inaturalist.org/v1/observations/species_counts?" + urllib.parse.urlencode(
            dict(taxon_id=",".join(map(str, ids[k:k + 100])), photos="true", per_page=500,
                 photo_license="cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nd,cc-by-nc-sa,cc-by-nc-nd")))
        for r in d["results"]:
            cc[r["taxon"]["id"]] = r["count"]
        time.sleep(1.1)
    res["any_cc_any_grade"] = cc
    save("inat.json", res)
    print({k: len(v) for k, v in res.items()})


# ---------------------------------------------------------------- iNat snapshot
def cmd_snapshot():
    """One pass over the local open-data observations dump (only observations
    with ≥ 1 CC-licensed photo are in it): observations per quality grade for
    EVERY label with < 20 training photos (exact, not a sample). Taxon ids are
    the labels' own iNat ids (species rank; subspecies not rolled up).
    Needs: uv run --with duckdb."""
    import duckdb
    labels = json.load(open(LABELS))["labels"]
    rows = [(i, u) for u, l in enumerate(labels) if l["train_photos"] < 20 for i in l["inat"]]
    con = duckdb.connect()
    con.execute("CREATE TABLE t(taxon_id INTEGER, u INTEGER)")
    con.executemany("INSERT INTO t VALUES (?, ?)", rows)
    src = os.path.join(CACHE, "meta", "observations.csv.gz")
    t = time.time()
    r = con.execute(f"""
        SELECT t.u, o.quality_grade AS g, count(*) AS n,
               count(*) FILTER (WHERE o.latitude BETWEEN -44 AND -9 AND o.longitude BETWEEN 112 AND 154) AS n_au
        FROM read_csv('{src}', delim='\t', header=true, quote='',
             columns={{'observation_uuid':'VARCHAR','observer_id':'INTEGER','latitude':'DOUBLE',
                      'longitude':'DOUBLE','positional_accuracy':'INTEGER','taxon_id':'INTEGER',
                      'quality_grade':'VARCHAR','observed_on':'VARCHAR','anomaly_score':'DOUBLE'}},
             ignore_errors=true) o
        JOIN t ON o.taxon_id = t.taxon_id GROUP BY 1, 2""").fetchall()
    out = collections.defaultdict(dict)
    for u, g, n, nau in r:
        out[u][g] = [n, nau]
    save("snapshot.json", {"seconds": round(time.time() - t), "counts": out})
    print(len(out), "labels with snapshot observations;", round(time.time() - t), "s")


# ---------------------------------------------------------------- report
FIELD = {"HUMAN_OBSERVATION", "OBSERVATION", "MACHINE_OBSERVATION", "HumanObservation",
         "Human observation", "Observation", "Machine observation"}
SPEC = {"PRESERVED_SPECIMEN", "PreservedSpecimen", "Preserved specimen", "MATERIAL_SAMPLE"}
LIVING = {"LIVING_SPECIMEN", "LivingSpecimen", "Living specimen"}


def kind(b):
    return "field" if b in FIELD else "specimen" if b in SPEC else "living" if b in LIVING else "other"


def cmd_report():
    smp = load("sample.json")
    S = {s["u"]: s for s in smp["species"]}
    nz, nl = smp["n_zero"], smp["n_low"]
    B = {"zero": [u for u, s in S.items() if s["bucket"] == "zero"],
         "low": [u for u, s in S.items() if s["bucket"] == "low"]}

    def line(title, has):  # has: u -> dict(kind -> count)
        for b, us in B.items():
            N = nz if b == "zero" else nl
            n = len(us)
            any_ = sum(1 for u in us if sum(has.get(u, {}).values()) > 0)
            fld = sum(1 for u in us if has.get(u, {}).get("field", 0) > 0)
            fld5 = sum(1 for u in us if has.get(u, {}).get("field", 0) >= 5)
            spec = sum(1 for u in us if has.get(u, {}).get("specimen", 0) > 0 and not has.get(u, {}).get("field", 0))
            med = sorted(sum(has.get(u, {}).values()) for u in us)[n // 2]
            print(f"| {title} | {b} (n={n}) | any {any_} ({any_ / n:.0%} → ~{any_ / n * N:,.0f}) | "
                  f"field ≥1 {fld} ({fld / n:.0%} → ~{fld / n * N:,.0f}) | field ≥5 {fld5} | "
                  f"specimen-only {spec} | median imgs {med} |")

    # ALA
    if os.path.exists(os.path.join(OUT, "ala.json")):
        ala = load("ala.json")
        has = {}
        drk = collections.Counter()
        for r in ala:
            c = collections.Counter()
            bor = r["facets"].get("basis_of_record", {})
            drs = r["facets"].get("dataResourceUid", {})
            inat = sum(n for d, n in drs.items() if d in ALA_INAT)
            # attribute iNat's records to "field" and subtract them
            for b, n in bor.items():
                c[kind(b)] += n
            c["field"] -= inat
            has[r["u"]] = {k: max(0, v) for k, v in c.items()}
            for d, n in drs.items():
                drk[(S[r["u"]]["bucket"], d)] += n
        print("\n### ALA (excluding dr1411 iNaturalist Australia)")
        line("ALA", has)
        names = load("ala_lic.json")["dr_names"] if os.path.exists(os.path.join(OUT, "ala_lic.json")) else {}
        for b in B:
            top = sorted(((n, d) for (bb, d), n in drk.items() if bb == b), reverse=True)[:15]
            print(b, [(d, names.get(d), n) for n, d in top])
        if names:
            L = load("ala_lic.json")["images"]
            print("image licences (sample of", len(L), "non-iNat images):",
                  collections.Counter((x["license"] or "∅") for x in L).most_common(15))
            print("by kind:", collections.Counter((kind(x["bor"]), x["license"] or "∅") for x in L).most_common(20))
    # GBIF
    if os.path.exists(os.path.join(OUT, "gbif.json")):
        g = load("gbif.json")
        has = {}
        dsk = collections.Counter()
        for r in g["species"]:
            c = collections.Counter()
            f = r.get("facets") or {}
            inat = sum(n for d, n in f.get("DATASET_KEY", {}).items() if d in INAT_DATASETS)
            for b, n in f.get("BASIS_OF_RECORD", {}).items():
                c[kind(b)] += n
            c["field"] -= inat
            has[r["u"]] = {k: max(0, v) for k, v in c.items()}
            for d, n in f.get("DATASET_KEY", {}).items():
                dsk[(S[r["u"]]["bucket"], d)] += n
        print("\n### GBIF (excluding the iNat research-grade dataset)")
        print("name match:", collections.Counter((S[r["u"]]["bucket"], r["match"], bool(r["key"])) for r in g["species"]))
        line("GBIF", has)
        for b in B:
            top = sorted(((n, d) for (bb, d), n in dsk.items() if bb == b), reverse=True)[:15]
            print(b, [((g["datasets"].get(d) or [d])[0], n) for n, d in top])
        ml = collections.Counter()
        for r in g["species"]:
            for rec in r.get("recs") or []:
                if rec["ds"] in INAT_DATASETS:
                    continue
                for m in rec["media"][:1]:
                    ml[(kind(rec["bor"]), m["lic"] or "∅")] += 1
        print("media licences (first 20 records/species, non-iNat):", ml.most_common(25))
    # Wikidata/Commons
    if os.path.exists(os.path.join(OUT, "commons.json")):
        c = load("commons.json")
        wd = load("wikidata.json")
        item = {r["name"] for r in wd}
        has = {o["u"]: {"field": (o["cat_files"] or 0) + (0 if o["cat_files"] else len(o["p18"]))} for o in c["species"]}
        print("\n### Wikidata / Commons")
        for b, us in B.items():
            n = len(us)
            print(b, "wikidata item", sum(1 for u in us if S[u]["name"] in item),
                  "P18", sum(1 for o in c["species"] if o["u"] in us and o["p18"]),
                  "category with files", sum(1 for o in c["species"] if o["u"] in us and o["cat_files"]),
                  "median files", sorted((o["cat_files"] or 0) for o in c["species"] if o["u"] in us)[n // 2])
        line("Commons (cat files, field/specimen not separated)", has)
        print("P18 licences:", collections.Counter(v["lic"] for v in c["p18_files"].values()).most_common())
    # iNat
    if os.path.exists(os.path.join(OUT, "inat.json")):
        r = load("inat.json")
        print("\n### iNat API (all grades, photos=true)")
        for b, us in B.items():
            n = len(us)
            ids = {u: S[u]["inat"] for u in us}
            for grade in ("research", "needs_id", "casual", "any_cc_any_grade"):
                k = sum(1 for u in us if any(str(i) in r[grade] or i in r[grade] for i in ids[u]))
                print(b, grade, f"{k}/{n}", "(of", sum(1 for u in us if ids[u]), "with iNat id)")


# ---------------------------------------------------------------- thumbs
def cmd_thumbs():
    d = os.path.join(OUT, "thumbs")
    os.makedirs(d, exist_ok=True)
    picks = []
    L = load("ala_lic.json")["images"]
    rng = random.Random(3)
    for k in ("field", "specimen", "living", "other"):
        xs = [x for x in L if kind(x["bor"]) == k and x["url"]]
        picks += [("ala-" + k + "-" + x["dr"], x["url"].replace("/thumbnail", "/thumbnail_large")) for x in rng.sample(xs, min(6, len(xs)))]
    g = load("gbif.json")
    for r in g["species"]:
        for rec in r.get("recs") or []:
            if rec["ds"] not in INAT_DATASETS and rec["media"] and kind(rec["bor"]) == "field":
                picks.append(("gbif-field-" + rec["ds"][:8], rec["media"][0]["url"]))
                break
    picks = picks[:24] + [p for p in picks[24:] if p[0].startswith("gbif")][:8]
    c = load("commons.json")
    for t, v in list(c["p18_files"].items())[:6]:
        if v.get("thumb"):  # upload.wikimedia.org serves only standard sizes (400 otherwise)
            picks.append(("commons", v["thumb"]))
    log = []
    for i, (tag, url) in enumerate(picks[:40]):
        try:
            b = get(url, timeout=30)
            ext = "png" if b[:4] == b"\x89PNG" else "jpg"
            fn = f"{i:02d}-{tag}.{ext}"
            open(os.path.join(d, fn), "wb").write(b)
            log.append((fn, url, len(b)))
        except Exception as e:  # noqa: BLE001
            log.append((tag, url, str(e)))
        time.sleep(0.3)
    save("thumbs.json", log)
    print(len(log))


if __name__ == "__main__":
    {"sample": cmd_sample, "ala": cmd_ala, "ala-lic": cmd_ala_lic, "gbif": cmd_gbif,
     "wikidata": cmd_wikidata, "commons": cmd_commons, "inat": cmd_inat,
     "snapshot": cmd_snapshot, "report": cmd_report, "thumbs": cmd_thumbs}[sys.argv[1]]()

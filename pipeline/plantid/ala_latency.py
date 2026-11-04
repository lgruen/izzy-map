#!/usr/bin/env python3
"""Measure the per-species ALA biocache facet pull (build_records.py's method)
Australia-wide, for the national-prior estimate: 20 species (10 random natives,
10 of the most-recorded), ≤ 1 request/s → australia/v2/ala_latency.json."""
import json, os, sys, time, urllib.parse, urllib.request, gzip
import numpy as np
import pyarrow.parquet as pq
HERE = os.path.dirname(os.path.abspath(__file__))
AU = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid", "australia"))
FQ = ["kingdom:Plantae", "-occurrenceStatus:ABSENT", "-dataGeneralizations:*", "-sensitive:*",
      "-basisOfRecord:FOSSIL_SPECIMEN", "-coordinateUncertaintyInMeters:[1000.001 TO *]",
      "decimalLatitude:[-44.0 TO -9.0] AND decimalLongitude:[112.0 TO 154.0]"]
UA = {"User-Agent": "izzymap-plantid-eval/1", "Accept-Encoding": "gzip"}
U = pq.read_table(os.path.join(AU, "labels.parquet"), columns=["name", "native", "rg_au"]).to_pydict()
nat = [i for i in range(len(U["name"])) if U["native"][i]]
rng = np.random.default_rng(1)
pick = [nat[i] for i in rng.permutation(len(nat))[:10]] + sorted(nat, key=lambda i: -U["rg_au"][i])[:10]
out = []
for i in pick:
    q = [("q", "*:*")] + [("fq", f) for f in FQ + [f'species:"{U["name"][i]}"']] + [
        ("pageSize", "0"), ("facets", "point-0.001,dataResourceUid,license"), ("flimit", "-1")]
    url = "https://biocache-ws.ala.org.au/ws/occurrences/search?" + urllib.parse.urlencode(q)
    t = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=180) as r:
            body = r.read()
            if r.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
        d = json.loads(body)
        pts = next((len(f["fieldResult"]) for f in d.get("facetResults", []) if f["fieldName"] == "point-0.001"), 0)
        out.append({"species": U["name"][i], "inat_rg_au": U["rg_au"][i], "records": d["totalRecords"], "points": pts,
                    "seconds": round(time.time() - t, 2), "kb": round(len(body) / 1e3, 1)})
    except Exception as e:  # noqa: BLE001
        out.append({"species": U["name"][i], "error": str(e)[:100], "seconds": round(time.time() - t, 2)})
    print(out[-1], flush=True)
    time.sleep(1.0)
ok = [r for r in out if "records" in r]
s = np.array([r["seconds"] for r in ok])
summ = {"n": len(ok), "median_s": float(np.median(s)), "mean_s": float(s.mean()), "max_s": float(s.max()),
        "records_random10": sum(r["records"] for r in ok[:10]), "inat_rg_random10": sum(r["inat_rg_au"] for r in ok[:10]),
        "records_top10": sum(r["records"] for r in ok[10:]), "inat_rg_top10": sum(r["inat_rg_au"] for r in ok[10:])}
json.dump({"summary": summ, "species": out}, open(os.path.join(AU, "v2", "ala_latency.json"), "w"), indent=1)
print(json.dumps(summ))

#!/usr/bin/env python3
"""Why are tail classes short of training photos? (README "Single model (v2)")
For every class with < 100 training photos: research-grade observations in the
2026-10 iNat open-data snapshot (world / Australia box), split by observer role
(pool = trainable; val/test held out), by the licence of the observation's
photos (usable CC0/BY/BY-NC/PD vs SA, NC-SA, ND, NC-ND only), and the extra
usable photos on observations we used once. The open-data snapshot holds only
CC-licensed photos: all-rights-reserved observations are not in it at all
(counted separately via the iNat API on a sample: `api`). → australia/v2/tail_data.json"""
import json, os, sys, time, collections, urllib.request
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia"); V2 = os.path.join(AU, "v2")
USABLE = "('CC0', 'PD', 'CC-BY', 'CC-BY-NC')"
BOX = "o.lat BETWEEN -44.0 AND -9.5 AND o.lon BETWEEN 112.0 AND 154.5"


def buckets(n):
    return np.select([n == 0, n < 10, n < 50, n < 100], ["0", "1-9", "10-49", "50-99"], "100")


def cmd_snapshot():
    import duckdb, pyarrow as pa, pyarrow.parquet as pq
    D = np.load(os.path.join(V2, "data.npz"))
    C = D["T"].shape[0]
    ntr = np.bincount(D["ytr"], minlength=C)
    con = duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    t = time.time()
    rows = con.execute(f"""
      WITH ob AS (SELECT o.uuid, o.role, m.u, ({BOX}) AS au FROM o JOIN imap_v m USING (species_id)),
      ph AS (SELECT uuid, count(*) FILTER (license IN {USABLE}) AS n_use,
                    count(*) FILTER (license = 'CC-BY-SA') AS n_sa, count(*) FILTER (license = 'CC-BY-NC-SA') AS n_ncsa,
                    count(*) FILTER (license = 'CC-BY-ND') AS n_nd, count(*) FILTER (license = 'CC-BY-NC-ND') AS n_ncnd,
                    count(*) AS n_all FROM pobs GROUP BY uuid)
      SELECT u, count(*) AS obs, count(*) FILTER (au) AS obs_au,
             count(*) FILTER (role = 'pool') AS pool,
             count(*) FILTER (role = 'pool' AND n_use > 0) AS pool_usable,
             count(*) FILTER (role = 'pool' AND n_use = 0 AND n_sa + n_ncsa > 0 AND n_nd + n_ncnd = 0) AS pool_only_sa,
             count(*) FILTER (role = 'pool' AND n_use = 0 AND n_nd + n_ncnd > 0) AS pool_only_nd,
             count(*) FILTER (role = 'pool' AND n_use = 0 AND n_sa = 0 AND n_ncsa = 0 AND n_nd + n_ncnd = 0) AS pool_other,
             sum(n_use) FILTER (role = 'pool') AS pool_usable_photos,
             sum(n_sa) FILTER (role = 'pool') AS ph_sa, sum(n_ncsa) FILTER (role = 'pool') AS ph_ncsa,
             sum(n_nd) FILTER (role = 'pool') AS ph_nd, sum(n_ncnd) FILTER (role = 'pool') AS ph_ncnd,
             count(*) FILTER (role != 'pool') AS heldout
      FROM ob JOIN ph USING (uuid) GROUP BY u""").fetchall()
    cols = ["obs", "obs_au", "pool", "pool_usable", "pool_only_sa", "pool_only_nd", "pool_other",
            "pool_usable_photos", "ph_sa", "ph_ncsa", "ph_nd", "ph_ncnd", "heldout"]
    A = np.zeros((C, len(cols)), np.int64)
    for r in rows:
        A[r[0]] = [x or 0 for x in r[1:]]
    print(f"snapshot query {time.time() - t:.0f} s")
    b = buckets(ntr)
    out = {"note": __doc__, "per_bucket": {}}
    for k in ("0", "1-9", "10-49", "50-99"):
        m = b == k
        s = {c: int(A[m, i].sum()) for i, c in enumerate(cols)}
        s["classes"] = int(m.sum())
        s["train_photos"] = int(ntr[m].sum())
        s["classes_with_no_snapshot_obs"] = int((A[m, 0] == 0).sum())
        # photos if we ALSO used: every usable photo of pool obs (not just one); SA; ND
        extra_multi = A[m, 7] - A[m, 3]
        s["extra_usable_photos_same_obs"] = int(extra_multi.sum())
        s["median_per_class"] = {c: float(np.median(A[m, i])) for i, c in enumerate(cols)}
        s["median_train"] = float(np.median(ntr[m]))
        # how many classes would reach ≥ 10 / ≥ 50 photos (capped 100) under each widening
        def reach(v):
            return {f">={t}": int((np.minimum(v, 100) >= t).sum()) for t in (10, 50)}
        s["reach_now"] = reach(ntr[m])
        s["reach_+multi_photos"] = reach(ntr[m] + extra_multi)
        s["reach_+SA_ND_obs"] = reach(ntr[m] + A[m, 4] + A[m, 5])
        s["reach_+both"] = reach(ntr[m] + extra_multi + A[m, 8] + A[m, 9] + A[m, 10] + A[m, 11])
        out["per_bucket"][k] = s
    tot = con.execute("SELECT license, count(*) FROM pobs GROUP BY 1 ORDER BY 2 DESC").fetchall()
    out["snapshot_licences_all_photos"] = {k: int(v) for k, v in tot}
    np.save(os.path.join(V2, "tail_counts.npy"), A)
    json.dump(out, open(os.path.join(V2, "tail_data.json"), "w"), indent=1)
    for k, s in out["per_bucket"].items():
        print(k, {x: s[x] for x in ("classes", "train_photos", "pool_usable", "heldout", "pool_only_sa",
                                    "pool_only_nd", "extra_usable_photos_same_obs", "ph_sa", "ph_ncsa", "ph_nd",
                                    "ph_ncnd", "reach_now", "reach_+multi_photos", "reach_+SA_ND_obs", "reach_+both")})


def cmd_api(n=50):
    """All-rights-reserved share, sampled: for n tail classes (1–99 training photos,
    Australian natives, seeded random), iNat API v1 counts of research-grade
    observations with photos in Australia: total vs with a CC-licensed photo.
    ≤ 1 request per second; User-Agent izzymap-plantid-eval/1."""
    import pyarrow.parquet as pq
    D = np.load(os.path.join(V2, "data.npz"))
    C = D["T"].shape[0]
    ntr = np.bincount(D["ytr"], minlength=C)
    U = pq.read_table(os.path.join(AU, "labels.parquet"), columns=["name", "native", "inat_ids"]).to_pydict()
    cand = [u for u in range(C) if 1 <= ntr[u] < 100 and U["native"][u] and U["inat_ids"][u]]
    pick = [cand[i] for i in np.random.default_rng(5).permutation(len(cand))[:n]]
    UA = {"User-Agent": "izzymap-plantid-eval/1"}
    lic = "cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nd,cc-by-nc-sa,cc-by-nc-nd"
    res = []
    for u in pick:
        tid = U["inat_ids"][u][0]
        r = {}
        for key, extra in (("total", ""), ("cc", f"&photo_license={lic}"), ("usable", "&photo_license=cc0,cc-by,cc-by-nc")):
            url = (f"https://api.inaturalist.org/v1/observations?taxon_id={tid}&quality_grade=research&place_id=6744"
                   f"&photos=true&per_page=0{extra}")
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as f:
                        r[key] = json.load(f)["total_results"]
                    break
                except Exception:
                    time.sleep(5)
            time.sleep(1.1)
        res.append({"u": int(u), "name": U["name"][u], "train": int(ntr[u]), **r})
        print(res[-1], flush=True)
    ok = [r for r in res if all(k in r for k in ("total", "cc", "usable"))]
    T, Cc, Us = (sum(r[k] for r in ok) for k in ("total", "cc", "usable"))
    summ = {"species": len(ok), "obs_total": T, "obs_with_cc_photo": Cc, "obs_with_usable_photo": Us,
            "all_rights_reserved_share": round(1 - Cc / T, 3) if T else None,
            "sa_nd_only_share": round((Cc - Us) / T, 3) if T else None,
            "median_ratio_total_to_usable": float(np.median([r["total"] / max(r["usable"], 1) for r in ok]))}
    json.dump({"summary": summ, "species": res}, open(os.path.join(V2, "tail_api.json"), "w"), indent=1)
    print(json.dumps(summ))


if __name__ == "__main__":
    {"snapshot": cmd_snapshot, "api": cmd_api}[sys.argv[1]]()

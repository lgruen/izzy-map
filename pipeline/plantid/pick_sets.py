#!/usr/bin/env python3
"""Plant-ID evaluation, step 1: label set, train / val / test photos and the
location-prior records, from the iNaturalist Open Dataset metadata.

Inputs (pipeline/cache/plantid/meta/, see fetch_meta.sh): taxa, observations,
photos as iNat ships them (tab-separated .csv.gz; plain .csv also accepted).
Optional: --un-plants = the Plants branch's app/src/generated/plants.json, so
every Understorey Network species is a label even without a Tasmanian iNat
record.

Design (why each rule exists):
- OBSERVER SPLIT FIRST. Observers are hashed into val (~10 %), test (~20 %)
  and pool (the rest). Train photos, the location prior and the label set come
  ONLY from pool observers; val/test photos ONLY from val/test observers. So a
  test photographer's own garden, camera and favourite walks are never in
  what the method learned from — the app's users (Leo, his partner) won't be
  in the training data either.
- TIME CUT for eval photos. BioCLIP 2 was trained on TreeOfLife-200M (GBIF
  ~May 2024), which contains iNat photos. Val/test photos are Tasmanian
  observations made on/after --cutoff, so the pretrained model cannot have
  seen them. Pool data of any date is fine (it is what the method may learn).
  The app's own prior (ALA nearby.bin) contains iNat records of all observers
  and dates, i.e. the test observations themselves — hence a prior built here.
- SHARED PHOTOS. One photo can be attached to several observations (duplicate
  uploads, group outings); an eval photo whose id belongs to any other
  observation is dropped, so identical pixels can't sit in train and test.
- Labels = species (infraspecific taxa roll up) with a research-grade
  Tasmanian pool record, plus UN species (active iNat names only). Eval
  photos of other species — and research-grade photos identified only to
  genus or as a hybrid — stay in as "not in label set": the real miss rate.
- Train photos come from anywhere (Tasmanian first, then Australian, then the
  rest), at most --train-cap per species, observer diversity first (an
  observer's 4th+ photo of a species only fills in when nobody else has one).
- Eval photos are capped per species and per observer; each carries its
  species' natural count in that split so the evaluation can re-weight to
  "photos people actually take".
- Licences: only photos under CC0 / PD / CC BY / CC BY-NC (see README.md).
  The prior uses observation coordinates only (facts), any photo licence.
- Caching: only the two big scans (obs, pobs) are cached in work.duckdb; they
  do not depend on any option. Everything downstream is rebuilt every run.
"""
import argparse
import json
import os
import sys
import time

import duckdb
import pyarrow as pa

PLANTAE = 47126
TAS = "lat BETWEEN -44.0 AND -39.2 AND lon BETWEEN 143.5 AND 149.0"
# Coarse Australia box (mainland + Tasmania, cuts off PNG / most of NZ);
# only used to prefer Australian photos when filling train slots.
AUS = "lat BETWEEN -44.0 AND -9.5 AND lon BETWEEN 112.0 AND 154.5"
USABLE = ("CC0", "PD", "CC-BY", "CC-BY-NC")
TAXO_RANKS = ("kingdom", "phylum", "class", "order", "family")

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")


def src(meta, name):
    for ext in (".csv.gz", ".csv"):
        p = os.path.join(meta, name + ext)
        if os.path.exists(p):
            return p
    sys.exit(f"missing {name}.csv(.gz) in {meta} — run fetch_meta.sh")


def tsv(path, cols):
    # iNat's TSVs carry no quoting; quote='' would still let a stray " in a
    # taxon name swallow lines, so disable quoting/escaping explicitly. Rows
    # that fail to parse are kept in reject tables and counted in the summary.
    spec = ", ".join(f"'{k}': '{v}'" for k, v in cols.items())
    return (f"read_csv('{path}', delim='\t', header=true, quote='', escape='', "
            f"auto_detect=false, columns={{{spec}}}, store_rejects=true)")


def stage(con, table, sql, cached=False, fresh=False):
    have = con.execute(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = ?",
        [table]).fetchone()[0]
    if have and cached and not fresh:
        n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        print(f"  {table}: cached ({n:,} rows)")
        return
    t = time.time()
    con.execute(f"CREATE OR REPLACE TABLE {table} AS {sql}")
    n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
    rej = con.execute("SELECT count(*) FROM reject_errors").fetchone()[0] \
        if con.execute("SELECT count(*) FROM duckdb_tables() "
                       "WHERE table_name = 'reject_errors'").fetchone()[0] else 0
    print(f"  {table}: {n:,} rows in {time.time() - t:.0f} s"
          + (f" ({rej:,} unparseable lines so far)" if rej else ""))


def build_taxa(con, meta, fresh):
    """plant(taxon_id -> species_id or NULL) + species names and taxonomy."""
    stage(con, "taxa", "SELECT * FROM " + tsv(src(meta, "taxa"), {
        "taxon_id": "INTEGER", "ancestry": "VARCHAR", "rank_level": "DOUBLE",
        "rank": "VARCHAR", "name": "VARCHAR", "active": "BOOLEAN"}) +
        # Plantae itself, its children (ancestry ends at Plantae: phyla such
        # as Tracheophyta) and everything below
        f" WHERE taxon_id = {PLANTAE} OR ancestry = '48460/{PLANTAE}'"
        f" OR ancestry LIKE '48460/{PLANTAE}/%'", cached=True, fresh=fresh)
    rows = con.execute("SELECT taxon_id, ancestry, rank_level, rank, name, active "
                       "FROM taxa").fetchall()
    by_id = {r[0]: r for r in rows}
    plant, species = [], []
    for tid, anc, lvl, rank, name, active in rows:
        sp = None
        if rank == "species":
            sp = tid
        elif lvl is not None and lvl < 10:
            # subspecies / variety / form → nearest species ancestor
            sp = next((int(a) for a in reversed(anc.split("/"))
                       if int(a) in by_id and by_id[int(a)][3] == "species"), None)
        # genus-level and hybrid taxa (rank "hybrid", level 10) keep sp = NULL:
        # they count as eval photos outside the label set, never as labels
        plant.append((tid, sp, rank))
        if rank == "species":
            lineage = {by_id[int(a)][3]: by_id[int(a)][4]
                       for a in anc.split("/") if int(a) in by_id}
            taxo = " ".join([lineage[r] for r in TAXO_RANKS if r in lineage] + [name])
            species.append((tid, name, bool(active), lineage.get("family"),
                            lineage.get("genus"), lineage.get("order"),
                            lineage.get("class"), taxo))
    # executemany is ~100x slower than handing DuckDB an Arrow table
    cols = lambda rows, names: pa.table({n: [r[i] for r in rows] for i, n in enumerate(names)})
    for name, rows, names in (
            ("plant", plant, ("taxon_id", "species_id", "rank")),
            ("species", species, ("species_id", "name", "active", "family", "genus",
                                  "ord", "cls", "taxo"))):
        con.register("v", cols(rows, names))
        con.execute(f"CREATE OR REPLACE TABLE {name} AS SELECT * FROM v")
        con.unregister("v")
    print(f"  plant taxa: {len(plant):,}, species: {len(species):,}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--meta", default=os.path.join(CACHE, "meta"))
    ap.add_argument("--out", default=os.path.join(CACHE, "sets"))
    ap.add_argument("--cutoff", default="2024-09-01")
    ap.add_argument("--train-cap", type=int, default=40)
    ap.add_argument("--test-cap", type=int, default=8)
    ap.add_argument("--obs-cap", type=int, default=3,
                    help="train photos per (species, observer) before others fill in")
    ap.add_argument("--val-share", type=int, default=2, help="observer hash %% 20 < this → val")
    ap.add_argument("--test-share", type=int, default=4, help="… next this many → test")
    ap.add_argument("--un-plants", help="plants.json from the Plants branch")
    ap.add_argument("--seed", default="izzy")
    ap.add_argument("--fresh", action="store_true", help="redo the cached big scans too")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    con = duckdb.connect(os.path.join(a.out, "work.duckdb"))
    con.execute("SET preserve_insertion_order = false")
    t0 = time.time()
    cut = f"DATE '{a.cutoff}'"

    print("taxa")
    build_taxa(con, a.meta, a.fresh)

    print("observations (research-grade plants, one pass over the dump)")
    stage(con, "obs", f"""
        SELECT o.observation_uuid AS uuid, o.observer_id, o.taxon_id,
               o.latitude AS lat, o.longitude AS lon, o.positional_accuracy AS pacc,
               p.species_id, o.observed_on
        FROM {tsv(src(a.meta, "observations"), {
            "observation_uuid": "UUID", "observer_id": "INTEGER", "latitude": "DOUBLE",
            "longitude": "DOUBLE", "positional_accuracy": "INTEGER", "taxon_id": "INTEGER",
            "quality_grade": "VARCHAR", "observed_on": "DATE", "anomaly_score": "DOUBLE"})} o
        JOIN plant p ON o.taxon_id = p.taxon_id
        WHERE o.quality_grade = 'research' AND o.latitude IS NOT NULL
          AND o.observed_on IS NOT NULL""", cached=True, fresh=a.fresh)

    print("photos of those observations (one pass, any licence)")
    stage(con, "pobs", f"""
        SELECT observation_uuid AS uuid, photo_id, extension AS ext, license, position
        FROM {tsv(src(a.meta, "photos"), {
            "photo_uuid": "UUID", "photo_id": "INTEGER", "observation_uuid": "UUID",
            "observer_id": "INTEGER", "extension": "VARCHAR", "license": "VARCHAR",
            "width": "SMALLINT", "height": "SMALLINT", "position": "SMALLINT"})}
        WHERE observation_uuid IN (SELECT uuid FROM obs)""", cached=True, fresh=a.fresh)

    print("splits")
    hv = f"hash(observer_id::VARCHAR || '{a.seed}') % 20"
    stage(con, "who", f"""
        SELECT DISTINCT observer_id,
               CASE WHEN {hv} < {a.val_share} THEN 'val'
                    WHEN {hv} < {a.val_share + a.test_share} THEN 'test'
                    ELSE 'pool' END AS role
        FROM obs""")
    lic = ", ".join(f"'{x}'" for x in USABLE)
    stage(con, "photo", f"""
        SELECT uuid, arg_min(photo_id, position) AS photo_id,
               arg_min(ext, position) AS ext, arg_min(license, position) AS license
        FROM pobs WHERE license IN ({lic}) GROUP BY uuid""")
    stage(con, "shared", """
        SELECT photo_id FROM pobs GROUP BY photo_id HAVING count(DISTINCT uuid) > 1""")
    stage(con, "o", f"""
        SELECT obs.*, who.role FROM obs JOIN who USING (observer_id)""")

    print("label set")
    un_ids, un_missing = set(), []
    if a.un_plants:
        names = sorted({p["species"] for p in json.load(open(a.un_plants))["plants"]
                        if p.get("species")})
        # active names only: an inactive (outdated) name has no observations
        # and would be a ghost class competing with its accepted synonym
        lut = dict(con.execute("SELECT name, species_id FROM species WHERE active").fetchall())
        for n in names:
            (un_ids.add(lut[n]) if n in lut else un_missing.append(n))
        print(f"  UN species: {len(names)} names, {len(un_ids)} matched to active iNat species")
    con.register("un_v", pa.table({"species_id": sorted(un_ids)}, schema=pa.schema(
        [("species_id", pa.int32())])))
    con.execute("CREATE OR REPLACE TABLE un AS SELECT * FROM un_v")
    stage(con, "labels", f"""
        WITH tas_pool AS (SELECT species_id, count(*) AS n_tas_pool FROM o
                          WHERE role = 'pool' AND {TAS} AND species_id IS NOT NULL
                          GROUP BY ALL),
             ids AS (SELECT species_id FROM tas_pool UNION SELECT species_id FROM un)
        SELECT s.species_id, s.name, s.family, s.genus, s.ord, s.cls, s.taxo,
               coalesce(n_tas_pool, 0) AS n_tas_pool,
               s.species_id IN (SELECT species_id FROM un) AS in_un
        FROM ids JOIN species s USING (species_id) LEFT JOIN tas_pool USING (species_id)""")

    print("sampling")
    h = f"hash(uuid::VARCHAR || '{a.seed}')"
    stage(con, "train", f"""
        WITH c AS (
            SELECT o.*, p.photo_id, p.ext, p.license,
                   CASE WHEN {TAS} THEN 0 WHEN {AUS} THEN 1 ELSE 2 END AS region, {h} AS h
            FROM o JOIN photo p USING (uuid)
            WHERE o.role = 'pool' AND o.species_id IN (SELECT species_id FROM labels)),
        c2 AS (SELECT *, row_number() OVER (PARTITION BY species_id, observer_id
                                            ORDER BY region, h) AS rk_obs FROM c),
        c3 AS (SELECT *, row_number() OVER (PARTITION BY species_id
                                            ORDER BY rk_obs > {a.obs_cap}, region, h) AS rk
               FROM c2)
        SELECT uuid, photo_id, ext, license, species_id, observer_id, lat, lon,
               observed_on, region, rk FROM c3 WHERE rk <= {a.train_cap}""")
    stage(con, "test", f"""
        WITH c AS (
            SELECT o.*, p.photo_id, p.ext, p.license, {h} AS h,
                   coalesce(o.species_id, -o.taxon_id) AS key
            FROM o JOIN photo p USING (uuid)
            WHERE o.role IN ('val', 'test') AND o.observed_on >= {cut} AND {TAS}
              AND p.photo_id NOT IN (SELECT photo_id FROM shared)),
        c2 AS (SELECT *, row_number() OVER (PARTITION BY key, observer_id ORDER BY h)
                   AS rk_obs FROM c),
        c3 AS (SELECT *, row_number() OVER (PARTITION BY role, key
                                            ORDER BY rk_obs > 2, h) AS rk,
                         count(*) OVER (PARTITION BY role, key) AS n_split FROM c2)
        SELECT uuid, photo_id, ext, license, species_id, taxon_id, observer_id, lat, lon,
               pacc, observed_on, role AS split, n_split,
               coalesce(species_id IN (SELECT species_id FROM labels), false) AS in_labels
        FROM c3 WHERE rk <= {a.test_cap}""")
    stage(con, "prior", f"""
        SELECT species_id, lat, lon FROM o
        WHERE role = 'pool' AND {TAS}
          AND species_id IN (SELECT species_id FROM labels)
          AND (pacc IS NULL OR pacc <= 1000)""")

    # invariants: the splits must not share observers or pixels
    q = lambda s: con.execute(s).fetchone()
    assert q("""SELECT count(*) FROM train t JOIN test e USING (photo_id)""")[0] == 0
    assert q("""SELECT count(*) FROM (SELECT DISTINCT observer_id FROM train)
                JOIN (SELECT DISTINCT observer_id FROM test) USING (observer_id)""")[0] == 0
    assert q("""SELECT count(*) FROM (SELECT observer_id FROM test WHERE split = 'val')
                JOIN (SELECT observer_id FROM test WHERE split = 'test')
                USING (observer_id)""")[0] == 0

    for t in ("labels", "train", "test", "prior"):
        con.execute(f"COPY {t} TO '{os.path.join(a.out, t)}.parquet' (FORMAT parquet)")

    nl, nun = q("SELECT count(*), count(*) FILTER (in_un) FROM labels")
    ntr, nsp = q("SELECT count(*), count(DISTINCT species_id) FROM train")
    tiers = con.execute("""
        SELECT CASE WHEN n = 0 THEN '0' WHEN n < 5 THEN '1-4' WHEN n < 20 THEN '5-19'
                    ELSE '20+' END AS tier, count(*)
        FROM (SELECT l.species_id, count(t.uuid) AS n FROM labels l
              LEFT JOIN train t USING (species_id) GROUP BY ALL) GROUP BY ALL ORDER BY 1""").fetchall()
    tst = con.execute("""SELECT split, count(*), count(DISTINCT species_id),
                                count(*) FILTER (NOT in_labels),
                                count(*) FILTER (species_id IS NULL),
                                count(DISTINCT observer_id) FROM test GROUP BY ALL""").fetchall()
    roles = dict(con.execute(f"""SELECT role, count(*) FROM o WHERE {TAS} GROUP BY ALL""").fetchall())
    dropped_shared = q(f"""SELECT count(*) FROM o JOIN photo p USING (uuid)
                           WHERE o.role IN ('val', 'test') AND o.observed_on >= {cut} AND {TAS}
                             AND p.photo_id IN (SELECT photo_id FROM shared)""")[0]
    rej = q("SELECT count(*) FROM reject_errors")[0] if q(
        "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'reject_errors'")[0] else 0
    summary = {
        "cutoff": a.cutoff, "labels": nl, "labels_from_un": nun,
        "un_unmatched_count": len(un_missing), "un_unmatched": un_missing,
        "tas_research_obs_by_role": roles,
        "train_photos": ntr, "train_species": nsp, "train_tiers": dict(tiers),
        "train_licences": dict(con.execute(
            "SELECT license, count(*) FROM train GROUP BY ALL ORDER BY 2 DESC").fetchall()),
        "eval": {s: {"photos": n, "species": k, "not_in_labels": x, "genus_or_hybrid": g,
                     "observers": ob} for s, n, k, x, g, ob in tst},
        "eval_dropped_shared_photo": dropped_shared,
        "prior_records": q("SELECT count(*) FROM prior")[0],
        "unparseable_lines": rej, "seconds": round(time.time() - t0),
    }
    json.dump(summary, open(os.path.join(a.out, "summary.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k != "un_unmatched"}, indent=1))


if __name__ == "__main__":
    main()

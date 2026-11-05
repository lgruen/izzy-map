#!/usr/bin/env python3
"""More training photos for the Australia-wide plant ID from the local iNat
open-data snapshot (notes/data_expansion.md; survey: notes/photo_sources.md).

Training today (`eval_australia.py plan` → australia/plan/train.parquet ∪ the
Tasmanian sets/train.parquet): pool observers only, ONE CC0/PD/BY/BY-NC photo
per research-grade observation, ≤ 100 photos per class. Three extras, all
photos 500 px "medium" from the open-data bucket, all observers pool-role and
asserted disjoint from every evaluation set (A val/test, C tune/report, plan
AU-val/AU-test — AU-tune is a subset of AU-val):

  inat-extra-photo  more photos of observations already in training (any CC
                    licence), ≤ 3 photos per observation in all
  inat-sa-nd        research-grade pool observations NOT in training whose
                    photos are only CC BY-SA / BY-NC-SA / BY-ND / BY-NC-ND
                    (licence decision, Leo 2026-11-05: every CC licence is
                    fine for TRAINING; all-rights-reserved never — not in the
                    open-data bucket anyway)
  inat-name-map     research-grade pool observations of an iNat taxon the
                    APC↔iNat name map (names/apc_inat_map.json) newly assigns
                    to a photo-less label (synonym / orthographic / split;
                    infraspecific parts take only their subtree, which leaves
                    the parent class — training photos so moved:
                    extra/reassign_train.parquet)
  inat-rg-unused    research-grade pool observations with a CC0/BY/BY-NC photo
                    that the plan did not use although the class is under the
                    cap (its first usable photo shared with another
                    observation; classes at 95–99 = photos gone upstream)
  inat-needs-id     needs_id observations, ONLY classes with < 20 training
                    photos, ONLY observers with a research-grade track record
                    in that genus (rule in `select`, noise estimate in `noise`)

Per-class budget: training + extras ≤ CAP (100) photos — the plan's cap, so
classes already at it gain nothing and rare classes gain the most. Fill order
inside a class (breadth before depth): new research-grade observations'
first photos, then every observation's 2nd photo, then 3rd photos, then the
needs_id tiers in the same order; ties: ≤ 3 per (class, observer) first,
Australia first, a fixed hash.

Subcommands (in order; outputs in pipeline/cache/plantid/extra/, gitignored):
  scan      one pass over observations.csv.gz (needs_id observations of the
            target classes) and one over photos.csv.gz (their photos)
            → extra/work/needs_id_{obs,photos}.parquet       (~4 + ~6 min)
  select    the candidate list → extra/work/candidates.parquet + summary
  measure   fetch the first N candidates (default 500), report photos/s and
            the projected total time; nothing else
  fetch     download (resumable) to extra/inat/<photo_id>.<ext> and hash
            (dedup.py: pHash + dHash) → extra/work/hashes-cand-part*.parquet;
            stores only classes with < --keep-below training photos (default
            1), the rest is hashed in memory (disk is tight; the VM streams
            from S3 anyway)
  evalhash  hash every evaluation photo (local copies where present, else
            streamed from S3, never stored) → extra/work/hashes-eval.parquet
  calibrate dedup thresholds from known duplicates (dedup.py calibrate)
  dedup     drop near-duplicates of evaluation photos and within the extras
            → extra/extra_photos.parquet (the list train_australia reads)
            + extra/dropped.parquet
  noise     needs_id label noise: iNat API v1 (≤ 1 req/s, 200 uuids per
            request) — current identifications of admitted (and, as a
            control, rejected) needs_id observations → extra/work/noise.json

Env: uv run --with duckdb --with pyarrow --with numpy --with pillow
         --with imagehash python3 -I pipeline/plantid/expand_inat.py <cmd>
User-Agent "izzymap-plantid-eval/1".
"""
import argparse
import collections
import concurrent.futures as cf
import hashlib
import http.client
import io
import json
import os
import shutil
import sys
import threading
import time
import urllib.parse
import urllib.request

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dedup  # noqa: E402

CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
META = os.path.join(CACHE, "meta")
EX = os.path.join(CACHE, "extra")
WORK = os.path.join(EX, "work")
PHOTOS = os.path.join(EX, "inat")
LABELS = os.path.join(CACHE, "ship", "au-labels.json")
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
CAP = 100            # photos per class, training + extras
PER_OBS = 3          # photos per observation in all
NEEDS_ID_BELOW = 20  # needs_id only for classes with fewer training photos
SAND = ("CC-BY-SA", "CC-BY-NC-SA", "CC-BY-ND", "CC-BY-NC-ND")
USABLE = ("CC0", "PD", "CC-BY", "CC-BY-NC")
CC_ALL = USABLE + SAND
AUS = "lat BETWEEN -44.0 AND -9.5 AND lon BETWEEN 112.0 AND 154.5"
# needs_id track record (see `select`): research-grade observations of the
# same iNat genus by the same observer
TRACK_MIN = 5
MIN_FREE_GB = 6.0    # stop downloading when the disk gets this full

sql_list = lambda xs: "(" + ", ".join(f"'{x}'" for x in xs) + ")"  # noqa: E731


def db():
    import duckdb
    con = duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)
    con.execute("SET preserve_insertion_order = false")
    return con


def labels():
    return json.load(open(LABELS))["labels"]


def ntr_table():
    L = labels()
    return pa.table({"u": np.arange(len(L), dtype=np.int64),
                     "ntr": np.array([l["train_photos"] for l in L], np.int64)})


def bucket(n):
    n = np.asarray(n)
    return np.select([n == 0, n < 10, n < 20, n < 50], ["0", "1-9", "10-19", "20-49"], "50+")


def eval_sets():
    """Every evaluation photo (photo_id, ext, observer_id, set) — A val/test
    (sets/test.parquet), C tune/report, plan eval (AU-val ⊃ AU-tune, AU-test)."""
    A = pq.read_table(os.path.join(CACHE, "sets", "test.parquet"),
                      columns=["photo_id", "ext", "observer_id", "split"]).to_pydict()
    C = pq.read_table(os.path.join(AU, "C.parquet"), columns=["photo_id", "ext", "observer_id", "half"]).to_pydict()
    P = pq.read_table(os.path.join(AU, "plan", "eval.parquet"),
                      columns=["photo_id", "ext", "observer_id", "role"]).to_pydict()
    rows = ([(p, e, o, "A-" + s) for p, e, o, s in zip(A["photo_id"], A["ext"], A["observer_id"], A["split"])] +
            [(p, e, o, "C-" + s) for p, e, o, s in zip(C["photo_id"], C["ext"], C["observer_id"], C["half"])] +
            [(p, e, o, "AU-" + s) for p, e, o, s in zip(P["photo_id"], P["ext"], P["observer_id"], P["role"])])
    return pa.table({"photo_id": [int(r[0]) for r in rows], "ext": [r[1] for r in rows],
                     "observer_id": [int(r[2]) for r in rows], "set": [r[3] for r in rows]})


# ------------------------------------------------------------------ names

NAME_MAP = os.path.join(CACHE, "names", "apc_inat_map.json")
FLOW_REL = ("exact", "synonym", "orthographic", "split")  # "lump", "none": no photos; "merge": already flow


def taxon_map(con):
    """TEMP TABLE tmap(taxon_id, species_id, u, via): which class an iNat taxon's
    observations train. Base = the eval's inat_map (species roll-up). Overrides
    from the APC↔iNat name map (names/apc_inat_map.json, photo-less labels):
    relation exact / synonym / orthographic / split with photo_flow ≠ merge →
    a species-rank part takes the whole species (all its infraspecies), an
    infraspecific / hybrid part only its own subtree — those observations
    LEAVE the parent class they reached through the roll-up."""
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    con.execute("""CREATE OR REPLACE TEMP TABLE tbase AS
        SELECT p.taxon_id::INTEGER AS taxon_id, p.species_id, m.u FROM plant p JOIN imap_v m USING (species_id)""")
    M = json.load(open(NAME_MAP)) if os.path.exists(NAME_MAP) else {}
    # "lump" / "none": the name map found the label's iNat taxon belongs to
    # another APC species (or is a homonym) → no photos, even through an
    # existing inat_map entry
    drop = [int(v["index"]) for v in M.values() if v.get("relation") in ("lump", "none")]
    con.register("drop_v", pa.table({"u": pa.array(drop, pa.int64())}))
    nd = con.execute("SELECT count(*), count(DISTINCT u) FROM tbase WHERE u IN (SELECT u FROM drop_v)").fetchall()[0]
    con.execute("DELETE FROM tbase WHERE u IN (SELECT u FROM drop_v)")
    print(f"name map lump/none: {nd[0]} taxa of {nd[1]} labels no longer feed them", flush=True)
    parts = []
    for v in M.values():
        if v.get("relation") in FLOW_REL and v.get("photo_flow") not in ("none", "merge"):
            for t in v.get("inat_taxon_ids") or []:
                parts.append((int(v["index"]), int(t), v["relation"]))
    con.register("parts_v", pa.table({"u": [x[0] for x in parts], "pid": [x[1] for x in parts],
                                      "rel": [x[2] for x in parts]}))
    con.execute("""CREATE OR REPLACE TEMP TABLE ov AS
        WITH pr AS (SELECT pv.*, t.rank AS prank FROM parts_v pv JOIN taxa t ON t.taxon_id = pv.pid),
        sp AS (SELECT p.taxon_id::INTEGER AS taxon_id, pr.u, pr.rel, 1 AS lvl
               FROM pr JOIN plant p ON p.species_id = pr.pid WHERE pr.prank = 'species'),
        sub AS (SELECT t.taxon_id, pr.u, pr.rel, 2 AS lvl FROM pr JOIN taxa t
                  ON t.taxon_id = pr.pid OR t.ancestry LIKE '%/' || pr.pid::VARCHAR
                  OR t.ancestry LIKE '%/' || pr.pid::VARCHAR || '/%'
                WHERE pr.prank != 'species')
        SELECT * FROM sp UNION ALL SELECT * FROM sub""")
    amb = con.execute("""SELECT count(*) FROM (SELECT taxon_id, lvl FROM ov GROUP BY ALL
                         HAVING count(DISTINCT u) > 1)""").fetchall()[0][0]
    assert amb == 0, f"{amb} taxa claimed by two labels at the same level"
    # a species-level override must not take a species another label already owns
    clash = con.execute("""SELECT count(DISTINCT o.u) FROM ov o JOIN tbase b USING (taxon_id)
                           WHERE o.lvl = 1 AND b.u != o.u""").fetchall()[0][0]
    con.execute("""CREATE OR REPLACE TEMP TABLE tmap AS
        WITH best AS (SELECT taxon_id, arg_max(u, lvl) AS u, arg_max(rel, lvl) AS rel FROM ov
                      WHERE lvl = 2 OR taxon_id NOT IN (SELECT taxon_id FROM tbase) GROUP BY taxon_id)
        SELECT coalesce(b.taxon_id, x.taxon_id) AS taxon_id, pl.species_id,
               coalesce(x.u, b.u) AS u, coalesce(x.rel, 'inat_map') AS via, b.u AS u_base
        FROM tbase b FULL OUTER JOIN best x USING (taxon_id) LEFT JOIN plant pl
             ON pl.taxon_id = coalesce(b.taxon_id, x.taxon_id)""")
    st = con.execute("""SELECT count(*) FILTER (via != 'inat_map'), count(DISTINCT u) FILTER (via != 'inat_map'),
                               count(*) FILTER (u_base IS NOT NULL AND u_base != u) FROM tmap""").fetchall()[0]
    print(f"name map: {len(parts)} parts; {st[0]:,} taxa → {st[1]} labels via the map, {st[2]:,} of them moved off a "
          f"parent class; {clash} species overrides skipped (owned by another label)", flush=True)
    return M


# ------------------------------------------------------------------ scan

def tsv(path, cols):
    spec = ", ".join(f"'{k}': '{v}'" for k, v in cols.items())
    return (f"read_csv('{path}', delim='\t', header=true, quote='', escape='', "
            f"auto_detect=false, columns={{{spec}}}, ignore_errors=true)")


def cmd_scan(a):
    """Incremental: the target-taxon list of every scan is kept
    (needs_id_targets.parquet); a later run (e.g. after the name map grew)
    scans only the new taxa and appends."""
    os.makedirs(WORK, exist_ok=True)
    con = db()
    con.register("ntr_v", ntr_table())
    taxon_map(con)
    con.execute(f"""CREATE TEMP TABLE tgt AS
        SELECT DISTINCT t.taxon_id FROM tmap t JOIN ntr_v USING (u) WHERE ntr < {NEEDS_ID_BELOW}""")
    out_o = os.path.join(WORK, "needs_id_obs.parquet")
    out_p = os.path.join(WORK, "needs_id_photos.parquet")
    out_t = os.path.join(WORK, "needs_id_targets.parquet")
    if os.path.exists(out_o) and not a.fresh:
        if os.path.exists(out_t):
            con.execute(f"CREATE TEMP TABLE old AS SELECT taxon_id FROM '{out_t}'")
        else:  # the first scan (before the name map): the inat_map roll-up targets
            con.execute(f"""CREATE TEMP TABLE old AS SELECT taxon_id FROM tbase JOIN ntr_v USING (u)
                            WHERE ntr < {NEEDS_ID_BELOW}""")
        con.execute("CREATE TEMP TABLE todo AS SELECT taxon_id FROM tgt EXCEPT SELECT taxon_id FROM old")
    else:
        con.execute("CREATE TEMP TABLE old AS SELECT 0 AS taxon_id WHERE FALSE")
        con.execute("CREATE TEMP TABLE todo AS SELECT taxon_id FROM tgt")
    n = con.execute("SELECT (SELECT count(*) FROM tgt), (SELECT count(*) FROM todo)").fetchall()[0]
    print(f"target taxa {n[0]:,}, to scan {n[1]:,}", flush=True)
    if n[1]:
        t = time.time()
        add_o, add_p = out_o + ".add.parquet", out_p + ".add.parquet"
        con.execute(f"""COPY (
            SELECT o.observation_uuid AS uuid, o.observer_id, o.taxon_id,
                   o.latitude AS lat, o.longitude AS lon, o.positional_accuracy AS pacc, o.observed_on
            FROM {tsv(os.path.join(META, 'observations.csv.gz'), {
                'observation_uuid': 'UUID', 'observer_id': 'INTEGER', 'latitude': 'DOUBLE',
                'longitude': 'DOUBLE', 'positional_accuracy': 'INTEGER', 'taxon_id': 'INTEGER',
                'quality_grade': 'VARCHAR', 'observed_on': 'DATE', 'anomaly_score': 'DOUBLE'})} o
            WHERE o.quality_grade = 'needs_id' AND o.taxon_id IN (SELECT taxon_id FROM todo))
            TO '{add_o}' (FORMAT parquet)""")
        print(f"needs_id observations: {pq.read_metadata(add_o).num_rows:,} new ({time.time() - t:.0f} s)", flush=True)
        t = time.time()
        con.execute(f"CREATE TEMP TABLE nid AS SELECT DISTINCT uuid FROM '{add_o}'")
        con.execute(f"""COPY (
            SELECT p.observation_uuid AS uuid, p.photo_id, p.observer_id, p.extension AS ext, p.license,
                   p.width, p.height, p.position
            FROM {tsv(os.path.join(META, 'photos.csv.gz'), {
                'photo_uuid': 'UUID', 'photo_id': 'INTEGER', 'observation_uuid': 'UUID',
                'observer_id': 'INTEGER', 'extension': 'VARCHAR', 'license': 'VARCHAR',
                'width': 'SMALLINT', 'height': 'SMALLINT', 'position': 'SMALLINT'})} p
            WHERE p.observation_uuid IN (SELECT uuid FROM nid)) TO '{add_p}' (FORMAT parquet)""")
        print(f"their photos: {pq.read_metadata(add_p).num_rows:,} ({time.time() - t:.0f} s)", flush=True)
        for out, add, cols in ((out_o, add_o, "uuid, observer_id, taxon_id, lat, lon, pacc, observed_on"),
                               (out_p, add_p, "*")):
            src = f"SELECT {cols} FROM '{out}' UNION ALL SELECT {cols} FROM '{add}'" if os.path.exists(out) \
                else f"SELECT {cols} FROM '{add}'"
            con.execute(f"COPY ({src}) TO '{out}.tmp' (FORMAT parquet)")
            os.replace(out + ".tmp", out)
            os.remove(add)
    con.execute(f"COPY (SELECT taxon_id FROM tgt UNION SELECT taxon_id FROM old) TO '{out_t}' (FORMAT parquet)")
    print(f"needs_id obs {pq.read_metadata(out_o).num_rows:,}, photos {pq.read_metadata(out_p).num_rows:,}")


# ------------------------------------------------------------------ select

def cmd_select(a):
    """--cap/--per-obs (defaults 100 / 3); --uncapped = no class cap, every CC
    photo of every observation (Leo, 2026-11-05) → candidates-uncapped.parquet."""
    t0 = time.time()
    CAP, PER_OBS = (10 ** 9, 10 ** 6) if a.uncapped else (a.cap, a.per_obs)
    tag = "-uncapped" if a.uncapped else (f"-{a.tag}" if a.tag else "")
    big = a.uncapped or bool(a.tag)
    con = db()
    L = labels()
    con.register("ntr0_v", ntr_table())
    NM = taxon_map(con)
    rel_of = {int(v["index"]): v["relation"] for v in NM.values()}
    con.register("rel_v", pa.table({"u": list(rel_of), "name_relation": list(rel_of.values())}))
    ev = eval_sets()
    con.register("ev_v", ev)
    # ---- observer roles: pool only. `who` covers every observer with a research-
    # grade plant observation; needs_id-only observers have no track record and
    # are dropped by the track rule anyway, but recompute the split hash for them
    # and check it reproduces `who` exactly (same DuckDB hash → same split).
    chk = con.execute("""SELECT count(*) FILTER (CASE WHEN hash(observer_id::VARCHAR || 'izzy') % 20 < 2 THEN 'val'
                              WHEN hash(observer_id::VARCHAR || 'izzy') % 20 < 6 THEN 'test' ELSE 'pool' END != role),
                         count(*) FROM who""").fetchall()[0]
    assert chk[0] == 0, f"split hash does not reproduce `who` ({chk[0]:,} of {chk[1]:,} differ)"
    eval_obs = set(ev.column("observer_id").to_pylist())
    roles = dict(con.execute("SELECT role, count(*) FROM who WHERE observer_id IN (SELECT observer_id FROM ev_v) "
                             "GROUP BY 1").fetchall())
    assert set(roles) <= {"val", "test"}, roles  # every eval observer is a val/test observer
    print(f"split hash reproduces who ({chk[1]:,} observers); {len(eval_obs):,} eval observers, roles {roles}")

    con.execute("""CREATE TEMP TABLE tr AS
        SELECT DISTINCT uuid::UUID AS uuid, photo_id FROM (
          SELECT uuid, photo_id FROM 'PLAN' UNION ALL SELECT uuid, photo_id FROM 'TAS')"""
                .replace("PLAN", os.path.join(AU, "plan", "train.parquet"))
                .replace("TAS", os.path.join(CACHE, "sets", "train.parquet")))
    n_tr = con.execute("SELECT count(*), count(DISTINCT uuid) FROM tr").fetchall()[0]
    assert n_tr[0] == n_tr[1], "an observation with two training photos?"
    # training observations the name map moves to an infraspecific label (the
    # trainer should relabel them) and the effective training counts after that
    con.execute(f"""CREATE TEMP TABLE moved AS
        SELECT pt.uuid::VARCHAR AS observation_uuid, pt.photo_id, pt.u AS u_old, t.u AS u_new, t.via AS relation
        FROM '{os.path.join(AU, "plan", "train.parquet")}' pt JOIN o ON o.uuid = pt.uuid::UUID
        JOIN tmap t ON t.taxon_id = o.taxon_id WHERE t.u != pt.u""")
    con.execute(f"COPY moved TO '{os.path.join(EX, 'reassign_train.parquet')}' (FORMAT parquet)")
    mv = con.execute("SELECT count(*), count(DISTINCT u_new) FROM moved").fetchall()[0]
    print(f"training photos the name map moves to another label: {mv[0]:,} (into {mv[1]} labels) "
          f"→ extra/reassign_train.parquet")
    con.execute("""CREATE TEMP TABLE ntr_v AS
        SELECT u, ntr - coalesce(o_, 0) + coalesce(i_, 0) AS ntr FROM ntr0_v
        LEFT JOIN (SELECT u_old AS u, count(*) AS o_ FROM moved GROUP BY 1) USING (u)
        LEFT JOIN (SELECT u_new AS u, count(*) AS i_ FROM moved GROUP BY 1) USING (u)""")
    # photos attached to more than one observation: research-grade `shared` +
    # needs_id photos also attached to a research-grade observation / each other
    nid_o = os.path.join(WORK, "needs_id_obs.parquet")
    nid_p = os.path.join(WORK, "needs_id_photos.parquet")
    con.execute(f"""CREATE TEMP TABLE shared2 AS
        SELECT photo_id FROM shared
        UNION SELECT photo_id FROM (SELECT photo_id, uuid FROM '{nid_p}' UNION ALL SELECT photo_id, uuid FROM pobs
                                    WHERE photo_id IN (SELECT photo_id FROM '{nid_p}'))
              GROUP BY photo_id HAVING count(DISTINCT uuid) > 1""")
    evp = "(SELECT photo_id FROM ev_v)"

    # ---- research grade: training observations' extra photos + SA/ND-only new observations
    con.execute(f"""CREATE TEMP TABLE rg AS
        SELECT o.uuid, o.observer_id, o.lat, o.lon, o.observed_on, m.u, m.via, 'research' AS grade,
               (o.uuid IN (SELECT uuid FROM tr)) AS in_train,
               p.photo_id, p.ext, p.license, p.position
        FROM o JOIN tmap m ON m.taxon_id = o.taxon_id JOIN ntr_v USING (u) JOIN pobs p USING (uuid)
        WHERE o.role = 'pool' AND ntr < {CAP} AND p.license IN {sql_list(CC_ALL)}""")
    # SA/ND-only = no CC0/PD/BY/BY-NC photo at all (otherwise the plan had it)
    con.execute(f"""CREATE TEMP TABLE rg2 AS
        WITH x AS (SELECT uuid, bool_or(license IN {sql_list(USABLE)}) AS has_usable FROM rg GROUP BY uuid)
        SELECT rg.*, CASE WHEN in_train THEN 'inat-extra-photo'
                          WHEN NOT has_usable THEN 'inat-sa-nd'
                          WHEN via != 'inat_map' THEN 'inat-name-map' ELSE 'inat-rg-unused' END AS source
        FROM rg JOIN x USING (uuid)""")
    other = con.execute("""SELECT count(DISTINCT uuid), count(DISTINCT u), count(DISTINCT uuid) FILTER (ntr < 95),
                                  count(DISTINCT u) FILTER (ntr < 95)
                           FROM rg2 JOIN ntr_v USING (u) WHERE source = 'inat-rg-unused'""").fetchall()[0]
    print(f"pool research obs with a CC0/BY/BY-NC photo, not in training, class under the cap: {other[0]:,} "
          f"({other[1]:,} classes) — {other[0] - other[2]:,} in classes at 95–99 (the plan's 100 minus photos "
          f"gone upstream), {other[2]:,} in {other[3]} classes (first usable photo shared, or the class lost photos "
          f"to a name-map move) — source inat-rg-unused, they fill those slots first")

    # ---- needs_id with the track rule
    con.execute(f"""CREATE TEMP TABLE genus_rg AS
        SELECT o.observer_id, s.genus, count(*) AS n_rg
        FROM o JOIN species s USING (species_id) GROUP BY ALL""")
    con.execute(f"""CREATE TEMP TABLE nid AS
        SELECT n.uuid, n.observer_id, n.lat, n.lon, n.observed_on, m.u, m.via, n.taxon_id,
               coalesce(m.species_id, n.taxon_id) AS species_id,
               split_part(tx.name, ' ', 1) AS genus, coalesce(g.n_rg, 0) AS n_rg_genus,
               CASE WHEN hash(n.observer_id::VARCHAR || 'izzy') % 20 < 6 THEN 'heldout' ELSE 'pool' END AS role
        FROM '{nid_o}' n JOIN tmap m ON m.taxon_id = n.taxon_id JOIN ntr_v USING (u)
        JOIN taxa tx ON tx.taxon_id = n.taxon_id
        LEFT JOIN genus_rg g ON g.observer_id = n.observer_id AND g.genus = split_part(tx.name, ' ', 1)
        WHERE ntr < {NEEDS_ID_BELOW}""")
    st = con.execute(f"""SELECT count(*), count(*) FILTER (role = 'pool'),
            count(*) FILTER (role = 'pool' AND n_rg_genus >= {TRACK_MIN}),
            count(DISTINCT u) FILTER (role = 'pool' AND n_rg_genus >= {TRACK_MIN}),
            count(DISTINCT observer_id) FILTER (role = 'pool' AND n_rg_genus >= {TRACK_MIN}) FROM nid""").fetchall()[0]
    print(f"needs_id obs of < {NEEDS_ID_BELOW}-photo classes: {st[0]:,}; pool observers {st[1]:,}; "
          f"track ≥ {TRACK_MIN} RG in genus: {st[2]:,} obs, {st[3]:,} classes, {st[4]:,} observers")
    con.execute(f"""CREATE TEMP TABLE nid2 AS
        SELECT n.uuid, n.observer_id, n.lat, n.lon, n.observed_on, n.u, n.via, 'needs_id' AS grade, FALSE AS in_train,
               p.photo_id, p.ext, p.license, p.position, 'inat-needs-id' AS source, n.n_rg_genus
        FROM nid n JOIN '{nid_p}' p USING (uuid)
        WHERE n.role = 'pool' AND n.n_rg_genus >= {TRACK_MIN} AND p.license IN {sql_list(CC_ALL)}""")
    # admitted / rejected needs_id observations (for `noise`)
    con.execute(f"""COPY (SELECT uuid::VARCHAR AS uuid, observer_id, u, genus, n_rg_genus, role, species_id,
                               (role = 'pool' AND n_rg_genus >= {TRACK_MIN}) AS admitted FROM nid)
                    TO '{os.path.join(WORK, "needs_id_admission.parquet")}' (FORMAT parquet)""")

    # ---- all candidates, ranked
    con.execute(f"""CREATE TEMP TABLE c AS
        WITH a AS (
          SELECT uuid, observer_id, lat, lon, observed_on, u, via, grade, in_train, photo_id, ext, license,
                 position, source, NULL::BIGINT AS n_rg_genus FROM rg2
          UNION ALL SELECT * FROM nid2),
        b AS (SELECT a.*, p.photo_id AS used FROM a LEFT JOIN tr p USING (uuid)
              WHERE a.photo_id NOT IN (SELECT photo_id FROM shared2) AND a.photo_id NOT IN {evp}
                AND a.photo_id NOT IN (SELECT photo_id FROM tr)),
        -- k = the photo's place among the observation's photos we may use
        -- (1 = the training photo for in-train observations, so extras start at 2)
        k AS (SELECT *, row_number() OVER (PARTITION BY uuid ORDER BY position, photo_id)
                        + CASE WHEN in_train THEN 1 ELSE 0 END AS k FROM b)
        SELECT * FROM k WHERE k <= {PER_OBS}""")
    # observer spread only counts new observations (k = 1)
    # default: tier (new obs first photo, 2nd, 3rd …; needs_id after), observer spread, Australia, hash.
    # --au-first (Leo, K = 1,000): Australian new observations, then new observations
    # elsewhere, then further photos per observation (Australia first); needs_id last
    order = ("grade != 'research', k > 1, CASE WHEN k = 1 THEN region ELSE 0 END, k, region, rk_obs > 3, h"
             if a.au_first else "tier, rk_obs > 3, region, h")
    con.execute(f"""CREATE TEMP TABLE r AS
        WITH x AS (SELECT c.*, CASE WHEN grade = 'research' THEN 0 ELSE 3 END + k AS tier,
                          CASE WHEN {AUS.replace('lat', 'c.lat').replace('lon', 'c.lon')} THEN 0 ELSE 1 END AS region,
                          hash(uuid::VARCHAR || photo_id::VARCHAR || 'izzy-extra') AS h FROM c),
        y AS (SELECT *, dense_rank() OVER (PARTITION BY u, observer_id, grade ORDER BY hash(uuid::VARCHAR || 'obs')) AS rk_obs FROM x),
        z AS (SELECT y.*, row_number() OVER (PARTITION BY u ORDER BY {order}) AS rk FROM y)
        SELECT z.*, ntr FROM z JOIN ntr_v USING (u)""")
    con.execute("CREATE TEMP TABLE sel AS SELECT * FROM r WHERE rk <= {} - ntr".format(CAP))
    # ---- leakage asserts
    bad = con.execute("SELECT count(*) FROM sel WHERE observer_id IN (SELECT observer_id FROM ev_v)").fetchall()[0][0]
    assert bad == 0, f"{bad} candidates from evaluation observers"
    bad = con.execute("SELECT count(*) FROM sel s JOIN who USING (observer_id) WHERE who.role != 'pool'").fetchall()[0][0]
    assert bad == 0, f"{bad} candidates from val/test observers"
    assert con.execute("SELECT count(*) - count(DISTINCT photo_id) FROM sel").fetchall()[0][0] == 0
    obs_login = os.path.join(WORK, "observers.parquet")
    if not os.path.exists(obs_login):
        con.execute(f"""COPY (SELECT * FROM read_csv('{os.path.join(META, 'observers.csv.gz')}', delim='\t',
                         header=true, quote='', escape='', auto_detect=false,
                         columns={{'observer_id': 'INTEGER', 'login': 'VARCHAR', 'name': 'VARCHAR'}},
                         ignore_errors=true)) TO '{obs_login}' (FORMAT parquet)""")
    con.execute(f"""COPY (
        SELECT s.u, s.source, s.photo_id, s.ext, s.uuid::VARCHAR AS observation_uuid, s.observer_id,
               w.login, w.name AS observer_name, s.license, s.grade, s.k, s.tier, s.rk, s.ntr,
               s.lat, s.lon, s.observed_on, s.n_rg_genus,
               CASE WHEN s.via = 'inat_map' THEN coalesce(r.name_relation, 'inat_map') ELSE s.via END AS name_relation,
               s.via != 'inat_map' AS via_name_map
        FROM sel s LEFT JOIN '{obs_login}' w USING (observer_id) LEFT JOIN rel_v r USING (u)
        ORDER BY s.u, s.rk) TO '{os.path.join(WORK, f"candidates{tag}.parquet")}' (FORMAT parquet)""")
    if big:
        summ = summarise_sql(con, os.path.join(WORK, f"candidates{tag}.parquet"))
        summ["seconds"] = round(time.time() - t0, 1)
        json.dump(summ, open(os.path.join(WORK, f"candidates{tag}-summary.json"), "w"), indent=1, default=int)
        print(json.dumps(summ, indent=1, default=int))
        return
    T = pq.read_table(os.path.join(WORK, "candidates.parquet")).to_pandas()
    summ = summarise(T, L)
    summ["seconds"] = round(time.time() - t0, 1)
    summ["skipped_usable_not_in_train"] = {"obs": other[0], "classes": other[1], "obs_below_95": other[2]}
    summ["needs_id"] = {"obs": st[0], "pool_obs": st[1], "admitted_obs": st[2], "admitted_classes": st[3],
                        "admitted_observers": st[4], "track_min": TRACK_MIN}
    # what the uncapped "cap counts observations" reading would add (extra photos only)
    summ["alt_reading_obs_cap_extra_photos"] = con.execute(f"""
        SELECT count(*) FROM (SELECT *, row_number() OVER (PARTITION BY uuid ORDER BY position, photo_id) + 1 AS k
               FROM pobs WHERE uuid IN (SELECT uuid FROM tr) AND license IN {sql_list(CC_ALL)}
                 AND photo_id NOT IN (SELECT photo_id FROM tr)) WHERE k <= {PER_OBS}""").fetchall()[0][0]
    json.dump(summ, open(os.path.join(WORK, "candidates-summary.json"), "w"), indent=1, default=int)
    print(json.dumps(summ, indent=1, default=int))


def summarise_sql(con, path):
    """summarise() in DuckDB (the uncapped list has millions of rows)."""
    con.register("lab_v", ntr_table())
    b = """CASE WHEN l.ntr = 0 THEN '0' WHEN l.ntr < 10 THEN '1-9' WHEN l.ntr < 20 THEN '10-19'
                WHEN l.ntr < 50 THEN '20-49' ELSE '50+' END"""
    q = lambda sql: con.execute(sql).fetchall()  # noqa: E731
    out = {"photos": q(f"SELECT count(*) FROM '{path}'")[0][0],
           "classes": q(f"SELECT count(DISTINCT u) FROM '{path}'")[0][0],
           "observations": q(f"SELECT count(DISTINCT observation_uuid) FROM '{path}'")[0][0],
           "by_source": dict(q(f"SELECT source, count(*) FROM '{path}' GROUP BY 1")),
           "by_licence": dict(q(f"SELECT * FROM (SELECT COLUMNS('^licen[cs]e$'), count(*) FROM '{path}' GROUP BY ALL)"))}
    bs = collections.defaultdict(dict)
    for bk, src, n in q(f"SELECT {b}, source, count(*) FROM '{path}' c JOIN lab_v l USING (u) GROUP BY ALL"):
        bs[bk][src] = n
    out["by_bucket_source"] = dict(bs)
    out["classes_gaining_by_bucket"] = dict(q(f"SELECT {b}, count(DISTINCT c.u) FROM '{path}' c JOIN lab_v l USING (u) GROUP BY 1"))
    z = q(f"""SELECT count(*) FILTER (n >= 1), count(*) FILTER (n >= 5), count(*) FILTER (n >= 20) FROM
              (SELECT u, count(*) n FROM '{path}' JOIN lab_v l USING (u) WHERE l.ntr = 0 GROUP BY u)""")[0]
    out["zero_classes_gaining_ge1_ge5_ge20"] = list(z)
    out["after_ge5_ge20_ge100"] = list(q(f"""SELECT count(*) FILTER (t >= 5), count(*) FILTER (t >= 20),
              count(*) FILTER (t >= 100) FROM (SELECT l.u, l.ntr + coalesce(n, 0) t FROM lab_v l
              LEFT JOIN (SELECT u, count(*) n FROM '{path}' GROUP BY u) USING (u))""")[0])
    out["per_class_quantiles"] = list(q(f"""SELECT quantile_cont(n, [0.5, 0.9, 0.99]), max(n) FROM
              (SELECT u, count(*) n FROM '{path}' GROUP BY u)""")[0])
    return out


def summarise(T, L, col="u"):
    ntr = np.array([l["train_photos"] for l in L])
    out = {"photos": int(len(T)), "classes": int(T[col].nunique()),
           "by_source": T.groupby("source").size().to_dict(),
           "by_licence": T.groupby("license" if "license" in T else "licence").size().to_dict()}
    T = T.assign(b=bucket(ntr[T[col].to_numpy()]))
    out["by_bucket_source"] = {b: g.groupby("source").size().to_dict() for b, g in T.groupby("b")}
    out["classes_gaining_by_bucket"] = T.groupby("b")[col].nunique().to_dict()
    per = T.groupby(col).size()
    z = per[ntr[per.index] == 0]
    out["zero_classes_gaining_ge1"] = int((z >= 1).sum())
    out["zero_classes_gaining_ge5"] = int((z >= 5).sum())
    after = ntr.copy()
    after[per.index.to_numpy()] += per.to_numpy()
    out["classes_ge5_before_after"] = [int((ntr >= 5).sum()), int((after >= 5).sum())]
    out["classes_ge20_before_after"] = [int((ntr >= 20).sum()), int((after >= 20).sum())]
    return out


# ------------------------------------------------------------------ fetch

def free_gb(path):
    return shutil.disk_usage(path).free / 1e9


class Fetcher:
    """Keep-alive HTTPS per thread from the open-data bucket; each body is
    checked (image magic), hashed (dedup.hashes) and optionally stored."""

    def __init__(self, keep, threads):
        self.keep, self.threads = keep, threads
        self.local = threading.local()
        self.lock = threading.Lock()
        self.stats = collections.Counter()

    def get(self, pid, ext):
        for attempt in range(5):
            try:
                c = getattr(self.local, "c", None)
                if c is None:
                    c = self.local.c = http.client.HTTPSConnection(HOST, timeout=30)
                c.request("GET", f"/photos/{pid}/medium.{ext}", headers=UA)
                r = c.getresponse()
                body = r.read()
                if r.status == 200 and body.startswith(dedup.MAGIC):
                    return body, "ok"
                if r.status in (403, 404):
                    return None, "missing"
                raise IOError(f"HTTP {r.status}")
            except Exception:  # noqa: BLE001
                self.local.c = None
                time.sleep(1 + 2 * attempt)
        return None, "failed"

    def one(self, row):
        pid, ext, path = row
        body = None
        if path and os.path.exists(path):
            body, why = open(path, "rb").read(), "local"
        else:
            body, why = self.get(pid, ext)
        rec = {"photo_id": pid, "status": why, "bytes": len(body) if body else 0}
        if body:
            try:
                rec.update(dedup.hashes(body))
            except Exception as e:  # noqa: BLE001
                rec["status"] = f"undecodable: {type(e).__name__}"
            if self.keep and why == "ok":
                dst = os.path.join(PHOTOS, f"{pid}.{ext}")
                with open(dst + ".part", "wb") as f:
                    f.write(body)
                os.replace(dst + ".part", dst)
        with self.lock:
            self.stats[rec["status"]] += 1
            self.stats["bytes"] += rec["bytes"]
        return rec

    def run(self, rows, out, every=30):
        os.makedirs(PHOTOS, exist_ok=True)
        done = set()
        parts = sorted(f for f in os.listdir(WORK) if f.startswith(out + "-part"))
        for f in parts:
            done.update(pq.read_table(os.path.join(WORK, f), columns=["photo_id"]).column(0).to_pylist())
        rows = [r for r in rows if r[0] not in done]
        print(f"{len(done):,} already hashed, {len(rows):,} to do", flush=True)
        t0, last, k = time.time(), time.time(), len(parts)
        for lo in range(0, len(rows), 5000):
            if self.keep and free_gb(PHOTOS) < MIN_FREE_GB:
                print(f"STOP: {free_gb(PHOTOS):.1f} GB free (< {MIN_FREE_GB})", flush=True)
                break
            with cf.ThreadPoolExecutor(self.threads) as ex:
                recs = list(ex.map(self.one, rows[lo:lo + 5000]))
            pq.write_table(hash_table(recs), os.path.join(WORK, f"{out}-part{k:04d}.parquet"))
            k += 1
            dt = time.time() - t0
            n = lo + len(recs)
            print(f"  {n:,}/{len(rows):,} in {dt:.0f} s = {n / dt:.1f}/s, {self.stats['bytes'] / dt / 1e6:.1f} MB/s, "
                  f"{dict((s, v) for s, v in self.stats.items() if s != 'bytes')}, free {free_gb(PHOTOS):.1f} GB",
                  flush=True)
        return time.time() - t0


HASH_SCHEMA = pa.schema([("photo_id", pa.int64()), ("status", pa.string()), ("bytes", pa.int64()),
                         ("phash", pa.uint64()), ("dhash", pa.uint64())])


def hash_table(recs):
    return pa.Table.from_pylist([{k: r.get(k) for k in HASH_SCHEMA.names} for r in recs], schema=HASH_SCHEMA)


def cmd_measure(a):
    T = pq.read_table(os.path.join(WORK, "candidates.parquet"), columns=["photo_id", "ext"]).to_pydict()
    rng = np.random.default_rng(0)
    ix = rng.choice(len(T["photo_id"]), min(a.n, len(T["photo_id"])), replace=False)
    rows = [(T["photo_id"][i], T["ext"][i], None) for i in ix]
    f = Fetcher(keep=False, threads=a.threads)
    t = time.time()
    with cf.ThreadPoolExecutor(a.threads) as ex:
        recs = list(ex.map(f.one, rows))
    dt = time.time() - t
    nb = sum(r["bytes"] for r in recs)
    n_all = len(T["photo_id"])
    rate = len(recs) / dt
    s = {"n": len(recs), "seconds": round(dt, 1), "photos_per_s": round(rate, 1), "mb_per_s": round(nb / dt / 1e6, 1),
         "mean_kb": round(nb / max(1, sum(r["bytes"] > 0 for r in recs)) / 1e3, 1),
         "status": dict(collections.Counter(r["status"] for r in recs)),
         "candidates": n_all, "projected_min": round(n_all / rate / 60, 1),
         "projected_gb": round(n_all * nb / max(1, sum(r["bytes"] > 0 for r in recs)) / 1e9, 1),
         "threads": a.threads}
    json.dump(s, open(os.path.join(WORK, "measure.json"), "w"), indent=1)
    print(json.dumps(s))


def cmd_fetch(a):
    T = pq.read_table(os.path.join(WORK, "candidates.parquet"), columns=["photo_id", "ext", "ntr"]).to_pydict()
    rows = [(p, e, os.path.join(PHOTOS, f"{p}.{e}")) for p, e in zip(T["photo_id"], T["ext"])]
    keep = np.array(T["ntr"]) < a.keep_below
    if a.limit:
        rows, keep = rows[:a.limit], keep[:a.limit]
    # disk is tight (~20 GB free) and the VM streams the photos from S3 anyway:
    # store only classes with < --keep-below training photos, hash the rest in memory
    dt = 0.0
    for kp in (True, False):
        sub = [r for r, k in zip(rows, keep) if k == kp]
        f = Fetcher(keep=kp, threads=a.threads)
        print(f"{'storing' if kp else 'hashing only'}: {len(sub):,} photos", flush=True)
        dt += f.run(sub, "hashes-cand")
    print(f"fetch: {dt / 60:.1f} min")


def eval_local_path(pid, ext):
    for d in (os.path.join(CACHE, "photos"), os.path.join(AU, "photos")):
        p = os.path.join(d, f"{pid}.{ext}")
        if os.path.exists(p):
            return p
    return None


def cmd_evalhash(a):
    ev = eval_sets().to_pydict()
    seen, rows = set(), []
    for p, e in zip(ev["photo_id"], ev["ext"]):
        if p not in seen:
            seen.add(p)
            rows.append((p, e, eval_local_path(p, e)))
    print(f"{len(rows):,} evaluation photos, {sum(r[2] is not None for r in rows):,} local")
    f = Fetcher(keep=False, threads=a.threads)
    dt = f.run(rows, "hashes-eval")
    print(f"evalhash: {dt / 60:.1f} min, {dict(f.stats)}")


def read_parts(prefix):
    fs = sorted(os.path.join(WORK, f) for f in os.listdir(WORK) if f.startswith(prefix + "-part"))
    return pa.concat_tables([pq.read_table(f) for f in fs], promote_options="default") if fs else None


# ------------------------------------------------------------------ dedup

def cmd_dedup(a):
    cal = json.load(open(os.path.join(WORK, "calibration.json")))
    th = cal["chosen"]
    C = pq.read_table(os.path.join(WORK, "candidates.parquet")).to_pandas()
    H = read_parts("hashes-cand").to_pandas()
    E = read_parts("hashes-eval").to_pandas()
    E = E[E["status"].isin(["ok", "local"])]
    C = C.merge(H[["photo_id", "status", "bytes", "phash", "dhash"]], on="photo_id", how="left")
    gone = C["status"].isna() | ~C["status"].isin(["ok", "local"])
    dropped = [C[gone].assign(reason=lambda d: "not fetched: " + d["status"].fillna("not attempted"))]
    C = C[~gone].reset_index(drop=True)
    # 1. near-duplicates of an evaluation photo
    ph_c, dh_c = C["phash"].to_numpy(np.uint64), C["dhash"].to_numpy(np.uint64)
    ph_e, dh_e = E["phash"].to_numpy(np.uint64), E["dhash"].to_numpy(np.uint64)
    t = time.time()
    hit_e, j_e = dedup.near_any(ph_c, dh_c, ph_e, dh_e, th["phash"], th["dhash"])
    print(f"vs eval: {hit_e.sum():,} of {len(C):,} candidates match one of {len(E):,} eval photos ({time.time() - t:.1f} s)")
    ev_ids = E["photo_id"].to_numpy()
    dropped.append(C[hit_e].assign(reason="near-duplicate of eval photo", match=ev_ids[j_e[hit_e]]))
    C = C[~hit_e].reset_index(drop=True)
    # 2. within the extras: keep the first of each near-duplicate group (rank order)
    t = time.time()
    C = C.sort_values(["u", "rk"]).reset_index(drop=True)
    dup, j_w = dedup.near_within(C["phash"].to_numpy(np.uint64), C["dhash"].to_numpy(np.uint64),
                                 th["phash"], th["dhash"])
    print(f"within extras: {dup.sum():,} near-duplicates ({time.time() - t:.1f} s)")
    ids = C["photo_id"].to_numpy()
    same_obs = (C["observation_uuid"].to_numpy()[j_w] == C["observation_uuid"].to_numpy())
    dropped.append(C[dup].assign(reason=np.where(same_obs[dup], "near-duplicate within extras (same observation)",
                                                 "near-duplicate within extras (other observation)"),
                                 match=ids[j_w[dup]]))
    # a photo uploaded to observations of DIFFERENT classes (habitat shots,
    # multi-species photos — seen by eye) is wrong for at least one of them:
    # drop the kept copy too (the plan drops shared photo ids for the same reason)
    uu = C["u"].to_numpy()
    cross = dup & (uu[np.maximum(j_w, 0)] != uu)
    first = np.zeros(len(C), bool)
    first[j_w[cross]] = True
    first &= ~dup
    dropped.append(C[first].assign(reason="kept copy of a cross-class near-duplicate", match=-1))
    C = C[~dup & ~first].reset_index(drop=True)
    L = labels()
    C["name"] = [L[u]["name"] for u in C["u"]]
    C["url"] = [f"https://{HOST}/photos/{p}/medium.{e}" for p, e in zip(C["photo_id"], C["ext"])]
    C["local_path"] = [os.path.join(PHOTOS, f"{p}.{e}") if os.path.exists(os.path.join(PHOTOS, f"{p}.{e}")) else None
                       for p, e in zip(C["photo_id"], C["ext"])]
    C["attribution"] = [attribution(n, lg, li) for n, lg, li in zip(C["observer_name"], C["login"], C["license"])]
    C["shard"] = pd_na_int(len(C))
    cols = ["u", "name", "source", "photo_id", "ext", "observation_uuid", "observer_id", "login", "license",
            "attribution", "url", "local_path", "shard", "grade", "k", "rk", "ntr", "lat", "lon", "observed_on",
            "n_rg_genus", "name_relation", "via_name_map", "phash", "dhash", "bytes"]
    out = C[cols]
    pq.write_table(pa.Table.from_pandas(out, preserve_index=False), os.path.join(EX, "extra_photos.parquet"))
    import pandas as pd
    D = pd.concat(dropped, ignore_index=True)
    pq.write_table(pa.Table.from_pandas(D.astype({c: str for c in ("observed_on",) if c in D}), preserve_index=False),
                   os.path.join(EX, "dropped.parquet"))
    summ = summarise(out, L)
    summ["dropped"] = D.groupby("reason").size().to_dict()
    summ["thresholds"] = th
    json.dump(summ, open(os.path.join(EX, "extra_photos-summary.json"), "w"), indent=1, default=int)
    print(json.dumps(summ, indent=1, default=int))


def cmd_dedup_emb(a):
    """Stage 2 (after the cloud embedding, shards in extra/emb/): the extras vs
    the EXISTING training photos (plan train ∪ Tasmanian train, 680k, their
    cloud embeddings), vs every evaluation photo, and within the extras.
    cos ≥ standalone (0.95) = duplicate (crops, edits); confirm (0.85) ≤ cos <
    0.95 = duplicate only if the hashes agree too (calibration.json) — the
    reference photo is streamed from S3 and hashed for that. Then the final
    list in train_v2.py's --extra format → extra/extra_photos_final.parquet."""
    import glob
    import pandas as pd
    import torch
    import train_australia as TA
    cal = json.load(open(os.path.join(WORK, "calibration.json")))["chosen"]
    ce = json.load(open(os.path.join(WORK, "calibration-emb.json")))["chosen"]
    t_conf, t_alone = ce["confirm"]["thr"], ce["standalone"]["thr"]
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    X = pq.read_table(os.path.join(EX, "extra_photos.parquet")).to_pandas()
    # extra embeddings
    ed = os.path.join(EX, "emb")
    q_id, q_e, q_sh = [], [], []
    for f in sorted(glob.glob(os.path.join(ed, "shard-*.npz"))):
        z = np.load(f)
        q_id.append(z["photo_id"].astype(np.int64)); q_e.append(z["emb"].astype(np.float16))
        q_sh.append(np.full(len(z["photo_id"]), int(os.path.basename(f)[6:10])))
    q_id, q_e, q_sh = np.concatenate(q_id), np.concatenate(q_e), np.concatenate(q_sh)
    pos = {int(p): i for i, p in enumerate(q_id)}
    X["ei"] = [pos.get(int(p), -1) for p in X["photo_id"]]
    miss = X["ei"] < 0
    print(f"extras: {len(X):,}, embedded {(~miss).sum():,}, missing upstream / not embedded {miss.sum():,}", flush=True)
    dropped = [X[miss].assign(reason="not embedded (gone upstream)")]
    X = X[~miss].sort_values(["u", "rk"]).reset_index(drop=True)
    Q = torch.from_numpy(q_e[X["ei"].to_numpy()]).to(dev)
    # references
    ids, E = TA.all_embeddings()
    tr_ids = np.unique(np.r_[pq.read_table(os.path.join(AU, "plan", "train.parquet"), columns=["photo_id"]).column(0)
                             .to_numpy().astype(np.int64),
                             pq.read_table(os.path.join(CACHE, "sets", "train.parquet"), columns=["photo_id"]).column(0)
                             .to_numpy().astype(np.int64)])
    ev = eval_sets().to_pandas().drop_duplicates("photo_id")
    refs = {}
    for nm, pids in (("train", tr_ids), ("eval", ev["photo_id"].to_numpy(np.int64))):
        i, ok = TA.lookup(ids, pids)
        refs[nm] = (pids[ok], E[i[ok]])
        print(f"  {nm}: {ok.sum():,} of {len(pids):,} with a cloud embedding", flush=True)
    # C photos lack cloud embeddings: their w8 Core ML ones (same model, int8 weights)
    import build_ship as BS
    have = set(refs["eval"][0].tolist())
    cid, ce_ = BS.load_parts(os.path.join(AU, "emb-w8"))
    m = np.array([int(p) not in have for p in cid])
    if m.any():
        e8 = ce_[m].astype(np.float32)
        e8 /= np.linalg.norm(e8, axis=1, keepdims=True)
        refs["eval"] = (np.r_[refs["eval"][0], cid[m].astype(np.int64)], np.r_[refs["eval"][1], e8.astype(np.float16)])
        print(f"  eval: + {m.sum():,} C photos via their w8 embeddings", flush=True)

    def top1(R, block=4096, within=False):
        Rt = torch.from_numpy(np.ascontiguousarray(R, np.float16)).to(dev)
        best = torch.full((len(Q),), -2.0, device=dev)
        arg = torch.full((len(Q),), -1, dtype=torch.long, device=dev)
        for lo in range(0, len(Q), block):
            q = Q[lo:lo + block]
            for r0 in range(0, len(Rt) if not within else lo + len(q), 65536):
                S = (q @ Rt[r0:r0 + 65536].T).float()
                if within:  # only earlier rows (rank order): j < i
                    jj = torch.arange(r0, r0 + S.shape[1], device=dev)[None, :]
                    ii = torch.arange(lo, lo + len(q), device=dev)[:, None]
                    S = S.masked_fill(jj >= ii, -2.0)
                v, k = S.max(1)
                upd = v > best[lo:lo + len(q)]
                best[lo:lo + len(q)] = torch.where(upd, v, best[lo:lo + len(q)])
                arg[lo:lo + len(q)] = torch.where(upd, k + r0, arg[lo:lo + len(q)])
        return best.cpu().numpy(), arg.cpu().numpy()
    res = {}
    t = time.time()
    for nm in ("eval", "train"):
        b, j = top1(refs[nm][1])
        X[f"cos_{nm}"], X[f"nn_{nm}"] = b, refs[nm][0][j]
        print(f"  vs {nm}: ≥ {t_alone}: {(b >= t_alone).sum():,}, {t_conf}–{t_alone}: "
              f"{((b >= t_conf) & (b < t_alone)).sum():,} ({time.time() - t:.0f} s)", flush=True)
    b, j = top1(Q.cpu().numpy(), within=True)
    X["cos_within"], X["nn_within"] = b, np.where(j >= 0, X["photo_id"].to_numpy()[np.maximum(j, 0)], -1)
    print(f"  within: ≥ {t_alone}: {(b >= t_alone).sum():,} ({time.time() - t:.0f} s)", flush=True)
    # hash-confirm the 0.85–0.95 band against references (stream their medium from S3)
    H_eval = read_parts("hashes-eval").to_pandas().set_index("photo_id")
    band = {nm: X[(X[f"cos_{nm}"] >= t_conf) & (X[f"cos_{nm}"] < t_alone)] for nm in ("eval", "train")}
    need = sorted(set(band["train"]["nn_train"].astype(int)))
    hf = os.path.join(WORK, "hashes-train-nn.parquet")
    Ht = pq.read_table(hf).to_pandas() if os.path.exists(hf) else pd.DataFrame({"photo_id": [], "phash": [], "dhash": []})
    todo = [p for p in need if p not in set(Ht["photo_id"])]
    if todo:
        ext = {}
        for f in (os.path.join(AU, "plan", "train.parquet"), os.path.join(CACHE, "sets", "train.parquet")):
            tt = pq.read_table(f, columns=["photo_id", "ext"]).to_pydict()
            ext.update(zip(map(int, tt["photo_id"]), tt["ext"]))
        print(f"  hashing {len(todo):,} training photos (S3) for the confirm band", flush=True)
        F = Fetcher(keep=False, threads=64)
        with cf.ThreadPoolExecutor(64) as exx:
            recs = list(exx.map(F.one, [(p, ext[p], None) for p in todo]))
        Ht = pd.concat([Ht, hash_table(recs).to_pandas()], ignore_index=True)
        pq.write_table(pa.Table.from_pandas(Ht, preserve_index=False), hf)
    Ht = Ht.dropna(subset=["phash"]).set_index("photo_id")
    conf = {}
    for nm, H in (("eval", H_eval), ("train", Ht)):
        d = band[nm]
        ok = d[f"nn_{nm}"].isin(H.index)
        hp = H.loc[d.loc[ok, f"nn_{nm}"], "phash"].to_numpy(np.uint64)
        hd = H.loc[d.loc[ok, f"nn_{nm}"], "dhash"].to_numpy(np.uint64)
        near = (np.bitwise_count(d.loc[ok, "phash"].to_numpy(np.uint64) ^ hp) <= cal["phash"]) & \
               (np.bitwise_count(d.loc[ok, "dhash"].to_numpy(np.uint64) ^ hd) <= cal["dhash"])
        conf[nm] = set(d.loc[ok].index[near])
        print(f"  {nm} band {len(d):,}: hash-confirmed {len(conf[nm]):,}", flush=True)
    tr_obs = {}
    for f in (os.path.join(AU, "plan", "train.parquet"), os.path.join(CACHE, "sets", "train.parquet")):
        tt = pq.read_table(f, columns=["photo_id", "uuid"]).to_pydict()
        tr_obs.update(zip(map(int, tt["photo_id"]), map(str, tt["uuid"])))
    same = np.array([tr_obs.get(int(n)) == o for n, o in zip(X["nn_train"], X["observation_uuid"])])
    reason = pd.Series("", index=X.index)
    reason[X["cos_within"] >= t_alone] = "emb ≥ standalone: within extras"
    for nm in ("train", "eval"):
        reason[list(conf[nm])] = f"emb band + hash: {nm} photo"
        reason[X[f"cos_{nm}"] >= t_alone] = f"emb ≥ standalone: {nm} photo"
    reason[(X["cos_train"] >= t_alone) & same] = "emb ≥ standalone: train photo, same observation"
    drop = reason != ""
    D = X[drop].assign(reason=reason[drop])
    dropped.append(D)
    F_ = X[~drop].copy()
    F_["shard"] = q_sh[F_["ei"].to_numpy()]
    F_["shard_path"] = [os.path.join(ed, f"shard-{k:04d}.npz") for k in F_["shard"]]
    # train_v2.py --extra: u, photo_id, source, licence, shard (= npz path)
    out = F_.drop(columns=["ei", "shard"]).rename(columns={"license": "licence"})
    out = out.rename(columns={"shard_path": "shard"})
    out.insert(out.columns.get_loc("shard") + 1, "shard_id", F_["shard"].to_numpy())
    # sorted by shard: train_v2.add_extra caches ONE npz at a time and keeps a row
    # view of each, so a list in class order reloads a shard per row (OOM, seen)
    out = out.sort_values(["shard_id", "photo_id"])
    pq.write_table(pa.Table.from_pandas(out, preserve_index=False), os.path.join(EX, "extra_photos_final.parquet"))
    Dall = pd.concat(dropped, ignore_index=True)
    pq.write_table(pa.Table.from_pandas(Dall.astype({c: str for c in ("observed_on",) if c in Dall}),
                                        preserve_index=False), os.path.join(EX, "dropped_emb.parquet"))
    summ = summarise(out, labels())
    summ["dropped_stage2"] = Dall.groupby("reason").size().to_dict()
    summ["thresholds"] = {"confirm": t_conf, "standalone": t_alone, "hash": cal}
    json.dump(summ, open(os.path.join(EX, "extra_photos_final-summary.json"), "w"), indent=1, default=int)
    print(json.dumps(summ, indent=1, default=int))


def stage1_hashes(X, cal, t0):
    """Hash stage of cmd_finalize: vs every eval photo, cross-class identical
    twins (both dropped), within the class (earlier fill rank wins)."""
    import pandas as pd  # noqa: F401
    reason = np.full(len(X), "", dtype=object)
    Eh = read_parts("hashes-eval").to_pandas()
    Eh = Eh[Eh["status"].isin(["ok", "local"])]
    hit, j = dedup.near_any(X["phash"].to_numpy(np.uint64), X["dhash"].to_numpy(np.uint64),
                            Eh["phash"].to_numpy(np.uint64), Eh["dhash"].to_numpy(np.uint64), cal["phash"], cal["dhash"])
    reason[hit] = "hash: eval photo"
    print(f"  hash vs eval: {hit.sum():,} ({time.time() - t0:.0f} s)", flush=True)
    key = X["phash"].astype(str) + ":" + X["dhash"].astype(str)
    multi = X.assign(k=key).groupby("k")["u"].transform("nunique") > 1
    reason[(reason == "") & multi.to_numpy()] = "hash: identical image in another class (both dropped)"
    uu = X["u"].to_numpy()
    bounds = np.r_[0, np.nonzero(uu[1:] != uu[:-1])[0] + 1, len(X)]
    phv, dhv = X["phash"].to_numpy(np.uint64), X["dhash"].to_numpy(np.uint64)
    nw = 0
    for lo, hi in zip(bounds[:-1], bounds[1:]):
        if hi - lo > 1:
            dup, _ = dedup.near_within(phv[lo:hi], dhv[lo:hi], cal["phash"], cal["dhash"])
            m = dup & (reason[lo:hi] == "")
            reason[lo:hi][m] = "hash: within class"
            nw += m.sum()
    print(f"  hash within class: {nw:,}; cross-class twins {multi.sum():,} ({time.time() - t0:.0f} s)", flush=True)
    return reason


def cmd_finalize(a):
    """Both dedup stages for a big list (`select --tag`, e.g. k1000) whose
    shards carry their own pHash/dHash (embed_extra.py on the VM); photos of
    the first, capped run are reused from extra/emb (+ hashes-cand).
    Stage 1 (hashes): vs every evaluation photo (all pairs); within the list
    per class (earlier fill rank wins) + exact hash twins across classes
    (both dropped). Stage 2 (BioCLIP cosine): vs every evaluation photo (all
    pairs; ≥ 0.95, or 0.85–0.95 with agreeing hashes); vs the class's own
    training photos and within the class (≥ 0.95). Scaled down from
    dedup-emb (all-pairs vs 680k training photos + S3-hashing the 0.85–0.95
    band): on the 260k list that band confirmed 14 of 114,706 and 93 % of the
    ≥ 0.95 training hits were the same observation, i.e. the same class.
    → extra/extra_photos_<tag>.parquet (train_v2 --extra format, sorted by shard)."""
    import glob
    import pandas as pd
    import torch
    import train_australia as TA
    tag = a.tag
    cal = json.load(open(os.path.join(WORK, "calibration.json")))["chosen"]
    ce = json.load(open(os.path.join(WORK, "calibration-emb.json")))["chosen"]
    tc, ta = ce["confirm"]["thr"], ce["standalone"]["thr"]
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    t0 = time.time()
    X = pq.read_table(os.path.join(WORK, f"candidates-{tag}.parquet")).to_pandas()
    H0 = read_parts("hashes-cand").to_pandas().drop_duplicates("photo_id").set_index("photo_id")
    ids, es, ph, dh, shp, row = [], [], [], [], [], []
    for d in a.emb_dirs:
        for f in sorted(glob.glob(os.path.join(d, "shard-*.npz"))):
            z = np.load(f)
            p = z["photo_id"].astype(np.int64)
            ids.append(p); es.append(z["emb"].astype(np.float16))
            if "phash" in z:
                ph.append(z["phash"].astype(np.uint64)); dh.append(z["dhash"].astype(np.uint64))
            else:
                hh = H0.reindex(p)
                ph.append(hh["phash"].fillna(0).to_numpy(np.uint64)); dh.append(hh["dhash"].fillna(0).to_numpy(np.uint64))
            shp += [f] * len(p); row.append(np.arange(len(p)))
    ids, E = np.concatenate(ids), np.concatenate(es)
    ph, dh, row = np.concatenate(ph), np.concatenate(dh), np.concatenate(row)
    shp = np.array(shp, dtype=object)
    _, first = np.unique(ids, return_index=True)  # a photo embedded twice: first copy
    pos = dict(zip(ids[first].tolist(), first.tolist()))
    X["ei"] = [pos.get(int(p), -1) for p in X["photo_id"]]
    miss = X["ei"] < 0
    print(f"{tag}: {len(X):,} rows, embedded {(~miss).sum():,} ({time.time() - t0:.0f} s)", flush=True)
    dropped = [X[miss].assign(reason="not embedded (gone upstream)")]
    X = X[~miss].sort_values(["u", "rk"]).reset_index(drop=True)
    ei = X["ei"].to_numpy()
    X["phash"], X["dhash"] = ph[ei], dh[ei]
    reason = np.full(len(X), "", dtype=object)
    s1 = os.path.join(WORK, f"finalize-{tag}-stage1.parquet")
    if os.path.exists(s1):  # stage 1 is ~11 min on 3.15M rows: cached per photo id
        r1 = pq.read_table(s1).to_pandas().set_index("photo_id")["reason"]
        reason[:] = r1.reindex(X["photo_id"]).fillna("").to_numpy(object)
        print(f"  stage 1 from cache: {(reason != '').sum():,} dropped", flush=True)
    else:
        reason = stage1_hashes(X, cal, t0)
        pq.write_table(pa.table({"photo_id": X["photo_id"].to_numpy(np.int64), "reason": reason.astype(str)}), s1)
    phv, dhv = X["phash"].to_numpy(np.uint64), X["dhash"].to_numpy(np.uint64)
    uu = X["u"].to_numpy()
    bounds = np.r_[0, np.nonzero(uu[1:] != uu[:-1])[0] + 1, len(X)]
    Eh = read_parts("hashes-eval").to_pandas()
    Eh = Eh[Eh["status"].isin(["ok", "local"])]
    # (stage 1 body moved to stage1_hashes)
    if False:
        pass
    # ---- stage 2: embeddings (nearest neighbours cached; thresholds applied after)
    s2 = os.path.join(WORK, f"finalize-{tag}-stage2.parquet")
    pid_x = X["photo_id"].to_numpy(np.int64)
    if os.path.exists(s2):
        C2 = pq.read_table(s2).to_pandas().set_index("photo_id").reindex(pid_x)
        cos_e, nn_e = C2["cos_eval"].to_numpy(), C2["nn_eval"].to_numpy()
        cos_t, nn_t = C2["cos_train"].to_numpy(), C2["nn_train"].to_numpy()
        cos_w, nn_w = C2["cos_within"].to_numpy(), C2["nn_within"].to_numpy()
        print("  stage 2 neighbours from cache", flush=True)
    else:
        Qn = E[ei]  # host memory: MPS tensors are limited to INT_MAX elements (3.15M × 1024 is more)
        ev = eval_sets().to_pandas().drop_duplicates("photo_id")
        aid, aE = TA.all_embeddings()
        i_, ok = TA.lookup(aid, ev["photo_id"].to_numpy(np.int64))
        R = torch.from_numpy(aE[i_[ok]]).to(dev)
        rid = ev["photo_id"].to_numpy(np.int64)[ok]
        cos_e = np.empty(len(Qn), np.float32)
        arg = np.empty(len(Qn), np.int64)
        for lo in range(0, len(Qn), 16384):
            S = (torch.from_numpy(Qn[lo:lo + 16384]).to(dev) @ R.T).float()
            v, k = S.max(1)
            cos_e[lo:lo + 16384], arg[lo:lo + 16384] = v.cpu().numpy(), k.cpu().numpy()
        nn_e = rid[arg]
        print(f"  emb vs eval done ({time.time() - t0:.0f} s)", flush=True)
        del R
        tr = pq.read_table(os.path.join(AU, "plan", "train.parquet"), columns=["photo_id", "u"]).to_pandas()
        rt = pq.read_table(os.path.join(EX, "reassign_train.parquet")).to_pandas()
        tr.loc[tr["photo_id"].isin(rt["photo_id"]), "u"] = tr["photo_id"].map(dict(zip(rt["photo_id"], rt["u_new"])))
        i_, ok = TA.lookup(aid, tr["photo_id"].to_numpy(np.int64))
        tr = tr[ok].assign(ai=i_[ok]).sort_values("u")
        tu, tai, tpid = tr["u"].to_numpy(), tr["ai"].to_numpy(), tr["photo_id"].to_numpy(np.int64)
        tb = dict(zip(*np.unique(tu, return_index=True)))
        tcnt = dict(zip(*np.unique(tu, return_counts=True)))
        cos_t = np.full(len(Qn), -2.0, np.float32)
        nn_t = np.full(len(Qn), -1, np.int64)
        cos_w = np.full(len(Qn), -2.0, np.float32)
        nn_w = np.full(len(Qn), -1, np.int64)
        for lo, hi in zip(bounds[:-1], bounds[1:]):
            u = int(uu[lo])
            q = torch.from_numpy(Qn[lo:hi]).to(dev)
            if u in tb:
                Rt = torch.from_numpy(aE[tai[tb[u]:tb[u] + tcnt[u]]]).to(dev)
                v, k = (q @ Rt.T).float().max(1)
                cos_t[lo:hi], nn_t[lo:hi] = v.cpu().numpy(), tpid[tb[u] + k.cpu().numpy()]
            if hi - lo > 1:
                S = (q @ q.T).float()
                S = S.masked_fill(torch.ones_like(S, dtype=torch.bool).triu(), -2.0)  # only earlier rows
                v, k = S.max(1)
                cos_w[lo:hi], nn_w[lo:hi] = v.cpu().numpy(), pid_x[lo + k.cpu().numpy()]
        del aE
        pq.write_table(pa.table({"photo_id": pid_x, "cos_eval": cos_e, "nn_eval": nn_e, "cos_train": cos_t,
                                 "nn_train": nn_t, "cos_within": cos_w, "nn_within": nn_w}), s2)
        print(f"  emb vs class training photos + within class done ({time.time() - t0:.0f} s)", flush=True)
    # thresholds: the calibrated standalone 0.95 only between photos of ONE observation
    # (bursts / zooms); across observations / observers a.cross (0.98): at this scale
    # (up to 1,000 photos per class, max over 85k eval photos) 0.95 flags many distinct
    # photos of common species — on this list 0 eval neighbours reached 0.99 and the hash
    # stage had already caught the true copies.
    Ehx = Eh.drop_duplicates("photo_id").set_index("photo_id")
    hp = Ehx.reindex(nn_e)["phash"].fillna(0).to_numpy(np.uint64)
    hd = Ehx.reindex(nn_e)["dhash"].fillna(0).to_numpy(np.uint64)
    near = (np.bitwise_count(phv ^ hp) <= cal["phash"]) & (np.bitwise_count(dhv ^ hd) <= cal["dhash"])
    m = (reason == "") & ((cos_e >= a.cross) | ((cos_e >= tc) & near))
    reason[m] = "emb: eval photo"
    print(f"  emb vs eval: {m.sum():,} (≥ {ta} would be {(cos_e >= ta).sum():,})", flush=True)
    tr_obs = {}
    for f in (os.path.join(AU, "plan", "train.parquet"), os.path.join(CACHE, "sets", "train.parquet")):
        tt = pq.read_table(f, columns=["photo_id", "uuid"]).to_pydict()
        tr_obs.update(zip(map(int, tt["photo_id"]), map(str, tt["uuid"])))
    obs = X["observation_uuid"].astype(str).to_numpy()
    obs_of = dict(zip(pid_x.tolist(), obs.tolist()))
    same_t = np.array([tr_obs.get(int(n)) == o for n, o in zip(nn_t, obs)])
    same_w = np.array([obs_of.get(int(n)) == o for n, o in zip(nn_w, obs)])
    for cos, same, lab in ((cos_t, same_t, "training photo"), (cos_w, same_w, "earlier extra")):
        m1 = (reason == "") & same & (cos >= ta)
        reason[m1] = f"emb: {lab}, same observation"
        m2 = (reason == "") & ~same & (cos >= a.cross)
        reason[m2] = f"emb: {lab}, other observation"
        print(f"  emb vs {lab}: same observation ≥ {ta}: {m1.sum():,}, other ≥ {a.cross}: {m2.sum():,} "
              f"(other ≥ {ta} would be {((cos >= ta) & ~same).sum():,})", flush=True)
    X["cos_eval"], X["cos_train"], X["cos_within"] = cos_e, cos_t, cos_w
    drop = reason != ""
    dropped.append(X[drop].assign(reason=reason[drop]))
    F_ = X[~drop].copy()
    L = labels()
    F_["name"] = [L[u]["name"] for u in F_["u"]]
    F_["url"] = [f"https://{HOST}/photos/{p}/medium.{e}" for p, e in zip(F_["photo_id"], F_["ext"])]
    F_["attribution"] = [attribution(n, lg, li) for n, lg, li in zip(F_["observer_name"], F_["login"], F_["license"])]
    F_["shard"] = shp[F_["ei"].to_numpy()]
    F_["shard_row"] = row[F_["ei"].to_numpy()]
    F_ = F_.drop(columns=["ei"]).rename(columns={"license": "licence"}).sort_values(["shard", "shard_row"])
    outp = os.path.join(EX, f"extra_photos_{tag}.parquet")
    pq.write_table(pa.Table.from_pandas(F_.astype({"observed_on": str}), preserve_index=False), outp)
    D = pd.concat(dropped, ignore_index=True)
    pq.write_table(pa.Table.from_pandas(D.astype({"observed_on": str}), preserve_index=False),
                   os.path.join(EX, f"dropped_{tag}.parquet"))
    con = __import__("duckdb").connect()
    summ = summarise_sql(con, outp)
    summ["dropped"] = D.groupby("reason").size().to_dict()
    summ["seconds"] = round(time.time() - t0)
    json.dump(summ, open(os.path.join(EX, f"extra_photos_{tag}-summary.json"), "w"), indent=1, default=int)
    print(json.dumps(summ, indent=1, default=int))


def load_shards(dirs):
    """All shard npz under `dirs` → photo ids, fp16 embeddings, pHash, dHash
    (0 where the shard has none), shard path, row; first copy of a photo wins."""
    import glob
    ids, es, ph, dh, shp, row = [], [], [], [], [], []
    for d in dirs:
        for f in sorted(glob.glob(os.path.join(d, "shard-*.npz"))):
            z = np.load(f)
            p = z["photo_id"].astype(np.int64)
            ids.append(p); es.append(z["emb"].astype(np.float16))
            ph.append(z["phash"].astype(np.uint64) if "phash" in z else np.zeros(len(p), np.uint64))
            dh.append(z["dhash"].astype(np.uint64) if "dhash" in z else np.zeros(len(p), np.uint64))
            shp.append(np.full(len(p), f, dtype=object)); row.append(np.arange(len(p)))
    ids, E, ph, dh = np.concatenate(ids), np.concatenate(es), np.concatenate(ph), np.concatenate(dh)
    shp, row = np.concatenate(shp), np.concatenate(row)
    _, first = np.unique(ids, return_index=True)
    return ids[first], E[first], ph[first], dh[first], shp[first], row[first]


def cmd_finalize_sources(a):
    """ALA + Commons extras (sources/extra_photos_sources.parquet, embedded +
    hashed on the VM into extra/emb-src/): stage 1 again with the VM's exact
    hashes (vs eval; vs the K = 1,000 iNat extras of the same class), stage 2
    (BioCLIP cosine) vs eval (all pairs: ≥ --cross, or ≥ confirm with agreeing
    hashes), vs the class's training photos and its K = 1,000 iNat extras
    (≥ --cross: other observations by construction), within the list per class
    (same ALA occurrence ≥ standalone 0.95, else ≥ --cross; earlier rank wins)
    → extra/extra_photos_src.parquet (train_v2 --extra format, sorted by shard)."""
    import pandas as pd
    import torch
    import train_australia as TA
    t0 = time.time()
    cal = json.load(open(os.path.join(WORK, "calibration.json")))["chosen"]
    ce = json.load(open(os.path.join(WORK, "calibration-emb.json")))["chosen"]
    tc, ta = ce["confirm"]["thr"], ce["standalone"]["thr"]
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    S = pq.read_table(os.path.join(CACHE, "sources", "extra_photos_sources.parquet")).to_pandas()
    ids_map = pq.read_table(os.path.join(WORK, "src", "ids-src.parquet")).to_pandas()
    S = S.merge(ids_map[["photo_id", "source", "image_id"]], on=["source", "image_id"], how="left")
    assert S["photo_id"].notna().all()
    S = S.drop(columns=["phash", "dhash"])  # float64 copies (lossy); the VM's exact hashes replace them
    sid, sE, sph, sdh, sshp, srow = load_shards([os.path.join(EX, "emb-src")])
    pos = dict(zip(sid.tolist(), range(len(sid))))
    S["ei"] = [pos.get(int(p), -1) for p in S["photo_id"]]
    dropped = [S[S["ei"] < 0].assign(reason="not embedded (missing)")]
    S = S[S["ei"] >= 0].sort_values(["u", "rk"]).reset_index(drop=True)
    ei = S["ei"].to_numpy()
    phv, dhv = sph[ei], sdh[ei]
    S["phash"], S["dhash"] = phv, dhv
    Qn = sE[ei]
    reason = np.full(len(S), "", dtype=object)
    print(f"sources: {len(S):,} embedded ({time.time() - t0:.0f} s)", flush=True)
    # ---- stage 1 (exact hashes)
    Eh = read_parts("hashes-eval").to_pandas()
    Eh = Eh[Eh["status"].isin(["ok", "local"])].drop_duplicates("photo_id")
    hit, _ = dedup.near_any(phv, dhv, Eh["phash"].to_numpy(np.uint64), Eh["dhash"].to_numpy(np.uint64),
                            cal["phash"], cal["dhash"])
    reason[hit] = "hash: eval photo"
    K = pq.read_table(os.path.join(EX, "extra_photos_k1000.parquet"),
                      columns=["u", "photo_id", "phash", "dhash", "observation_uuid"]).to_pandas().sort_values("u")
    ku = K["u"].to_numpy()
    kb = dict(zip(*np.unique(ku, return_index=True)))
    kc = dict(zip(*np.unique(ku, return_counts=True)))
    kp, kd = K["phash"].to_numpy(np.uint64), K["dhash"].to_numpy(np.uint64)
    uu = S["u"].to_numpy()
    bounds = np.r_[0, np.nonzero(uu[1:] != uu[:-1])[0] + 1, len(S)]
    nk = 0
    for lo, hi in zip(bounds[:-1], bounds[1:]):
        u = int(uu[lo])
        if u in kb:
            h, _ = dedup.near_any(phv[lo:hi], dhv[lo:hi], kp[kb[u]:kb[u] + kc[u]], kd[kb[u]:kb[u] + kc[u]],
                                  cal["phash"], cal["dhash"])
            m = h & (reason[lo:hi] == "")
            reason[lo:hi][m] = "hash: iNat extra (same class)"
            nk += m.sum()
    print(f"  hash: eval {hit.sum():,}, iNat extras {nk:,} ({time.time() - t0:.0f} s)", flush=True)
    # ---- stage 2: vs eval (all pairs)
    ev = eval_sets().to_pandas().drop_duplicates("photo_id")
    aid, aE = TA.all_embeddings()
    i_, ok = TA.lookup(aid, ev["photo_id"].to_numpy(np.int64))
    R = torch.from_numpy(aE[i_[ok]]).to(dev)
    rid = ev["photo_id"].to_numpy(np.int64)[ok]
    cos_e = np.empty(len(Qn), np.float32)
    arg = np.empty(len(Qn), np.int64)
    for lo in range(0, len(Qn), 16384):
        v, k = (torch.from_numpy(Qn[lo:lo + 16384]).to(dev) @ R.T).float().max(1)
        cos_e[lo:lo + 16384], arg[lo:lo + 16384] = v.cpu().numpy(), k.cpu().numpy()
    del R
    Ehx = Eh.set_index("photo_id")
    nn = rid[arg]
    near = (np.bitwise_count(phv ^ Ehx.reindex(nn)["phash"].fillna(0).to_numpy(np.uint64)) <= cal["phash"]) & \
           (np.bitwise_count(dhv ^ Ehx.reindex(nn)["dhash"].fillna(0).to_numpy(np.uint64)) <= cal["dhash"])
    m = (reason == "") & ((cos_e >= a.cross) | ((cos_e >= tc) & near))
    reason[m] = "emb: eval photo"
    print(f"  emb vs eval: {m.sum():,} (≥ {ta} would be {(cos_e >= ta).sum():,}) ({time.time() - t0:.0f} s)", flush=True)
    # ---- stage 2: vs the class's training photos + its K = 1,000 iNat extras, within the class
    tr = pq.read_table(os.path.join(AU, "plan", "train.parquet"), columns=["photo_id", "u"]).to_pandas()
    rt = pq.read_table(os.path.join(EX, "reassign_train.parquet")).to_pandas()
    tr.loc[tr["photo_id"].isin(rt["photo_id"]), "u"] = tr["photo_id"].map(dict(zip(rt["photo_id"], rt["u_new"])))
    i_, ok = TA.lookup(aid, tr["photo_id"].to_numpy(np.int64))
    tr = tr[ok].assign(ai=i_[ok]).sort_values("u")
    tu, tai = tr["u"].to_numpy(), tr["ai"].to_numpy()
    tb = dict(zip(*np.unique(tu, return_index=True)))
    tcnt = dict(zip(*np.unique(tu, return_counts=True)))
    xid, xE, _, _, _, _ = load_shards([os.path.join(EX, "emb"), os.path.join(EX, "emb-k1000")])
    xi, xok = TA.lookup(xid, K["photo_id"].to_numpy(np.int64))
    assert xok.all()
    xi = xi  # rows of xE in K's (class-sorted) order
    obs = S["observation_uuid"].fillna("").astype(str).to_numpy()
    n_t = n_k = n_w1 = n_w2 = 0
    cos_t = np.full(len(S), -2.0, np.float32)
    cos_k = np.full(len(S), -2.0, np.float32)
    cos_w = np.full(len(S), -2.0, np.float32)
    for lo, hi in zip(bounds[:-1], bounds[1:]):
        u = int(uu[lo])
        q = torch.from_numpy(Qn[lo:hi]).to(dev)
        if u in tb:
            v = (q @ torch.from_numpy(aE[tai[tb[u]:tb[u] + tcnt[u]]]).to(dev).T).float().max(1).values.cpu().numpy()
            cos_t[lo:hi] = v
        if u in kb:
            v = (q @ torch.from_numpy(xE[xi[kb[u]:kb[u] + kc[u]]]).to(dev).T).float().max(1).values.cpu().numpy()
            cos_k[lo:hi] = v
        if hi - lo > 1:
            Sm = (q @ q.T).float()
            Sm = Sm.masked_fill(torch.ones_like(Sm, dtype=torch.bool).triu(), -2.0)
            v, k = Sm.max(1)
            v, k = v.cpu().numpy(), k.cpu().numpy()
            cos_w[lo:hi] = v
            same = (obs[lo:hi] != "") & (obs[lo + k] == obs[lo:hi])
            m1 = (reason[lo:hi] == "") & same & (v >= ta)
            reason[lo:hi][m1] = "emb: earlier source photo, same occurrence"
            m2 = (reason[lo:hi] == "") & ~same & (v >= a.cross)
            reason[lo:hi][m2] = "emb: earlier source photo, other occurrence"
            n_w1 += m1.sum(); n_w2 += m2.sum()
    m = (reason == "") & (cos_t >= a.cross)
    reason[m] = "emb: training photo (same class)"
    n_t = m.sum()
    m = (reason == "") & (cos_k >= a.cross)
    reason[m] = "emb: iNat extra (same class)"
    n_k = m.sum()
    print(f"  emb: training {n_t:,}, iNat extras {n_k:,}, within same occurrence {n_w1:,}, other {n_w2:,} "
          f"({time.time() - t0:.0f} s)", flush=True)
    S["cos_eval"], S["cos_train"], S["cos_inat_extra"], S["cos_within"] = cos_e, cos_t, cos_k, cos_w
    drop = reason != ""
    dropped.append(S[drop].assign(reason=reason[drop]))
    F_ = S[~drop].copy()
    F_["shard"] = sshp[F_["ei"].to_numpy()]
    F_["shard_row"] = srow[F_["ei"].to_numpy()]
    F_ = F_.drop(columns=["ei"]).rename(columns={"license": "licence"}).sort_values(["shard", "shard_row"])
    outp = os.path.join(EX, "extra_photos_src.parquet")
    pq.write_table(pa.Table.from_pandas(F_, preserve_index=False), outp)
    D = pd.concat(dropped, ignore_index=True)
    pq.write_table(pa.Table.from_pandas(D, preserve_index=False), os.path.join(EX, "dropped_src.parquet"))
    con = __import__("duckdb").connect()
    summ = summarise_sql(con, outp)
    summ["dropped"] = D.groupby("reason").size().to_dict()
    summ["seconds"] = round(time.time() - t0)
    json.dump(summ, open(os.path.join(EX, "extra_photos_src-summary.json"), "w"), indent=1, default=int)
    print(json.dumps(summ, indent=1, default=int))


def pd_na_int(n):
    import pandas as pd
    return pd.array([None] * n, dtype="Int32")


LIC_TXT = {"CC0": "CC0 (no rights reserved)", "PD": "public domain", "CC-BY": "CC BY", "CC-BY-NC": "CC BY-NC",
           "CC-BY-SA": "CC BY-SA", "CC-BY-NC-SA": "CC BY-NC-SA", "CC-BY-ND": "CC BY-ND", "CC-BY-NC-ND": "CC BY-NC-ND"}


def attribution(name, login, lic):
    who = name if isinstance(name, str) and name.strip() and name != "null" else login
    lt = LIC_TXT.get(lic, lic)
    if lic in ("CC0", "PD"):
        return f"{who}, {lt}, via iNaturalist"
    return f"© {who}, {lt}, via iNaturalist"


# ------------------------------------------------------------------ calibrate

def cmd_calibrate(a):
    dedup.calibrate(WORK, read_parts("hashes-cand"), pq.read_table(os.path.join(WORK, "candidates.parquet")),
                    n=a.n, threads=a.threads)


def cmd_calibrate_emb(a):
    """Stage-2 threshold on the same kind of known duplicates (needs the torch
    env: uv run --python 3.12 --with 'torch==2.7.*' --with 'torchvision==0.22.*'
    --with open_clip_torch --with pyarrow --with pillow --with imagehash --with
    numpy --with duckdb)."""
    C = pq.read_table(os.path.join(WORK, "candidates.parquet"),
                      columns=["photo_id", "ext", "observation_uuid"]).to_pandas()
    H = read_parts("hashes-cand").to_pandas()
    C = C[C["photo_id"].isin(H.loc[H["status"].isin(["ok", "local"]), "photo_id"])]
    g = C.groupby("observation_uuid")
    pairs = [(int(x.iloc[0].photo_id), x.iloc[0].ext, int(x.iloc[1].photo_id), x.iloc[1].ext)
             for _, x in g if len(x) >= 2]
    rng = np.random.default_rng(3)
    pairs = [pairs[i] for i in rng.permutation(len(pairs))]

    def fetch(pid, ext, size):
        p = os.path.join(PHOTOS, f"{pid}.{ext}")
        if size == "medium" and os.path.exists(p):
            return open(p, "rb").read()
        c = http.client.HTTPSConnection(HOST, timeout=30)
        c.request("GET", f"/photos/{pid}/{size}.{ext}", headers=UA)
        r = c.getresponse()
        b = r.read()
        return b if r.status == 200 and b.startswith(dedup.MAGIC) else None
    dedup.calibrate_emb(WORK, pairs, fetch, n_max=a.n)


# ------------------------------------------------------------------ noise

def api_obs(uuids, tag, cache):
    """iNat API v1 observations by uuid, 200 per request, ≤ 1 request/s, cached."""
    got = {}
    for lo in range(0, len(uuids), 200):
        f = os.path.join(cache, f"{tag}-{lo:05d}.json")
        if not os.path.exists(f):
            url = "https://api.inaturalist.org/v1/observations?" + urllib.parse.urlencode(
                {"uuid": ",".join(uuids[lo:lo + 200]), "per_page": 200})
            body = None
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                        body = r.read()
                    break
                except Exception as e:  # noqa: BLE001
                    print("  retry", e, flush=True)
                    time.sleep(5 * (attempt + 1))
            assert body, url
            open(f, "wb").write(body)
            time.sleep(1.1)
        for o in json.load(open(f))["results"]:
            got[o["uuid"]] = o
    return got


def observer_error(adm, con, rng, cache, n_pairs):
    """Admitted observers' error rate on REVIEWED observations: for random
    admitted (observer, genus) pairs, all their observations in that genus
    (API, any grade, ≤ 200 newest). Reviewed = someone else has a current ID.
    The observer's own current species-level ID vs the community taxon:
    right = community taxon is that species (or inside it); contested = the
    community backed off to a coarser taxon containing it (genus …);
    wrong = the community taxon is somewhere else. Observations of any grade,
    so disagreements that pushed an observation off species rank (and out of
    our species-level needs_id scan) are counted too."""
    pairs = adm[adm["admitted"]][["observer_id", "genus"]].drop_duplicates()
    pairs = pairs.iloc[rng.choice(len(pairs), min(n_pairs, len(pairs)), replace=False)]
    gid = dict(con.execute(f"""SELECT name, min(taxon_id) FROM taxa WHERE rank = 'genus' AND active
                              AND name IN ({",".join("'" + g.replace("'", "") + "'" for g in pairs["genus"].unique())})
                              GROUP BY name""").fetchall())
    c = collections.Counter()
    per_pair = []
    for row in pairs.itertuples():
        g = gid.get(row.genus)
        if g is None:
            continue
        f = os.path.join(cache, f"user-{row.observer_id}-{g}.json")
        if not os.path.exists(f):
            url = ("https://api.inaturalist.org/v1/observations?" +
                   urllib.parse.urlencode({"user_id": row.observer_id, "taxon_id": g, "per_page": 200}))
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                    open(f, "wb").write(r.read())
            except Exception as e:  # noqa: BLE001
                print("  skip", e, flush=True)
                time.sleep(5)
                continue
            time.sleep(1.1)
        k = collections.Counter()
        for o in json.load(open(f))["results"]:
            uid = (o.get("user") or {}).get("id")
            ids = [i for i in o.get("identifications", []) if i.get("current")]
            own = [i for i in ids if (i.get("user") or {}).get("id") == uid]
            if not own or not any((i.get("user") or {}).get("id") != uid for i in ids):
                continue
            t = own[-1].get("taxon") or {}
            if (t.get("rank_level") or 100) > 10:
                continue  # own ID not at species level
            ct = o.get("community_taxon_id")
            tx = o.get("taxon") or {}
            if ct is None:
                continue
            ct_anc = set(tx.get("ancestor_ids") or []) if tx.get("id") == ct else None
            own_anc = set(t.get("ancestor_ids") or [])
            if ct == t.get("id") or (ct_anc is not None and t.get("id") in ct_anc):
                k["right"] += 1
            elif ct in own_anc:
                k["contested (community coarser)"] += 1
            else:
                k["wrong"] += 1
        c.update(k)
        per_pair.append(sum(k.values()))
    n = sum(c.values())
    r = dict(c)
    r["pairs"] = len(per_pair)
    r["reviewed_obs"] = n
    r["wrong_share"] = round(c["wrong"] / n, 3) if n else None
    r["wrong_or_contested_share"] = round((c["wrong"] + c["contested (community coarser)"]) / n, 3) if n else None
    r["median_reviewed_per_pair"] = float(np.median(per_pair)) if per_pair else None
    return r


def cmd_noise(a):
    """needs_id label noise, measured with the iNat API (state of today, i.e.
    ~1–2 weeks after the snapshot): random samples of ADMITTED and of REJECTED
    (pool observer, < TRACK_MIN research-grade obs in the genus) needs_id
    observations. For every current identification by someone OTHER than the
    observer: agree = that taxon is the snapshot species or inside it;
    consistent = a coarser taxon containing it (genus, family …); disagree =
    anything else (another species, another genus). Plus the track rule's own
    premise: for admitted (observer, genus) pairs, one research-grade
    observation each — was the observer's own current ID the community's
    species?"""
    import duckdb
    adm = pq.read_table(os.path.join(WORK, "needs_id_admission.parquet")).to_pandas()
    con = db()
    anc = {}
    for sid, ancestry in con.execute(f"""SELECT taxon_id, ancestry FROM taxa WHERE taxon_id IN
            ({",".join(str(int(x)) for x in adm["species_id"].unique())})""").fetchall():
        anc[sid] = set(map(int, ancestry.split("/")))
    rng = np.random.default_rng(11)
    groups = {"admitted": adm[adm["admitted"]], "rejected_pool": adm[(~adm["admitted"]) & (adm["role"] == "pool")]}
    cache = os.path.join(WORK, "noise_api")
    os.makedirs(cache, exist_ok=True)
    out = {}
    for g, d in groups.items():
        d = d.iloc[rng.choice(len(d), min(a.n, len(d)), replace=False)]
        got = api_obs(d["uuid"].tolist(), g, cache)
        c = collections.Counter()
        for row in d.itertuples():
            o = got.get(row.uuid)
            if o is None:
                c["not returned (deleted / private)"] += 1
                continue
            c["fetched"] += 1
            sp = int(row.species_id)
            up = anc.get(sp, set())
            tx = o.get("taxon") or {}
            if o.get("quality_grade") == "research":
                c["now research"] += 1
                c["now research, same species"] += int(tx.get("id") == sp or sp in set(tx.get("ancestor_ids") or []))
            uid = (o.get("user") or {}).get("id")
            ag = dis = 0
            for i in o.get("identifications", []):
                if not i.get("current") or (i.get("user") or {}).get("id") == uid:
                    continue
                t = i.get("taxon") or {}
                if t.get("id") == sp or sp in set(t.get("ancestor_ids") or []):
                    ag += 1
                elif t.get("id") in up:
                    c["coarser consistent IDs"] += 1
                else:
                    dis += 1
            if ag or dis:
                c["with another person's informative ID"] += 1
                c["agree only"] += int(dis == 0)
                c["any disagreement"] += int(dis > 0)
        r = dict(c)
        r["sampled"] = len(d)
        n = c["with another person's informative ID"]
        r["disagreement_share_among_reviewed"] = round(c["any disagreement"] / n, 3) if n else None
        r["reviewed_share"] = round(n / max(1, c["fetched"]), 3)
        r["now_research_same_species_share"] = round(c["now research, same species"] / max(1, c["fetched"]), 3)
        out[g] = r
    # track-rule premise: own ID == community species on their research-grade obs in the genus
    pairs = adm[adm["admitted"]][["observer_id", "genus"]].drop_duplicates()
    pairs = pairs.iloc[rng.choice(len(pairs), min(a.n_track, len(pairs)), replace=False)]
    con.register("pairs_v", pa.Table.from_pandas(pairs, preserve_index=False))
    rows = con.execute("""SELECT uuid::VARCHAR, observer_id, species_id FROM (
        SELECT o.uuid, o.observer_id, o.species_id,
               row_number() OVER (PARTITION BY o.observer_id, s.genus ORDER BY hash(o.uuid::VARCHAR)) AS r
        FROM o JOIN species s USING (species_id) JOIN pairs_v p ON p.observer_id = o.observer_id AND p.genus = s.genus)
        WHERE r = 1""").fetchall()
    miss = {int(r[2]) for r in rows} - set(anc)
    if miss:
        for sid, ancestry in con.execute(f"SELECT taxon_id, ancestry FROM taxa WHERE taxon_id IN "
                                         f"({','.join(map(str, miss))})").fetchall():
            anc[sid] = set(map(int, ancestry.split("/")))
    got = api_obs([r[0] for r in rows], "track", cache)
    c = collections.Counter()
    for uu, ob, sp in rows:
        o = got.get(uu)
        if o is None:
            c["not returned"] += 1
            continue
        own = [i for i in o.get("identifications", []) if i.get("current") and (i.get("user") or {}).get("id") == ob]
        if not own:
            c["no current own ID"] += 1
            continue
        t = own[-1].get("taxon") or {}
        c["own ID present"] += 1
        c["own ID = community species"] += int(t.get("id") == sp or sp in set(t.get("ancestor_ids") or []))
        c["own ID coarser (genus etc.)"] += int(t.get("id") in anc.get(sp, set()))
    tr = dict(c)
    tr["sampled_pairs"] = len(rows)
    tr["own_species_match_share"] = round(c["own ID = community species"] / max(1, c["own ID present"]), 3)
    out["track_premise"] = tr
    out["observer_error_when_reviewed"] = observer_error(adm, con, rng, cache, a.n_pairs)
    json.dump(out, open(os.path.join(WORK, "noise.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("scan")
    p.add_argument("--fresh", action="store_true")
    p = sub.add_parser("select")
    p.add_argument("--cap", type=int, default=100)
    p.add_argument("--per-obs", type=int, default=3)
    p.add_argument("--uncapped", action="store_true")
    p.add_argument("--au-first", action="store_true")
    p.add_argument("--tag", default="", help="output candidates-<tag>.parquet (SQL summary)")
    p = sub.add_parser("measure")
    p.add_argument("--n", type=int, default=500)
    p.add_argument("--threads", type=int, default=48)
    p = sub.add_parser("fetch")
    p.add_argument("--threads", type=int, default=48)
    p.add_argument("--limit", type=int, default=0)
    p.add_argument("--keep-below", type=int, default=1, help="store photos of classes with fewer training photos")
    p = sub.add_parser("evalhash")
    p.add_argument("--threads", type=int, default=48)
    p = sub.add_parser("calibrate")
    p.add_argument("--n", type=int, default=300)
    p.add_argument("--threads", type=int, default=16)
    p = sub.add_parser("calibrate-emb")
    p.add_argument("--n", type=int, default=80)
    sub.add_parser("dedup")
    sub.add_parser("dedup-emb")
    p = sub.add_parser("finalize-sources")
    p.add_argument("--cross", type=float, default=0.98)
    p = sub.add_parser("finalize")
    p.add_argument("--tag", default="k1000")
    p.add_argument("--cross", type=float, default=0.98, help="cosine threshold across observations")
    p.add_argument("--emb-dirs", nargs="+", default=[os.path.join(EX, "emb"), os.path.join(EX, "emb-k1000")])
    p = sub.add_parser("noise")
    p.add_argument("--n", type=int, default=1000)
    p.add_argument("--n-track", type=int, default=400)
    p.add_argument("--n-pairs", type=int, default=150)
    a = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)
    {"scan": cmd_scan, "select": cmd_select, "measure": cmd_measure, "fetch": cmd_fetch, "evalhash": cmd_evalhash,
     "calibrate": cmd_calibrate, "calibrate-emb": cmd_calibrate_emb, "dedup": cmd_dedup, "dedup-emb": cmd_dedup_emb, "finalize": cmd_finalize, "finalize-sources": cmd_finalize_sources, "noise": cmd_noise}[a.cmd](a)


if __name__ == "__main__":
    main()

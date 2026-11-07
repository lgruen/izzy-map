#!/usr/bin/env python3
"""Rare species may not lose their only photos to the evaluation split
(Leo, 2026-11-07: "more important to train on something than nothing").

Rule, by construction: a species with fewer than K = 10 training photos takes
its HELD-OUT (val/test-role) observers' research-grade observations into
training — whole observers, in a fixed hash order — until it has ≥ K training
photos; the remaining held-out observations stay for evaluation. Photos: every
CC-licensed photo of the moved observations (the snapshot holds only CC),
≤ 3 per observation (lowest position first), never a photo shared between
observations.

  plan     → cache/plantid/rare_heldout/{moved.parquet (observation uuid, u,
             observer), todo.parquet (embed_extra.py input), summary.json}
  extras   after `embed_extra.py vm-embed --bucket local --device mps --todo
             todo.parquet --work cache/plantid/rare_heldout` →
             extras.parquet in train_v2 `--extra` format (source
             "inat-heldout-rare")
Every evaluation set must then drop the moved observations (eval code reads
moved.parquet: `moved_uuids()` / `moved_photo_ids()`).

Env: uv run --with duckdb --with pyarrow --with 'numpy<2.3' python3 -I pipeline/plantid/rare_heldout.py plan|extras
"""
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
OUT = os.path.join(CACHE, "rare_heldout")
K = 10
RUN = "final-cb50-s1"   # its n_c = training photos per class over ALL sources (3.9M photos)


def moved_uuids():
    import pyarrow.parquet as pq
    p = os.path.join(OUT, "moved.parquet")
    return set(pq.read_table(p, columns=["uuid"]).column(0).to_pylist()) if os.path.exists(p) else set()


def moved_photo_ids():
    """Photo ids of EVERY photo of a moved observation (eval sets may hold any of them)."""
    import pyarrow.parquet as pq
    p = os.path.join(OUT, "moved_photos.parquet")
    return set(pq.read_table(p, columns=["photo_id"]).column(0).to_pylist()) if os.path.exists(p) else set()


def cmd_plan():
    import duckdb
    import pyarrow as pa
    import pyarrow.parquet as pq
    os.makedirs(OUT, exist_ok=True)
    n = np.load(os.path.join(AU, "v2", "runs", RUN + ".npz"))["n_c"].astype(np.int64)
    con = duckdb.connect(os.path.join(CACHE, "sets", "work.duckdb"), read_only=True)
    con.register("imap_v", pq.read_table(os.path.join(AU, "inat_map.parquet")))
    con.register("ntr", pa.table({"u": np.arange(len(n)), "n": n}))
    con.execute(f"""CREATE TEMP TABLE ob AS
        SELECT o.uuid, o.observer_id, o.lat, o.lon, o.observed_on, o.role, m.u
        FROM o JOIN imap_v m USING (species_id) JOIN ntr USING (u)
        WHERE o.role IN ('val', 'test') AND n < {K}""")
    con.execute("""CREATE TEMP TABLE ph AS
        SELECT p.uuid, p.photo_id, p.ext, p.license, p.position,
               row_number() OVER (PARTITION BY p.uuid ORDER BY p.position, p.photo_id) AS rk
        FROM pobs p JOIN ob USING (uuid) WHERE p.photo_id NOT IN (SELECT photo_id FROM shared)""")
    con.execute(f"""CREATE TEMP TABLE mv AS
        WITH g AS (SELECT u, observer_id, count(DISTINCT ob.uuid) AS nobs,
                          count(*) FILTER (WHERE rk <= 3) AS nph,
                          hash(observer_id::VARCHAR || 'izzy-rare-move') AS h
                   FROM ob JOIN ph USING (uuid) GROUP BY 1, 2),
             c AS (SELECT g.*, n, coalesce(sum(nph) OVER (PARTITION BY u ORDER BY h
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS before FROM g JOIN ntr USING (u))
        SELECT u, observer_id FROM c WHERE n + before < {K}""")
    con.execute("""CREATE TEMP TABLE mobs AS
        SELECT ob.* FROM ob JOIN mv USING (u, observer_id)""")
    con.execute(f"COPY mobs TO '{os.path.join(OUT, 'moved.parquet')}' (FORMAT parquet)")
    con.execute(f"""COPY (SELECT ph.photo_id, ph.uuid FROM ph JOIN mobs USING (uuid))
                    TO '{os.path.join(OUT, 'moved_photos.parquet')}' (FORMAT parquet)""")
    con.execute(f"""COPY (SELECT ph.photo_id, ph.ext, ph.license AS licence, ph.position, mobs.uuid AS observation_uuid,
                                 mobs.observer_id, mobs.u, mobs.lat, mobs.lon, mobs.observed_on, mobs.role
                          FROM ph JOIN mobs USING (uuid) WHERE rk <= 3 ORDER BY photo_id)
                    TO '{os.path.join(OUT, 'todo.parquet')}' (FORMAT parquet)""")
    s = dict(zip(["observations", "photos_all", "classes", "zero_classes", "observers"], con.execute("""
        SELECT count(DISTINCT uuid), (SELECT count(*) FROM moved_p), count(DISTINCT u),
               count(DISTINCT u) FILTER (WHERE n = 0), count(DISTINCT observer_id)
        FROM mobs JOIN ntr USING (u)""".replace("moved_p", f"read_parquet('{os.path.join(OUT, 'moved_photos.parquet')}')")).fetchone()))
    s["todo_photos"] = con.execute(f"SELECT count(*) FROM read_parquet('{os.path.join(OUT, 'todo.parquet')}')").fetchone()[0]
    s["kept_for_eval_observations"] = con.execute(
        "SELECT count(*) FROM ob WHERE uuid NOT IN (SELECT uuid FROM mobs)").fetchone()[0]
    s["licences"] = dict(con.execute(f"SELECT licence, count(*) FROM read_parquet('{os.path.join(OUT, 'todo.parquet')}') "
                                     "GROUP BY 1").fetchall())
    s["K"], s["run"] = K, RUN
    json.dump(s, open(os.path.join(OUT, "summary.json"), "w"), indent=1, default=str)
    print(json.dumps(s, indent=1, default=str))


def cmd_extras():
    import pyarrow as pa
    import pyarrow.parquet as pq
    T = pq.read_table(os.path.join(OUT, "todo.parquet")).to_pydict()
    pos = {}
    for f in sorted(glob.glob(os.path.join(OUT, "emb", "shard-*.npz"))):
        z = np.load(f)
        for r, (p, ok) in enumerate(zip(z["photo_id"], z["ok"])):
            if ok:
                pos[int(p)] = (os.path.relpath(f, OUT), r)
    keep = [i for i, p in enumerate(T["photo_id"]) if int(p) in pos]
    rows = {c: [T[c][i] for i in keep] for c in ("u", "photo_id", "ext", "observation_uuid", "observer_id", "licence",
                                                  "lat", "lon", "observed_on")}
    rows["source"] = ["inat-heldout-rare"] * len(keep)
    rows["shard"] = [pos[int(p)][0] for p in rows["photo_id"]]
    rows["shard_row"] = [pos[int(p)][1] for p in rows["photo_id"]]
    pq.write_table(pa.table(rows), os.path.join(OUT, "extras.parquet"))
    print(f"extras: {len(keep)} of {len(T['photo_id'])} photos embedded, {len(set(rows['u']))} classes")


if __name__ == "__main__":
    {"plan": cmd_plan, "extras": cmd_extras}[sys.argv[1]]()

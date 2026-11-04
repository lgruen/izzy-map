#!/usr/bin/env python3
"""Location prior for the single model from an occurrence-count table, so
ALA (or any other source) can drop in for iNat without code changes.

  prior_v2.py build [--counts T.parquet[:weight] ...] [--name NAME]
      Each table: columns u (class = labels.parquet row) and n (records), plus
      either lat/lon (points, e.g. ALA point-0.001 facet centres) or cy/cx on
      the 0.05° grid (lat0 −44, lon0 112). Several tables are summed (optional
      per-table weight, e.g. ala.parquet:1 inat.parquet:1). Without --counts:
      the iNat pool-observer research-grade counts (train_australia.prior_counts).
      Counts are written RAW (the transform — √ for v2 — is applied at scoring,
      eval_v2's "kind") → australia/v2/prior-NAME.bin (the au-prior.bin format,
      build_ship.DegPrior), header `sources` lists the tables.
  Use it: V2PRIOR=…/prior-NAME.bin for eval_v2.py / ladder_v3.py / tas_gap.py.
Class merges (train_v2.class_merges) are applied when the prior is read."""
import argparse, json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship as BS  # noqa: E402
import train_australia as TA  # noqa: E402
import train_v2 as V  # noqa: E402

G = TA.PRIOR_GRID


def load_table(spec):
    import pyarrow.parquet as pq
    path, _, w = spec.partition(":")
    t = pq.read_table(path).to_pydict()
    if "cy" in t:
        cy, cx = np.array(t["cy"], np.int64), np.array(t["cx"], np.int64)
    else:
        cy = np.floor((np.array(t["lat"], float) - G["lat0"]) / G["cell"]).astype(np.int64)
        cx = np.floor((np.array(t["lon"], float) - G["lon0"]) / G["cell"]).astype(np.int64)
    u, n = np.array(t["u"], np.int64), np.array(t["n"], float) * float(w or 1)
    ok = (cy >= 0) & (cy < G["ny"]) & (cx >= 0) & (cx < G["nx"]) & (u >= 0)
    return cy[ok], cx[ok], u[ok], n[ok], {"table": path, "weight": float(w or 1), "rows": int(len(u)),
                                          "kept": int(ok.sum()), "records": float(n[ok].sum())}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("--counts", nargs="*", default=[])
    p.add_argument("--name", default="inat")
    a = ap.parse_args()
    import pyarrow.parquet as pq
    C = len(pq.read_table(os.path.join(TA.AU, "labels.parquet"), columns=["name"]))
    parts, meta = [], []
    if not a.counts:
        pc = TA.prior_counts()
        parts.append((np.array(pc["cy"]), np.array(pc["cx"]), np.array(pc["u"]), np.array(pc["n"], float)))
        meta.append({"table": "iNat pool-observer research-grade records (train_australia.prior_counts)",
                     "records": float(np.sum(pc["n"]))})
    for spec in a.counts:
        *arr, m = load_table(spec)
        parts.append(tuple(arr))
        meta.append(m)
    cy, cx, u, n = (np.concatenate([q[i] for q in parts]) for i in range(4))
    key = (cy * G["nx"] + cx) * C + u
    uk, inv = np.unique(key, return_inverse=True)
    cnt = np.bincount(inv, n)
    cell, cls = uk // C, uk % C
    out = os.path.join(V.V2, f"prior-{a.name}.bin")
    # write_deg_prior stores integer counts: round (fractional weights → ≥ 1 kept)
    BS.write_deg_prior(out, cell // G["nx"], cell % G["nx"], cls, np.maximum(np.round(cnt), 1).astype(np.int64), C, G,
                       10.0, 16.0, "occurrence counts per (0.05° cell, class): " + json.dumps(meta))
    print(json.dumps(meta, indent=1))


if __name__ == "__main__":
    main()

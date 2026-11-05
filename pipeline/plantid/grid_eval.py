#!/usr/bin/env python3
"""Evaluate the imbalance-ablation heads (train_v2.grid_imbalance) as they land
in GCS: light eval_v2 (prior / temperature tuned on val per run) with the data
file the run was trained on, post-hoc logit adjustment τ' ∈ {0.5, 1, 1.5} for
the plain-CE runs (chosen on val), then a table of mean ± half-range over seeds
→ australia/v2/grid_eval.{json,md}.
  grid_eval.py run [--prior FILE]   (loops until every grid run is evaluated)
  grid_eval.py table"""
import glob
import re
import json
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import train_v2 as V  # noqa: E402

BUCKET = "gs://leo-superresolution-izzy-plantid/au"
GRID = os.environ.get("GRID", "imbalance")
OUT = os.path.join(V.V2, "grid" if GRID == "imbalance" else GRID)
E = ["uv", "run", "--python", "3.12", "--with", "torch==2.7.*", "--with", "numpy<2.3", "--with", "scipy", "--with",
     "pyarrow", "--with", "pillow", "--with", "duckdb", "--with", "matplotlib", "python3", "-I",
     os.path.join(HERE, "eval_v2.py")]


def evaluate(name, cfg, prior, post=None):
    tag = name + (f"-posthoc{post:g}" if post else "")
    out = os.path.join(OUT, tag + ".json")
    if os.path.exists(out):
        return
    env = dict(os.environ, EVAL_LIGHT="1", EVAL_OUT=out,
               **({"EVAL_VALONLY": "1"} if os.environ.get("VALONLY") else {}), FINAL=name, V2DATA=os.path.join(V.V2, cfg["data"]))
    if prior:
        env["V2PRIOR"] = prior
    if post:
        env["POSTHOC_TAU"] = str(post)
    t = time.time()
    r = subprocess.run(E, env=env, capture_output=True, text=True)
    print(f"{tag}: exit {r.returncode} ({time.time() - t:.0f} s)", flush=True)
    if r.returncode:
        print(r.stdout[-1500:], r.stderr[-1500:])


def cmd_run(prior):
    os.makedirs(OUT, exist_ok=True)
    want = {c["name"]: c for c in {"imbalance": V.grid_imbalance, "decide": V.grid_decide, "tail": V.grid_tail, "final": V.grid_final}[GRID]()}
    while True:
        subprocess.run(["gcloud", "storage", "rsync", f"{BUCKET}/v2/runs", os.path.join(V.V2, "runs"), "--quiet"],
                       capture_output=True)
        have = {os.path.basename(f)[:-4] for f in glob.glob(os.path.join(V.V2, "runs", "g-*.npz"))}
        for nm in sorted(have & set(want)):
            evaluate(nm, want[nm], prior)
            if want[nm]["tau"] == 0 and not want[nm].get("iw"):
                for pt in (0.5, 1.0, 1.5):
                    evaluate(nm, want[nm], prior, pt)
        if set(want) <= have:
            break
        time.sleep(120)
    cmd_table()


def cmd_table():
    rows = {}
    for f in sorted(glob.glob(os.path.join(OUT, "*.json"))):
        tag = os.path.basename(f)[:-5]
        r = json.load(open(f))
        fin = r.get("report", {}).get("final")
        key = re.sub(r"-s\d+", "", tag)
        nan = float("nan")
        g = (lambda a, b: fin[a][b]) if fin else (lambda a, b: nan)  # noqa: E731
        rows.setdefault(key, []).append({
            "val_sp": r["prior"]["sp"],
            "AU_sp": g("AU-test", "top1_sp"), "AU_w": g("AU-test", "top1_w"), "AU_top5_sp": g("AU-test", "top5_sp"),
            "A_sp": g("A-test", "top1_sp"), "A_w": g("A-test", "top1_w"),
            "Ceuc_sp": g("C-euc", "top1_sp"), "Ceuc_top5": g("C-euc", "top5_sp"),
            "b19_sp": fin["buckets"]["1-9"]["top1_sp"] if fin else nan, "b19_w": fin["buckets"]["1-9"]["top1_w"] if fin else nan,
            "ece_sp": r.get("ece_AU-test", {}).get("per_species", nan), "ece_w": r.get("ece_AU-test", {}).get("natural", nan),
            "valrw_sp": r.get("val_reweighted", {}).get("top1_sp", nan),
            "valrw_top5": r.get("val_reweighted", {}).get("top5_sp", nan),
            "val_b19": r.get("val_reweighted", {}).get("b19_top1_sp", nan)})
    # post-hoc: keep the τ' with the best val per seed
    agg = {}
    for key, rs in rows.items():
        if "-posthoc" in key:
            continue
        agg[key] = rs
    ph = {}
    for key, rs in rows.items():
        if "-posthoc" in key:
            base = key.split("-posthoc")[0]
            ph.setdefault(base, []).append((key, rs))
    for base, opts in ph.items():
        best = max(opts, key=lambda o: np.mean([x["val_sp"] for x in o[1]]))
        agg[best[0]] = best[1]
    cols = ("valrw_sp", "valrw_top5", "val_b19", "val_sp", "AU_sp", "AU_w", "AU_top5_sp", "A_sp", "A_w", "Ceuc_sp", "Ceuc_top5", "b19_sp", "b19_w", "ece_sp", "ece_w")
    lines = ["| run (seeds) | " + " | ".join(cols) + " |", "|" + "---|" * (len(cols) + 1)]
    for key in sorted(agg):
        rs = agg[key]
        cell = []
        for c in cols:
            v = np.array([x[c] for x in rs]) * 100
            cell.append(f"{v.mean():.1f} ± {(v.max() - v.min()) / 2:.1f}" if len(v) > 1 else f"{v.mean():.1f}")
        lines.append(f"| {key} ({len(rs)}) | " + " | ".join(cell) + " |")
    open(OUT + "_eval.md", "w").write("\n".join(lines) + "\n")
    json.dump({k: v for k, v in rows.items()}, open(OUT + "_eval.json", "w"), indent=1)
    print("\n".join(lines))


if __name__ == "__main__":
    if sys.argv[1] == "run":
        cmd_run(sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--prior" else None)
    else:
        cmd_table()

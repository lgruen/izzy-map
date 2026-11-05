#!/usr/bin/env python3
"""Plant-ID provenance (CLAUDE.md "Plant-ID provenance": no weights we can't
regenerate). Every v2 step calls `record()`, which appends one line to
australia/v2/provenance-steps.jsonl: the step, its exact argv and env
(V2DATA, V2PRIOR, FINAL), the git commit of pipeline/plantid/ and whether it
was clean, torch/numpy versions and device, seeds, and sha256 of its inputs
and outputs.

  provenance.py inputs      copy the small inputs a rebuild needs (manifests,
                            labels, text vectors, name map, extras list, prior
                            counts, …) to gs://…/au/inputs/<sha256>/<name>
                            (content-addressed; skips what is there)
  provenance.py section     → australia/v2/provenance.json: the `provenance`
                            section for the shipped pipeline.json (git commit,
                            steps, snapshot ids, input hashes + GCS paths, the
                            embedding GCS prefixes, seeds)
  provenance.py ship        merge provenance.json into ship/pipeline.json
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
CACHE = os.path.normpath(os.path.join(HERE, "..", "cache", "plantid"))
AU = os.path.join(CACHE, "australia")
V2 = os.path.join(AU, "v2")
STEPS = os.path.join(V2, "provenance-steps.jsonl")
BUCKET = "gs://leo-superresolution-izzy-plantid/au"
# embeddings (BioCLIP 2.5, cloud fp16, L2-normalised; npz shards {photo_id, emb})
EMB_GCS = {"au_run_2026-11-04": f"{BUCKET}/emb  (590,824 photos, 591 shards; train_australia.py vm-embed)",
           "tasmanian_run_2026-11-01": f"{BUCKET}/emb0  (92,006 photos; copied from emb/bioclip25 of the 2026-11-01 run)"}
INPUTS = {  # name → local path (the small files a rebuild needs besides the embeddings)
    "plan_train.parquet": os.path.join(AU, "plan", "train.parquet"),
    "plan_eval.parquet": os.path.join(AU, "plan", "eval.parquet"),
    "labels.parquet": os.path.join(AU, "labels.parquet"),
    "inat_map.parquet": os.path.join(AU, "inat_map.parquet"),
    "text.npz": os.path.join(AU, "text.npz"),
    "C.parquet": os.path.join(AU, "C.parquet"),
    "prior_counts_0.05.parquet": os.path.join(AU, "train", "prior_counts_0.05.parquet"),
    "sets_train.parquet": os.path.join(CACHE, "sets", "train.parquet"),
    "sets_test.parquet": os.path.join(CACHE, "sets", "test.parquet"),
    "sets_labels.parquet": os.path.join(CACHE, "sets", "labels.parquet"),
    "sets_prior.parquet": os.path.join(CACHE, "sets", "prior.parquet"),
    "apc_inat_map.json": os.path.join(CACHE, "names", "apc_inat_map.json"),
    "extra_photos.parquet": os.path.join(CACHE, "extra", "extra_photos.parquet"),
    "reassign_train.parquet": os.path.join(CACHE, "extra", "reassign_train.parquet"),
}


def sha256(path, cache={}):  # noqa: B006 (memo per process)
    st = os.stat(path)
    k = (path, st.st_size, st.st_mtime)
    if k not in cache:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for b in iter(lambda: f.read(1 << 22), b""):
                h.update(b)
        cache[k] = h.hexdigest()
    return cache[k]


def git_state():
    def g(*a):
        return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True).stdout
    dirty = g("status", "--porcelain", "--", "pipeline/plantid").rstrip("\n")
    return {"commit": g("rev-parse", "HEAD").strip(), "plantid_clean": not dirty,
            "plantid_dirty_files": [l[3:] for l in dirty.splitlines()][:50]}


def record(step, inputs=(), outputs=(), extra=None):
    """Append one provenance line for a pipeline step (call at its END)."""
    try:
        import numpy
        import torch
        versions = {"torch": torch.__version__, "numpy": numpy.__version__, "python": sys.version.split()[0],
                    "mps": bool(torch.backends.mps.is_available()), "cuda": bool(torch.cuda.is_available())}
    except Exception:  # noqa: BLE001
        versions = {"python": sys.version.split()[0]}
    os.makedirs(V2, exist_ok=True)
    line = {"step": step, "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "argv": sys.argv, "env": {k: os.environ[k] for k in ("V2DATA", "V2PRIOR", "FINAL") if k in os.environ},
            "git": git_state(), "versions": versions,
            "inputs": {os.path.relpath(p, REPO): sha256(p) for p in inputs if p and os.path.isfile(p)},
            "outputs": {os.path.relpath(p, REPO): sha256(p) for p in outputs if p and os.path.isfile(p)},
            **(extra or {})}
    with open(STEPS, "a") as f:
        f.write(json.dumps(line, default=str) + "\n")
    if not line["git"]["plantid_clean"]:
        print(f"provenance: pipeline/plantid has uncommitted changes {line['git']['plantid_dirty_files'][:5]} "
              "— commit before this output ships", file=sys.stderr)


def snapshot_ids():
    meta = os.path.join(CACHE, "meta")
    out = {}
    for f in ("observations.csv.gz", "photos.csv.gz", "taxa.csv.gz", "observers.csv.gz"):
        p = os.path.join(meta, f)
        if os.path.exists(p):
            st = os.stat(p)
            out[f] = {"bytes": st.st_size, "fetched": datetime.datetime.fromtimestamp(st.st_mtime).date().isoformat()}
    return {"inat_open_data": {"bucket": "s3://inaturalist-open-data", "snapshot": "2026-10 monthly export",
                               "files": out},
            "apc": "NSL taxon export CSV, downloaded 2026-11-04 (australia/apc/taxon.csv)",
            "bioclip": "hf-hub:imageomics/bioclip-2.5-vith14 @ 6e3d04e3d6522012c88181085c5ae666e14c45cd"}


def cmd_inputs():
    out = {}
    for name, p in INPUTS.items():
        if not os.path.exists(p):
            continue
        h = sha256(p)
        dst = f"{BUCKET}/inputs/{h}/{name}"
        r = subprocess.run(["gcloud", "storage", "ls", dst], capture_output=True, text=True)
        if r.returncode != 0:
            subprocess.run(["gcloud", "storage", "cp", p, dst, "--quiet"], check=True)
        out[name] = {"sha256": h, "gcs": dst, "bytes": os.path.getsize(p)}
        print(name, out[name]["gcs"])
    # evaluation-only embeddings (Core ML w8 of A-test and C; not needed to rebuild the weights)
    for name, d in (("eval_w8_A-test", os.path.join(CACHE, "ship", "eval", "coreml-w8")),
                    ("eval_w8_C", os.path.join(AU, "emb-w8"))):
        if os.path.isdir(d):
            dst = f"{BUCKET}/inputs/{name}"
            subprocess.run(["gcloud", "storage", "rsync", d, dst, "--quiet"], check=True)
            out[name] = {"gcs": dst, "files": len(os.listdir(d))}
    json.dump(out, open(os.path.join(V2, "inputs-gcs.json"), "w"), indent=1)


def cmd_section():
    steps = [json.loads(l) for l in open(STEPS)] if os.path.exists(STEPS) else []
    gi = os.path.join(V2, "inputs-gcs.json")
    sec = {"version": 1, "built": datetime.date.today().isoformat(), "git": git_state(),
           "snapshots": snapshot_ids(), "embeddings_gcs": EMB_GCS,
           "inputs": json.load(open(gi)) if os.path.exists(gi) else {},
           "seeds": {"train_v2.train": "torch.manual_seed(cfg.seed = 0) + numpy default_rng(seed) (data fraction "
                                       "subsampling); val tuning subsets by sha256(observer) hashes (no RNG)"},
           "determinism": "two identical 1-epoch runs (30k photos) gave bit-identical weights on MPS and on CPU "
                          "(torch 2.7, 2026-11-05); MPS vs CPU vs CUDA are not bit-identical to each other "
                          "(float reduction order) — rebuild on the device the step records",
           "steps": steps}
    if not sec["git"]["plantid_clean"]:
        sec["WARNING"] = "pipeline/plantid had uncommitted changes when this section was written"
    json.dump(sec, open(os.path.join(V2, "provenance.json"), "w"), indent=1, default=str)
    print(f"provenance.json: {len(steps)} steps, git {sec['git']['commit'][:10]} clean={sec['git']['plantid_clean']}")


def cmd_ship():
    sys.path.insert(0, HERE)
    import build_ship as BS
    p = os.path.join(BS.SHIP, "pipeline.json")
    pipe = json.load(open(p))
    pipe["provenance"] = json.load(open(os.path.join(V2, "provenance.json")))
    json.dump(pipe, open(p, "w"), indent=1, ensure_ascii=False)
    print(f"provenance merged into {p}")


if __name__ == "__main__":
    {"inputs": cmd_inputs, "section": cmd_section, "ship": cmd_ship}[sys.argv[1]]()

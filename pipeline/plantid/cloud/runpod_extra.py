#!/usr/bin/env python3
"""Embed extra training photos on RunPod GPU pods, driven from the Mac
(notes/data_expansion.md). Pods get NO cloud credentials and no RunPod key:
each runs cloud/runpod_pod.py (a token-guarded HTTP server behind RunPod's
HTTPS proxy); the Mac uploads code + todo, starts the job, downloads the
shards, verifies them (count + sha256) and terminates the pod.

  gpus [--min-vram 20]            catalog: availability + price per GPU type
  validate --gpu ID [--cloud C]   1 pod, 300 photos already embedded on the
                                  GCP L4 → cosine + hash parity, photos/s
  launch --gpu ID --pods N [--cloud C] [--todo PATH] [--first-shard K]
                                  N pods, contiguous shard ranges of the todo
  status                          per pod: state, shards, last log line
  pull                            download + verify shards of every pod;
                                  terminate a pod once ALL its shards are
                                  verified and its job is done
  terminate [POD …|--all]         delete pods (and forget them)

The RunPod key is read from ~/.config/izzymap/runpod.env into this process
only (never printed, logged or passed to a pod). State (pod ids + their
one-purpose tokens): extra/work/runpod/state.json (mode 600).
Env: uv run --with pyarrow --with numpy python3 -I pipeline/plantid/cloud/runpod_extra.py …
"""
import argparse
import base64
import glob
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.dirname(HERE)
CACHE = os.path.normpath(os.path.join(P, "..", "cache", "plantid"))
EX = os.path.join(CACHE, "extra")
RP = os.path.join(EX, "work", "runpod")
STATE = os.path.join(RP, "state.json")
API = "https://api.runpod.io"
UA = "izzymap-plantid-eval/1"
IMAGE = "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"  # only python3 + bash + curl are used
REVISION = "6e3d04e3d6522012c88181085c5ae666e14c45cd"      # BioCLIP 2.5 snapshot the GCP runs used
SHARD = 1000
os.makedirs(RP, exist_ok=True)


def key():
    for line in open(os.path.expanduser("~/.config/izzymap/runpod.env")):
        if line.startswith("RUNPOD_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("no RUNPOD_API_KEY")


def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key(), "User-Agent": UA,
                                          "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            b = r.read()
            return json.loads(b) if b else {}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path}: HTTP {e.code} {e.read()[:400].decode('utf-8', 'replace')}") from None


def load_state():
    return json.load(open(STATE)) if os.path.exists(STATE) else {"pods": {}}


def save_state(s):
    with open(STATE + ".tmp", "w") as f:
        json.dump(s, f, indent=1)
    os.chmod(STATE + ".tmp", 0o600)
    os.replace(STATE + ".tmp", STATE)


def pod_call(pod, method, path, data=None, timeout=90):
    url = f"https://{pod['id']}-8000.proxy.runpod.net{path}"
    req = urllib.request.Request(url, method=method, data=data,
                                 headers={"X-Token": pod["token"], "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def code_tgz():
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:gz") as t:
        for f in ("embed_extra.py", "dedup.py"):
            t.add(os.path.join(P, f), arcname=f)
    return b.getvalue()


def create(name, gpu, cloud, token):
    boot = base64.b64encode(open(os.path.join(HERE, "runpod_pod.py"), "rb").read()).decode()
    body = {"name": name, "image": IMAGE, "cloud": cloud, "disk": 80, "ports": ["8000/http"],
            "gpu": {"id": gpu, "count": 1, "minVcpuCountPerGpu": 8, "minRamPerGpu": 24, "minCudaVersion": "12.6"},
            "env": {"IZZY_TOKEN": token, "IZZY_BOOT": boot},
            "entrypoint": ["bash", "-c"],
            "cmd": ["echo \"$IZZY_BOOT\" | base64 -d > /boot.py && exec python3 /boot.py"]}
    return api("POST", "/v2/pods", body)


def wait_up(pod, limit=900):
    t = time.time()
    while time.time() - t < limit:
        try:
            return json.loads(pod_call(pod, "GET", "/status", timeout=20))
        except Exception:  # noqa: BLE001 — pod still pulling the image / proxy not ready
            time.sleep(15)
    raise RuntimeError(f"pod {pod['id']} not reachable after {limit} s")


def start(pod, todo_path, shard_range, threads=48):
    for n, data in (("code.tgz", code_tgz()), ("todo.parquet", open(todo_path, "rb").read()),
                    ("job.json", json.dumps({"shard_range": shard_range, "revision": REVISION,
                                             "threads": threads}).encode())):
        r = json.loads(pod_call(pod, "PUT", f"/in/{n}", data, timeout=300))
        assert r["sha256"] == hashlib.sha256(data).hexdigest(), n
    return json.loads(pod_call(pod, "POST", "/go", b""))


# ------------------------------------------------------------------ commands

def cmd_gpus(a):
    d = api("GET", "/v2/catalog/gpus?include=AVAILABILITY&product=POD")
    items = d if isinstance(d, list) else d.get("data") or d.get("items") or []
    json.dump(d, open(os.path.join(RP, "gpus.json"), "w"), indent=1)
    for g in items:
        mem = g.get("memoryInGb") or g.get("memory") or 0
        if mem and mem < a.min_vram:
            continue
        print(json.dumps({k: g.get(k) for k in g if k not in ("description",)})[:400])


def new_pod(st, name, gpu, cloud, rng, todo, kind):
    token = secrets.token_urlsafe(32)
    r = create(name, gpu, cloud, token)
    pod = {"id": r["id"], "token": token, "gpu": gpu, "cloud": cloud, "range": rng, "todo": todo, "kind": kind,
           "created": time.time(), "image": IMAGE, "info": {k: r.get(k) for k in ("costPerHr", "dataCenterId", "machineId",
                                                                                   "vcpuCount", "memoryInGb") if k in r}}
    st["pods"][pod["id"]] = pod
    save_state(st)
    print(f"created {pod['id']} ({gpu}, {cloud}) range {rng} {pod['info']}", flush=True)
    return pod


def cmd_validate(a):
    """300 photos the GCP L4 already embedded (extra/emb/shard-0000.npz)."""
    import numpy as np
    import pyarrow as pa
    import pyarrow.parquet as pq
    z = np.load(os.path.join(EX, "emb", "shard-0000.npz"))
    ids = sorted(int(x) for x in z["photo_id"][:300])
    ext = dict(zip(*pq.read_table(os.path.join(EX, "work", "candidates-k1000.parquet"),
                                  columns=["photo_id", "ext"]).to_pydict().values()))
    todo = os.path.join(RP, "todo-validate.parquet")
    pq.write_table(pa.table({"photo_id": pa.array(ids, pa.int64()), "ext": [ext[i] for i in ids]}), todo)
    st = load_state()
    pod = new_pod(st, "izzy-embed-validate", a.gpu, a.cloud, "0:1", todo, "validate")
    print("waiting for the pod …", flush=True)
    wait_up(pod)
    print(start(pod, todo, "0:1", threads=16))


def cmd_launch(a):
    import pyarrow.parquet as pq
    n = pq.read_metadata(a.todo).num_rows
    nsh = -(-n // SHARD)
    first = a.first_shard
    per = -(-(nsh - first) // a.pods)
    st = load_state()
    for i in range(a.pods):
        lo, hi = first + i * per, min(nsh, first + (i + 1) * per)
        if lo >= hi:
            break
        try:
            pod = new_pod(st, f"izzy-embed-{lo:04d}", a.gpu, a.cloud, f"{lo}:{hi}", a.todo, "run")
        except RuntimeError as e:
            print(f"create failed for {lo}:{hi}: {e}", flush=True)
            continue
    for pod in [p for p in st["pods"].values() if p["kind"] == "run" and not p.get("started")]:
        try:
            wait_up(pod)
            print(pod["id"], start(pod, pod["todo"], pod["range"]), flush=True)
            pod["started"] = time.time()
            save_state(st)
        except Exception as e:  # noqa: BLE001
            print(f"start failed {pod['id']}: {e}", flush=True)


def cmd_status(a):
    st = load_state()
    for pid, pod in st["pods"].items():
        try:
            s = json.loads(pod_call(pod, "GET", "/status", timeout=30))
            last = [l for l in s["log"].splitlines() if l.strip()][-1:] if s.get("log") else []
            print(pid, pod["range"], s["state"], s["rc"], "shards", s["shards"], "|", last[0][:200] if last else "")
        except Exception as e:  # noqa: BLE001
            print(pid, pod["range"], "unreachable:", e)


def pull_pod(pod, out_dir):
    man = json.loads(pod_call(pod, "GET", "/manifest", timeout=120))
    got = 0
    for name, (size, sha) in man.items():
        p = os.path.join(out_dir, name)
        if os.path.exists(p) and os.path.getsize(p) == size and \
                hashlib.sha256(open(p, "rb").read()).hexdigest() == sha:
            continue
        for attempt in range(4):
            try:
                b = pod_call(pod, "GET", f"/emb/{name}", timeout=120)
                if len(b) == size and hashlib.sha256(b).hexdigest() == sha:
                    with open(p + ".part", "wb") as f:
                        f.write(b)
                    os.replace(p + ".part", p)
                    got += 1
                    break
            except Exception:  # noqa: BLE001
                time.sleep(3)
        else:
            print(f"  {pod['id']}: {name} failed verification", flush=True)
    return man, got


def cmd_pull(a):
    st = load_state()
    for pid, pod in list(st["pods"].items()):
        out = os.path.join(EX, "emb-validate" if pod["kind"] == "validate" else f"emb-{a.tag}")
        os.makedirs(out, exist_ok=True)
        try:
            s = json.loads(pod_call(pod, "GET", "/status", timeout=30))
            man, got = pull_pod(pod, out)
        except Exception as e:  # noqa: BLE001
            print(pid, "unreachable:", e)
            continue
        lo, hi = map(int, pod["range"].split(":"))
        want = {f"shard-{k:04d}.npz" for k in range(lo, hi)}
        have = {n for n in want if os.path.exists(os.path.join(out, n)) and n in man and
                hashlib.sha256(open(os.path.join(out, n), "rb").read()).hexdigest() == man[n][1]}
        print(f"{pid} {pod['range']}: {s['state']}, {got} new, {len(have)}/{len(want)} verified", flush=True)
        if s["state"] == "done" and have == want and not a.keep:
            api("DELETE", f"/v2/pods/{pid}")
            pod["terminated"] = time.time()
            st.setdefault("done", {})[pid] = pod
            del st["pods"][pid]
            save_state(st)
            print(f"  terminated {pid}", flush=True)


def cmd_terminate(a):
    st = load_state()
    ids = list(st["pods"]) if a.all else a.pods
    for pid in ids:
        try:
            api("DELETE", f"/v2/pods/{pid}")
        except RuntimeError as e:
            print(e)
        pod = st["pods"].pop(pid, None)
        if pod:
            pod["terminated"] = time.time()
            st.setdefault("done", {})[pid] = pod
        print("terminated", pid)
    save_state(st)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gpus")
    p.add_argument("--min-vram", type=int, default=20)
    p = sub.add_parser("validate")
    p.add_argument("--gpu", required=True)
    p.add_argument("--cloud", default="SECURE")
    p = sub.add_parser("launch")
    p.add_argument("--gpu", required=True)
    p.add_argument("--pods", type=int, required=True)
    p.add_argument("--cloud", default="SECURE")
    p.add_argument("--todo", default=os.path.join(EX, "work", "todo-k1000.parquet"))
    p.add_argument("--first-shard", type=int, default=0)
    sub.add_parser("status")
    p = sub.add_parser("pull")
    p.add_argument("--tag", default="k1000")
    p.add_argument("--keep", action="store_true", help="never terminate")
    p = sub.add_parser("terminate")
    p.add_argument("pods", nargs="*")
    p.add_argument("--all", action="store_true")
    a = ap.parse_args()
    {"gpus": cmd_gpus, "validate": cmd_validate, "launch": cmd_launch, "status": cmd_status, "pull": cmd_pull,
     "terminate": cmd_terminate}[a.cmd](a)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Drive the encoder fine-tuning pilot on RunPod pods from the Mac (same
pattern as cloud/runpod_extra.py, whose `api` is reused; the key is read from
~/.config/izzymap/runpod.env into this process only — never printed, logged
or passed to a pod). One pod per arm; each runs finetune/ft_pod.py.

  launch --arm NAME --job '{json}' [--gpu ID] [--cloud SECURE] [--dcs …]
  start POD              (re)upload inputs + start the job of a created pod
  status                 per pod: state, last log lines
  pull [--keep]          download + sha256-verify every output file; terminate a
                         pod once its job is done and ALL its files are verified
                         (a failed job is pulled and kept for inspection)
  terminate [POD …|--all]
  pods                   what RunPod itself lists (GET /v2/pods)

State: cache/plantid/finetune/runpod/state.json (mode 600; pod ids + tokens).
Env: uv run --with pyarrow --with numpy python3 -I pipeline/plantid/finetune/ft_runpod.py …
"""
import argparse
import base64
import concurrent.futures as cf
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(P, "cloud"))
import runpod_extra as RX  # noqa: E402  (api(), IMAGE, REVISION)

CACHE = os.path.normpath(os.path.join(P, "..", "cache", "plantid"))
FT = os.path.join(CACHE, "finetune")
PLAN = os.path.join(FT, "plan")
RP = os.path.join(FT, "runpod")
STATE = os.path.join(RP, "state.json")
UA = "izzymap-plantid-eval/1"
os.makedirs(RP, exist_ok=True)
LOCK = threading.Lock()


def load_state():
    return json.load(open(STATE)) if os.path.exists(STATE) else {"pods": {}, "done": {}}


def save_state(s, drop=()):
    """Merge into the file on disk (several driver processes may run at once):
    pods/done entries of `s` overwrite theirs by id; `drop` ids leave "pods"."""
    import fcntl
    with LOCK, open(STATE + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        cur = load_state()
        cur["pods"].update(s["pods"])
        cur.setdefault("done", {}).update(s.get("done", {}))
        for pid in list(drop) + list(s.get("done", {})):
            cur["pods"].pop(pid, None)
        with open(STATE + ".tmp", "w") as f:
            json.dump(cur, f, indent=1)
        os.chmod(STATE + ".tmp", 0o600)
        os.replace(STATE + ".tmp", STATE)


def call(pod, method, path, data=None, timeout=120):
    req = urllib.request.Request(f"https://{pod['id']}-8000.proxy.runpod.net{path}", method=method, data=data,
                                 headers={"X-Token": pod["token"], "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def code_tgz():
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w:gz") as t:
        t.add(os.path.join(HERE, "ft_train.py"), arcname="ft_train.py")
    return b.getvalue()


def wait_up(pod, limit=1200):
    t = time.time()
    while time.time() - t < limit:
        try:
            return json.loads(call(pod, "GET", "/status", timeout=20))
        except Exception:  # noqa: BLE001 — image pull / proxy not ready yet
            time.sleep(15)
    raise RuntimeError(f"pod {pod['id']} not reachable after {limit} s")


def put(pod, name, data):
    for att in range(5):
        try:
            r = json.loads(call(pod, "PUT", f"/in/{name}", data, timeout=600))
            assert r["sha256"] == hashlib.sha256(data).hexdigest(), name
            return
        except Exception as e:  # noqa: BLE001
            print(f"  put {name} retry {att}: {e}", flush=True)
            time.sleep(5)
    raise RuntimeError(f"upload of {name} failed")


def cmd_launch(a):
    job = dict(json.loads(a.job), arm=a.arm, revision=RX.REVISION)
    token = secrets.token_urlsafe(32)
    boot = base64.b64encode(open(os.path.join(HERE, "ft_pod.py"), "rb").read()).decode()
    body = {"name": f"izzy-ft-{a.name or a.arm}", "image": RX.IMAGE, "cloud": a.cloud, "disk": 120,
            "ports": ["8000/http"], "gpu": {"id": a.gpu, "count": 1, "minVcpuCountPerGpu": a.vcpu},
            "env": {"IZZY_TOKEN": token, "IZZY_BOOT": boot}, "entrypoint": ["bash", "-c"],
            "cmd": ["echo \"$IZZY_BOOT\" | base64 -d > /boot.py && exec python3 /boot.py"]}
    if a.dcs:
        body["dataCenterIds"] = a.dcs.split(",")
    r = RX.api("POST", "/v2/pods", body)
    pod = {"id": r["id"], "token": token, "gpu": a.gpu, "cloud": a.cloud, "name": a.name or a.arm, "job": job,
           "created": time.time(), "info": {k: r.get(k) for k in ("costPerHr", "dataCenterId", "machineId",
                                                                   "vcpuCount", "memoryInGb") if k in r}}
    save_state({"pods": {pod["id"]: pod}})
    print(f"created {pod['id']} {pod['name']} ({a.gpu}) {pod['info']}", flush=True)
    start(pod)


def cmd_start(a):
    st = load_state()
    start(st["pods"][a.pod])


def start(pod):
    job = pod["job"]
    wait_up(pod)
    t0 = time.time()
    files = [("code.tgz", code_tgz()), ("job.json", json.dumps(job).encode())]
    for n in ("todo.parquet", "classes.json", "mu.npy", "tmean.npy", "text_sub.npy"):
        files.append((n, open(os.path.join(PLAN, n), "rb").read()))
    tars = sorted(f for f in os.listdir(PLAN) if f.startswith("photos-") and f.endswith(".tar"))
    if job.get("no_tars"):
        tars = []
    with cf.ThreadPoolExecutor(12) as ex:
        list(ex.map(lambda nd: put(pod, *nd), files))
        list(ex.map(lambda n: put(pod, n, open(os.path.join(PLAN, n), "rb").read()), tars))
    print(f"  uploaded {len(files) + len(tars)} files in {time.time() - t0:.0f} s", flush=True)
    print(" ", json.loads(call(pod, "POST", "/go", b"")), flush=True)
    pod["started"] = time.time()
    save_state({"pods": {pod["id"]: pod}})


def cmd_status(a):
    st = load_state()
    for pid, pod in st["pods"].items():
        try:
            s = json.loads(call(pod, "GET", "/status", timeout=30))
            lines = [l for l in s["log"].splitlines() if l.strip()][-a.lines:]
            age = (time.time() - pod["created"]) / 3600
            print(f"{pid} {pod['name']} {s['state']} rc={s['rc']} ({age:.2f} h, ~${age * (pod['info'].get('costPerHr') or 0.89):.2f})")
            for l in lines:
                print("   ", l[:220])
        except Exception as e:  # noqa: BLE001
            print(pid, pod["name"], "unreachable:", e)


def pull_one(a, st, pid, pod):
    out = os.path.join(FT, "runs", pod["name"])
    os.makedirs(out, exist_ok=True)
    try:
        s = json.loads(call(pod, "GET", "/status", timeout=30))
        man = json.loads(call(pod, "GET", "/manifest", timeout=300))
    except Exception as e:  # noqa: BLE001
        print(pid, "unreachable:", e)
        return

    def one(item):
        name, (size, sha) = item
        p = os.path.join(out, name)
        if os.path.exists(p) and os.path.getsize(p) == size and hashlib.sha256(open(p, "rb").read()).hexdigest() == sha:
            return 0
        for att in range(5):
            try:
                b = call(pod, "GET", f"/out/{name}", timeout=600)
                if len(b) == size and hashlib.sha256(b).hexdigest() == sha:
                    with open(p + ".part", "wb") as f:
                        f.write(b)
                    os.replace(p + ".part", p)
                    return 1
            except Exception:  # noqa: BLE001
                time.sleep(3 + 3 * att)
        return 0
    with cf.ThreadPoolExecutor(16) as ex:
        got = sum(ex.map(one, man.items()))
    # re-read the manifest: a file still being written changes its hash
    man2 = json.loads(call(pod, "GET", "/manifest", timeout=300))
    ok = all(os.path.exists(os.path.join(out, n)) and
             hashlib.sha256(open(os.path.join(out, n), "rb").read()).hexdigest() == v[1] for n, v in man2.items())
    print(f"{pid} {pod['name']}: {s['state']}, {got} new files, {len(man2)} listed, all verified: {ok}", flush=True)
    if s["state"] == "done" and ok and man2 == man and not a.keep:
        open(os.path.join(out, "job.log.tail"), "w").write(s["log"])
        RX.api("DELETE", f"/v2/pods/{pid}")
        pod["terminated"] = time.time()
        save_state({"pods": {}, "done": {pid: pod}})
        print(f"  terminated {pid} after {(pod['terminated'] - pod['created']) / 3600:.2f} h", flush=True)


def cmd_pull(a):
    st = load_state()
    with cf.ThreadPoolExecutor(max(1, len(st["pods"]))) as ex:
        list(ex.map(lambda kv: pull_one(a, st, *kv), list(st["pods"].items())))


def cmd_terminate(a):
    st = load_state()
    for pid in (list(st["pods"]) if a.all else a.pods):
        try:
            RX.api("DELETE", f"/v2/pods/{pid}")
        except RuntimeError as e:
            print(e)
        pod = st["pods"].pop(pid, None)
        if pod:
            pod["terminated"] = time.time()
            save_state({"pods": {}, "done": {pid: pod}}, drop=[pid])
        print("terminated", pid)


def cmd_pods(a):
    d = RX.api("GET", "/v2/pods")
    items = d if isinstance(d, list) else d.get("data") or d.get("pods") or []
    print(len(items), "pods listed by RunPod")
    for p in items:
        print({k: p.get(k) for k in ("id", "name", "desiredStatus", "costPerHr")})


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("launch")
    p.add_argument("--arm", required=True)
    p.add_argument("--name", default="")
    p.add_argument("--job", default="{}")
    p.add_argument("--gpu", default="NVIDIA GeForce RTX 4090")
    p.add_argument("--cloud", default="SECURE")
    p.add_argument("--vcpu", type=int, default=16)
    p.add_argument("--dcs", default="")
    p = sub.add_parser("status")
    p.add_argument("--lines", type=int, default=3)
    p = sub.add_parser("pull")
    p.add_argument("--keep", action="store_true")
    p = sub.add_parser("terminate")
    p.add_argument("pods", nargs="*")
    p.add_argument("--all", action="store_true")
    sub.add_parser("pods")
    p = sub.add_parser("start")
    p.add_argument("pod")
    a = ap.parse_args()
    {"launch": cmd_launch, "status": cmd_status, "pull": cmd_pull, "terminate": cmd_terminate, "pods": cmd_pods,
     "start": cmd_start}[a.cmd](a)


if __name__ == "__main__":
    main()

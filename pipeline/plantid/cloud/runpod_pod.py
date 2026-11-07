#!/usr/bin/env python3
"""Runs INSIDE a RunPod pod (started by cloud/runpod_extra.py; stdlib only,
passed in base64 through the pod's env — the image is a stock RunPod PyTorch
image). The pod gets NO cloud credentials: the Mac uploads the code and the
todo through this server and downloads the finished shards from it.

Server on 0.0.0.0:8000 (reached via RunPod's HTTPS proxy), every request
needs header `X-Token: $IZZY_TOKEN` (random, one per pod, single purpose):
  PUT  /in/{code.tgz,todo.parquet,job.json}   inputs (only these three names)
  POST /go                                    start the job once (job.json:
                                              {"shard_range": "lo:hi",
                                               "revision": <HF commit>, …})
  GET  /status                                state, shards done, log tail
  GET  /manifest                              {shard file: [bytes, sha256]}
  GET  /emb/shard-NNNN.npz                    one finished shard (read-only)
Job: uv (installed here) → torch 2.7 / torchvision 0.22 / open_clip (the GCP
run's env) → BioCLIP 2.5 at the pinned revision from Hugging Face →
embed_extra.py vm-embed --bucket local → shards in /work/emb/.
"""
import hashlib
import hmac
import http.server
import json
import os
import re
import subprocess
import threading

W = "/work"
IN = os.path.join(W, "in")
EMB = os.path.join(W, "emb")
TOKEN = os.environ["IZZY_TOKEN"]
os.makedirs(IN, exist_ok=True)
os.makedirs(EMB, exist_ok=True)
STATE = {"state": "waiting for inputs", "rc": None}
SHA = {}
LOCK = threading.Lock()

JOB = r"""
set -uo pipefail
cd /work
export HOME=/root PATH=/root/.local/bin:$PATH
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
rm -rf code && mkdir code && tar -C code -xzf in/code.tgz
REV=$(python3 -c "import json;print(json.load(open('in/job.json'))['revision'])")
RANGE=$(python3 -c "import json;print(json.load(open('in/job.json'))['shard_range'])")
THREADS=$(python3 -c "import json;print(json.load(open('in/job.json')).get('threads', 48))")
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch
   --with pyarrow --with pillow --with imagehash --with numpy<2.3 --with huggingface_hub python3 -u"
# the model at the pinned revision, then offline (refs/main → that commit)
$E -c "
from huggingface_hub import snapshot_download; import os
p = snapshot_download('imageomics/bioclip-2.5-vith14', revision='$REV')
d = os.path.dirname(os.path.dirname(p)); os.makedirs(d + '/refs', exist_ok=True)
open(d + '/refs/main', 'w').write('$REV'); print('model', p)" || exit 3
export HF_HUB_OFFLINE=1
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
$E code/embed_extra.py vm-embed --bucket local --todo in/todo.parquet --work /work \
   --shard-range "$RANGE" --threads "$THREADS" --batch 128
"""


def run_job():
    with LOCK:
        STATE["state"] = "running"
    with open(os.path.join(W, "job.log"), "ab") as log:
        rc = subprocess.call(["bash", "-c", JOB], stdout=log, stderr=subprocess.STDOUT)
    with LOCK:
        STATE["state"], STATE["rc"] = ("done" if rc == 0 else "failed"), rc


def sha(name):
    p = os.path.join(EMB, name)
    st = os.stat(p)
    key = (name, st.st_size, st.st_mtime)
    if key not in SHA:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        SHA[key] = h.hexdigest()
    return [st.st_size, SHA[key]]


class H(http.server.BaseHTTPRequestHandler):
    def ok(self):
        t = self.headers.get("X-Token", "")
        if not hmac.compare_digest(t.encode(), TOKEN.encode()):
            self.send_error(403)
            return False
        return True

    def reply(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        if not self.ok():
            return
        m = re.fullmatch(r"/in/(code\.tgz|todo\.parquet|job\.json)", self.path)
        if not m:
            return self.send_error(404)
        n = int(self.headers.get("Content-Length", "0"))
        if n > 200 * 2 ** 20:
            return self.send_error(413)
        data = self.rfile.read(n)
        p = os.path.join(IN, m.group(1))
        with open(p + ".part", "wb") as f:
            f.write(data)
        os.replace(p + ".part", p)
        self.reply(200, {"stored": m.group(1), "bytes": n, "sha256": hashlib.sha256(data).hexdigest()})

    def do_POST(self):
        if not self.ok():
            return
        if self.path != "/go":
            return self.send_error(404)
        with LOCK:
            if STATE["state"] not in ("waiting for inputs", "failed"):
                return self.reply(409, STATE)
            if not all(os.path.exists(os.path.join(IN, n)) for n in ("code.tgz", "todo.parquet", "job.json")):
                return self.reply(400, {"error": "inputs missing"})
            STATE["state"] = "starting"
        threading.Thread(target=run_job, daemon=True).start()
        self.reply(200, STATE)

    def do_GET(self):
        if not self.ok():
            return
        if self.path == "/status":
            try:
                tail = open(os.path.join(W, "job.log"), "rb").read()[-3000:].decode("utf-8", "replace")
            except OSError:
                tail = ""
            n = len([f for f in os.listdir(EMB) if f.endswith(".npz")])
            with LOCK:
                return self.reply(200, {**STATE, "shards": n, "log": tail})
        if self.path == "/manifest":
            return self.reply(200, {f: sha(f) for f in sorted(os.listdir(EMB)) if re.fullmatch(r"shard-\d{4,}\.npz", f)})
        m = re.fullmatch(r"/emb/(shard-\d{4,}\.npz)", self.path)
        if m and os.path.exists(os.path.join(EMB, m.group(1))):
            with open(os.path.join(EMB, m.group(1)), "rb") as f:
                return self.reply(200, f.read(), "application/octet-stream")
        self.send_error(404)

    def log_message(self, *a):
        pass


# ---- spend cap ON THE POD (never depend on the Mac session staying alive; 2026-11-07:
# a finished pod idled 4.5 h when the driving session restarted). The pod removes
# ITSELF (RunPod's pod-scoped RUNPOD_API_KEY + RUNPOD_POD_ID, injected into every pod):
#   * IZZY_MAX_H hours after boot (env, default 3.0), whatever the state;
#   * IZZY_GRACE_MIN minutes after the job ended (default 45) — time for the Mac to
#     pull; unpulled outputs are lost (a re-run costs ~$1), idle billing never runs on;
#   * IZZY_IDLE_MIN minutes after boot if no job was ever started (default 60).
# Removal = terminate (no stopped-pod volume billing).
import time as _time
import urllib.request as _ur
_BOOT = _time.time()
_DONE_AT = [None]


def _self_remove(why):
    pid, key = os.environ.get("RUNPOD_POD_ID"), os.environ.get("RUNPOD_API_KEY")
    with open(os.path.join(W, "job.log"), "a") as f:
        f.write(f"\nwatchdog: removing this pod ({why})\n")
    try:
        subprocess.run(["runpodctl", "remove", "pod", pid], timeout=60, check=True)
        return
    except Exception as e:  # noqa: BLE001 — fall back to the REST API
        err = str(e)
    try:
        req = _ur.Request(f"https://rest.runpod.io/v1/pods/{pid}", method="DELETE",
                          headers={"Authorization": f"Bearer {key}"})
        _ur.urlopen(req, timeout=60).read()
    except Exception as e2:  # noqa: BLE001
        with open(os.path.join(W, "job.log"), "a") as f:
            f.write(f"watchdog: removal FAILED ({err}; {e2}) — stopping the container\n")
        os.kill(1, 15)  # last resort: end PID 1 (the container exits)


def _watchdog():
    max_h = float(os.environ.get("IZZY_MAX_H", "3.0"))
    grace = 60 * float(os.environ.get("IZZY_GRACE_MIN", "45"))
    idle = 60 * float(os.environ.get("IZZY_IDLE_MIN", "60"))
    while True:
        _time.sleep(30)
        now = _time.time()
        with LOCK:
            st = STATE["state"]
        if st in ("done", "failed") and _DONE_AT[0] is None:
            _DONE_AT[0] = now
        if now - _BOOT > max_h * 3600:
            return _self_remove(f"max runtime {max_h} h")
        if _DONE_AT[0] is not None and now - _DONE_AT[0] > grace:
            return _self_remove(f"job {st} {grace / 60:.0f} min ago")
        if st == "waiting for inputs" and now - _BOOT > idle:
            return _self_remove(f"no job started within {idle / 60:.0f} min")


threading.Thread(target=_watchdog, daemon=True).start()

http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()

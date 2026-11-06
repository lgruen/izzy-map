#!/usr/bin/env python3
"""Runs INSIDE a RunPod pod for the encoder fine-tuning pilot (started by
finetune/ft_runpod.py; stdlib only, passed in base64 through the pod's env —
stock RunPod PyTorch image). Same pattern as cloud/runpod_pod.py: the pod gets
NO cloud credentials; the Mac uploads the inputs and downloads the outputs.

Server on 0.0.0.0:8000 (RunPod HTTPS proxy), every request needs header
`X-Token: $IZZY_TOKEN` (random, one per pod):
  PUT  /in/<name>        code.tgz, todo.parquet, job.json, classes.json, mu.npy,
                         tmean.npy, text_sub.npy, photos-NN.tar (≤ 100 MB each)
  POST /go               start the job once
  GET  /status           state, rc, log tail
  GET  /manifest         {out file: [bytes, sha256]} (finished files only)
  GET  /out/<file>       one output file (read-only)
Job: uv → torch 2.7 / torchvision 0.22 / open_clip → BioCLIP 2.5 at the pinned
revision → ft_train.py (outputs in /work/out).
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
OUT = os.path.join(W, "out")
TOKEN = os.environ["IZZY_TOKEN"]
os.makedirs(IN, exist_ok=True)
os.makedirs(OUT, exist_ok=True)
STATE = {"state": "waiting for inputs", "rc": None}
SHA = {}
LOCK = threading.Lock()
NAMES = r"(code\.tgz|todo\.parquet|job\.json|classes\.json|mu\.npy|tmean\.npy|text_sub\.npy|photos-\d{2}\.tar)"
NEED = ("code.tgz", "todo.parquet", "job.json", "classes.json", "mu.npy", "tmean.npy", "text_sub.npy")

JOB = r"""
set -uo pipefail
cd /work
export HOME=/root PATH=/root/.local/bin:$PATH
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
rm -rf code && mkdir code && tar -C code -xzf in/code.tgz
REV=$(python3 -c "import json;print(json.load(open('in/job.json'))['revision'])")
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch
   --with pyarrow --with pillow --with numpy<2.3 --with huggingface_hub python3 -u"
$E -c "
from huggingface_hub import snapshot_download; import os
p = snapshot_download('imageomics/bioclip-2.5-vith14', revision='$REV')
d = os.path.dirname(os.path.dirname(p)); os.makedirs(d + '/refs', exist_ok=True)
open(d + '/refs/main', 'w').write('$REV'); print('model', p)" || exit 3
export HF_HUB_OFFLINE=1
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
nproc; free -g | head -2; df -h /work | tail -1
$E code/ft_train.py --job in/job.json --inp in --out out --photos /work/photos
"""


def run_job():
    with LOCK:
        STATE["state"] = "running"
    with open(os.path.join(W, "job.log"), "ab") as log:
        rc = subprocess.call(["bash", "-c", JOB], stdout=log, stderr=subprocess.STDOUT)
    with LOCK:
        STATE["state"], STATE["rc"] = ("done" if rc == 0 else "failed"), rc


def sha(name):
    p = os.path.join(OUT, name)
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
        m = re.fullmatch(r"/in/" + NAMES, self.path)
        if not m:
            return self.send_error(404)
        n = int(self.headers.get("Content-Length", "0"))
        if n > 100 * 2 ** 20:
            return self.send_error(413)
        p = os.path.join(IN, m.group(1))
        h = hashlib.sha256()
        with open(p + ".part", "wb") as f:
            left = n
            while left:
                b = self.rfile.read(min(left, 1 << 20))
                if not b:
                    break
                f.write(b)
                h.update(b)
                left -= len(b)
        if left:
            return self.send_error(400)
        os.replace(p + ".part", p)
        self.reply(200, {"stored": m.group(1), "bytes": n, "sha256": h.hexdigest()})

    def do_POST(self):
        if not self.ok():
            return
        if self.path != "/go":
            return self.send_error(404)
        with LOCK:
            if STATE["state"] not in ("waiting for inputs", "failed"):
                return self.reply(409, STATE)
            if not all(os.path.exists(os.path.join(IN, n)) for n in NEED):
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
            with LOCK:
                return self.reply(200, {**STATE, "log": tail})
        if self.path == "/manifest":
            return self.reply(200, {f: sha(f) for f in sorted(os.listdir(OUT))
                                    if re.fullmatch(r"[a-z]+(-\d+)?\.(npz|json)", f)})
        m = re.fullmatch(r"/out/([a-z]+(-\d+)?\.(npz|json))", self.path)
        if m and os.path.exists(os.path.join(OUT, m.group(1))):
            with open(os.path.join(OUT, m.group(1)), "rb") as f:
                return self.reply(200, f.read(), "application/octet-stream")
        self.send_error(404)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()

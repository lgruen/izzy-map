#!/usr/bin/env python3
"""Embed the extra training photos (expand_inat.py lists) on the cloud VM AND
hash them there (dedup.py stage 1 on the same bytes), so millions of photos
never have to pass through the laptop. A copy of train_australia.py's
vm-embed (that file belongs to another agent) plus `phash`/`dhash` per row in
every shard npz (uint64, same `dedup.hashes` as the laptop).

  vm-embed --bucket gs://…/au/extra-N|local --todo todo.parquet --work /opt/izzy
           [--shards N] [--shard-range lo:hi] [--threads 48] [--batch 128]
  (--bucket local: no gcloud at all — shards stay in work/emb/, resume from
  there; used on RunPod, whose pods get no cloud credentials)

VM env: as train_australia.py + --with imagehash (cloud/vm_extra.sh).
"""
import argparse
import http.client
import json
import os
import queue
import subprocess
import sys
import threading
import time

import numpy as np
import pyarrow.parquet as pq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dedup  # noqa: E402

SHARD = 1000
HOST = "inaturalist-open-data.s3.amazonaws.com"
UA = {"User-Agent": "izzymap-plantid-eval/1"}
MAGIC = dedup.MAGIC
HF = "hf-hub:imageomics/bioclip-2.5-vith14"


def gs(*args, check=True):
    return subprocess.run(["gcloud", "storage", *args, "--quiet"], check=check, capture_output=True, text=True)


def cmd_vm_embed(a):
    import open_clip
    import torch
    from PIL import Image
    bucket = a.bucket.rstrip("/")
    T = pq.read_table(a.todo).to_pydict()
    ids, exts = T["photo_id"], T["ext"]
    nsh = -(-len(ids) // SHARD)
    out = os.path.join(a.work, "emb")
    os.makedirs(out, exist_ok=True)
    if bucket == "local":  # RunPod: no cloud credentials; shards stay in work/emb/, resume from there
        import glob
        done = {int(os.path.basename(f)[6:-4]) for f in glob.glob(os.path.join(a.work, "emb", "shard-*.npz"))}
    else:
        r = gs("ls", f"{bucket}/emb/", check=False)
        done = {int(os.path.basename(l)[6:-4]) for l in r.stdout.split() if l.endswith(".npz")}
    if a.shard_range:
        lo_, hi_ = map(int, a.shard_range.split(":"))
        nsh_keep = set(range(lo_, hi_))
    else:
        nsh_keep = None
    todo = [k for k in range(nsh) if k not in done and (nsh_keep is None or k in nsh_keep)]
    if a.shards:
        todo = todo[:a.shards]
    print(f"{nsh} shards, {len(done)} in GCS, {len(todo)} to do now", flush=True)
    if not todo:
        return
    model, _, tf = open_clip.create_model_and_transforms(HF)
    model = model.visual.to(a.device).half().eval()
    torch.backends.cudnn.benchmark = True

    items = queue.Queue()
    for k in todo:
        for i in range(k * SHARD, min((k + 1) * SHARD, len(ids))):
            items.put((k, ids[i], exts[i]))
    results = queue.Queue(maxsize=2048)
    stats = {"bytes": 0, "missing": 0, "failed": 0, "fetched": 0}
    hsh = {}  # photo_id → (pHash, dHash) of the same bytes (dedup stage 1, on the VM)
    lock = threading.Lock()

    def fetcher():
        conn = None
        while True:
            try:
                k, pid, ext = items.get_nowait()
            except queue.Empty:
                return
            x, why = None, "failed"
            for attempt in range(5):
                try:
                    if conn is None:
                        conn = http.client.HTTPSConnection(HOST, timeout=30)
                    conn.request("GET", f"/photos/{pid}/medium.{ext}", headers=UA)
                    resp = conn.getresponse()
                    body = resp.read()
                    if resp.status == 200 and body.startswith(MAGIC):
                        import io
                        with Image.open(io.BytesIO(body)) as im:
                            x = tf(im.convert("RGB"))
                        hh = dedup.hashes(body)
                        with lock:
                            hsh[pid] = (hh["phash"], hh["dhash"])
                        with lock:
                            stats["bytes"] += len(body)
                            stats["fetched"] += 1
                    elif resp.status in (403, 404):
                        why = "missing"
                    else:
                        raise IOError(f"HTTP {resp.status}")
                    break
                except Exception:
                    conn = None
                    time.sleep(1 + 2 * attempt)
            if x is None:
                with lock:
                    stats[why] += 1
            results.put((k, pid, x, why))

    ths = [threading.Thread(target=fetcher, daemon=True) for _ in range(a.threads)]
    for t in ths:
        t.start()
    need = {k: min((k + 1) * SHARD, len(ids)) - k * SHARD for k in todo}
    buf = {k: {"id": [], "emb": [], "missing": []} for k in todo}
    uploads = []
    t0, last, n_emb, n_sh = time.time(), time.time(), 0, 0

    def finish(k):
        nonlocal n_sh
        b = buf.pop(k)
        p = os.path.join(out, f"shard-{k:04d}.npz")
        with lock:
            hh = [hsh.pop(q, (0, 0)) for q in b["id"]]
        with open(p + ".part", "wb") as f:
            np.savez(f, photo_id=np.array(b["id"], np.int64),
                     emb=(np.concatenate(b["emb"]) if b["emb"] else np.zeros((0, 1024))).astype(np.float16),
                     missing=np.array(b["missing"], np.int64),
                     phash=np.array([h[0] for h in hh], np.uint64),
                     dhash=np.array([h[1] for h in hh], np.uint64))
        os.replace(p + ".part", p)
        if bucket != "local":
          uploads.append(subprocess.Popen(["gcloud", "storage", "cp", p, f"{bucket}/emb/", "--quiet"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        n_sh += 1

    pend_k, pend_id, pend_x = [], [], []

    def run_batch():
        nonlocal n_emb
        with torch.inference_mode():
            e = model(torch.stack(pend_x).to(a.device, torch.float16))
            e = torch.nn.functional.normalize(e.float(), dim=-1).cpu().numpy()
        for j, (k, pid) in enumerate(zip(pend_k, pend_id)):
            buf[k]["id"].append(pid)
            buf[k]["emb"].append(e[j:j + 1])
            need[k] -= 1
            if need[k] == 0:
                finish(k)
        n_emb += len(pend_x)
        pend_k.clear(), pend_id.clear(), pend_x.clear()

    left = sum(need.values())
    while left:
        k, pid, x, why = results.get()
        left -= 1
        if x is None:
            buf[k]["missing"].append(pid)
            need[k] -= 1
            if need[k] == 0 and not any(kk == k for kk in pend_k):
                finish(k)
            continue
        pend_k.append(k), pend_id.append(pid), pend_x.append(x)
        if len(pend_x) >= a.batch or left == 0:
            run_batch()
        if time.time() - last > 30:
            last = time.time()
            dt = last - t0
            print(f"  {n_emb:,} embedded ({n_emb / dt:.1f}/s), {stats['fetched'] / dt:.1f} fetched/s "
                  f"{stats['bytes'] / dt / 1e6:.1f} MB/s, missing {stats['missing']} failed "
                  f"{stats['failed']}, shards {n_sh}/{len(todo)}, queue {results.qsize()}", flush=True)
            uploads[:] = [u for u in uploads if u.poll() is None]
    if pend_x:
        run_batch()
    for k in list(buf):  # a shard whose last item was a miss after its batch
        if need[k] == 0:
            finish(k)
    for u in uploads:
        u.wait()
    bad = [u for u in uploads if u.returncode]
    dt = time.time() - t0
    s = {"shards": n_sh, "embedded": n_emb, "seconds": round(dt), "photos_per_s": round(n_emb / dt, 1),
         "mb_per_s": round(stats["bytes"] / dt / 1e6, 1), "missing": stats["missing"],
         "failed": stats["failed"], "upload_errors": len(bad),
         "gpu": torch.cuda.get_device_name(0) if a.device == "cuda" else a.device, "threads": a.threads, "batch": a.batch}
    print(json.dumps(s), flush=True)
    p = os.path.join(a.work, f"embed-run-{time.strftime('%Y%m%d-%H%M%S')}.json")
    json.dump(s, open(p, "w"))
    if bucket != "local":
        gs("cp", p, f"{bucket}/log/", check=False)
    assert not bad, "some shard uploads failed — rerun (they will be redone)"



def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("vm-embed")
    p.add_argument("--bucket", required=True)
    p.add_argument("--todo", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--shards", type=int, default=0)
    p.add_argument("--threads", type=int, default=48)
    p.add_argument("--batch", type=int, default=128)
    p.add_argument("--device", default="cuda")
    p.add_argument("--shard-range", default="", help="lo:hi — only shards lo … hi-1 (one pod's slice)")
    a = ap.parse_args()
    cmd_vm_embed(a)


if __name__ == "__main__":
    main()

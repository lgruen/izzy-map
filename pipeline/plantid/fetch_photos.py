#!/usr/bin/env python3
"""Plant-ID evaluation, step 2: fetch the train/val/test photos (500 px
"medium") from the iNaturalist Open Dataset bucket into
pipeline/cache/plantid/photos/<photo_id>.<ext>.

Resumable (existing files are skipped), one keep-alive HTTPS connection per
worker (see CLAUDE.md: urllib's per-request TLS handshake caps throughput),
image-magic checked. Photos never leave the cache (gitignored) — they are
licensed per photo; only the trained head + a credits list would ship.
The extension is case-sensitive in the bucket (".JPG" ≠ ".jpg").
"""
import argparse
import http.client
import json
import os
import queue
import threading
import time

import duckdb

HOST = "inaturalist-open-data.s3.amazonaws.com"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache", "plantid")
MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"GIF8", b"RIFF")


def worker(q, out, stats, lock):
    conn = None
    while True:
        item = q.get()
        if item is None:
            return
        pid, ext = item
        path = os.path.join(out, f"{pid}.{ext}")
        for attempt in range(4):
            try:
                if conn is None:
                    conn = http.client.HTTPSConnection(HOST, timeout=30)
                conn.request("GET", f"/photos/{pid}/medium.{ext}")
                r = conn.getresponse()
                body = r.read()
                if r.status == 200 and body.startswith(MAGIC):
                    tmp = path + ".part"
                    with open(tmp, "wb") as f:
                        f.write(body)
                    os.replace(tmp, path)
                    key, n = "ok", len(body)
                elif r.status in (403, 404):
                    key, n = "missing", 0  # deleted / moved since the snapshot
                else:
                    raise IOError(f"HTTP {r.status}")
                break
            except Exception:
                conn = None
                time.sleep(1 + 2 * attempt)
        else:
            key, n = "failed", 0
        with lock:
            stats[key] += 1
            stats["bytes"] += n
            if key != "ok":
                stats["bad"].append(pid)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sets", default=os.path.join(CACHE, "sets"))
    ap.add_argument("--out", default=os.path.join(CACHE, "photos"))
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--limit", type=int, help="fetch at most N (timing runs)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rows = duckdb.sql(f"""
        SELECT DISTINCT photo_id, ext FROM (
            SELECT photo_id, ext FROM '{a.sets}/train.parquet'
            UNION ALL SELECT photo_id, ext FROM '{a.sets}/test.parquet')
        ORDER BY photo_id""").fetchall()
    todo = [(p, e) for p, e in rows if not os.path.exists(os.path.join(a.out, f"{p}.{e}"))]
    if a.limit:
        todo = todo[:a.limit]
    print(f"{len(rows):,} photos in the sets, {len(todo):,} to fetch")
    q = queue.Queue(maxsize=a.workers * 4)
    stats = {"ok": 0, "missing": 0, "failed": 0, "bytes": 0, "bad": []}
    lock = threading.Lock()
    ts = [threading.Thread(target=worker, args=(q, a.out, stats, lock), daemon=True)
          for _ in range(a.workers)]
    for t in ts:
        t.start()
    t0 = last = time.time()
    for i, item in enumerate(todo):
        q.put(item)
        if time.time() - last > 15:
            last = time.time()
            dt = last - t0
            print(f"  {i:,}/{len(todo):,}  {stats['ok'] / dt:.0f} photos/s  "
                  f"{stats['bytes'] / dt / 1e6:.1f} MB/s  missing {stats['missing']} "
                  f"failed {stats['failed']}", flush=True)
    for _ in ts:
        q.put(None)
    for t in ts:
        t.join()
    dt = max(time.time() - t0, 1e-9)
    print(f"done in {dt:.0f} s: {stats['ok']:,} ok ({stats['bytes'] / 1e6:.0f} MB, "
          f"{stats['ok'] / dt:.0f}/s), {stats['missing']} missing, {stats['failed']} failed")
    bad_path = os.path.join(a.out, "_unavailable.json")
    prev = json.load(open(bad_path)) if os.path.exists(bad_path) else []
    json.dump(sorted(set(prev) | set(stats["bad"])), open(bad_path, "w"))


if __name__ == "__main__":
    main()

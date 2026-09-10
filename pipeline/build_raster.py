#!/usr/bin/env python3
"""Build offline raster packs (PMTiles) from LIST ArcGIS cached tile services.

Packs are declared in packs.json (key, service, file, ext, maxzoom, prune,
attribution, optional season/note/licence_override); the bbox comes from
regions.json (packs.json "region"). Every tile is stored byte-for-byte as
served — the archive is a verbatim collection (see docs/LICENSING.md).

Usage:
    python3 build_raster.py --pack aerial2024 [--pack ...]   # build packs
    python3 build_raster.py --all                            # every pack (incl. topo)
    python3 build_raster.py --estimate [--pack ...]          # candidate counts, no fetch
    python3 build_raster.py --measure 2000 --pack aerial     # time N uncached z14 tiles
    python3 build_raster.py --pack aerial2026 --fresh        # wipe cache/aerial2026 first
                                                             # (refresh an in-progress season)
    python3 build_raster.py --no-validate --pack ...         # skip the prune spot-check
    python3 build_raster.py --check-footprints --pack aerial2020  # LIST mosaic-index cross-check

Licence guard: the service's live copyrightText must name a Creative Commons
BY licence, or the pack must carry a licence_override whose recorded_text
equals the live text EXACTLY — any edit by LIST aborts the build so it gets
re-verified. The live text is written into the archive metadata.

Politeness/robustness:
  - tiles cached on disk in cache/<key>/{z}/{y}/{x}.<ext>: reruns are free,
    interrupted runs resume; HTTP 404 is cached as an empty marker file
    (--fresh drops them — that is how a growing season gets re-checked)
  - 8 concurrent requests, 3 retries with backoff, 30 s timeout
  - prune "blank@Z": from zoom Z down, a tile is blank if it 404s or is
    byte-identical to a sentinel — a tile seen >= SENTINEL_MIN times at one
    level (the constant ocean JPEG, the transparent no-imagery PNG). Blank
    tiles are not stored and their descendants are never requested.
    Validated 2026-09-10: 60/60 z15 descendants of empty z12 season parents
    were 404. prune "size<N@Z" is the legacy topo rule, kept verbatim so the
    shipped topo archive stays reproducible.
NOTE: ArcGIS tile path is /tile/{z}/{y}/{x} — row (y) BEFORE column (x).

Stdlib only (urllib + sqlite3 + concurrent.futures).
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import math
import os
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

HOST = "services.thelist.tas.gov.au"
ROOT = f"https://{HOST}/arcgis/rest/services/Basemaps"
HERE = Path(__file__).parent
CACHE = HERE / "cache"
WORK = HERE / "work"
DATA = HERE.parent / "data"
CONCURRENCY = 8
RETRIES = 3
TIMEOUT = 30
SENTINEL_MIN = 8  # identical-byte tiles at one level -> blank sentinel
UA = {"User-Agent": "IzzyMap-pipeline/1.0 (personal use)"}


def licence_re(licence):
    """Regex for ONE Creative Commons flavour, e.g. 'CC BY 3.0 AU' or
    'CC BY-NC-ND 3.0 AU' — BY must not match BY-NC-ND and vice versa."""
    token = licence.split()[1]  # BY | BY-NC-ND | BY-SA ...
    return re.compile(
        rf"creativecommons\.org/licenses/{re.escape(token.lower())}/|Creative Commons {re.escape(token)}(?![-\w])",
        re.I)


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    lat_r = math.radians(lat)
    y = int((1 - math.asinh(math.tan(lat_r)) / math.pi) / 2 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tiles_at(bbox, z):
    w, s, e, n = bbox
    x0, y0 = lonlat_to_tile(w, n, z)   # top-left
    x1, y1 = lonlat_to_tile(e, s, z)   # bottom-right
    return [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


def load_config():
    cfg = json.loads((HERE / "packs.json").read_text())
    regions = json.loads((HERE / "regions.json").read_text())
    region = next(r for r in regions["packs"] if r["id"] == cfg["region"])
    return cfg["packs"], region["bbox"]


def parse_prune(spec):
    """'size<1000@13' -> ('size', 1000, 13); 'blank@10' -> ('blank', None, 10)."""
    m = re.fullmatch(r"size<(\d+)@(\d+)", spec)
    if m:
        return "size", int(m.group(1)), int(m.group(2))
    m = re.fullmatch(r"blank@(\d+)", spec)
    if m:
        return "blank", None, int(m.group(1))
    raise SystemExit(f"bad prune spec: {spec}")


def http_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def check_licence(pack):
    """Return the live copyrightText or abort. See docs/LICENSING.md.

    Order matters: a recorded licence_override is compared FIRST, so any
    change of the live text (a badge appearing, or something restrictive)
    aborts for re-verification instead of slipping past a lenient match."""
    meta = http_json(f"{ROOT}/{pack['service']}/MapServer?f=pjson")
    text = (meta.get("copyrightText") or "").strip()
    print(f"[{pack['key']}] live copyrightText: {text!r}")
    ov = pack.get("licence_override")
    if ov:
        if ov["recorded_text"].strip() != text:
            raise SystemExit(
                f"[{pack['key']}] REFUSING: copyrightText changed since the override was recorded "
                f"({ov['recorded_text']!r} -> {text!r}). Re-verify the licence, then update packs.json "
                "(delete the override if the live text now names the licence itself).")
        print(f"[{pack['key']}] licence_override in effect ({pack['licence']}): {ov['reason']}")
        return text
    if not licence_re(pack["licence"]).search(text):
        raise SystemExit(
            f"[{pack['key']}] REFUSING: copyrightText does not name {pack['licence']!r} "
            "(and packs.json has no licence_override for this pack).")
    return text


def is_image(data):
    return data.startswith(b"\xff\xd8") or data.startswith(b"\x89PNG")


class Fetcher:
    """One persistent HTTPS connection per worker thread. A fresh TLS
    handshake per tile (urllib) made the pull latency-bound: ~55 tiles/s at
    8 workers = 0.8 MB/s. Keep-alive removes the handshake from every
    request; a dropped connection is reopened and the request retried."""

    def __init__(self, pack):
        self.service = pack["service"]
        self.ext = pack["ext"]
        self.cache = CACHE / pack.get("cache", pack["key"])
        self._local = threading.local()

    def path(self, z, x, y):
        return self.cache / str(z) / str(y) / f"{x}.{self.ext}"

    def _conn(self):
        c = getattr(self._local, "conn", None)
        if c is None:
            c = http.client.HTTPSConnection(HOST, timeout=TIMEOUT)
            self._local.conn = c
        return c

    def _drop(self):
        c = getattr(self._local, "conn", None)
        if c is not None:
            try:
                c.close()
            except Exception:  # noqa: BLE001
                pass
        self._local.conn = None

    def fetch(self, z, x, y):
        """Tile bytes; b'' if absent (404); raise after repeated failure."""
        p = self.path(z, x, y)
        if p.exists():
            return p.read_bytes()  # b'' marker files mean 'known absent'
        err = None
        stale_retry = True  # one free retry: an idle keep-alive may have been closed
        attempt = 0
        while attempt < RETRIES:
            try:
                conn = self._conn()
                conn.request("GET", f"/arcgis/rest/services/Basemaps/{self.service}/MapServer/tile/{z}/{y}/{x}",
                             headers=UA)
                r = conn.getresponse()
                data = r.read()
                if r.status == 200 and is_image(data):
                    break
                if r.status == 404:
                    data = b""
                    break
                # 5xx, 429, or a 200 carrying an HTML/JSON error page: never
                # cache it, never let it become a "blank" sentinel — retry
                err = RuntimeError(f"HTTP {r.status}" if r.status != 200 else "200 with a non-image body")
                self._drop()
            except Exception as e:  # noqa: BLE001 — retry everything else
                err = e
                self._drop()
                if stale_retry:
                    stale_retry = False
                    continue
            attempt += 1
            time.sleep(1.5 * attempt)
        else:
            raise RuntimeError(f"tile {z}/{y}/{x} failed after {RETRIES} tries: {err}")
        p.parent.mkdir(parents=True, exist_ok=True)
        # atomic: a kill mid-write must not leave a 0-byte file that reads as
        # a permanent "known absent" marker (and prunes the whole subtree)
        tmp = p.with_suffix(p.suffix + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, p)
        return data


class Sentinels:
    """Byte-identical 'blank' tiles, persisted per pack across levels/runs."""

    def __init__(self, pack):
        self.dir = WORK / f"{pack['key']}_sentinels"
        self.ext = pack["ext"]
        self.hashes = set()
        if self.dir.exists():
            for f in self.dir.iterdir():
                self.hashes.add(hashlib.sha1(f.read_bytes()).hexdigest())

    def learn(self, h, data):
        self.dir.mkdir(parents=True, exist_ok=True)
        (self.dir / f"{h}.{self.ext}").write_bytes(data)
        self.hashes.add(h)
        print(f"  sentinel learned: {h[:12]} ({len(data)} bytes)", flush=True)


def build_pack(pack, bbox, validate=True):
    key = pack["key"]
    zmin, zmax = 0, pack["maxzoom"]
    mode, threshold, prune_from = parse_prune(pack["prune"])
    copyright_text = check_licence(pack)
    fetcher = Fetcher(pack)
    sentinels = Sentinels(pack) if mode == "blank" else None
    print(f"[{key}] {pack['service']}: z{zmin}-{zmax}, prune={pack['prune']}, cache={fetcher.cache}")

    WORK.mkdir(exist_ok=True)
    mbt = WORK / f"{key}.mbtiles"
    mbt.unlink(missing_ok=True)
    db = sqlite3.connect(mbt)
    db.executescript(
        """
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER,
                            tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles
            (zoom_level, tile_column, tile_row);
        """
    )
    w, s, e, n = bbox
    meta = {
        "name": f"IzzyMap {pack['label']} — Tasmania",
        "format": pack["ext"],
        "type": "baselayer",
        "version": "1",
        "minzoom": str(zmin),
        "maxzoom": str(zmax),
        "bounds": f"{w},{s},{e},{n}",
        "attribution": pack["attribution"],
        "copyright_text": copyright_text,
        "service": f"{ROOT}/{pack['service']}/MapServer",
        "built": time.strftime("%Y-%m-%d"),
        "key": key,
    }
    for k in ("season", "note"):
        if pack.get(k):
            meta[k] = pack[k]
    for k, v in meta.items():
        db.execute("INSERT INTO metadata VALUES (?,?)", (k, v))

    t0 = time.time()
    done = absent = blank_dropped = pruned_total = stored = 0
    total_bytes = 0
    kept_parents = None
    kept_prev = set()
    pruned_last = []
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        for z in range(zmin, zmax + 1):
            candidates = tiles_at(bbox, z)
            if z >= prune_from and kept_parents is not None:
                before = len(candidates)
                kept_c = [t for t in candidates if (t[1] // 2, t[2] // 2) in kept_parents]
                pruned_last = [t for t in candidates if (t[1] // 2, t[2] // 2) not in kept_parents]
                candidates = kept_c
                pruned_total += before - len(candidates)
            recs = []  # (x, y, sha1-or-None, size)
            futs = {pool.submit(fetcher.fetch, z, x, y): (z, x, y) for z, x, y in candidates}
            for fut in concurrent.futures.as_completed(futs):
                tz, x, y = futs[fut]
                try:
                    data = fut.result()
                except Exception:
                    # an outage must not turn into hours of retries against a
                    # struggling server: drop everything still queued and stop
                    for f in futs:
                        f.cancel()
                    raise
                done += 1
                if not data:
                    absent += 1
                    recs.append((x, y, None, 0))
                    continue
                h = hashlib.sha1(data).hexdigest() if mode == "blank" else None
                recs.append((x, y, h, len(data)))
                total_bytes += len(data)
                tms_y = (2 ** tz) - 1 - y  # MBTiles uses TMS row order
                db.execute("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)",
                           (tz, x, tms_y, sqlite3.Binary(data)))
                if done % 2000 == 0:
                    rate = done / (time.time() - t0)
                    print(f"  z{tz}: {done} tiles, {total_bytes/1e6:.0f} MB, "
                          f"{rate:.0f} tiles/s", flush=True)
            if mode == "blank":
                counts = Counter(h for _, _, h, _ in recs if h)
                for h, c in counts.items():
                    if c >= SENTINEL_MIN and h not in sentinels.hashes:
                        x, y = next((x, y) for x, y, hh, _ in recs if hh == h)
                        row = db.execute("SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                                         (z, x, (2 ** z) - 1 - y)).fetchone()
                        sentinels.learn(h, bytes(row[0]))
                kept = set()
                for x, y, h, size in recs:
                    if h is None:
                        continue
                    if h in sentinels.hashes:
                        db.execute("DELETE FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
                                   (z, x, (2 ** z) - 1 - y))
                        blank_dropped += 1
                        total_bytes -= size
                    else:
                        kept.add((x, y))
            else:
                kept = {(x, y) for x, y, _, size in recs if size >= threshold}
            db.commit()
            kept_prev = kept_parents or set()
            kept_parents = kept
            level_stored = db.execute("SELECT count(*) FROM tiles WHERE zoom_level=?", (z,)).fetchone()[0]
            stored += level_stored
            print(f"  z{z} done: {len(candidates)} fetched, {len(kept)} with content, {level_stored} stored",
                  flush=True)
    print(f"  pruned {pruned_total} descendants of blank/ocean tiles; "
          f"{absent} absent (404), {blank_dropped} sentinel-blank dropped")
    db.close()

    if validate and mode == "blank" and pruned_last:
        # Spot-check the prune assumption on THIS service BEFORE anything is
        # written to data/: children of blank parents at maxzoom must
        # themselves be blank. Uniform samples from ~330k pruned tiles are
        # mostly deep ocean, so 30 of the 40 come from pruned tiles whose
        # parent touches a kept parent — the project edges, where a wrong
        # prune would actually bite.
        edge = [t for t in pruned_last if any(
            (t[1] // 2 + dx, t[2] // 2 + dy) in kept_prev for dx in (-1, 0, 1) for dy in (-1, 0, 1))]
        random.seed(0)
        sample = random.sample(edge, min(30, len(edge))) + random.sample(pruned_last, min(10, len(pruned_last)))
        bad = []
        for z, x, y in sample:
            data = fetcher.fetch(z, x, y)
            if data and hashlib.sha1(data).hexdigest() not in sentinels.hashes:
                bad.append((z, y, x, len(data)))
        if bad:
            mbt.unlink(missing_ok=True)
            print(f"[{key}] VALIDATION FAILED: {len(bad)}/{len(sample)} pruned z{zmax} tiles have content: "
                  f"{bad[:5]} — the prune rule is unsafe for this service; nothing written. Investigate.")
            sys.exit(1)
        print(f"[{key}] validation: {len(sample)}/{len(sample)} pruned z{zmax} tiles confirmed blank "
              f"({min(30, len(edge))} at project edges)")

    DATA.mkdir(exist_ok=True)
    out = DATA / pack["file"]
    subprocess.run(["pmtiles", "convert", str(mbt), str(out)], check=True)
    mbt.unlink()
    size = out.stat().st_size
    print(f"[{key}] done: {stored} tiles stored, {size/1e6:.1f} MB -> {out.name}, "
          f"{time.time()-t0:.0f}s, licence: {copyright_text!r}")
    return size


def check_footprints(packs):
    """Cross-check a season pack against LIST's Digital Imagery Mosaic Index
    (Public/Indexes layer 100): the z15 tile at each project footprint's
    centroid must be in the tile cache with content, or be confirmed blank
    live. Catches a project pruned away wholesale (e.g. invisible at z9)."""
    import urllib.parse
    for pack in packs:
        if not pack.get("season"):
            print(f"[{pack['key']}] not a season pack — skipped")
            continue
        a, b = pack["season"].replace("\u2013", "-").split("-")
        cap = f"{a}-{a[:2]}{b}"  # '2019–20' -> '2019-2020'
        q = urllib.parse.urlencode({"where": f"CAP_SEASON='{cap}'", "outFields": "PROJ_NAME",
                                    "outSR": "4326", "f": "geojson", "resultRecordCount": "2000"})
        url = f"https://{HOST}/arcgis/rest/services/Public/Indexes/MapServer/100/query?{q}"
        feats = http_json(url).get("features", [])
        fetcher = Fetcher(pack)
        missing, blank_live, ok = [], [], 0
        for f in feats:
            g = f["geometry"]
            ring = g["coordinates"][0] if g["type"] == "Polygon" else g["coordinates"][0][0]
            lon = sum(c[0] for c in ring) / len(ring)
            lat = sum(c[1] for c in ring) / len(ring)
            x, y = lonlat_to_tile(lon, lat, pack["maxzoom"])
            p = fetcher.path(pack["maxzoom"], x, y)
            if p.exists() and p.stat().st_size > 0:
                ok += 1
                continue
            data = fetcher.fetch(pack["maxzoom"], x, y)  # never fetched (pruned) or absent
            if data and not any(data == s.read_bytes() for s in (WORK / f"{pack['key']}_sentinels").glob("*")):
                missing.append((f["properties"].get("PROJ_NAME"), pack["maxzoom"], y, x))
            else:
                blank_live.append(f["properties"].get("PROJ_NAME"))
        print(f"[{pack['key']}] {cap}: {len(feats)} footprints; {ok} centroid tiles in the pack, "
              f"{len(blank_live)} blank live (index entry without published imagery), "
              f"{len(missing)} PRUNED BUT HAVE IMAGERY: {missing[:8]}")
        if missing:
            sys.exit(1)


def estimate(packs, bbox):
    for pack in packs:
        counts = {z: len(tiles_at(bbox, z)) for z in range(0, pack["maxzoom"] + 1)}
        total = sum(counts.values())
        print(f"[{pack['key']}] {pack['service']}: z0-{pack['maxzoom']}, {total} candidate tiles pre-prune "
              f"(z13 {counts.get(13, 0)}, z14 {counts.get(14, 0)}, z15 {counts.get(15, 0)})")


def measure(packs, bbox, n):
    """Fetch n uncached z14 tiles for each pack and report tiles/s — run this
    BEFORE a full pull so the wall time is an extrapolation, not a hope."""
    for pack in packs:
        fetcher = Fetcher(pack)
        cands = [t for t in tiles_at(bbox, 14) if not fetcher.path(*t).exists()]
        random.seed(1)
        sample = random.sample(cands, min(n, len(cands)))
        t0 = time.time()
        sizes = []
        with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
            for data in pool.map(lambda t: fetcher.fetch(*t), sample):
                sizes.append(len(data))
        dt = time.time() - t0
        present = [s for s in sizes if s]
        pre = sum(len(tiles_at(bbox, z)) for z in range(0, pack["maxzoom"] + 1))
        print(f"[{pack['key']}] {len(sample)} tiles in {dt:.0f}s = {len(sample)/dt:.1f} tiles/s; "
              f"{len(present)}/{len(sample)} present, mean {sum(present)/max(1,len(present))/1e3:.1f} KB; "
              f"pre-prune candidates {pre} -> ~{pre/(len(sample)/dt)/3600:.1f} h worst case")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", action="append", default=[], help="pack key (repeatable)")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--estimate", action="store_true")
    ap.add_argument("--measure", type=int, metavar="N")
    ap.add_argument("--check-footprints", action="store_true",
                    help="season packs: verify every LIST mosaic-index project centroid survived pruning")
    ap.add_argument("--fresh", action="store_true", help="wipe the pack's tile cache + sentinels first")
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()
    packs, bbox = load_config()
    by_key = {p["key"]: p for p in packs}
    for k in args.pack:
        if k not in by_key:
            raise SystemExit(f"unknown pack {k!r}; known: {list(by_key)}")
    chosen = packs if args.all else [by_key[k] for k in args.pack]
    if not chosen:
        ap.error("give --pack <key> (repeatable) or --all")
    if args.estimate:
        estimate(chosen, bbox)
        return
    if args.measure:
        measure(chosen, bbox, args.measure)
        return
    if args.check_footprints:
        check_footprints(chosen)
        return
    for pack in chosen:
        if args.fresh:
            for d in (CACHE / pack.get("cache", pack["key"]), WORK / f"{pack['key']}_sentinels"):
                if d.exists():
                    print(f"[{pack['key']}] --fresh: removing {d}")
                    shutil.rmtree(d)
        build_pack(pack, bbox, validate=not args.no_validate)


if __name__ == "__main__":
    main()

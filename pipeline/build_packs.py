#!/usr/bin/env python3
"""Build the Apple-hosted Background Assets packs (docs/NATIVE_PLAN.md §2).

For every pack in pipeline/asset_packs.json: write a ba-package manifest
(data/packs/manifests/<id>.json) and run `xcrun ba-package` →
data/packs/<id>.aar. Stdlib only; needs Xcode 27 (ba-package 2.0, `aa`).

    python3 pipeline/build_packs.py                  # every pack whose inputs exist
    python3 pipeline/build_packs.py vector season-2021
    python3 pipeline/build_packs.py --verify all     # extract + hash every pack
    python3 pipeline/build_packs.py --data /Users/leo/izzy-map/data   # from a worktree
    python3 pipeline/build_packs.py plantid --verify plantid          # plant ID (milestone 6)

An .aar is an Apple Archive (pbz block compression). PMTiles are already
compressed tiles, so the archive is ~the size of its inputs (vector: +7 KB on
398 MB) and building is I/O-bound (~1 GB/s, 2026-11-03). Packaging never
touches the bytes: `--verify` extracts with `aa` and compares SHA-256 against
data/ — the CC BY-NC-ND imagery must stay byte-for-byte (LICENSING.md).
By default the smallest pack (`vector`) is verified in full and every pack's
entry sizes are checked against data/ from `aa list`.

`plantid` is staged first (`"stage": "plantid"`): its files come from
pipeline/cache/plantid/ship (build_ship.py), each SHA-256-checked against
ship/pipeline.json, hard-linked into <out>/stage-plantid/plantid/; the 8-bit
encoder .mlpackage is compiled to .mlmodelc there (`xcrun coremlcompiler
compile --platform iOS --deployment-target 26.0`, ~1 s: it re-encodes the
program, the 0.63 GB weight file is copied verbatim — checked). Shipping
the compiled model (what Xcode puts in app bundles) means no on-device
compile and no second 0.6 GB copy in Application Support.

`refphotos` is staged too (`"stage": "refphotos"`): build_refphotos_v2.py's
pack folder, checked against its index.json, hard-linked into
<out>/stage-refphotos/refphotos/ (where a DEBUG `-dataDir` run finds it).

A `files` entry ending in "/" is a directory (packed recursively); a file
listed inside it is packed with it (listed so the app can check for it).

Upload is a separate, LOCAL, approved step: pipeline/upload_packs.sh.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TABLE = REPO / "pipeline" / "asset_packs.json"
POLICIES = {"essential", "prefetch", "onDemand"}
SHIP = REPO / "pipeline" / "cache" / "plantid" / "ship"
REFPHOTOS = REPO / "pipeline" / "cache" / "plantid" / "refphotos" / "pack-v2" / "refphotos"
PLANTID_ENCODER = ("PlantEncoder-w8.mlpackage", "PlantEncoder-w8.mlmodelc")
ENV = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", "")}


def check_app_mirror(table: list[dict]) -> None:
    """The app mirrors the table by hand (Packs.swift + Archive.swift): fail
    loudly when they drift, or a pack would ship files the app never opens."""
    src = REPO / "ios" / "IzzyMap" / "Sources" / "Data"
    try:
        archive_swift = (src / "Archive.swift").read_text()
        packs_swift = (src / "Packs.swift").read_text()
    except FileNotFoundError:
        print("(no ios/ sources here: app mirror not checked)")
        return
    file_of = dict(re.findall(r'case \.(\w+): "([^"]+\.pmtiles)"', archive_swift))
    body = packs_swift[packs_swift.index("var archives: [Archive]"):]
    body = body[:body.index("\n    }\n")]
    raw = {name: name for name in re.findall(r"\bcase (\w+)\b", packs_swift.split("nonisolated enum Policy")[0])}
    for line in packs_swift.split("nonisolated enum Policy")[0].splitlines():
        for name, value in re.findall(r'(\w+) = "([\w-]+)"', line):
            raw[name] = value
    app = {}
    for name, archives in re.findall(r"case \.(\w+): \[([^\]]*)\]", body):
        app[raw.get(name, name)] = sorted(file_of[a] for a in re.findall(r"\.(\w+)", archives))
    # packs whose files aren't map archives: `enum <X>Files { … static let packPaths = [ … ] }`
    for enum_name, pack_id in (("PlantIDFiles", "plantid"), ("RefPhotoFiles", "refphotos")):
        block = re.search(rf"enum {enum_name} \{{(.*?)\n\}}", packs_swift, re.S)
        other = block and re.search(r"static let packPaths = \[(.*?)\]", block.group(1), re.S)
        if other:
            app[pack_id] = sorted(app.get(pack_id, []) + re.findall(r'"([^"]+)"', other.group(1)))
    want = {p["id"]: sorted(p["files"]) for p in table}
    if app != want:
        diff = {k: (want.get(k), app.get(k)) for k in set(app) | set(want) if want.get(k) != app.get(k)}
        sys.exit(f"asset_packs.json and ios/…/Packs.swift disagree (json, app): {diff}")


def manifest_for(pack: dict, source_root: Path, manifest_dir: Path) -> dict:
    policy = pack["policy"]
    if policy not in POLICIES:
        sys.exit(f"{pack['id']}: unknown policy {policy!r}")
    # essential/prefetch apply on first install AND on updates (a user who
    # updates from a build that lacked the pack gets it too); onDemand = {}
    body = {} if policy == "onDemand" else {"installationEventTypes": ["firstInstallation", "subsequentUpdate"]}
    return {
        "assetPackID": pack["id"],
        "downloadPolicy": {policy: body},
        # files at the pack root under their data/ names (one shared namespace)
        # a file inside a listed directory is packed with it (it is listed too
        # so the app can check it — Packs.swift `otherFiles`)
        "fileSelectors": [{"directorySource": f.rstrip("/"), "directoryDestination": f.rstrip("/")}
                          if f.endswith("/") else {"fileSource": f, "fileDestination": f}
                          for f in pack["files"]
                          if f.endswith("/") or not any(f.startswith(d) for d in pack["files"] if d.endswith("/"))],
        "platforms": ["iOS"],
        # relative to the manifest's own location (ba-package template)
        "sourceRoot": os.path.relpath(source_root, manifest_dir),
    }


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def archive_entries(aar: Path) -> dict[str, int]:
    """PAT → DAT size of the archive's regular files (`aa list -v`)."""
    out = subprocess.run(["aa", "list", "-v", "-i", str(aar)], env=ENV, check=True,
                         capture_output=True, text=True).stdout
    entries = {}
    for line in out.splitlines():
        m = re.match(r"F PAT=(\S+) .*DAT\[(\d+)\]", line)
        if m:
            entries[m.group(1)] = int(m.group(2))
    return entries


def expand(pack: dict, root: Path) -> dict[str, Path]:
    """Pack path → source file for every regular file (directories walked)."""
    out = {}
    for f in pack["files"]:
        if f.endswith("/"):
            d = root / f.rstrip("/")
            for p in sorted(d.rglob("*")):
                if p.is_file():
                    out[str(p.relative_to(root))] = p
        else:
            out[f] = root / f
    return out


def present(pack: dict, root: Path) -> list[str]:
    """The pack's `files` entries missing under root."""
    return [f for f in pack["files"]
            if not ((root / f.rstrip("/")).is_dir() if f.endswith("/") else (root / f).is_file())]


def stage_plantid(out: Path, ship: Path) -> Path:
    """<out>/stage-plantid/plantid/: the ship/ tables (sha256 = pipeline.json)
    hard-linked, the encoder compiled. Returns the stage root."""
    root = out / "stage-plantid"
    dest = root / "plantid"
    dest.mkdir(parents=True, exist_ok=True)
    pipe = json.loads((ship / "pipeline.json").read_text())
    table = next(p for p in json.loads(TABLE.read_text())["packs"] if p["id"] == "plantid")
    for f in table["files"]:
        name = f.split("/", 1)[1]
        if name.endswith("/"):
            continue
        src, dst = ship / name, dest / name
        if not src.is_file():
            sys.exit(f"plantid: {src} missing (pipeline/plantid/build_ship.py data)")
        if name != "pipeline.json":
            want = pipe["files"].get(name)
            if not want or src.stat().st_size != want["bytes"] or sha256(src) != want["sha256"]:
                sys.exit(f"plantid: {name} doesn't match ship/pipeline.json (rebuild with build_ship.py data)")
        if not (dst.is_file() and os.path.samefile(src, dst)):
            dst.unlink(missing_ok=True)
            try:
                os.link(src, dst)
            except OSError:
                shutil.copy2(src, dst)
    pkg, compiled = PLANTID_ENCODER
    src = ship / "encoder" / pkg
    mlc = dest / compiled
    newest = max(p.stat().st_mtime for p in src.rglob("*") if p.is_file())
    if not mlc.is_dir() or (mlc / "coremldata.bin").stat().st_mtime < newest:
        t = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="mlc-", dir=root) as tmp:
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(src), tmp, "--platform", "iOS",
                            "--deployment-target", "26.0"], env=ENV, check=True, capture_output=True)
            if mlc.exists():
                shutil.rmtree(mlc)
            os.replace(Path(tmp) / compiled, mlc)
        print(f"    {compiled}: compiled in {time.monotonic() - t:.1f} s")
    # the weights must be the quantised ones, byte for byte
    w_src = next(src.rglob("weight.bin"))
    if sha256(w_src) != sha256(mlc / "weights" / "weight.bin"):
        sys.exit("plantid: the compiled model's weights differ from the .mlpackage's")
    return root


def stage_refphotos(out: Path, src: Path) -> Path:
    """<out>/stage-refphotos/refphotos/: build_refphotos_v2.py's pack folder
    hard-linked (dotfiles — its encode stamp — left out, stale files removed),
    after checking index.json against the files: every photo present with
    the byte count the index gives. Returns the stage root."""
    root = out / "stage-refphotos"
    dest = root / "refphotos"
    index = src / "index.json"
    if not index.is_file():
        sys.exit(f"refphotos: {index} missing (pipeline/plantid/build_refphotos_v2.py build)")
    ix = json.loads(index.read_text())
    photos = ix["photos"]
    if ix.get("count") != len(photos):
        sys.exit(f"refphotos: index.json count {ix.get('count')} != {len(photos)} photos")
    for name, p in photos.items():
        f = src / p["file"]
        if not f.is_file() or f.stat().st_size != p["bytes"]:
            sys.exit(f"refphotos: {name}: {f.name} missing or not {p['bytes']} bytes")
    want = {f.name for f in src.iterdir() if f.is_file() and not f.name.startswith(".")}
    if want != {p["file"] for p in photos.values()} | {"index.json", "credits.json"}:
        sys.exit("refphotos: the folder holds files index.json doesn't list (or lacks credits.json)")
    dest.mkdir(parents=True, exist_ok=True)
    for f in dest.iterdir():
        if f.name not in want:
            f.unlink()
    for name in want:
        a, b = src / name, dest / name
        if not (b.is_file() and os.path.samefile(a, b)):
            b.unlink(missing_ok=True)
            try:
                os.link(a, b)
            except OSError:
                shutil.copy2(a, b)
    print(f"    refphotos: {len(photos):,} photos staged ({sum(p['bytes'] for p in photos.values()) / 1e6:.0f} MB)")
    return root


def check_sizes(pack: dict, aar: Path, data: Path) -> None:
    entries = archive_entries(aar)
    want = {f"Contents/{f}": p.stat().st_size for f, p in expand(pack, data).items()}
    got = {k: v for k, v in entries.items() if k.startswith("Contents/")}
    if got != want:
        sys.exit(f"{pack['id']}: archive entries {got} != data/ {want}")
    if "Manifest.json" not in entries:
        sys.exit(f"{pack['id']}: archive has no Manifest.json")


def verify_hashes(pack: dict, aar: Path, data: Path) -> float:
    t = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=f"pack-{pack['id']}-", dir=aar.parent) as tmp:
        subprocess.run(["aa", "extract", "-i", str(aar), "-d", tmp], env=ENV, check=True)
        for f, src in expand(pack, data).items():
            a, b = sha256(Path(tmp) / "Contents" / f), sha256(src)
            if a != b:
                sys.exit(f"{pack['id']}: {f} differs after packaging ({a} vs {b})")
            print(f"    {f}: sha256 {a[:16]}… identical")
    return time.monotonic() - t


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("packs", nargs="*", help="pack ids (default: every pack whose files exist)")
    ap.add_argument("--data", type=Path, default=REPO / "data", help="directory holding the .pmtiles (default data/)")
    ap.add_argument("--out", type=Path, default=None, help="output directory (default <data>/packs)")
    ap.add_argument("--verify", default="vector", help="'all', 'none' or comma-separated ids to extract + hash")
    ap.add_argument("--force", action="store_true", help="rebuild even when the .aar is newer than its inputs")
    ap.add_argument("--plantid-ship", type=Path, default=SHIP,
                    help="build_ship.py output for the plantid pack (default pipeline/cache/plantid/ship)")
    ap.add_argument("--refphotos", type=Path, default=REFPHOTOS,
                    help="build_refphotos_v2.py's pack folder (default pipeline/cache/plantid/refphotos/pack-v2/refphotos)")
    args = ap.parse_args()

    data = args.data.resolve()
    out = (args.out or data / "packs").resolve()
    manifests = out / "manifests"
    manifests.mkdir(parents=True, exist_ok=True)

    table = json.loads(TABLE.read_text())["packs"]
    ids = [p["id"] for p in table]
    if len(set(ids)) != len(ids):
        sys.exit("duplicate pack id in asset_packs.json")
    names = [f for p in table for f in p["files"]]
    if len(set(names)) != len(names):
        sys.exit("a file is in two packs: the device merges every pack into ONE namespace")
    check_app_mirror(table)
    unknown = set(args.packs) - set(ids)
    if unknown:
        sys.exit(f"unknown pack(s): {sorted(unknown)}")
    verify = set(ids) if args.verify == "all" else set() if args.verify == "none" else set(args.verify.split(","))

    total_in = total_out = 0
    started = time.monotonic()
    for pack in table:
        pid = pack["id"]
        if args.packs and pid not in args.packs:
            continue
        if not pack["files"]:
            print(f"- {pid}: no files yet ({pack.get('_todo', 'empty')}) — skipped")
            continue
        root = data
        if pack.get("stage") == "plantid":
            if not (args.plantid_ship / "pipeline.json").is_file():
                print(f"- {pid}: no {args.plantid_ship}/pipeline.json (build_ship.py data) — skipped")
                continue
            root = stage_plantid(out, args.plantid_ship.resolve())
        elif pack.get("stage") == "refphotos":
            if not (args.refphotos / "index.json").is_file():
                print(f"- {pid}: no {args.refphotos}/index.json (build_refphotos_v2.py build) — skipped")
                continue
            root = stage_refphotos(out, args.refphotos.resolve())
        missing = present(pack, root)
        if missing:
            print(f"- {pid}: missing {missing} in {root} — skipped")
            continue

        manifest_path = manifests / f"{pid}.json"
        manifest = json.dumps(manifest_for(pack, root, manifests), indent=2) + "\n"
        aar = out / f"{pid}.aar"
        inputs = list(expand(pack, root).values())
        size_in = sum(p.stat().st_size for p in inputs)
        fresh = (aar.is_file() and manifest_path.is_file() and manifest_path.read_text() == manifest
                 and aar.stat().st_mtime > max(p.stat().st_mtime for p in inputs))
        t = time.monotonic()
        if fresh and not args.force:
            note = "up to date"
        else:
            manifest_path.write_text(manifest)
            subprocess.run(["xcrun", "ba-package", "evaluate", str(manifest_path)], env=ENV, check=True,
                           capture_output=True)
            aar.unlink(missing_ok=True)
            subprocess.run(["xcrun", "ba-package", "package", str(manifest_path), "--output-path", str(aar),
                            "--quiet"], env=ENV, check=True)
            note = f"built in {time.monotonic() - t:.1f} s"
        check_sizes(pack, aar, root)
        size_out = aar.stat().st_size
        total_in += size_in
        total_out += size_out
        print(f"- {pid} ({pack['policy']}): {size_in / 1e9:.3f} GB in → {size_out / 1e9:.3f} GB .aar"
              f" ({size_out - size_in:+,} B), {note}")
        if pid in verify:
            print(f"    verified byte-for-byte in {verify_hashes(pack, aar, root):.1f} s")

    print(f"total {total_in / 1e9:.2f} GB in → {total_out / 1e9:.2f} GB in {time.monotonic() - started:.0f} s; "
          f"output {out}")


if __name__ == "__main__":
    main()

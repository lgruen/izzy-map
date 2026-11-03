#!/usr/bin/env python3
"""Build the Apple-hosted Background Assets packs (docs/NATIVE_PLAN.md §2).

For every pack in pipeline/asset_packs.json: write a ba-package manifest
(data/packs/manifests/<id>.json) and run `xcrun ba-package` →
data/packs/<id>.aar. Stdlib only; needs Xcode 27 (ba-package 2.0, `aa`).

    python3 pipeline/build_packs.py                  # every pack whose inputs exist
    python3 pipeline/build_packs.py vector season-2021
    python3 pipeline/build_packs.py --verify all     # extract + hash every pack
    python3 pipeline/build_packs.py --data /Users/leo/izzy-map/data   # from a worktree

An .aar is an Apple Archive (pbz block compression). PMTiles are already
compressed tiles, so the archive is ~the size of its inputs (vector: +7 KB on
398 MB) and building is I/O-bound (~1 GB/s, 2026-11-03). Packaging never
touches the bytes: `--verify` extracts with `aa` and compares SHA-256 against
data/ — the CC BY-NC-ND imagery must stay byte-for-byte (LICENSING.md).
By default the smallest pack (`vector`) is verified in full and every pack's
entry sizes are checked against data/ from `aa list`.

Upload is a separate, LOCAL, approved step: pipeline/upload_packs.sh.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TABLE = REPO / "pipeline" / "asset_packs.json"
POLICIES = {"essential", "prefetch", "onDemand"}
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
        "fileSelectors": [{"fileSource": f, "fileDestination": f} for f in pack["files"]],
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


def check_sizes(pack: dict, aar: Path, data: Path) -> None:
    entries = archive_entries(aar)
    want = {f"Contents/{f}": (data / f).stat().st_size for f in pack["files"]}
    got = {k: v for k, v in entries.items() if k.startswith("Contents/")}
    if got != want:
        sys.exit(f"{pack['id']}: archive entries {got} != data/ {want}")
    if "Manifest.json" not in entries:
        sys.exit(f"{pack['id']}: archive has no Manifest.json")


def verify_hashes(pack: dict, aar: Path, data: Path) -> float:
    t = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=f"pack-{pack['id']}-", dir=aar.parent) as tmp:
        subprocess.run(["aa", "extract", "-i", str(aar), "-d", tmp], env=ENV, check=True)
        for f in pack["files"]:
            a, b = sha256(Path(tmp) / "Contents" / f), sha256(data / f)
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
        missing = [f for f in pack["files"] if not (data / f).is_file()]
        if missing:
            print(f"- {pid}: missing {missing} in {data} — skipped")
            continue

        manifest_path = manifests / f"{pid}.json"
        manifest = json.dumps(manifest_for(pack, data, manifests), indent=2) + "\n"
        aar = out / f"{pid}.aar"
        inputs = [data / f for f in pack["files"]]
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
        check_sizes(pack, aar, data)
        size_out = aar.stat().st_size
        total_in += size_in
        total_out += size_out
        print(f"- {pid} ({pack['policy']}): {size_in / 1e9:.3f} GB in → {size_out / 1e9:.3f} GB .aar"
              f" ({size_out - size_in:+,} B), {note}")
        if pid in verify:
            print(f"    verified byte-for-byte in {verify_hashes(pack, aar, data):.1f} s")

    print(f"total {total_in / 1e9:.2f} GB in → {total_out / 1e9:.2f} GB in {time.monotonic() - started:.0f} s; "
          f"output {out}")


if __name__ == "__main__":
    main()

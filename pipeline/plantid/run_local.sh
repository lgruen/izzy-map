#!/usr/bin/env bash
# Whole plant-ID evaluation on this Mac, unattended (~3.5 h on the M4,
# 2026-11: 35 GB download, ~95k photos, BioCLIP 2 at ~16 img/s).
# Every stage is resumable: re-running skips finished work. Keep the Mac
# awake (Amphetamine, or `caffeinate -i`; a closed lid on battery still
# sleeps it). Log: pipeline/cache/plantid/run.log
set -euo pipefail
P="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$P/../.." && pwd)"
C="$REPO/pipeline/cache/plantid"
mkdir -p "$C"
PLANTS="$REPO/ios/IzzyMap/Resources/Data/plants.json"   # the bundled UN plant list (pipeline/build_plants.py)
[ -s "$PLANTS" ] || { echo "missing $PLANTS" >&2; exit 1; }
t0=$(date +%s)
stamp() { echo "== $(date +%H:%M:%S) (+$(( ($(date +%s) - t0) / 60 )) min) $*"; }
E="uv run --with torch --with torchvision --with open_clip_torch --with pyarrow --with pillow --with numpy"
V="uv run --with torch --with numpy --with scipy --with pyarrow"

stamp "metadata"
bash "$P/fetch_meta.sh"
stamp "pick sets"
uv run --with duckdb --with pyarrow python3 -I "$P/pick_sets.py" --un-plants "$PLANTS"
stamp "photos"
uv run --with duckdb python3 -I "$P/fetch_photos.py" --workers 48
stamp "embed bioclip"
$E python3 -I "$P/embed.py" --model bioclip
stamp "evaluate bioclip (interim)"
$V python3 -I "$P/evaluate.py" --models bioclip --out "$C/report-bioclip"
stamp "embed bioclip2"
$E python3 -I "$P/embed.py" --model bioclip2
stamp "evaluate both"
$V python3 -I "$P/evaluate.py" --models bioclip bioclip2
stamp "done"

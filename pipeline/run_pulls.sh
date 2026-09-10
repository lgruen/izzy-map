#!/bin/bash
# One-shot, resumable driver: build each raster pack in turn and upload it as
# it finishes. Order: the small season packs first (top-down pruned, ~35k
# requests each), then the two statewide packs. Re-running after an
# interruption is free — the tile cache makes build_raster.py resume.
# Usage: nohup pipeline/run_pulls.sh > pipeline/work/pulls.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
PACKS=(aerial2020 aerial2021 aerial2022 aerial2023 aerial2024 aerial2025 aerial2026 aerial tasmap)
for key in "${PACKS[@]}"; do
  file=$(python3 -c "import json; print(next(p['file'] for p in json.load(open('pipeline/packs.json'))['packs'] if p['key']=='$key'))")
  echo "===== $(date '+%F %T') build $key ====="
  if ! python3 pipeline/build_raster.py --pack "$key" > "pipeline/work/build_$key.log" 2>&1; then
    echo "!!! build $key FAILED (see pipeline/work/build_$key.log); continuing with the next pack"
    tail -5 "pipeline/work/build_$key.log"
    continue
  fi
  tail -3 "pipeline/work/build_$key.log"
  echo "===== $(date '+%F %T') upload $file ====="
  if ! pipeline/upload_r2.sh "data/$file" > "pipeline/work/upload_$key.log" 2>&1; then
    echo "!!! upload $key FAILED (see pipeline/work/upload_$key.log); archive stays in data/ — rerun upload_r2.sh data/$file"
    tail -5 "pipeline/work/upload_$key.log"
  else
    tail -2 "pipeline/work/upload_$key.log"
  fi
done
echo "===== $(date '+%F %T') all done ====="

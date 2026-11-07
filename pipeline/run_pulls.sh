#!/bin/bash
# One-shot, resumable driver: build each raster pack in turn and package it
# as its Background Assets pack (build_packs.py → data/packs/<id>.aar) as it
# finishes. Order: the small season packs first (top-down pruned, ~35k
# requests each), then the two statewide packs. Topo is deliberately NOT in
# the list (a rebuild of identical tiles changes the archive's bytes → every
# device would re-download ~2 GB; CLAUDE.md). Re-running after an
# interruption is free — the tile cache makes build_raster.py resume.
# Nothing is uploaded: uploads stay a deliberate local step, printed at the
# end (pipeline/upload_packs.sh <id>@<hash> — only for packs whose tiles changed).
# Usage: nohup pipeline/run_pulls.sh > pipeline/work/pulls.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p pipeline/work
PACKS=(aerial2020 aerial2021 aerial2022 aerial2023 aerial2024 aerial2025 aerial2026 aerial tasmap)
BUILT=()
for key in "${PACKS[@]}"; do
  file=$(python3 -c "import json; print(next(p['file'] for p in json.load(open('pipeline/packs.json'))['packs'] if p['key']=='$key'))")
  # the asset pack that ships this file (pipeline/asset_packs.json)
  id=$(python3 -c "import json; print(next(p['id'] for p in json.load(open('pipeline/asset_packs.json'))['packs'] if '$file' in p['files']))")
  echo "===== $(date '+%F %T') build $key ====="
  if ! python3 pipeline/build_raster.py --pack "$key" > "pipeline/work/build_$key.log" 2>&1; then
    echo "!!! build $key FAILED (see pipeline/work/build_$key.log); continuing with the next pack"
    tail -5 "pipeline/work/build_$key.log"
    continue
  fi
  tail -3 "pipeline/work/build_$key.log"
  echo "===== $(date '+%F %T') package $file → data/packs/$id.aar ====="
  if ! python3 pipeline/build_packs.py "$id" --verify "$id" > "pipeline/work/pack_$id.log" 2>&1; then
    echo "!!! packaging $id FAILED (see pipeline/work/pack_$id.log); archive stays in data/ — rerun build_packs.py $id"
    tail -5 "pipeline/work/pack_$id.log"
  else
    tail -2 "pipeline/work/pack_$id.log"
    # "up to date" = the .aar is newer than its inputs: nothing new to upload
    grep -q "built in" "pipeline/work/pack_$id.log" && BUILT+=("$id")
  fi
done
echo "===== $(date '+%F %T') all done ====="
if [[ ${#BUILT[@]} -gt 0 ]]; then
  echo "Newly packaged: ${BUILT[*]}. Upload (LOCAL, ask Leo; each upload = a new version"
  echo "every device re-downloads — only packs whose tiles changed):"
  echo "  pipeline/upload_packs.sh --show ${BUILT[*]}   # then <id>@<hash> as it prints, once approved"
fi

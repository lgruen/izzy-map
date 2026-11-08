#!/usr/bin/env bash
# Release r2 of the plant-ID pack (2026-11-08): retrained heads (rare_heldout.py photos,
# cloud/hc_retrain.sh) + herbarium-sheet rows (sheet_rows.py) → final_sweep calib/test →
# build_ship v3 (V3_R2) → build_packs plantid --verify → upload_packs --show.
# Runs DETACHED (nohup) so a restart of the driving session cannot stall it; log:
# pipeline/cache/plantid/australia/v2/r2_ship.log. Uploads nothing.
set -euo pipefail
cd "$(dirname "$0")/../.."
V=pipeline/cache/plantid/australia/v2
S=pipeline/cache/plantid/ship
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch --with numpy<2.3
   --with scipy --with pyarrow --with pillow --with duckdb --with matplotlib --with coremltools python3 -I -W ignore"
echo "== r2 ship $(date -u +%FT%TZ) git $(git rev-parse --short HEAD)"
# 1. sheet rows into the retrained heads
mkdir -p $V/hc_sheets_r2 $V/final_sweep3
for s in 0 1; do
  uv run --with 'numpy<2.3' --with pyarrow python3 -I pipeline/plantid/sheet_rows.py \
    $V/head_capacity2/runs/hc-mpAc-s$s.npz $V/hc_sheets_r2/hc-mpAc-s$s.npz --data $V/data-final2.npz
done
gcloud --project leo-superresolution storage cp $V/hc_sheets_r2/hc-mpAc-s0.npz $V/hc_sheets_r2/hc-mpAc-s1.npz \
  gs://leo-superresolution-izzy-plantid/au-r2/hc/sheets/ --quiet
# 2. the shipped configuration on the new heads: T + ladder on val, test once
cp $V/final_sweep/fit.json $V/final_sweep/refine.json $V/final_sweep3/
ln -sfn ../final_sweep/heads $V/final_sweep3/heads
for f in $V/final_sweep2old/prior-adF2-*.npy; do ln -sfn ../final_sweep2old/$(basename $f) $V/final_sweep3/$(basename $f); done
export V2DATA=$V/data-final2.npz BA_WORK=$V/bank_analysis2 FS_WORK=$V/final_sweep3 FS_HCR=$V/hc_sheets_r2
$E pipeline/plantid/final_sweep.py calib "mpA01|adaptive|box"
$E pipeline/plantid/final_sweep.py test "mpA01|adaptive|box"
# 3. pack files (previous release kept for rollback)
mkdir -p $S/r1-2026-11-06
for f in v3-head.bin v3-prior.bin v2-labels.json pipeline.json credits.json credits-photos.tsv.gz; do
  [ -f $S/r1-2026-11-06/$f ] || cp -p $S/$f $S/r1-2026-11-06/$f
done
V3_R2=1 V3_ID=final-mpA01-adaptive-r2 V3_HEADS_GCS=gs://leo-superresolution-izzy-plantid/au-r2/hc/sheets/ \
  $E pipeline/plantid/build_ship.py v3
# 4. the pack + its approval line
python3 pipeline/build_packs.py plantid --verify plantid
pipeline/upload_packs.sh --show plantid
echo "== r2 ship done $(date -u +%FT%TZ)"

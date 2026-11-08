#!/usr/bin/env bash
# Hugging Face release r2: eval (no bank) → build → check → build, from the r2 pack's heads/sweep.
# Detached (nohup); log pipeline/cache/plantid/hf-release-work/r2.log. Uploads nothing.
set -euo pipefail
cd "$(dirname "$0")/../.."
V=pipeline/cache/plantid/australia/v2
export V2DATA=$V/data-final2.npz BA_WORK=$V/bank_analysis2 FS_HCR=$V/hc_sheets_r2 HF_FSDIR=$V/final_sweep3 HF_HEADS_DIR=$V/hc_sheets_r2
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch==3.3.0
   --with numpy<2.3 --with scipy --with pyarrow --with pillow --with duckdb --with safetensors python3 -I -W ignore"
rm -f pipeline/cache/plantid/hf-release-work/eval-nobank.json
$E pipeline/plantid/hf_release.py eval
$E pipeline/plantid/hf_release.py build
$E pipeline/plantid/hf_release.py check
$E pipeline/plantid/hf_release.py build
echo "== hf r2 done $(date -u +%FT%TZ)"

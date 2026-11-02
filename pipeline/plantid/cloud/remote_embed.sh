#!/usr/bin/env bash
# Runs ON the cloud VM: embed-only job for one model. The sets (train/test
# parquet) are uploaded by `run_cloud.sh embed`; photos are fetched here from
# the iNat bucket (same region), embeddings go to GCS, then the VM powers off.
# Resumable: photos and shards already present are skipped.
set -euo pipefail
BUCKET=${BUCKET:-}; MODEL=${MODEL:?}  # no BUCKET: results stay on the VM disk
ROOT=$HOME/izzy; P=$ROOT/pipeline/plantid; C=$ROOT/pipeline/cache/plantid
export PATH=$HOME/.local/bin:$PATH
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
t0=$(date +%s)
stamp() { echo "== $(date -u +%H:%M:%S) (+$(( ($(date +%s) - t0) / 60 )) min) $*"; }
stamp "photos"
uv run --with duckdb python3 "$P/fetch_photos.py" --workers 64
stamp "embed $MODEL"
uv run --with torch --with torchvision --with open_clip_torch --with pyarrow --with pillow \
  --with numpy python3 "$P/embed.py" --model "$MODEL" --batch 128 --workers 7
[ -z "$BUCKET" ] || gcloud storage rsync -r "$C/emb/$MODEL" "$BUCKET/emb/$MODEL" --quiet
stamp "done — powering off"
sudo shutdown -h now

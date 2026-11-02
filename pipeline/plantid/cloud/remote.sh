#!/usr/bin/env bash
# Runs ON the cloud VM (started by run_cloud.sh). Every stage is resumable:
# after a SPOT preemption the VM is STOPPED (disk kept); `run_cloud.sh resume`
# starts it and re-runs this script, which skips finished work. Results are
# copied to GCS after each stage, and the VM powers itself off at the end so
# the GPU stops billing even if nobody is watching.
set -euo pipefail
BUCKET=${BUCKET:?}
ROOT=$HOME/izzy
P=$ROOT/pipeline/plantid
C=$ROOT/pipeline/cache/plantid
export PATH=$HOME/.local/bin:$PATH
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
t0=$(date +%s)
stamp() { echo "== $(date -u +%H:%M:%S) (+$(( ($(date +%s) - t0) / 60 )) min) $*"; }
push() { gcloud storage rsync -r "$C/$1" "$BUCKET/$1" --quiet; }

stamp "metadata"
AWS="uvx --from awscli aws" bash "$P/fetch_meta.sh"

stamp "pick sets"
uv run --with duckdb --with pyarrow python3 "$P/pick_sets.py" --un-plants "$ROOT/plants.json"
gcloud storage cp "$C"/sets/*.parquet "$C"/sets/summary.json "$BUCKET/sets/" --quiet

stamp "photos"
uv run --with duckdb python3 "$P/fetch_photos.py" --workers 64

E="uv run --with torch --with torchvision --with open_clip_torch --with pyarrow --with pillow --with numpy"
for m in bioclip bioclip2; do
  stamp "embed $m"
  $E python3 "$P/embed.py" --model "$m" --batch 128 --workers 7
  push "emb/$m"
done

stamp "done — powering off"
sudo shutdown -h now

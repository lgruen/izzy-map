#!/usr/bin/env bash
# Startup script of the Australia-wide training VM (run_au.sh passes it as
# metadata `startup-script`; it runs as root on EVERY boot, so a VM stopped by
# a SPOT preemption resumes by just being started again). Instance metadata:
#   izzy-bucket   gs://… work prefix (inputs in/, code in code/, results)
#   izzy-mode     "embed", "train" or "embed+train" (no comma: metadata syntax)
#   izzy-shards   embed at most N shards this boot (0 = all; smoke test = 3)
# Model weights: $B/model/ (refs/ + snapshots/, the HF cache layout).
# Code and inputs come from GCS (no ssh needed); the log is copied to
# $B/log/run.log every minute. The VM powers itself off when the job ends —
# whatever the outcome — so the GPU never idles on the bill.
set -uo pipefail
md() { curl -sf -H Metadata-Flavor:Google \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
B=$(md izzy-bucket); MODE=$(md izzy-mode || echo embed); SHARDS=$(md izzy-shards || echo 0)
W=/opt/izzy; mkdir -p "$W"; cd "$W"
exec >> "$W/run.log" 2>&1
echo "== boot $(date -u +%FT%TZ) mode=$MODE shards=$SHARDS"
( while sleep 60; do gcloud storage cp "$W/run.log" "$B/log/run.log" --quiet 2>/dev/null; done ) &
finish() { echo "== end $(date -u +%FT%TZ) ($1)"; gcloud storage cp "$W/run.log" "$B/log/run.log" --quiet
           shutdown -h now; exit 0; }
for i in $(seq 90); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || finish "no GPU"
export HOME=/root PATH=/root/.local/bin:$PATH
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch
   --with pyarrow --with pillow --with numpy<2.3 python3 -u"
code() { gcloud storage cp "$B/code/code.tgz" . --quiet && rm -rf code && mkdir code && tar -C code -xzf code.tgz; }
code || finish "no code"
# the model from GCS (copied there from the laptop's HF cache): an HF download cut
# by a preemption left a corrupt cache once; offline from here on
HFM=/root/.cache/huggingface/hub/models--imageomics--bioclip-2.5-vith14
if [ ! -f "$W/model-ok" ]; then
  rm -rf "$HFM"; mkdir -p "$HFM"
  gcloud storage cp -r "$B/model/refs" "$B/model/snapshots" "$HFM/" --quiet || finish "no model"
  touch "$W/model-ok"
fi
export HF_HUB_OFFLINE=1
if [[ $MODE == *embed* ]]; then
  gcloud storage cp "$B/in/todo.parquet" . --quiet || finish "no todo.parquet"
  $E code/train_australia.py vm-embed --bucket "$B" --todo todo.parquet --work "$W" \
    --shards "$SHARDS" || finish "embed failed"
fi
if [[ $MODE == *train* ]]; then
  code || finish "no code"
  gcloud storage cp "$B/in/train-ready" . --quiet || finish "trainer not released (in/train-ready)"
  mkdir -p emb0 emb
  gcloud storage cp "$B/in/train.parquet" "$B/in/text.npz" . --quiet || finish "no train inputs"
  gcloud storage rsync "$B/emb0" emb0 --quiet && gcloud storage rsync "$B/emb" emb --quiet \
    || finish "embedding sync failed"
  $E code/train_australia.py vm-train --bucket "$B" --work "$W" || finish "train failed"
fi
finish ok

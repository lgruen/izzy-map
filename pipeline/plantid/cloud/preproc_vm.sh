#!/usr/bin/env bash
# Startup script of the preprocessing-audit VM (preproc_run.sh passes it as
# metadata; runs as root on EVERY boot → a SPOT VM stopped by preemption
# resumes by `start`). Inputs + code from $B (metadata izzy-bucket), shards to
# $B/out/ (existing ones skipped), log to $B/log/run.log each minute, power-off
# at the end whatever the outcome.
set -uo pipefail
md() { curl -sf -H Metadata-Flavor:Google \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
B=$(md izzy-bucket)
W=/opt/izzy; mkdir -p "$W"; cd "$W"
exec >> "$W/run.log" 2>&1
echo "== boot $(date -u +%FT%TZ)"
( while sleep 60; do gcloud storage cp "$W/run.log" "$B/log/run.log" --quiet 2>/dev/null; done ) &
finish() { echo "== end $(date -u +%FT%TZ) ($1)"; gcloud storage cp "$W/run.log" "$B/log/run.log" --quiet
           shutdown -h now; exit 0; }
for i in $(seq 90); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || finish "no GPU"
export HOME=/root PATH=/root/.local/bin:$PATH
uv --version 2>/dev/null | grep -q "^uv " || { rm -f /root/.local/bin/uv /root/.local/bin/uvx
  curl -LsSf https://astral.sh/uv/install.sh | sh; }
E="uv run --python 3.12 --with torch==2.7.* --with torchvision==0.22.* --with open_clip_torch
   --with transformers<5 --with pyarrow --with pillow --with numpy<2.3 python3 -u"
gcloud storage cp "$B/code/code.tgz" . --quiet || finish "no code"
rm -rf code && mkdir code && tar -C code -xzf code.tgz
mkdir -p in && gcloud storage cp "$B/in/*" in/ --quiet || finish "no inputs"
# HF downloads cut by a preemption can leave a corrupt cache: wipe until one boot finished them
if [ ! -f "$W/models-ok" ]; then rm -rf /root/.cache/huggingface; fi
$E -c "import open_clip; open_clip.create_model_and_transforms('hf-hub:imageomics/bioclip-2.5-vith14');
from transformers import Owlv2ForObjectDetection, Owlv2Processor
Owlv2ForObjectDetection.from_pretrained('google/owlv2-base-patch16-ensemble'); Owlv2Processor.from_pretrained('google/owlv2-base-patch16-ensemble'); print('models ok')" \
  && touch "$W/models-ok" || finish "model download failed"
export HF_HUB_OFFLINE=1
$E code/preproc_audit.py work --inp in --out "$W/out" --bucket "$B" --det-bs 16 --enc-bs 128 \
  || finish "work failed"
finish ok

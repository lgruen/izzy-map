#!/usr/bin/env bash
# Startup script of the bank-analysis head-training VM (bank_heads.py vm): the
# v2 part of vm_au.sh with bank_heads.py instead of train_v2.py. Runs as root on
# EVERY boot (a SPOT preemption = STOP → `start` resumes; finished runs in
# $B/bank/runs/ are skipped). Log → $B/log/bank.log every minute; powers off
# when done, whatever the outcome.
#   launch (laptop):  see the commands in bank_heads.py's caller notes
set -uo pipefail
md() { curl -sf -H Metadata-Flavor:Google \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
B=$(md izzy-bucket)
W=/opt/izzy; mkdir -p "$W"; cd "$W"
exec >> "$W/bank.log" 2>&1
echo "== boot $(date -u +%FT%TZ)"
( while sleep 60; do gcloud storage cp "$W/bank.log" "$B/log/bank.log" --quiet 2>/dev/null; done ) &
finish() { echo "== end $(date -u +%FT%TZ) ($1)"; gcloud storage cp "$W/bank.log" "$B/log/bank.log" --quiet
           shutdown -h now; exit 0; }
for i in $(seq 90); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || finish "no GPU"
export HOME=/root PATH=/root/.local/bin:$PATH
uv --version 2>/dev/null | grep -q "^uv " || { rm -f /root/.local/bin/uv /root/.local/bin/uvx
  curl -LsSf https://astral.sh/uv/install.sh | sh; }
E="uv run --python 3.12 --with torch==2.7.* --with numpy<2.3 python3 -u"
gcloud storage cp "$B/bank/bank_heads.py" . --quiet || finish "no code"
[ -f data-final.npz ] || gcloud storage cp "$B/v2/data-final.npz" . --quiet || finish "no v2 data"
$E -c "import torch; print('env ok', torch.__version__, torch.cuda.is_available())" | grep -q "env ok" \
  || { uv cache clean; $E -c "import torch; print('env ok after clean', torch.__version__)"; }
export V2_GPU_BYTES=1.6e10
$E bank_heads.py vm --bucket "$B" --work "$W"; rc=$?
echo "bank_heads exit $rc"; [ $rc = 0 ] || finish "bank_heads failed"
finish ok

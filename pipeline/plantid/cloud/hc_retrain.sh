#!/usr/bin/env bash
# Retrain the shipped two-head model (head_capacity.py mproto, cfgs hc-mpAc-s0/s1)
# on a new data file (2026-11-07: + the rare species' held-out photos) — ONE SPOT L4.
# Spend cap is enforced by GCP, never by the laptop session: --max-run-duration with
# termination action DELETE, and the startup script deletes its own VM when done
# (falls back to power-off).
#   hc_retrain.sh upload DATA HCVM   data npz + head_capacity.py + cfgs + val pack → GCS
#   hc_retrain.sh up CAP             create the VM (CAP e.g. 2h)
#   hc_retrain.sh log [n] | state | fetch DIR | down
set -euo pipefail
PROJECT=${PROJECT:-leo-superresolution}
ZONE=${ZONE:-us-central1-a}
VM=${VM:-izzy-plantid-hc2}
BUCKET=${BUCKET:-gs://leo-superresolution-izzy-plantid/au-r2}
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$HERE/.." && pwd)"
G="gcloud --project $PROJECT --quiet"
case "${1:-}" in
  upload)
    DATA=${2:?data npz}; HCVM=${3:?head_capacity vm dir (val pack)}
    printf '[{"name": "hc-mpAc-s0", "head": "mproto", "sampler": "balanced:50", "eval_every": 1, "seed": 0, "mp_init": "text", "kbreaks": [[50, 2], [150, 4], [300, 8]]},
 {"name": "hc-mpAc-s1", "head": "mproto", "sampler": "balanced:50", "eval_every": 1, "seed": 1, "mp_init": "text", "kbreaks": [[50, 2], [150, 4], [300, 8]]}]\n' > /tmp/izzy-hc2-cfgs.json
    $G storage cp "$P/head_capacity.py" "$BUCKET/hc/head_capacity.py"
    $G storage cp /tmp/izzy-hc2-cfgs.json "$BUCKET/hc/cfgs.json"
    $G storage cp "$HCVM"/* "$BUCKET/hc/vm/"
    $G storage cp "$DATA" "$BUCKET/v2/data-final.npz" ;;
  up)
    CAP=${2:?max run duration}
    python3 - "$P/head_capacity.py" > /tmp/izzy-hc2-vm.sh <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
v = s[s.index('VMSCRIPT = r"""') + len('VMSCRIPT = r"""'):]
v = v[:v.index('"""')]
# self-delete instead of power-off when finished (the VM's own service account)
v = v.replace('shutdown -h now; exit 0; }',
              'Z=$(curl -sf -H Metadata-Flavor:Google http://metadata.google.internal/computeMetadata/v1/instance/zone | sed "s|.*/||"); '
              'gcloud compute instances delete "$(hostname)" --zone "$Z" --quiet || shutdown -h now; exit 0; }')
assert "instances delete" in v
print(v)
EOF
    $G compute instances create "$VM" --zone "$ZONE" \
      --machine-type g2-standard-8 --accelerator type=nvidia-l4,count=1 \
      --provisioning-model=SPOT --instance-termination-action=DELETE \
      --max-run-duration="$CAP" --maintenance-policy=TERMINATE \
      --image-family pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
      --image-project deeplearning-platform-release \
      --boot-disk-size 100GB --boot-disk-type pd-balanced --scopes cloud-platform \
      --metadata "install-nvidia-driver=True,izzy-bucket=$BUCKET" \
      --metadata-from-file startup-script=/tmp/izzy-hc2-vm.sh ;;
  log) $G storage cat "$BUCKET/log/hc.log" | tail -n "${2:-30}" ;;
  state)
    $G compute instances list --filter="name=$VM" --format='value(name,status,zone)' || true
    $G storage ls "$BUCKET/hc/runs/" 2>/dev/null || true ;;
  fetch) mkdir -p "${2:?dir}"; $G storage rsync "$BUCKET/hc/runs" "$2" ;;
  down) $G compute instances delete "$VM" --zone "$ZONE" --delete-disks=all ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

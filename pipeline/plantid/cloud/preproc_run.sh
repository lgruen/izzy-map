#!/usr/bin/env bash
# Preprocessing audit (crop experiment + training-view pilot) on ONE SPOT L4
# (laptop side; notes/preprocessing.md has the bound).
#   preproc_run.sh upload     code + inputs (pipeline/cache/plantid/preproc/in/) → GCS
#   preproc_run.sh up CAP     create the VM (CAP = --max-run-duration, e.g. 1.5h)
#   preproc_run.sh start      restart after a preemption
#   preproc_run.sh log [n]    tail of the VM log
#   preproc_run.sh state      VM status + shards in GCS
#   preproc_run.sh fetch      GCS out/ + samples/ → pipeline/cache/plantid/preproc/work/
#   preproc_run.sh down       delete the VM and its disk
set -euo pipefail
PROJECT=${PROJECT:-leo-superresolution}
ZONE=${ZONE:-us-central1-a}
VM=${VM:-izzy-plantid-preproc}
BUCKET=${BUCKET:-gs://leo-superresolution-izzy-plantid/preproc}
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$HERE/.." && pwd)"
C="$P/../cache/plantid/preproc"
G="gcloud --project $PROJECT --quiet"
case "${1:-}" in
  upload)
    tar -C "$P" -czf /tmp/izzy-preproc-code.tgz preproc_audit.py build_ship.py
    $G storage cp /tmp/izzy-preproc-code.tgz "$BUCKET/code/code.tgz"
    $G storage cp "$C/in/views.parquet" "$C/in/pilot_train.parquet" "$C/in/pilot_test.parquet" "$BUCKET/in/" ;;
  up)
    CAP=${2:?max run duration}
    $G compute instances create "$VM" --zone "$ZONE" \
      --machine-type g2-standard-8 --accelerator type=nvidia-l4,count=1 \
      --provisioning-model=SPOT --instance-termination-action=STOP \
      --max-run-duration="$CAP" --maintenance-policy=TERMINATE \
      --image-family pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
      --image-project deeplearning-platform-release \
      --boot-disk-size 100GB --boot-disk-type pd-balanced --scopes cloud-platform \
      --metadata "install-nvidia-driver=True,izzy-bucket=$BUCKET" \
      --metadata-from-file startup-script="$HERE/preproc_vm.sh" ;;
  start) $G compute instances start "$VM" --zone "$ZONE" ;;
  log) $G storage cat "$BUCKET/log/run.log" | tail -n "${2:-30}" ;;
  state)
    $G compute instances describe "$VM" --zone "$ZONE" --format='value(status,lastStartTimestamp,lastStopTimestamp)' || true
    echo "shards in GCS: $($G storage ls "$BUCKET/out/" 2>/dev/null | grep -c npz || true)" ;;
  fetch)
    mkdir -p "$C/work/samples"
    $G storage rsync "$BUCKET/out" "$C/work"
    $G storage rsync "$BUCKET/samples" "$C/work/samples" || true ;;
  down) $G compute instances delete "$VM" --zone "$ZONE" --delete-disks=all ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac

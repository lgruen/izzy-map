#!/usr/bin/env bash
# Trained Australia-wide plant-ID model on ONE GCP SPOT GPU VM (laptop side).
# The VM runs cloud/vm_au.sh at every boot and pulls code + inputs from GCS,
# so no ssh is needed and a preempted (STOPPED) VM resumes with `start`.
#
#   run_au.sh bucket          create the work bucket (us-central1, standard)
#   run_au.sh upload          code.tgz + inputs (todo/train manifests, text.npz,
#                             the already-embedded emb/bioclip25 shards) → GCS
#   run_au.sh up MODE N CAP   create the VM: MODE embed|train|embed+train,
#                             N shards (0 = all), CAP = --max-run-duration
#   run_au.sh again MODE N CAP  same VM (stopped), new mode/shards/cap, start
#   run_au.sh start           start the stopped VM (after a preemption)
#   run_au.sh log [n]         tail of the VM log (from GCS)
#   run_au.sh state           VM status + shards in GCS
#   run_au.sh release         allow the train stage (uploads code + in/train-ready)
#   run_au.sh v2-upload       train_v2.py code + australia/v2/data.npz → GCS (then `up v2 0 CAP`)
#   run_au.sh fetch           GCS → pipeline/cache/plantid/australia/train/
#   run_au.sh down            delete the VM and its disk
#
# g2-standard-8 + 1× L4 in us-central1 (GPUS_ALL_REGIONS = 1: one GPU at a
# time), SPOT with STOP on preemption (disk kept → resumable), external IP
# (no Cloud NAT in the project; all data public), hard cap --max-run-duration.
set -euo pipefail
PROJECT=${PROJECT:-leo-superresolution}
ZONE=${ZONE:-us-central1-a}
VM=${VM:-izzy-plantid-au}
BUCKET=${BUCKET:-gs://leo-superresolution-izzy-plantid/au}
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$HERE/.." && pwd)"
C="$P/../cache/plantid"
G="gcloud --project $PROJECT --quiet"

case "${1:-}" in
  bucket)
    $G storage buckets create "${BUCKET%/au}" --location us-central1 --uniform-bucket-level-access ;;
  upload)
    tar -C "$P" -czf /tmp/izzy-au-code.tgz train_australia.py embed.py
    $G storage cp /tmp/izzy-au-code.tgz "$BUCKET/code/code.tgz"
    $G storage cp "$C/australia/train/todo.parquet" "$C/australia/plan/train.parquet" \
      "$C/australia/text.npz" "$BUCKET/in/"
    $G storage rsync "$C/emb/bioclip25" "$BUCKET/emb0" --exclude 'text\.npz|info\.json' ;;
  v2-upload)  # train_v2.py: code + data file(s); recorded in the provenance log
    tar -C "$P" -czf /tmp/izzy-au-code.tgz train_australia.py embed.py train_v2.py
    $G storage cp /tmp/izzy-au-code.tgz "$BUCKET/code/code.tgz"
    uv run --with numpy --with pyarrow python3 -I "$P/provenance.py" note "v2 cloud code+data upload" \
      in:/tmp/izzy-au-code.tgz gcs_code="$BUCKET/code/code.tgz" gcs_data="$BUCKET/v2/${DATAF:-data*.npz}" || true
    for f in "$C"/australia/v2/${DATAF:-data*.npz}; do $G storage cp "$f" "$BUCKET/v2/$(basename "$f")"; done ;;
  release)
    tar -C "$P" -czf /tmp/izzy-au-code.tgz train_australia.py embed.py
    $G storage cp /tmp/izzy-au-code.tgz "$BUCKET/code/code.tgz"
    echo ok | $G storage cp - "$BUCKET/in/train-ready" ;;
  up)
    MODE=${2:?mode}; N=${3:?shards}; CAP=${4:?max run duration, e.g. 1h}
    $G compute instances create "$VM" --zone "$ZONE" \
      --machine-type g2-standard-8 --accelerator type=nvidia-l4,count=1 \
      --provisioning-model=SPOT --instance-termination-action=STOP \
      --max-run-duration="$CAP" --maintenance-policy=TERMINATE \
      --image-family pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
      --image-project deeplearning-platform-release \
      --boot-disk-size 120GB --boot-disk-type pd-balanced --scopes cloud-platform \
      --metadata "install-nvidia-driver=True,izzy-bucket=$BUCKET,izzy-mode=$MODE,izzy-shards=$N,izzy-grid=${GRID:-},izzy-data=${DATAF:-data*.npz}" \
      --metadata-from-file startup-script="$HERE/vm_au.sh" ;;
  again)
    MODE=${2:?mode}; N=${3:?shards}; CAP=${4:?cap}
    $G compute instances add-metadata "$VM" --zone "$ZONE" \
      --metadata "izzy-mode=$MODE,izzy-shards=$N" --metadata-from-file startup-script="$HERE/vm_au.sh"
    $G compute instances set-scheduling "$VM" --zone "$ZONE" --max-run-duration="$CAP" \
      --instance-termination-action=STOP
    $G compute instances start "$VM" --zone "$ZONE" ;;
  start)
    $G compute instances start "$VM" --zone "$ZONE" ;;
  log)
    $G storage cat "$BUCKET/log/run.log" | tail -n "${2:-30}" ;;
  state)
    $G compute instances describe "$VM" --zone "$ZONE" --format='value(status,lastStartTimestamp,lastStopTimestamp)' || true
    echo "shards in GCS: $($G storage ls "$BUCKET/emb/" 2>/dev/null | grep -c npz || true)" ;;
  fetch)
    mkdir -p "$C/australia/train"
    for d in emb heads log; do $G storage rsync -r "$BUCKET/$d" "$C/australia/train/$d"; done ;;
  down)
    $G compute instances delete "$VM" --zone "$ZONE" --delete-disks=all ;;
  *)
    sed -n '2,20p' "$0"; exit 1 ;;
esac

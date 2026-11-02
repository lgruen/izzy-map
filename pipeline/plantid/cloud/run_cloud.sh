#!/usr/bin/env bash
# Plant-ID evaluation on one GCP SPOT GPU VM (laptop side).
#
#   run_cloud.sh up      create VM, copy code, start remote.sh in the background
#   run_cloud.sh embed M create VM, upload the local sets, embed photos with model M
#                        only (remote_embed.sh) — no 35 GB metadata pass
#   run_cloud.sh log     show the remote log (tail)
#   run_cloud.sh resume [M]  after a preemption/stop: start VM, re-run the job
#   run_cloud.sh fetch   copy sets + embeddings from GCS into pipeline/cache/plantid
#   run_cloud.sh down    delete the VM (and its disk)
#
# g2-standard-8 + 1× L4, us-east4 (next to the bucket in AWS us-east-1),
# SPOT with STOP on preemption (disk survives → resumable), hard cap
# --max-run-duration (the VM is stopped after it whatever happens), external
# IP (the project has no Cloud NAT; all data is public). remote.sh powers the
# VM off when done. Photos never leave the VM; only parquet + embeddings go to
# GCS. Run `down` after `fetch` — a stopped VM still bills its disk.
set -euo pipefail
PROJECT=${PROJECT:-cyclic-nets-2026}
ZONE=${ZONE:-us-east4-a}
VM=${VM:-izzy-plantid}
# BUCKET="" (e.g. a project without a work bucket): results stay on the VM's
# disk and `fetch MODEL` copies them over ssh (starting the stopped VM briefly)
BUCKET=${BUCKET-gs://cyclic-nets-2026-work/izzy-plantid}
MAX_RUN=${MAX_RUN:-4h}
PLANTS_JSON=${PLANTS_JSON:-}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
G="gcloud --project $PROJECT --quiet"  # --quiet: never prompt (keys, zones)

start_remote() {  # $1 = model key → embed-only job, else the full remote.sh
  local job="remote.sh" env="BUCKET=$BUCKET"
  [ -n "${1:-}" ] && job="remote_embed.sh" env="BUCKET=$BUCKET MODEL=$1"
  $G compute ssh "$VM" --zone "$ZONE" --command \
    "nohup env $env bash izzy/pipeline/plantid/cloud/$job >> izzy/run.log 2>&1 < /dev/null &"
  echo "started; follow with: $0 log"
}

create_vm() {
    $G compute instances create "$VM" --zone "$ZONE" \
      --machine-type g2-standard-8 --accelerator type=nvidia-l4,count=1 \
      --provisioning-model=SPOT --instance-termination-action=STOP \
      --max-run-duration="$MAX_RUN" --maintenance-policy=TERMINATE \
      --image-family pytorch-2-9-cu129-ubuntu-2204-nvidia-580 \
      --image-project deeplearning-platform-release \
      --boot-disk-size 200GB --boot-disk-type pd-balanced \
      --scopes cloud-platform --metadata install-nvidia-driver=True
    for i in $(seq 30); do
      $G compute ssh "$VM" --zone "$ZONE" --command true 2>/dev/null && break
      sleep 10
    done
    $G compute ssh "$VM" --zone "$ZONE" --command "mkdir -p izzy/pipeline/cache/plantid/sets"
    tar -C "$REPO" -czf - --exclude __pycache__ pipeline/plantid | \
      $G compute ssh "$VM" --zone "$ZONE" --command "tar -C izzy -xzf -"
}

case "${1:-}" in
  embed)
    MODEL=${2:?model key, e.g. bioclip25}
    create_vm
    $G compute scp --zone "$ZONE" "$REPO"/pipeline/cache/plantid/sets/{labels,train,test}.parquet \
      "$VM:izzy/pipeline/cache/plantid/sets/"
    start_remote "$MODEL" ;;
  up)
    [ -n "$PLANTS_JSON" ] || PLANTS_JSON=$(mktemp)
    [ -s "$PLANTS_JSON" ] || git -C "$REPO" show worktree-understorey:app/src/generated/plants.json > "$PLANTS_JSON"
    create_vm
    $G compute scp --zone "$ZONE" "$PLANTS_JSON" "$VM:izzy/plants.json"
    start_remote ;;
  log)
    $G compute ssh "$VM" --zone "$ZONE" --command "tail -n ${2:-40} izzy/run.log" ;;
  resume)  # resume [MODEL] — pass the model key for an embed-only job
    $G compute instances start "$VM" --zone "$ZONE"
    sleep 30
    start_remote "${2:-}" ;;
  fetch)
    dst="$REPO/pipeline/cache/plantid"
    mkdir -p "$dst/emb"
    if [ -z "$BUCKET" ]; then  # straight from the VM disk
      [ "$($G compute instances describe "$VM" --zone "$ZONE" --format='value(status)')" = RUNNING ] || {
        $G compute instances start "$VM" --zone "$ZONE"; sleep 30; }
      $G compute ssh "$VM" --zone "$ZONE" --command \
        "tar -C izzy/pipeline/cache/plantid -cf - emb/${2:?model key}" | tar -C "$dst" -xf -
      $G compute instances stop "$VM" --zone "$ZONE"
    elif [ -n "${2:-}" ]; then  # one model's embeddings only
      gcloud storage rsync -r "$BUCKET/emb/$2" "$dst/emb/$2"
    else
      gcloud storage rsync -r "$BUCKET/sets" "$dst/sets"
      gcloud storage rsync -r "$BUCKET/emb" "$dst/emb"
    fi ;;
  down)
    $G compute instances delete "$VM" --zone "$ZONE" --quiet ;;
  *)
    sed -n '2,9p' "$0"; exit 1 ;;
esac

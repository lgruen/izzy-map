#!/bin/bash
# Upload data archives + manifest to the R2 bucket. Runs LOCALLY with your
# authenticated wrangler session (no tokens in CI — deliberate; see CLAUDE.md).
#
# wrangler's direct `r2 object put` caps at 300 MiB, so this deploys a
# temporary multipart uploader Worker (pipeline/r2-uploader/) with a fresh
# random secret, streams the archives through it in 64 MiB parts, then
# DELETES the Worker again.
#
# Usage: pipeline/upload_r2.sh [file ...]      # default: all archives + manifest
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLIC_URL="https://pub-0ef9b8ef1e7541f8814d3e4374485b76.r2.dev"
PART_MB=64

# Regenerate the manifest from what's in data/
python3 - <<'EOF'
import json, time
from pathlib import Path
data = Path("data")
archives = {}
for key, fname in [("tasveg", "tasveg.pmtiles"), ("topo", "topo_tas.pmtiles")]:
    p = data / fname
    if p.exists():
        archives[key] = {"file": fname, "bytes": p.stat().st_size}
manifest = {"version": time.strftime("%Y-%m-%d"), "archives": archives}
(data / "data-manifest.json").write_text(json.dumps(manifest, indent=1))
print("manifest:", manifest)
EOF

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=(data/tasveg.pmtiles data/topo_tas.pmtiles data/data-manifest.json)
fi

SECRET=$(openssl rand -hex 24)
echo "== deploying temporary uploader worker =="
cleanup() {
  echo "== deleting uploader worker =="
  (cd pipeline/r2-uploader && npx wrangler@latest delete --force 2>/dev/null) || true
}
trap cleanup EXIT   # installed BEFORE the URL check: a deploy that succeeded
                    # but failed to parse must still be torn down
UPLOAD_URL=$(cd pipeline/r2-uploader && npx wrangler@latest deploy --var "UPLOAD_SECRET:$SECRET" \
  | grep -o 'https://[a-z0-9.-]*workers.dev' | head -1)
[[ -n "$UPLOAD_URL" ]] || { echo "worker deploy failed (URL not found in output)"; exit 1; }
echo "uploader at $UPLOAD_URL"
# wait until the fresh route actually answers (403/400 = alive; 000/5xx = not yet)
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$UPLOAD_URL/" || echo 000)
  [[ "$code" == "403" || "$code" == "400" ]] && break
  sleep 2
done

api() { # api <action> <key> [extra query] [curl args...] — retries transient failures
  local action=$1 key=$2 extra=${3:-}
  shift 3 || shift 2
  local out
  for attempt in 1 2 3; do
    if out=$(curl -sf --retry 2 -H "x-auth: $SECRET" "$@" "$UPLOAD_URL/?action=$action&key=$key$extra"); then
      printf '%s' "$out"
      return 0
    fi
    echo "  api $action attempt $attempt failed, retrying…" >&2
    sleep $((attempt * 3))
  done
  echo "  api $action failed after 3 attempts" >&2
  return 1
}

remote_size() { # current size of an object on the public bucket, or 0
  curl -sI "$PUBLIC_URL/$1" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub(/\r/,""); print $2}' | tail -1
}

for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "skip missing $f"; continue; }
  key=$(basename "$f")
  size=$(stat -f%z "$f")
  if [[ "$key" == *.pmtiles && "$(remote_size "$key")" == "$size" ]]; then
    echo "== $key already up to date ($((size / 1000000)) MB) =="
    continue
  fi
  echo "== $key ($((size / 1000000)) MB) =="
  if (( size < 90 * 1024 * 1024 )); then
    api put "$key" "" --data-binary "@$f" >/dev/null
    echo "  single-shot upload done"
    continue
  fi
  uploadId=$(api create "$key" "" -X POST | python3 -c "import sys,json;print(json.load(sys.stdin)['uploadId'])")
  parts_json="["
  part=1
  offset=0
  chunk=$((PART_MB * 1024 * 1024))
  while (( offset < size )); do
    n=$(( size - offset < chunk ? size - offset : chunk ))
    etag=""
    for attempt in 1 2 3; do
      resp=$(dd if="$f" bs=1m iseek=$((offset / 1024 / 1024)) count=$PART_MB 2>/dev/null \
        | curl -sf -H "x-auth: $SECRET" --data-binary @- \
          "$UPLOAD_URL/?action=part&key=$key&uploadId=$uploadId&part=$part") \
        && etag=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['etag'])" 2>/dev/null) \
        && [[ -n "$etag" ]] && break
      echo "  part $part attempt $attempt failed, retrying…"
      sleep $((attempt * 5))
    done
    [[ -n "$etag" ]] || { echo "FAILED: part $part gave no etag after 3 attempts"; exit 1; }
    [[ $part -gt 1 ]] && parts_json+=","
    parts_json+="{\"partNumber\":$part,\"etag\":\"$etag\"}"
    offset=$((offset + n))
    echo "  part $part: $((offset / 1000000)) / $((size / 1000000)) MB"
    part=$((part + 1))
  done
  parts_json+="]"
  echo "$parts_json" | api complete "$key" "&uploadId=$uploadId" -X POST --data-binary @- >/dev/null
  echo "  multipart complete"
done

echo "done. public base: $PUBLIC_URL"

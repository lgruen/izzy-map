#!/usr/bin/env bash
# Upload the plant-ID phone test's data to R2 under plantid-test/<version>/:
#   bioclip25/  bioclip/   export_onnx.py output (model shards, labels, samples)
#   ort/        onnxruntime-web runtime (WebGPU build) — pinned version
# The page (probe/plantid/, deployed with the app) reads it from
#   https://pub-…r2.dev/plantid-test/<version>/
# Files are < 300 MiB each (model shards are 64 MiB), so plain
# `wrangler r2 object put` works — no uploader Worker, and the archive
# manifest (data-manifest.json) is not touched. The path is versioned and
# treated as immutable: after re-exporting, bump VERSION here AND the default
# `data` URL in probe/plantid/index.html.
#
#   pipeline/plantid/upload_test.sh            # ~1.5 GB
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=v1
ORT_VERSION=1.30.0
BUCKET=izzy-map
PREFIX="plantid-test/$VERSION"
SRC=pipeline/cache/plantid/onnx
W="npx --yes wrangler@4"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
(cd "$stage" && npm pack "onnxruntime-web@$ORT_VERSION" --silent >/dev/null && tar xzf onnxruntime-web-*.tgz)
ort="$stage/package/dist"

put() {  # put <local file> <key> <content-type>
  local size out; size=$(stat -f%z "$1")
  for attempt in 1 2 3; do
    if out=$($W r2 object put "$BUCKET/$PREFIX/$2" --file "$1" --content-type "$3" \
         --cache-control "public, max-age=86400" --remote 2>&1); then
      printf '  %-40s %6d MB\n' "$2" $((size / 1000000)); return 0
    fi
    echo "  $2: attempt $attempt failed, retrying…"; sleep $((attempt * 5))
  done
  echo "FAILED: $2"; echo "$out" | tail -20; exit 1
}
type_of() {
  case "$1" in
    *.json) echo application/json ;; *.jpg) echo image/jpeg ;; *.mjs) echo text/javascript ;;
    *.wasm) echo application/wasm ;; *) echo application/octet-stream ;;
  esac
}

echo "== ort $ORT_VERSION"
for f in ort.webgpu.min.mjs ort-wasm-simd-threaded.asyncify.mjs ort-wasm-simd-threaded.asyncify.wasm; do
  put "$ort/$f" "ort/$f" "$(type_of "$f")"
done
for m in bioclip bioclip25; do
  [[ -f "$SRC/$m/manifest.json" ]] || { echo "missing $SRC/$m — run export_onnx.py --model $m"; exit 1; }
  echo "== $m"
  # manifest last: a half-finished upload never advertises missing shards
  files=$(cd "$SRC/$m" && { ls | grep -v -e '^manifest.json$' -e '^samples$'; ls samples/*.jpg; echo manifest.json; })
  for f in $files; do put "$SRC/$m/$f" "$m/$f" "$(type_of "$f")"; done
done
base="https://pub-0ef9b8ef1e7541f8814d3e4374485b76.r2.dev/$PREFIX"
echo "== check"
hdrs=$(curl -s -o /dev/null -H "Origin: https://lgruen.github.io" -D - "$base/bioclip25/manifest.json" || true)
if grep -qi '^access-control-allow-origin: https://lgruen.github.io' <<<"$hdrs"; then
  echo "CORS ok for lgruen.github.io"
else
  echo "WARNING: no CORS header for lgruen.github.io on $base/bioclip25/manifest.json:"; echo "$hdrs"; exit 1
fi
echo "done: $base/"

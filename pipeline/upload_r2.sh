#!/bin/bash
# Upload data archives + manifest to the R2 bucket. Runs LOCALLY with your
# authenticated wrangler session (no tokens in CI — deliberate; see CLAUDE.md).
#
# Usage: pipeline/upload_r2.sh [file ...]      # default: all archives + manifest
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET=izzy-map
PUBLIC_URL="https://pub-0ef9b8ef1e7541f8814d3e4374485b76.r2.dev"

# Regenerate the manifest from what's in data/
python3 - <<'EOF'
import json, os, time
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
for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "skip missing $f"; continue; }
  echo "== uploading $f ($(du -h "$f" | cut -f1)) =="
  npx wrangler@latest r2 object put "$BUCKET/$(basename "$f")" --file="$f" --remote
done
echo "done. public base: $PUBLIC_URL"

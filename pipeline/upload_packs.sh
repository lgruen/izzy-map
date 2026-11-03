#!/bin/bash
# Upload Background Assets packs (data/packs/<id>.aar, from build_packs.py) to
# App Store Connect as Apple-hosted asset packs. Runs LOCALLY only, never in
# CI (CLAUDE.md: data uploads are local; Leo approves each upload).
#
# Each upload creates a NEW version of that pack (the version number counts
# up by itself). Internal TestFlight testers get the latest processed version
# automatically; external testers / the App Store need that version submitted
# for review in App Store Connect → TestFlight → Asset Packs.
# Only upload a pack whose files changed: every new version is re-downloaded
# by every device in the background.
#
# Auth: an App Store Connect API key (Admin or App Manager / Developer role).
# altool looks for AuthKey_<KEY_ID>.p8 in ./private_keys, ~/private_keys,
# ~/.private_keys or ~/.appstoreconnect/private_keys.
#
# Usage:
#   APP_APPLE_ID=<numeric App Store Connect app id> ASC_KEY_ID=<key id> \
#   ASC_ISSUER_ID=<issuer uuid> pipeline/upload_packs.sh vector [topo ...]
# The numeric app id is App Store Connect → IzzyMap → App Information →
# "Apple ID" (or `xcrun altool --list-apps …`).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

: "${APP_APPLE_ID:?set APP_APPLE_ID (numeric app id)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
[[ $# -gt 0 ]] || { echo "name the pack ids to upload (no default: uploads are deliberate)" >&2; exit 2; }

for id in "$@"; do
  aar="data/packs/$id.aar"
  [[ -f "$aar" ]] || { echo "missing $aar — run pipeline/build_packs.py $id" >&2; exit 1; }
  echo "== $id ($(du -h "$aar" | cut -f1))"
  xcrun altool --upload-asset-pack "$aar" --apple-id "$APP_APPLE_ID" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait
done
xcrun altool --list-asset-packs --apple-id "$APP_APPLE_ID" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

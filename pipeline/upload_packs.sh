#!/bin/bash
# Upload Background Assets packs (data/packs/<id>.aar, from build_packs.py) to
# App Store Connect as Apple-hosted asset packs. Runs LOCALLY on Leo's Mac
# only (altool is macOS-only and the packs live in data/), never in CI
# (CLAUDE.md: data uploads are local; Leo approves each upload). A Claude
# session may run it through Remote Control after Leo approved the exact
# pack + hash in the thread; the repo's .claude/settings.json keeps the
# command on the "ask" list, so the prompt on the Mac is the second gate.
#
# Each upload creates a NEW version of that pack (the version number counts
# up by itself). Internal TestFlight testers get the latest processed version
# automatically; external testers / the App Store need that version submitted
# for review in App Store Connect → TestFlight → Asset Packs.
# Only upload a pack whose files changed: every new version is re-downloaded
# by every device in the background.
#
# Usage:
#   pipeline/upload_packs.sh --show [<id> ...]      # size, sha256, last upload; uploads nothing
#   pipeline/upload_packs.sh refphotos@3f9a1c2e4b5d [vector@… ...]
# Every pack is named WITH the hash that was approved (the full SHA-256 or a
# prefix of ≥ 12 hex characters, as `--show` and build_packs.py print it).
# The script refuses a pack when:
#   - build_packs.py --verify has not passed for this archive (no
#     <id>.aar.sha256, or the .aar is newer than it),
#   - the archive's recomputed SHA-256 differs from the .sha256 file or
#     from the approved hash,
#   - the same bytes were already uploaded (data/packs/uploaded.log;
#     ALLOW_REUPLOAD=1 overrides — every device would download it again),
#   - another upload is running (lock directory data/packs/.upload.lock).
# Every pack is checked before the first one is uploaded.
#
# Auth: a dedicated App Store Connect API key (lowest role that can upload
# asset packs; revocable on its own in Users and Access → Integrations).
# altool looks for AuthKey_<KEY_ID>.p8 in ./private_keys, ~/private_keys,
# ~/.private_keys or ~/.appstoreconnect/private_keys (keep it mode 600).
# The ids come from ~/.config/izzymap/asc.env (mode 600, refused if group-
# or world-readable), which may set APP_APPLE_ID, ASC_KEY_ID, ASC_ISSUER_ID;
# variables already in the environment win. APP_APPLE_ID is App Store
# Connect → IzzyMap → App Information → "Apple ID".
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PACKS=data/packs
LOG="$PACKS/uploaded.log"
ENV_FILE="${IZZY_ASC_ENV:-$HOME/.config/izzymap/asc.env}"

die() { echo "upload_packs: $*" >&2; exit 1; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
mtime() { stat -f %m "$1"; }
last_upload() { [[ -f "$LOG" ]] && awk -v id="$1" '$2 == id { line = $0 } END { if (line) print line }' "$LOG" || true; }
# Fields of the .sha256 file written by build_packs.py: "<sha256>  <id>.aar".
recorded_sha() {
  local aar="$1" side="$1.sha256" want got
  [[ -f "$side" ]] || die "$aar has no $(basename "$side") — run: python3 pipeline/build_packs.py ${2} --verify ${2}"
  (( $(mtime "$aar") <= $(mtime "$side") )) || die "$aar changed after its --verify — run: python3 pipeline/build_packs.py ${2} --verify ${2}"
  read -r want got < "$side"
  [[ "$got" == "$(basename "$aar")" && "$want" =~ ^[0-9a-f]{64}$ ]] || die "$side is malformed"
  echo "$want"
}

if [[ "${1:-}" == "--show" ]]; then
  shift
  if [[ $# -eq 0 ]]; then
    set -- $(ls "$PACKS"/*.aar 2>/dev/null | xargs -n1 basename | sed 's/\.aar$//')
  fi
  for id in "$@"; do
    aar="$PACKS/$id.aar"
    [[ -f "$aar" ]] || { echo "$id: no $aar"; continue; }
    size=$(du -h "$aar" | cut -f1)
    if want=$( (recorded_sha "$aar" "$id") 2>&1 ); then
      got=$(sha_of "$aar")
      [[ "$got" == "$want" ]] || { echo "$id: $size, HASH MISMATCH (.sha256 $want, file $got) — rebuild"; continue; }
      prev=$(last_upload "$id")
      if [[ -n "$prev" && "$(echo "$prev" | cut -d' ' -f3)" == "$got" ]]; then
        state="already uploaded $(echo "$prev" | cut -d' ' -f1)"
      else
        state="not uploaded yet${prev:+ (last upload $(echo "$prev" | cut -d' ' -f1): $(echo "$prev" | cut -d' ' -f3 | cut -c1-12))}"
      fi
      echo "$id: $size, sha256 $got, built $(date -r "$(mtime "$aar")" '+%Y-%m-%d %H:%M'), $state → $id@${got:0:12}"
    else
      echo "$id: $size, not uploadable: ${want#upload_packs: }"
    fi
  done
  exit 0
fi

[[ $# -gt 0 ]] || die "name the packs as <id>@<sha256 prefix> (see --show; no default: uploads are deliberate)"

if [[ -f "$ENV_FILE" ]]; then
  perm=$(stat -f %Lp "$ENV_FILE")
  (( (8#$perm & 8#077) == 0 )) || die "$ENV_FILE is mode $perm — chmod 600 it"
  # Only the three known variables, never the file as code; environment wins.
  while IFS='=' read -r k v; do
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$k" in
      APP_APPLE_ID|ASC_KEY_ID|ASC_ISSUER_ID) [[ -n "${!k:-}" ]] || export "$k=$v" ;;
    esac
  done < <(grep -E '^(export +)?[A-Z_]+=' "$ENV_FILE" | sed -E 's/^export +//')
fi
: "${APP_APPLE_ID:?set APP_APPLE_ID (numeric app id) in $ENV_FILE}"
: "${ASC_KEY_ID:?set ASC_KEY_ID in $ENV_FILE}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in $ENV_FILE}"

mkdir "$PACKS/.upload.lock" 2>/dev/null || die "another upload is running ($PACKS/.upload.lock; remove it if none is)"
trap 'rmdir "$PACKS/.upload.lock"' EXIT

# Check every named pack before uploading any of them.
ids=() shas=()
for arg in "$@"; do
  [[ "$arg" == *@* ]] || die "$arg: name the approved hash too, e.g. $arg@<sha256 prefix> (see --show)"
  id="${arg%%@*}" approved="${arg#*@}"
  [[ "$approved" =~ ^[0-9a-f]{12,64}$ ]] || die "$arg: the hash must be ≥ 12 lowercase hex characters"
  for seen in "${ids[@]:-}"; do [[ "$seen" != "$id" ]] || die "$id named twice"; done
  aar="$PACKS/$id.aar"
  [[ -f "$aar" ]] || die "missing $aar — run pipeline/build_packs.py $id --verify $id"
  want=$(recorded_sha "$aar" "$id")
  echo "== $id: hashing $(du -h "$aar" | cut -f1) …"
  got=$(sha_of "$aar")
  [[ "$got" == "$want" ]] || die "$id: archive sha256 $got != its --verify record $want — rebuild and verify"
  [[ "$got" == "$approved"* ]] || die "$id: archive sha256 $got does not start with the approved $approved — NOT the approved pack"
  prev=$(last_upload "$id")
  if [[ -n "$prev" && "$(echo "$prev" | cut -d' ' -f3)" == "$got" && "${ALLOW_REUPLOAD:-0}" != 1 ]]; then
    die "$id: these exact bytes were uploaded on $(echo "$prev" | cut -d' ' -f1) — set ALLOW_REUPLOAD=1 only if that upload failed upstream"
  fi
  ids+=("$id") shas+=("$got")
done

for i in "${!ids[@]}"; do
  id="${ids[$i]}" sha="${shas[$i]}" aar="$PACKS/${ids[$i]}.aar"
  # Re-check right before the upload: the files are big and slow to hash.
  (( $(mtime "$aar") <= $(mtime "$aar.sha256") )) || die "$id: $aar changed while checking — nothing more uploaded"
  echo "== uploading $id (sha256 ${sha:0:12}…, $(du -h "$aar" | cut -f1))"
  xcrun altool --upload-asset-pack "$aar" --apple-id "$APP_APPLE_ID" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --wait
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $id $sha $(stat -f %z "$aar")" >> "$LOG"
done
xcrun altool --list-asset-packs --apple-id "$APP_APPLE_ID" --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

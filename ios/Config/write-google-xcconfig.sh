#!/bin/bash
# Writes ios/Config/Google.xcconfig (gitignored) with the Google OAuth client
# id for the pins export (docs/PINS_PLAN.md §6), read from
# ~/.config/izzymap/google.env (GOOGLE_OAUTH_CLIENT_ID=…). The id is not a
# secret, but it stays out of the public repo. Run once per checkout or
# worktree; Debug.xcconfig and Release.xcconfig include the file. Prints only
# whether it worked, never the id.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
env_file="${GOOGLE_ENV:-$HOME/.config/izzymap/google.env}"
out="$here/Google.xcconfig"

id="$(sed -n 's/^GOOGLE_OAUTH_CLIENT_ID=//p' "$env_file" | tail -n 1 | tr -d '[:space:]"'"'")"
if [[ ! "$id" =~ ^[A-Za-z0-9-]+\.apps\.googleusercontent\.com$ ]]; then
    echo "error: no GOOGLE_OAUTH_CLIENT_ID=<…>.apps.googleusercontent.com in $env_file" >&2
    exit 1
fi
umask 077
printf '// Written by write-google-xcconfig.sh — gitignored, never commit.\nGOOGLE_OAUTH_CLIENT_ID = %s\n' "$id" > "$out"
echo "wrote $out"

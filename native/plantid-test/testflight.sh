#!/usr/bin/env bash
# Archive the test app and upload it to TestFlight.
#   TEAM=<team id> native/plantid-test/testflight.sh
# Signing/upload auth: either an Apple ID signed in under Xcode → Settings →
# Accounts, or an App Store Connect API key passed in the environment:
#   ASC_KEY_PATH=/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=uuid
# The app record (bundle id org.gruenschloss.plantidtest) must exist in App
# Store Connect before the upload. Each run gets a fresh build number.
set -euo pipefail
cd "$(dirname "$0")"
# Xcode's export runs `rsync` from PATH with flags only Apple's openrsync
# accepts; Homebrew's rsync 3.x first in PATH fails it with "Copy failed"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
: "${TEAM:?set TEAM to the Apple developer team id}"
auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
build=$(date +%Y%m%d%H%M)
xcodegen generate --quiet
rm -rf build/PlantIDTest.xcarchive build/export
xcodebuild -project PlantIDTest.xcodeproj -scheme PlantIDTest -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/PlantIDTest.xcarchive \
  -allowProvisioningUpdates "${auth[@]}" DEVELOPMENT_TEAM="$TEAM" \
  CURRENT_PROJECT_VERSION="$build" archive | grep -E 'error|warning: |ARCHIVE' || true
[[ -d build/PlantIDTest.xcarchive ]] || { echo "archive failed"; exit 1; }
plutil -replace teamID -string "$TEAM" -o build/ExportOptions.plist ExportOptions.plist
xcodebuild -exportArchive -archivePath build/PlantIDTest.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates "${auth[@]}"
echo "uploaded build $build — it shows in TestFlight after Apple's processing (usually 5–30 min)"

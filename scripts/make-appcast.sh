#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:?Usage: make-appcast.sh ARCHIVE.zip [Cairn.app] [appcast.xml]}"
app="${2:-dist/Cairn.app}"
feed="${3:-dist/appcast.xml}"
scripts/sparkle-release-signing.sh validate-input
[[ -f "$archive" && "$archive" == *.zip ]] || { echo "ERROR: signed updates must be ZIP archives" >&2; exit 1; }
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
signature="$(scripts/sparkle-release-signing.sh sign "$archive")"
swift Resources/ReleaseTools/VerifySignature.swift "$public_key" "$signature" "$archive"
export CAIRN_ARCHIVE_SIGNATURE="$signature"
python3 Resources/ReleaseTools/appcast.py "$archive" "$app" "$feed"
scripts/sparkle-release-signing.sh sign-feed "$feed"
scripts/sparkle-release-signing.sh verify-feed "$feed"
swift Resources/ReleaseTools/VerifySignature.swift --feed "$public_key" "$feed"
echo "Created authenticated $feed"

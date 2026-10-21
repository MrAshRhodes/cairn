#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-dist/Cairn.app}"
[[ -d "$app" ]] || { echo "ERROR: run scripts/bundle-app.sh first" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
arch="$(/usr/libexec/PlistBuddy -c 'Print CairnBuildArchitecture' "$app/Contents/Info.plist")"
output="${2:-dist/Cairn-$version-$arch.dmg}"
stage=".build/dmg-stage"
mkdir -p .build "$(dirname "$output")"
rm -rf "$stage"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Cairn.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -format UDZO -fs HFS+ -volname Cairn -srcfolder "$stage" "$output"
if [[ "${SIGNING_IDENTITY:--}" != "-" ]]; then
  sign_args=(--force --sign "$SIGNING_IDENTITY" --timestamp)
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then sign_args+=(--keychain "$SIGNING_KEYCHAIN"); fi
  codesign "${sign_args[@]}" "$output"
fi
hdiutil verify "$output"
echo "Created $output"

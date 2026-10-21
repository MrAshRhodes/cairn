#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
export ARCH="${ARCH:-$(uname -m)}" CONFIGURATION="${CONFIGURATION:-release}"
export VERSION="${VERSION:-0.1.0}"
export BUILD_NUMBER="${BUILD_NUMBER:-${VERSION}}"
export SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
export SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
case "$ARCH" in
  arm64|x86_64) arches=("$ARCH") ;;
  universal) arches=(arm64 x86_64) ;;
  *) echo "ERROR: ARCH must be arm64, x86_64 or universal" >&2; exit 1 ;;
esac
case "$CONFIGURATION" in debug|release) ;; *) echo "Invalid CONFIGURATION" >&2; exit 1 ;; esac
case "${CAIRN_WITH_CHROMIUM:-0}" in
  0) ;;
  1) [[ -f engine/bundle.py ]] || { echo "ERROR: optional Chromium bundler is not installed" >&2; exit 1; } ;;
  *) echo "CAIRN_WITH_CHROMIUM must be 0 or 1" >&2; exit 1 ;;
esac
if [[ "$SIGNING_IDENTITY" != "-" && "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
  echo "ERROR: SIGNING_IDENTITY must be '-' or a Developer ID Application identity" >&2
  exit 1
fi

work="$root/.build/packaging-$ARCH"
app="$work/Cairn.app"
mkdir -p "$work" dist
rm -rf "$app"
mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks}
# Validate configuration before compiling; plistlib escapes all substituted values.
python3 Resources/ReleaseTools/bundle.py configure "$app"
binaries=()
for arch in "${arches[@]}"; do
  build_args=(-c "$CONFIGURATION" --arch "$arch" --product Cairn
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
  scripts/swiftw build "${build_args[@]}"
  bin="$(scripts/swiftw build "${build_args[@]}" --show-bin-path)"
  binaries+=("$bin/Cairn")
done
if [[ ${#binaries[@]} -eq 1 ]]; then
  ditto "${binaries[0]}" "$app/Contents/MacOS/Cairn"
else
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Cairn"
fi
framework="$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { echo "ERROR: resolved Sparkle framework missing" >&2; exit 1; }
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
for resource in "$bin/"*.bundle; do
  [[ -d "$resource" ]] && ditto "$resource" "$app/Contents/Resources/$(basename "$resource")"
done
swift Resources/ReleaseTools/Icon.swift "$work/Cairn.iconset"
iconutil -c icns "$work/Cairn.iconset" -o "$app/Contents/Resources/Cairn.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"
ditto .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE"
if [[ "${CAIRN_WITH_CHROMIUM:-0}" == 1 ]]; then
  python3 engine/bundle.py --app "$app" --configuration "$CONFIGURATION"
  [[ -f engine/entitlements/renderer.plist && -f engine/entitlements/helper.plist ]] || {
    echo "ERROR: Chromium helper entitlements missing" >&2; exit 1;
  }
fi
python3 Resources/ReleaseTools/bundle.py rpaths "$app"

sign_args=(--force --sign "$SIGNING_IDENTITY")
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
  sign_args+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
else
  echo "AD-HOC DEVELOPMENT BUILD: no Apple identity, no notarization or Gatekeeper trust."
fi
sign_nested() {
  local target="$1"
  local metadata=("--preserve-metadata=identifier,entitlements")
  if [[ "${CAIRN_WITH_CHROMIUM:-0}" == 1 ]]; then
    case "$target" in
      *"Cairn Helper (Renderer).app"*|*"Cairn Helper (GPU).app"*)
        metadata=(--preserve-metadata=identifier --entitlements engine/entitlements/renderer.plist) ;;
      *"Cairn Helper"*.app*)
        metadata=(--preserve-metadata=identifier --entitlements engine/entitlements/helper.plist) ;;
    esac
  fi
  codesign "${sign_args[@]}" "${metadata[@]}" "$target"
}
# Sign leaves before their containing bundles. Do not use codesign --deep to sign.
while IFS= read -r -d '' leaf; do
  if file -b "$leaf" | grep -q 'Mach-O'; then
    sign_nested "$leaf"
  fi
done < <(find "$app/Contents/Frameworks" -type f -print0)
while IFS= read -r -d '' nested; do
  sign_nested "$nested"
done < <(find "$app/Contents/Frameworks" -depth -type d \
  \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print0)
codesign "${sign_args[@]}" --entitlements Resources/Cairn.entitlements "$app"
codesign --verify --deep --strict "$app"
python3 Resources/ReleaseTools/bundle.py verify "$app"
rm -rf dist/Cairn.app
ditto "$app" dist/Cairn.app
echo "Built $root/dist/Cairn.app ($ARCH; $CONFIGURATION)"

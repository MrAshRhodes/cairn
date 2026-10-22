#!/usr/bin/env bash
# Verifies a built Cairn.app against the packaging contract: layout, Info.plist, architecture and minimum OS of
# every Mach-O, code signatures (hardened runtime for Developer ID builds), per-process entitlements and stray files.
# Read-only. Every problem is reported before the script exits non-zero, so one run shows everything to fix.
#
# Usage: verify-bundle.sh [--arch arm64|x86_64] [--require-developer-id] [--notarized] [APP]   (default dist/Cairn.app)
#   --require-developer-id  fail unless the app carries a hardened-runtime, timestamped Developer ID signature
#   --notarized             also require a stapled ticket and Gatekeeper acceptance (run after notarization)
# Bash 3.2 compatible (macOS /bin/bash).
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
usage="Usage: verify-bundle.sh [--arch arm64|x86_64] [--require-developer-id] [--notarized] [APP]"
arch="" require_developer_id=0 notarized=0 app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) [[ $# -ge 2 ]] || { echo "$usage" >&2; exit 2; }; arch="$2"; shift 2 ;;
    --require-developer-id) require_developer_id=1; shift ;;
    --notarized) notarized=1; shift ;;
    -h|--help) echo "$usage"; exit 0 ;;
    -*) echo "ERROR: unknown option $1. $usage" >&2; exit 2 ;;
    *) [[ -z "$app" ]] || { echo "$usage" >&2; exit 2; }; app="$1"; shift ;;
  esac
done
app="${app:-$root/dist/Cairn.app}"
[[ -d "$app/Contents" ]] || { echo "ERROR: $app is not an application bundle. Run scripts/bundle-app.sh first." >&2; exit 2; }
app="$(cd "$app" && pwd -P)"
contents="$app/Contents"
info="$contents/Info.plist"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
require_value() { # PLIST KEY LABEL
  local value
  value="$(plist_value "$1" "$2")"
  if [[ -z "$value" ]]; then fail "$3: $2 is missing or empty"; fi
}
plutil -lint "$info" >/dev/null 2>&1 || { fail "Info.plist is not a valid property list"; echo "verify-bundle: $failures problem(s)" >&2; exit 1; }

main_id="$(plist_value "$info" CFBundleIdentifier)"
declared_arch="$(plist_value "$info" CairnBuildArchitecture)"
mode="$(plist_value "$info" CairnSigningMode)"
min_os="$(plist_value "$info" LSMinimumSystemVersion)"
arch="${arch:-$declared_arch}"
case "$arch" in arm64|x86_64) ;; *) fail "architecture must be arm64 or x86_64 (got '${arch}')"; arch="" ;; esac
[[ -z "$declared_arch" || "$declared_arch" == "$arch" ]] || fail "Info.plist CairnBuildArchitecture is $declared_arch but $arch was requested"
case "$mode" in ad-hoc|developer-id) ;; *) fail "CairnSigningMode must be ad-hoc or developer-id (got '${mode}')" ;; esac
if [[ "$require_developer_id" == 1 && "$mode" != developer-id ]]; then fail "a Developer ID build is required but this app is $mode"; fi
if [[ "$mode" == ad-hoc ]]; then
  echo "NOTICE: ad-hoc build: hardened runtime, Developer ID, notarization and Gatekeeper are NOT verified."
fi
developer_id=0
[[ "$mode" == developer-id || "$require_developer_id" == 1 ]] && developer_id=1

# --- Info.plist -------------------------------------------------------------------------------------------------
if grep -q '@[A-Z_]*@' "$info"; then fail "Info.plist still contains unsubstituted @PLACEHOLDER@ values"; fi
if grep -q '/Users/\|/home/runner' "$info"; then fail "Info.plist embeds a build machine path"; fi
for key in CFBundleIdentifier CFBundleName CFBundleDisplayName CFBundleExecutable CFBundleIconFile CFBundlePackageType \
  LSApplicationCategoryType NSPrincipalClass CairnBrowserEngine NSCameraUsageDescription NSMicrophoneUsageDescription \
  NSLocationWhenInUseUsageDescription NSBluetoothAlwaysUsageDescription NSLocalNetworkUsageDescription; do
  require_value "$info" "$key" "Info.plist"
done
[[ "$(plist_value "$info" CFBundleExecutable)" == Cairn ]] || fail "CFBundleExecutable must be Cairn"
[[ "$(plist_value "$info" CairnBrowserEngine)" == chromium ]] || fail "CairnBrowserEngine must be chromium"
for key in CFBundleShortVersionString CFBundleVersion; do
  [[ "$(plist_value "$info" "$key")" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "$key must be a numeric version"
done
[[ "$(plist_value "$info" NSHighResolutionCapable)" == true ]] || fail "NSHighResolutionCapable must be true"
package_minimum="$(grep -Eo 'platforms:[[:space:]]*\[\.macOS\(\.v[0-9]+' "$root/Package.swift" 2>/dev/null | grep -Eo '[0-9]+$')"
if [[ -n "$package_minimum" && "$min_os" != "$package_minimum.0" ]]; then
  fail "LSMinimumSystemVersion is '$min_os' but Package.swift requires macOS $package_minimum"
fi
[[ "$min_os" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "LSMinimumSystemVersion is missing or malformed"
url_schemes="$(plist_value "$info" CFBundleURLTypes:0:CFBundleURLSchemes)"
for scheme in http https; do
  grep -qx "[[:space:]]*$scheme" <<<"$url_schemes" || fail "CFBundleURLTypes does not register $scheme (default browser)"
done
documents="$(plist_value "$info" CFBundleDocumentTypes)"
grep -q 'public\.html' <<<"$documents" || fail "CFBundleDocumentTypes does not register public.html"
[[ "$(plist_value "$info" SUFeedURL)" == https://* ]] || fail "SUFeedURL must be an https URL"
for key in SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
  [[ "$(plist_value "$info" "$key")" == true ]] || fail "$key must be true"
done
public_key="$(plist_value "$info" SUPublicEDKey)"
if [[ -n "$public_key" ]]; then
  [[ "$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] || fail "SUPublicEDKey is not a 32-byte Ed25519 key"
elif [[ "$developer_id" == 1 ]]; then
  fail "SUPublicEDKey is empty: a release must carry the update-signing public key"
fi

# --- Layout -----------------------------------------------------------------------------------------------------
framework="$contents/Frameworks/Chromium Embedded Framework.framework"
snapshot="v8_context_snapshot.${arch:-arm64}.bin"
for path in "$contents/MacOS/Cairn" "$contents/Resources/Cairn.icns" "$contents/Resources/cef.lock.json" \
  "$contents/Resources/CEF-LICENSE.txt" "$contents/Resources/Sparkle-LICENSE" \
  "$contents/Frameworks/Sparkle.framework/Sparkle" "$framework/Chromium Embedded Framework" \
  "$framework/Resources/icudtl.dat" "$framework/Resources/resources.pak" "$framework/Resources/$snapshot" \
  "$framework/Libraries/libcef_sandbox.dylib" "$framework/Libraries/libvk_swiftshader.dylib" \
  "$framework/Libraries/vk_swiftshader_icd.json"; do
  [[ -f "$path" ]] || fail "missing ${path#"$app"/}"
done
[[ -x "$contents/MacOS/Cairn" ]] || fail "Contents/MacOS/Cairn is not executable"
for link in "$framework/Versions/Current" "$contents/Frameworks/Sparkle.framework/Versions/Current"; do
  [[ -L "$link" ]] || fail "${link#"$app"/} must be a symlink"
done
for other in "$framework"/Resources/v8_context_snapshot.*.bin; do
  [[ -e "$other" && "${other##*/}" != "$snapshot" ]] && fail "CEF resource ${other##*/} belongs to another architecture"
done
for pair in ":" " (Alerts):.alerts" " (GPU):.gpu" " (Plugin):.plugin" " (Renderer):.renderer"; do
  suffix="${pair%%:*}" id_suffix="${pair#*:}"
  name="Cairn Helper$suffix"
  helper="$contents/Frameworks/$name.app"
  hinfo="$helper/Contents/Info.plist"
  [[ -f "$helper/Contents/MacOS/$name" ]] || { fail "missing helper executable $name"; continue; }
  [[ "$(plist_value "$hinfo" CFBundleExecutable)" == "$name" ]] || fail "$name: CFBundleExecutable is wrong"
  [[ "$(plist_value "$hinfo" CFBundleIdentifier)" == "$main_id.helper$id_suffix" ]] || fail "$name: CFBundleIdentifier must be $main_id.helper$id_suffix"
  [[ "$(plist_value "$hinfo" LSUIElement)" == true ]] || fail "$name: LSUIElement must be true"
  [[ "$(plist_value "$hinfo" LSMinimumSystemVersion)" == "$min_os" ]] || fail "$name: LSMinimumSystemVersion differs from the app"
done
for bundle in "$contents"/Frameworks/*.app; do
  case "${bundle##*/}" in
    "Cairn Helper.app"|"Cairn Helper (Alerts).app"|"Cairn Helper (GPU).app"|"Cairn Helper (Plugin).app"|"Cairn Helper (Renderer).app") ;;
    *) fail "unexpected application in Frameworks: ${bundle##*/}" ;;
  esac
done

# --- Architecture and deployment target of every Mach-O ----------------------------------------------------------
macho_files=()
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q 'Mach-O'; then macho_files+=("$file"); fi
done < <(find "$app" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0)
[[ ${#macho_files[@]} -gt 0 ]] || fail "no Mach-O binaries found"
version_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
for file in ${macho_files[@]+"${macho_files[@]}"}; do
  rel="${file#"$app"/}"
  slices="$(lipo -archs "$file" 2>/dev/null)"
  if [[ -z "$arch" ]]; then continue; fi
  case "$file" in
    */Sparkle.framework/*) # Sparkle ships universal; the wanted slice must be present
      grep -qw "$arch" <<<"$slices" || fail "$rel has no $arch slice (found: $slices)" ;;
    *) [[ "$slices" == "$arch" ]] || fail "$rel must be a thin $arch binary (found: $slices)" ;;
  esac
  minos="$(vtool -arch "$arch" -show-build "$file" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
  if [[ -z "$minos" ]]; then
    fail "$rel: cannot read the deployment target (vtool)"
  elif [[ -n "$min_os" ]] && ! version_le "$minos" "$min_os"; then
    fail "$rel requires macOS $minos, newer than the declared LSMinimumSystemVersion $min_os"
  fi
done

# --- Code signatures --------------------------------------------------------------------------------------------
codesign --verify --deep --strict "$app" 2>/dev/null || fail "codesign --verify --deep --strict failed (re-run it for details)"
code_objects=("$app")
while IFS= read -r -d '' bundle; do code_objects+=("$bundle"); done \
  < <(find "$contents/Frameworks" \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -type d -print0)
code_objects+=(${macho_files[@]+"${macho_files[@]}"})
team=""
for object in "${code_objects[@]}"; do
  rel="${object#"$app"}"
  rel="${rel#/}"
  details="$(codesign -dvv "$object" 2>&1)"
  if ! grep -q '^Signature size=\|^Signature=adhoc' <<<"$details"; then fail "${rel:-Cairn.app} is not signed"; continue; fi
  if [[ "$developer_id" == 1 ]]; then
    grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([a-z,]*runtime' <<<"$details" || fail "${rel:-Cairn.app}: hardened runtime flag is missing"
    grep -q '^Authority=Developer ID Application: ' <<<"$details" || fail "${rel:-Cairn.app}: not signed by a Developer ID Application identity"
    grep -q '^Timestamp=' <<<"$details" || fail "${rel:-Cairn.app}: no secure timestamp"
    object_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
    if [[ -z "$object_team" || "$object_team" == "not set" ]]; then
      fail "${rel:-Cairn.app}: no Team ID"
    elif [[ -z "$team" ]]; then team="$object_team"
    elif [[ "$team" != "$object_team" ]]; then fail "${rel:-Cairn.app}: Team ID $object_team differs from $team (library validation would fail)"
    fi
  fi
done
for bundle in "$contents"/Frameworks/*.framework "$contents"/Frameworks/*.app; do
  codesign --verify --strict "$bundle" 2>/dev/null || fail "${bundle#"$app"/}: invalid signature"
done

# --- Entitlements -----------------------------------------------------------------------------------------------
entitlement_keys() { # OBJECT -> one entitlement key per line (empty when none)
  local xml
  xml="$(codesign -d --xml --entitlements - "$1" 2>/dev/null)"
  [[ -n "$xml" ]] || xml="$(codesign -d --entitlements :- "$1" 2>/dev/null)"
  [[ "$xml" == "<?xml"* ]] || return 0
  plutil -convert json -o - - <<<"$xml" 2>/dev/null | grep -Eo '"[^"]+":(true|false|[0-9"])' | sed -E 's/^"([^"]+)":.*/\1/' | sort
}
source_keys() { # entitlements plist in the repository -> sorted keys
  plutil -convert json -o - "$1" 2>/dev/null | grep -Eo '"[^"]+":(true|false|[0-9"])' | sed -E 's/^"([^"]+)":.*/\1/' | sort
}
forbidden_entitlements="com.apple.security.get-task-allow com.apple.security.cs.disable-library-validation
com.apple.security.cs.allow-unsigned-executable-memory com.apple.security.cs.disable-executable-page-protection
com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.debugger com.apple.security.app-sandbox"
check_entitlements() { # OBJECT LABEL SOURCE-PLIST REQUIRED-KEYS...
  local object="$1" label="$2" source="$3" actual expected key
  shift 3
  actual="$(entitlement_keys "$object")"
  expected="$(source_keys "$source")"
  if [[ "$actual" != "$expected" ]]; then
    fail "$label: entitlements [$(tr '\n' ' ' <<<"$actual")] differ from $(basename "$source") [$(tr '\n' ' ' <<<"$expected")]"
  fi
  for key in "$@"; do
    grep -qxF "$key" <<<"$actual" || fail "$label: required entitlement $key is missing"
  done
  for key in $forbidden_entitlements; do
    ! grep -qxF "$key" <<<"$actual" || fail "$label: forbidden entitlement $key"
  done
}
check_entitlements "$app" "Cairn.app" "$root/Resources/Cairn.entitlements" \
  com.apple.security.device.camera com.apple.security.device.audio-input com.apple.security.personal-information.location
for suffix in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  helper="$contents/Frameworks/Cairn Helper$suffix.app"
  [[ -d "$helper" ]] || continue
  case "$suffix" in
    " (GPU)"|" (Renderer)") check_entitlements "$helper" "Cairn Helper$suffix" "$root/engine/entitlements/renderer.plist" com.apple.security.cs.allow-jit ;;
    *) check_entitlements "$helper" "Cairn Helper$suffix" "$root/engine/entitlements/helper.plist" ;;
  esac
done
for object in "$contents"/Frameworks/*.framework; do
  keys="$(entitlement_keys "$object")"
  for key in $forbidden_entitlements; do
    ! grep -qxF "$key" <<<"$keys" || fail "${object#"$app"/}: forbidden entitlement $key"
  done
done

# --- Stray files and links ----------------------------------------------------------------------------------------
stray="$(find "$app" \( -name '*.mobileprovision' -o -name '*.provisionprofile' -o -name 'embedded.provisionprofile' \
  -o -name '*.p12' -o -name '*.pfx' -o -name '*.pem' -o -name '*.key' -o -name '*.cer' -o -name '.env' -o -name '.env.*' \
  -o -name '*.dmp' -o -name '*.har' -o -name '*.trace' -o -name '.DS_Store' -o -name '*.dSYM' -o -name '*.swiftmodule' \
  -o -name '*.a' -o -name '*.o' -o -name '*.log' -o -name '__MACOSX' -o -name '.git' -o -name 'sparkle_*private*' \
  -o -name 'Cookies' -o -name 'Login Data' -o -name 'Local State' -o -name 'Web Data' -o -name 'CairnChromiumSmoke' \) -print)"
[[ -z "$stray" ]] || fail "stray file(s) in the bundle (credentials, profiles or build products): $(echo "$stray" | sed "s|$app/||" | tr '\n' ' ')"
while IFS= read -r -d '' link; do
  resolved="$(readlink -f "$link" 2>/dev/null)"
  [[ "$resolved" == "$app"/* ]] || fail "${link#"$app"/} is a symlink that leaves the bundle"
done < <(find "$app" -type l -print0)

# --- Gatekeeper (after notarization) ----------------------------------------------------------------------------
if [[ "$notarized" == 1 ]]; then
  [[ "$developer_id" == 1 ]] || fail "--notarized needs a Developer ID build"
  xcrun stapler validate "$app" >/dev/null 2>&1 || fail "no valid stapled notarization ticket"
  spctl --assess --type execute "$app" >/dev/null 2>&1 || fail "Gatekeeper rejects the application (spctl --assess)"
fi

if [[ $failures -gt 0 ]]; then
  echo "verify-bundle: $failures problem(s) in $app" >&2
  exit 1
fi
echo "Verified ${app##*/} (${arch:-unknown arch}, $mode): layout, Info.plist, architecture, signatures, entitlements."

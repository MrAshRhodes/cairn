#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
# Public releases retain the WebKit gate until CEF release-security validation is complete.
export CAIRN_WITH_CHROMIUM="${CAIRN_WITH_CHROMIUM:-0}"
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || {
  echo "ERROR: release requires SPARKLE_PUBLIC_ED_KEY." >&2; exit 1;
}
scripts/sparkle-release-signing.sh validate-input
if [[ ! -x .build/artifacts/sparkle/Sparkle/bin/sign_update ]]; then
  scripts/swiftw package resolve
fi
scripts/sparkle-release-signing.sh check-key
export VERSION="${VERSION:?Set VERSION to the numeric release version, e.g. 0.1.0}"
export BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}" ARCH="${ARCH:-universal}" CONFIGURATION=release
export SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
signing_dir="$PWD/.build/release-signing"
cleanup() {
  if [[ -n "${imported_keychain:-}" ]]; then
    security delete-keychain "$imported_keychain" >/dev/null 2>&1 || true
    rm -rf "$signing_dir"
  fi
}
trap cleanup EXIT
# CI-only optional certificate import; local users may use an existing login-keychain identity.
if [[ -n "${APPLE_CERTIFICATE_P12_BASE64:-}${APPLE_CERTIFICATE_PASSWORD:-}${APPLE_SIGNING_IDENTITY:-}" ]]; then
  [[ -n "${APPLE_CERTIFICATE_P12_BASE64:-}" && -n "${APPLE_CERTIFICATE_PASSWORD:-}" &&
     -n "${APPLE_SIGNING_IDENTITY:-}" ]] || { echo "ERROR: incomplete Apple signing configuration" >&2; exit 1; }
  umask 077
  mkdir -p "$signing_dir"
  imported_keychain="$signing_dir/signing.keychain-db"
  password="$(uuidgen)"
  python3 - "$signing_dir/certificate.p12" <<'PY'
import base64, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(os.environ["APPLE_CERTIFICATE_P12_BASE64"], validate=True))
PY
  security create-keychain -p "$password" "$imported_keychain"
  security set-keychain-settings -lut 21600 "$imported_keychain"
  security unlock-keychain -p "$password" "$imported_keychain"
  security import "$signing_dir/certificate.p12" -k "$imported_keychain" \
    -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$imported_keychain" >/dev/null
  rm "$signing_dir/certificate.p12"
  export SIGNING_IDENTITY="$APPLE_SIGNING_IDENTITY" SIGNING_KEYCHAIN="$imported_keychain"
fi
notary_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}${APPLE_TEAM_ID:-}${APPLE_APP_PASSWORD:-}" ]]; then
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]] || {
    echo "ERROR: incomplete Apple notarization configuration" >&2; exit 1;
  }
  notary_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if [[ ${#notary_args[@]} -gt 0 && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "ERROR: notarization requires a Developer ID signature" >&2; exit 1
fi

scripts/swiftw test
scripts/test-release.sh
scripts/bundle-app.sh
assets="dist/release"
rm -rf "$assets"
mkdir -p "$assets"
archive="$assets/Cairn-$VERSION-$ARCH.zip"
dmg="$assets/Cairn-$VERSION-$ARCH.dmg"
notarized=false
if [[ ${#notary_args[@]} -gt 0 ]]; then
  ditto -c -k --sequesterRsrc --keepParent dist/Cairn.app .build/notarization.zip
  xcrun notarytool submit .build/notarization.zip "${notary_args[@]}" --wait --output-format json \
    > .build/notarization-result.json
  python3 -c 'import json; assert json.load(open(".build/notarization-result.json"))["status"] == "Accepted", "Notarization rejected"'
  xcrun stapler staple dist/Cairn.app
  xcrun stapler validate dist/Cairn.app
  spctl --assess --type execute --verbose dist/Cairn.app
  notarized=true
fi
# Archive after stapling: the exact uploaded bytes are the exact EdDSA-signed bytes.
ditto -c -k --sequesterRsrc --keepParent dist/Cairn.app "$archive"
scripts/make-dmg.sh dist/Cairn.app "$dmg"
if [[ "$notarized" == true ]]; then
  xcrun notarytool submit "$dmg" "${notary_args[@]}" --wait --output-format json > .build/dmg-notarization-result.json
  python3 -c 'import json; assert json.load(open(".build/dmg-notarization-result.json"))["status"] == "Accepted", "DMG notarization rejected"'
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
scripts/make-appcast.sh "$archive" dist/Cairn.app "$assets/appcast.xml"
export CAIRN_NOTARIZED="$notarized"
python3 - <<'PY'
import json, os, pathlib
mode = "ad-hoc" if os.environ["SIGNING_IDENTITY"] == "-" else "Developer ID"
record = dict(version=os.environ["VERSION"], build=os.environ["BUILD_NUMBER"],
              architecture=os.environ["ARCH"], signing=mode,
              notarized=os.environ["CAIRN_NOTARIZED"] == "true", sparkle="Ed25519 archive and feed")
pathlib.Path("dist/release/RELEASE-INFO.json").write_text(json.dumps(record, indent=2) + "\n")
notice = "Notarized by Apple." if record["notarized"] else "NOT notarized by Apple."
pathlib.Path("dist/release/RELEASE-NOTES.txt").write_text(
    f"Cairn {record['version']} ({record['architecture']})\n\n"
    f"Apple signing: {mode}. {notice}\n"
    "The ZIP and appcast have verified Sparkle Ed25519 signatures.\n"
    "Ad-hoc builds have no Apple Gatekeeper trust. Prefer a Developer ID notarized release for distribution.\n")
PY
(cd "$assets" && shasum -a 256 ./*.zip ./*.dmg appcast.xml RELEASE-INFO.json RELEASE-NOTES.txt > SHA256SUMS)
echo "Release assets prepared in $assets; nothing has been published."

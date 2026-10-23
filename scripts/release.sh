#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
# One architecture per run: Chromium (CEF) is the only engine and is single-architecture, so a public release is
# two same-version builds (arm64 on Apple silicon, x86_64 on Intel) that scripts/finalize-release.sh signs into
# one Sparkle feed. Only that script handles the Sparkle private key; this one must never see it.
unset SPARKLE_PRIVATE_ED_KEY SPARKLE_KEYCHAIN_ACCOUNT
export VERSION="${VERSION:?Set VERSION to the numeric release version, e.g. 0.1.0}"
host_arch="$(uname -m)"
case "$host_arch" in
  arm64|aarch64) host_arch=arm64 ;;
  x86_64|amd64) host_arch=x86_64 ;;
  *) echo "ERROR: unsupported host architecture: $host_arch" >&2; exit 1 ;;
esac
export BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}" ARCH="${ARCH:-$host_arch}" CONFIGURATION=release
export SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || {
  echo "ERROR: release requires SPARKLE_PUBLIC_ED_KEY." >&2; exit 1;
}
# Fail before the long test and build steps: valid ARCH/VERSION/public key, and Chromium prepared (never fetched here).
python3 Resources/ReleaseTools/bundle.py check
python3 Resources/ReleaseTools/bundle.py engine "$ARCH"
if [[ "$ARCH" != "$host_arch" ]]; then
  # The unit tests run natively, so a cross-architecture build still needs the host's Chromium.
  python3 Resources/ReleaseTools/bundle.py engine "$host_arch"
fi
assets="dist/release"
archive="$assets/Cairn-$VERSION-$ARCH.zip"
dmg="$assets/Cairn-$VERSION-$ARCH.dmg"
record="$assets/Cairn-$VERSION-$ARCH.json"
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

mkdir -p "$assets"
# Keep the other architecture's files; drop this one's previous outputs and anything finalized from them.
rm -f "$archive" "$dmg" "$record" "$assets"/{appcast.xml,RELEASE-INFO.json,RELEASE-NOTES.txt,SHA256SUMS}
CAIRN_CEF_ARCH="$host_arch" scripts/swiftw test
scripts/test-release.sh
scripts/bundle-app.sh
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
  # Stop before the disk image is built and notarized if the stapled app no longer satisfies the packaging contract.
  scripts/verify-bundle.sh --arch "$ARCH" --require-developer-id --notarized dist/Cairn.app
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
# Verify what users receive, not only the build directory: the update archive is extracted and the disk image mounted,
# and the app inside must satisfy the whole packaging contract (stapled and Gatekeeper-accepted after notarization).
verify_args=(--arch "$ARCH")
if [[ "$notarized" == true ]]; then
  verify_args+=(--require-developer-id --notarized)
elif [[ "$SIGNING_IDENTITY" != "-" ]]; then
  verify_args+=(--require-developer-id)
fi
scripts/verify-bundle.sh "${verify_args[@]}" "$archive"
scripts/verify-bundle.sh "${verify_args[@]}" "$dmg"
python3 Resources/ReleaseTools/ReleaseAssets.py record --app dist/Cairn.app --zip "$archive" --dmg "$dmg" \
  --notarized "$notarized" --output "$record"
echo "Release assets for $ARCH prepared in $assets; nothing has been signed for Sparkle or published."
echo "Build the other architecture, then run scripts/finalize-release.sh to sign the shared update feed."

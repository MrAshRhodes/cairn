#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:?Usage: make-appcast.sh ARCHIVE.zip [Cairn.app] [appcast.xml]}"
app="${2:-dist/Cairn.app}"
feed="${3:-dist/appcast.xml}"
[[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]] || { echo "ERROR: SPARKLE_PRIVATE_ED_KEY is required; no unsigned feed will be emitted." >&2; exit 1; }
python3 Resources/ReleaseTools/validate-key.py
[[ -f "$archive" && "$archive" == *.zip ]] || { echo "ERROR: signed updates must be ZIP archives" >&2; exit 1; }
signer=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$signer" ]] || { echo "ERROR: build Cairn to resolve Sparkle's signing tools" >&2; exit 1; }
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")"
if ! signature="$(printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$signer" --ed-key-file - -p "$archive" 2>/dev/null)"; then
  echo "ERROR: Sparkle archive signing failed. Check the configured key." >&2; exit 1
fi
swift Resources/ReleaseTools/VerifySignature.swift "$public_key" "$signature" "$archive"
export CAIRN_ARCHIVE_SIGNATURE="$signature"
python3 Resources/ReleaseTools/appcast.py "$archive" "$app" "$feed"
# Sparkle can echo malformed key text in diagnostics, so never forward signer diagnostics.
if ! printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$signer" --ed-key-file - "$feed" >/dev/null 2>&1; then
  echo "ERROR: Sparkle feed signing failed." >&2; exit 1
fi
if ! printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$signer" --ed-key-file - --verify "$feed" >/dev/null 2>&1; then
  echo "ERROR: Sparkle feed verification failed." >&2; exit 1
fi
swift Resources/ReleaseTools/VerifySignature.swift --feed "$public_key" "$feed"
echo "Created authenticated $feed"

#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" && -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  echo "ERROR: choose one Sparkle signing mode, not both." >&2
  exit 1
fi
if [[ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]]; then
  auth=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
else
  [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]] || {
    echo "ERROR: set SPARKLE_KEYCHAIN_ACCOUNT or SPARKLE_PRIVATE_ED_KEY." >&2; exit 1;
  }
  python3 Resources/ReleaseTools/validate-key.py
  auth=(--ed-key-file -)
fi
[[ "${1:-}" == validate-input ]] && exit 0
signer=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$signer" ]] || { echo "ERROR: resolve Sparkle's signing tools first." >&2; exit 1; }
run_signer() {
  if [[ -n "${SPARKLE_KEYCHAIN_ACCOUNT:-}" ]]; then
    "$signer" "${auth[@]}" "$@" </dev/null
  else
    printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$signer" "${auth[@]}" "$@"
  fi
}
sign_file() {
  local signature
  # The upstream signer can echo malformed private material in diagnostics.
  if ! signature="$(run_signer -p "$1" 2>/dev/null)"; then
    echo "ERROR: Sparkle signing failed. Check the selected account/key and Keychain access." >&2; exit 1
  fi
  printf '%s\n' "$signature"
}
case "${1:-}" in
  check-key)
    [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || {
      echo "ERROR: SPARKLE_PUBLIC_ED_KEY is required." >&2; exit 1;
    }
    mkdir -p .build
    probe=".build/sparkle-key-check-$$"
    trap 'rm -f "$probe"' EXIT
    : > "$probe"
    signature="$(sign_file "$probe")"
    swift Resources/ReleaseTools/VerifySignature.swift "$SPARKLE_PUBLIC_ED_KEY" "$signature" "$probe"
    echo "Sparkle signing key matches the configured public key."
    ;;
  sign)
    [[ -f "${2:-}" ]] || { echo "ERROR: signing input file is missing." >&2; exit 1; }
    sign_file "$2"
    ;;
  sign-feed|verify-feed)
    [[ -f "${2:-}" && "$2" == *.xml ]] || { echo "ERROR: appcast XML input is missing." >&2; exit 1; }
    if [[ "$1" == sign-feed ]]; then
      if ! run_signer "$2" >/dev/null 2>&1; then
        echo "ERROR: Sparkle feed signing failed." >&2; exit 1
      fi
    elif ! run_signer --verify "$2" >/dev/null 2>&1; then
      echo "ERROR: Sparkle feed verification failed." >&2; exit 1
    fi
    ;;
  *) echo "ERROR: expected validate-input, check-key, sign, sign-feed or verify-feed." >&2; exit 1 ;;
esac

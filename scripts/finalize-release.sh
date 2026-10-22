#!/usr/bin/env bash
set +x
set -euo pipefail
usage="Usage: finalize-release.sh [RELEASE_DIR]  (default dist/release, holding both architectures' scripts/release.sh outputs)"
if [[ $# -gt 1 || ( $# -eq 1 && -z "$1" ) ]]; then
  echo "ERROR: $usage" >&2; exit 1
fi
# Resolve caller-relative paths before changing into the repository.
if [[ $# -eq 1 ]]; then
  release_dir="$(cd "$1" 2>/dev/null && pwd -P)" || { echo "ERROR: $1 is not a directory. $usage" >&2; exit 1; }
fi
gate_record="${CAIRN_CHROMIUM_GATE_RECORD:-}"
[[ -f "$gate_record" ]] || {
  echo "ERROR: set CAIRN_CHROMIUM_GATE_RECORD to the chromium-gate.json written by Resources/ReleaseTools/ChromiumGate.py." >&2
  exit 1
}
gate_record="$(cd "$(dirname "$gate_record")" && pwd -P)/$(basename "$gate_record")"
cd "$(dirname "$0")/.."
release_dir="${release_dir:-$PWD/dist/release}"
[[ -d "$release_dir" ]] || { echo "ERROR: $release_dir is not a directory. $usage" >&2; exit 1; }
# The final step of a release and the only one that holds the Sparkle private key. It authenticates the two
# architectures' build outputs and writes the shared update feed and release metadata; it never builds,
# uploads or publishes anything.
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || {
  echo "ERROR: finalizing a release requires SPARKLE_PUBLIC_ED_KEY." >&2; exit 1;
}
scripts/sparkle-release-signing.sh validate-input
outputs=("$release_dir/appcast.xml" "$release_dir/RELEASE-INFO.json" "$release_dir/RELEASE-NOTES.txt"
  "$release_dir/SHA256SUMS")
# Never leave a partly finalized release behind: either every output is written or none is.
cleanup() {
  local status=$?
  [[ $status -eq 0 ]] || rm -f "${outputs[@]}"
  return "$status"
}
trap cleanup EXIT
rm -f "${outputs[@]}"
validate=(validate "$release_dir" --chromium-gate "$gate_record")
if [[ -n "${VERSION:-}" ]]; then
  validate+=(--version "$VERSION")
fi
# Exactly both architectures' intact, consistent files and a gate record for the built Chromium, before any signing.
version="$(python3 Resources/ReleaseTools/ReleaseAssets.py "${validate[@]}")"
if [[ ! -x .build/artifacts/sparkle/Sparkle/bin/sign_update ]]; then
  scripts/swiftw package resolve
fi
scripts/sparkle-release-signing.sh check-key
scripts/make-appcast.sh "$release_dir/appcast.xml" \
  "$release_dir/Cairn-$version-arm64.zip" "$release_dir/Cairn-$version-x86_64.zip"
python3 Resources/ReleaseTools/ReleaseAssets.py publish "$release_dir" --chromium-gate "$gate_record"
echo "Finalized Cairn $version in $release_dir; nothing has been uploaded or published."

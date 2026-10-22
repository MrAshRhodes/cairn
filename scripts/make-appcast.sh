#!/usr/bin/env bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
usage="Usage: make-appcast.sh FEED.xml ARCHIVE.zip [ARCHIVE.zip ...]  (one Cairn-VERSION-ARCH.zip per architecture)"
feed="${1:?$usage}"
shift
[[ $# -ge 1 && "$feed" == *.xml ]] || { echo "ERROR: $usage" >&2; exit 1; }
scripts/sparkle-release-signing.sh validate-input
public_key="${SPARKLE_PUBLIC_ED_KEY:-}"
[[ -n "$public_key" ]] || { echo "ERROR: SPARKLE_PUBLIC_ED_KEY is required." >&2; exit 1; }
# Never leave a stale feed behind: either every archive is authenticated or there is no feed.
rm -f "$feed"
work="$PWD/.build/make-appcast-$$"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
pairs=()
index=0
for archive in "$@"; do
  [[ -f "$archive" && "$archive" == *.zip ]] || { echo "ERROR: signed updates must be ZIP archives" >&2; exit 1; }
  python3 Resources/ReleaseTools/appcast.py check-archive "$archive"
  index=$((index + 1))
  mkdir "$work/app-$index"
  ditto -x -k "$archive" "$work/app-$index"
  app="$work/app-$index/Cairn.app"
  [[ -d "$app" ]] || { echo "ERROR: $archive does not contain Cairn.app" >&2; exit 1; }
  # Authenticate the application inside each archive, not just the archive bytes.
  codesign --verify --deep --strict "$app"
  python3 Resources/ReleaseTools/bundle.py verify "$app"
  pairs+=("$archive" "$app")
done
# The whole release must be consistent before anything is signed.
python3 Resources/ReleaseTools/appcast.py validate "${pairs[@]}"
signed=()
for ((i = 0; i < ${#pairs[@]}; i += 2)); do
  archive="${pairs[i]}"
  signature="$(scripts/sparkle-release-signing.sh sign "$archive")"
  swift Resources/ReleaseTools/VerifySignature.swift "$public_key" "$signature" "$archive"
  signed+=("$archive" "${pairs[i + 1]}" "$signature")
done
python3 Resources/ReleaseTools/appcast.py build "$work/appcast.xml" "${signed[@]}"
scripts/sparkle-release-signing.sh sign-feed "$work/appcast.xml"
scripts/sparkle-release-signing.sh verify-feed "$work/appcast.xml"
swift Resources/ReleaseTools/VerifySignature.swift --feed "$public_key" "$work/appcast.xml"
python3 Resources/ReleaseTools/appcast.py check-feed "$work/appcast.xml" "$@"
mkdir -p "$(dirname "$feed")"
mv "$work/appcast.xml" "$feed"
echo "Created authenticated $feed"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$PWD/.build/release-tests"
mkdir -p "$work"
for script in scripts/bundle-app.sh scripts/make-dmg.sh scripts/make-appcast.sh scripts/*release*.sh; do
  bash -n "$script"
done
shellcheck scripts/bundle-app.sh scripts/make-dmg.sh scripts/make-appcast.sh scripts/*release*.sh
python3 - <<'PY'
import ast
from pathlib import Path
import plistlib
for path in Path("Resources/ReleaseTools").glob("*.py"):
    ast.parse(path.read_text(), filename=str(path))
for path in [Path("Resources/Info.plist"), Path("Resources/Cairn.entitlements")]:
    with path.open("rb") as stream:
        plistlib.load(stream)
print("Python syntax and plist templates validated.")
PY
scripts/swiftw build --product Cairn
framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swiftc -parse-as-library Sources/CairnUpdater/Updater.swift Resources/ReleaseTools/UpdateTests.swift \
  -F "$framework" -framework Sparkle -Xlinker -rpath -Xlinker "$framework" -o "$work/update-tests"
"$work/update-tests" "$work"
python3 Resources/ReleaseTools/PackagingTests.py "$work"
# RFC 8032 public key + signature for an empty message; private material is never needed.
public_key="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
signature="5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
: > "$work/message"
swift Resources/ReleaseTools/VerifySignature.swift "$public_key" "$signature" "$work/message"
printf 'tampered' > "$work/message"
if swift Resources/ReleaseTools/VerifySignature.swift "$public_key" "$signature" "$work/message"; then
  echo "ERROR: tampered signature was accepted" >&2; exit 1
fi
if SPARKLE_PUBLIC_ED_KEY=invalid scripts/bundle-app.sh > "$work/invalid-key.log" 2>&1; then
  echo "ERROR: invalid public key was accepted" >&2; exit 1
fi
if SPARKLE_PRIVATE_ED_KEY='' scripts/make-appcast.sh "$work/missing.zip" > "$work/missing-key.log" 2>&1; then
  echo "ERROR: unsigned appcast was accepted" >&2; exit 1
fi
echo "Release tooling checks passed, including fail-closed and tamper checks."

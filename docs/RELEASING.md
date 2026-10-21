# Packaging and authenticated updates

Cairn is an independent macOS browser. Its icon is original vector artwork generated
with AppKit (`Resources/ReleaseTools/Icon.swift`), not an asset from another browser.
No account or telemetry service is used. Sparkle system profiling is explicitly
disabled, including any previously saved preference. Update checking contacts
GitHub; automatic checking is **off by default**, opt-in in Settings. Installation
uses Sparkle's native UI and consent flow.

## Local development (no Apple account)

Requires macOS 14+, Swift 6+, Python 3, Command Line Tools (or Xcode), and ShellCheck.
No Node installation is required. `scripts/swiftw` supports CLT-only installations.

```sh
scripts/swiftw test
scripts/test-release.sh
ARCH=arm64 scripts/bundle-app.sh
scripts/make-dmg.sh
open dist/Cairn.app
```

`make app` and `make dmg` are shortcuts. Use `ARCH=x86_64` or `ARCH=universal`
for an Intel or universal binary, and `CONFIGURATION=debug` for a debug build.
The default architecture is the host's architecture. Universal packaging builds
each slice independently, then combines the executable with `lipo`.

Without `SIGNING_IDENTITY`, everything is explicitly **ad-hoc signed**, not Developer
ID signed, not notarized, and not trusted by Gatekeeper for public distribution.
Do not tell users to disable Gatekeeper globally. The script verifies nested code
signatures, architecture, Sparkle linkage, and the app-relative framework rpath.
Sparkle symlinks and executable bits are preserved with `ditto`; nested Mach-O files,
XPC services, helper apps, and frameworks are signed inside-out, not with `--deep`.
The non-sandboxed WebKit host has only camera/microphone usage entitlements; it does
not enable JIT, disable library validation, or add sandbox bypasses.
The transport-security exception applies only to browser web content, so users can
visit HTTP pages; Sparkle's update transport remains HTTPS-only.

## Update trust and public key

The stable feed is:

`https://github.com/mrashrhodes/cairn/releases/latest/download/appcast.xml`

Before first public distribution, the maintainer must provision and securely back up
a Sparkle Ed25519 key using the official Sparkle tooling. **These scripts do not
generate keys, export Keychain keys, configure GitHub secrets, or publish locally.**
Do not commit a private key. The future public repository must exist before the feed
can work.

Set `SPARKLE_PUBLIC_ED_KEY` to the canonical base64 public key when bundling.
`Resources/Info.plist` contains a placeholder which the bundle script substitutes,
never a private key. A supplied malformed/zero key fails the build. A missing key
is permitted only for local development: the updater remains inactive, Settings
can display `configurationError`, and Check for Updates presents a native error.
Running an unbundled `swift run Cairn` likewise cannot start the updater.

Every configured build requires:

* `SUPublicEDKey`: a nonzero 32-byte Ed25519 public key.
* `SUVerifyUpdateBeforeExtraction = true`: authenticate the ZIP **before extraction**.
* `SURequireSignedFeed = true`: authenticate appcast content as well.
* `SUSignedFeedFailureExpirationInterval = 0`: never fall back to an unsigned feed.
* HTTPS feed URLs without embedded credentials and system profiling disabled.

Release archives are ZIPs, not Developer ID disk-image signature fallbacks. Missing
or invalid configuration fails closed. Keep the key stable: losing it means these
clients cannot authenticate another ZIP; arrange a separately authenticated manual
reinstallation instead of weakening the validation policy.

## Prepare a release locally

After securely supplying the public key and the private Ed25519 key as environment
variables from your secret manager (do not type private material into shell history):

```sh
VERSION=0.1.0 ARCH=universal scripts/release.sh
```

This runs tests, builds, optionally notarizes, creates a ZIP and DMG, and signs the
ZIP and appcast with Sparkle 2.10's resolved `sign_update` tool. The private key is
passed through **stdin**, never a command-line argument or file. CryptoKit verifies
the ZIP and feed signatures against the public key embedded in the app, rejecting
mismatched key pairs; Sparkle also verifies the signed feed. No deltas or remote release-note
content are emitted. The archive's Info.plist must match the supplied app.

Output: `dist/release/Cairn-VERSION-ARCH.zip`, `.dmg`, `appcast.xml`, `SHA256SUMS`,
`RELEASE-INFO.json`, and `RELEASE-NOTES.txt`. The latter two state actual Apple signing
and notarization status. Local preparation **does not upload or publish anything**.
The signature is on the final stapled ZIP bytes, so do not modify archives or the
appcast after signing.

For individual steps:

```sh
VERSION=0.1.0 BUILD_NUMBER=0.1.0 ARCH=universal scripts/bundle-app.sh
ditto -c -k --sequesterRsrc --keepParent dist/Cairn.app dist/Cairn-0.1.0-universal.zip
scripts/make-appcast.sh dist/Cairn-0.1.0-universal.zip dist/Cairn.app dist/appcast.xml
scripts/make-dmg.sh dist/Cairn.app dist/Cairn-0.1.0-universal.dmg
```

`CFBundleVersion` must increase on every update; by default it matches the numeric
release version. Never reissue the same tag/version with different bytes or a new key.
Use universal releases for the stable feed so both supported architectures receive
the same release. ARM-only feeds include Sparkle's `arm64` hardware requirement.
Intel-only app/DMG builds are supported, but the appcast generator rejects them:
Sparkle 2.10 has no Intel-only hardware requirement, so an Intel-only update could
replace an ARM app with a Rosetta-dependent app. Use universal releases instead.

## Optional Developer ID and notarization

For an already-installed local identity:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE='cairn-notary' \
VERSION=0.1.0 ARCH=universal scripts/release.sh
```

Provision the profile yourself with Apple's `notarytool`; Xcode/notarytool must be
available. Without a notary profile/credentials the release is **not notarized** even
if it is Developer ID signed. Partial credentials or notarization failure stop release
preparation rather than silently downgrading. App and DMG are separately submitted,
accepted, stapled, and validated. The app is checked with `spctl` after stapling.

CI can import an existing Developer ID certificate into a short-lived keychain under
`.build/release-signing`, which is deleted on exit. It never changes the default
keychain or the user's keychain search list. Do not enable shell tracing around secrets.

## GitHub Actions (maintainer setup, not automatic secret provisioning)

CI tests on macOS Apple Silicon and Intel, validates workflows/shell scripts, and
produces clearly ad-hoc DMGs without any secrets.

The release workflow accepts stable `vMAJOR.MINOR.PATCH` tags. Create a protected
`release` environment and tag rules that require maintainer approval. Configure:

| Name | Location | Requirement |
| --- | --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | environment/repository variable | Required public key |
| `SPARKLE_PRIVATE_ED_KEY` | environment secret | Required; official Sparkle exported key text |
| `APPLE_CERTIFICATE_P12_BASE64` | environment secret | Optional existing Developer ID certificate, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | environment secret | Required when importing that certificate |
| `APPLE_SIGNING_IDENTITY` | environment secret | Full Developer ID Application identity for that certificate |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | environment secrets | Optional notarization credentials, all three required together |

With only Sparkle keys, the public release is Ed25519-authenticated but **ad-hoc and
not notarized**, as its release notes state. With no Sparkle keys, release fails;
there is no unsigned fallback. Appcast consumers need no GitHub account.

Actions are pinned to reviewed full commit SHAs; checkout does not persist credentials.
The build job has only `contents: read`; the separate publish job has `contents: write`
and no signing secrets. It verifies artifact checksums and publishes the versioned ZIP,
DMG, appcast, and checksums to the tag's GitHub release. Update action pins deliberately.
Manual dispatch must select an existing release tag; dispatch from a branch does nothing.
The architecture input defaults to `universal`. Do not mix older manually published
versions into GitHub's `latest` release or overwrite release assets.

## Optional Chromium assembly

The default build never downloads or bundles Chromium. Once the optional engine has
been fetched/built following `engine/` documentation:

```sh
CAIRN_WITH_CHROMIUM=1 ARCH=arm64 scripts/bundle-app.sh
```

The script sets `CAIRN_CEF_ARCH` from `ARCH` for the gated SwiftPM manifest and calls
`python3 engine/bundle.py --app APP --configuration release --arch ARCH`
after the native executable is built, before signing. Fetch and build the matching
engine architecture first (including its required pin markers), following
`docs/UPDATING_CHROMIUM.md`. Missing engine packaging fails;
there is no placeholder or WebKit masquerading as Chromium. The hook must include real
CEF frameworks, resources, architecture-matched helpers, notices and helper entitlements.
Renderer and GPU helpers receive `engine/entitlements/renderer.plist`; other helpers
receive `engine/entitlements/helper.plist`. The host retains the minimal Cairn entitlements.
The CEF bundler currently requires a single architecture and rejects universal.
Ad-hoc development signing is intentionally not hardened; a hardened CEF distribution
requires all nested code to use the same Developer ID identity. Library validation is
never disabled to conceal mismatched Team IDs.
Chromium has its own security/update cadence; the default
release workflow intentionally builds WebKit only until the engine is release-ready.

## Validation boundaries

`scripts/test-release.sh` exercises the real updater's fail-closed configuration,
validates a public RFC 8032 signature and rejects tampering without generating private
keys. A real local ad-hoc app/DMG and linkage can be verified without Apple credentials.
End-to-end update installation requires a real key, two increasing app versions and an
accessible feed; Apple signing/notarization requires your account. Test those before
the first public release. No local validation alone establishes Gatekeeper trust.

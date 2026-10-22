# Packaging and authenticated updates

Cairn is an independent macOS browser. Its icon is original vector artwork generated
with AppKit (`Resources/ReleaseTools/Icon.swift`), not an asset from another browser.
No account or telemetry service is used. Sparkle system profiling is explicitly
disabled, including any previously saved preference. Update checking contacts
GitHub; automatic checking is **off by default**, opt-in in Settings. Installation
uses Sparkle's native UI and consent flow.

## v0.1.0 release path and status

This guide is for maintainers preparing and publishing Cairn developer previews.
The v0.1.0 publishing path is **local Keychain signing, followed by a separate,
explicit upload of the finished release assets**. GitHub Actions signing is not
configured: no private signing material has been uploaded to GitHub.

The published v0.1.0 artifact is **WebKit, universal arm64/x86_64, ad-hoc signed, and
not notarized**. It is a developer preview, not a Gatekeeper-trusted distribution.
The integrated GUI has **not yet been manually verified**. Build, packaging and
signature checks must not be presented as a completed manual GUI acceptance test.

The public update key for this release is:

```text
ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8=
```

This public key may be committed or stored as a GitHub variable. Its corresponding
private key stays in the maintainer's local Keychain; never print it, pass it in
command-line arguments, write it to a key file, or upload it to GitHub.

## Weekly release automation

The Release workflow checks the default branch every **Monday at 06:17 UTC**.
GitHub schedules are best-effort, not a guaranteed publication time. It compares
the checked-out commit with the latest published stable release:

- No net product changes: skip testing, building, version creation and publication.
  README, website, test-only and workflow-only edits do not trigger a release.
- Product changes: inspect commits touching the changed product files. A
  conventional `feat:` / `feat(scope):` bumps minor; `type!:` or a
  `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer bumps major. Other changes bump
  patch. The largest applicable bump wins.
- Run the reusable CI workflow on Apple Silicon and Intel, then build and
  authenticate the **universal WebKit** preview. The derived version is embedded
  in the app, archive names and appcast; no version-only commit is pushed.
- Verify transferred checksums, ensure the latest release has not changed, and
  publish a new release/tag targeting the tested commit, without overwriting
  existing artifacts. A failed
  build or signing check publishes nothing. An existing unpublished planned tag
  fails closed instead of overwriting it.

This pipeline **does not publish Chromium**. Public Chromium distribution still
requires the security review, both-architecture packaging/update strategy and
real-device signing checks in the Chromium guide. Weekly scheduling does not
close an upstream security gap.

In Actions, select **Release → Run workflow**, on the default branch, with
`dry_run` enabled to inspect the next version and run CI without signing or
publication. Disable it only for an intended authenticated release. Pushing an
explicit stable `vMAJOR.MINOR.PATCH` tag also runs the same pipeline; the tag must
identify the checked-out commit and be newer than the current release.

**CI publication is currently blocked on signing provisioning.** Only the public
Sparkle key is configured in GitHub. The existing private key remains in the local
Keychain. After a separate, explicit maintainer security decision, configure a
protected `release` environment with the matching `SPARKLE_PRIVATE_ED_KEY` secret
and retain `SPARKLE_PUBLIC_ED_KEY` as a variable. Optional Apple signing and
notarization credentials are described below. Do not create a replacement Sparkle
key: installed clients trust the existing public key. Until provisioning is
approved, scheduled product releases stop with an explicit error; local
Keychain-native signing remains available.

The Homebrew tap independently checks published releases and updates its cask
only after verifying the release artifacts. The product site deploys from `site/` using the Product site
workflow; site-only changes never create a browser release.

## Local development (no Apple account)

Requires macOS 14+, Swift 6+, Python 3, Command Line Tools (or Xcode), and ShellCheck.
Chromium packaging also requires CMake 3.21+ and Python 3.12+ (or a Python with
`tarfile.data_filter`). No Node installation is required. `scripts/swiftw` supports
CLT-only installations.

```sh
scripts/swiftw test
scripts/test-release.sh
make cef
scripts/bundle-app.sh
scripts/make-dmg.sh
open dist/Cairn.app
```

`scripts/bundle-app.sh` packages the experimental Chromium variant by default
(`CAIRN_WITH_CHROMIUM=1`) for a single architecture, the host's unless `ARCH` is set.
It never downloads CEF: run `make cef` first. A missing or stale engine fails the
build; there is no WebKit fallback. `make app`, `make run` and `make dmg` prepare
CEF and bundle in one step. For WebKit packaging, including Intel-on-Apple-Silicon
or universal binaries, set `CAIRN_WITH_CHROMIUM=0` explicitly (for example
`CAIRN_WITH_CHROMIUM=0 ARCH=universal scripts/bundle-app.sh`); `make webkit-app`
is the host-architecture shortcut. `scripts/release.sh` and the release workflow
keep `CAIRN_WITH_CHROMIUM=0`. Use `CONFIGURATION=debug` for a debug build.
Universal WebKit packaging builds each slice independently, then combines the
executable with `lipo`.

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

Before first public distribution, the maintainer must provision and securely retain
a Sparkle Ed25519 key using the official Sparkle tooling. **The packaging scripts do
not generate keys, configure GitHub secrets, or publish releases.** Do not commit a
private key. The feed works only once the public repository has a release containing
the authenticated appcast and its exact matching archive.

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

## Prepare v0.1.0 using the local Keychain

Run these commands from the integrated repository checkout. Resolve Sparkle's tools
with `scripts/swiftw build --product Cairn` if they are not already available.

### One-time key provisioning

The per-app Keychain account is `io.github.mrashrhodes.cairn`, with service
`https://sparkle-project.org`. At initial provisioning only, the maintainer runs:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account io.github.mrashrhodes.cairn
```

This creates a Keychain item, or reuses the item if it already exists, and prints
only the public key. The v0.1.0 public key above is already designated: **do not
generate a replacement on another machine and publish it under the same version**.
If the original item is unavailable, stop and recover it securely. Do not use the
tool's private-key export option or copy private material into shell history.

### Build and authenticate the local preview

Use **Keychain-native signing** for local publication. Set the account name and the
known public key; do not export private material from Keychain. The release script
calls the official `sign_update --account` tool for the archive and feed, and uses
the same account for feed verification. Neither `generate_keys -p` nor a raw Keychain
password lookup is needed during a release.

```bash
(
  set +x
  set -euo pipefail
  unset SPARKLE_PRIVATE_ED_KEY
  export SPARKLE_KEYCHAIN_ACCOUNT=io.github.mrashrhodes.cairn
  export SPARKLE_PUBLIC_ED_KEY='ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8='

  # Explicitly select the ad-hoc, non-notarized WebKit developer-preview path.
  unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY
  unset APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD NOTARY_KEYCHAIN_PROFILE SIGNING_KEYCHAIN
  CAIRN_WITH_CHROMIUM=0 SIGNING_IDENTITY=- \
    VERSION=0.1.0 BUILD_NUMBER=0.1.0 ARCH=universal scripts/release.sh

  scripts/sparkle-release-signing.sh verify-feed dist/release/appcast.xml
  swift Resources/ReleaseTools/VerifySignature.swift --feed \
    "$SPARKLE_PUBLIC_ED_KEY" dist/release/appcast.xml
)
```

Before tests or compilation, the script signs an empty, nonsecret probe and verifies
its signature against `SPARKLE_PUBLIC_ED_KEY` with CryptoKit. A missing/denied Keychain
item, a signer failure, or a mismatched public key stops the release before building.
If the resolved Sparkle tools are absent, dependency resolution runs first; it does
not build or sign an app. The probe is removed afterward.

macOS may still ask for permission for the official Sparkle signer to access its
Keychain item. Allow access only to the expected signer. If access is blocked, unlock
the appropriate Keychain or cancel and resolve its access controls; do not work around
it by exporting the secret. There is no automatic fallback to a different account,
unsigned output, or raw password extraction.

Do not use `echo`, `tee`, shell tracing, an argument such as `--body`, or a file
redirect to expose or persist private material. Do not add a `gh secret set` step.

The release script runs tests, builds, creates a ZIP and DMG, and signs the ZIP and
appcast with Sparkle 2.10's resolved `sign_update` tool. In Keychain-native mode, only
the official signer accesses the private item; the shell never receives it. CryptoKit verifies
the actual ZIP and feed signatures against the public key embedded in the app,
rejecting mismatched key pairs; Sparkle also verifies the signed feed. These are
real-key checks, not the public test-vector checks in the tooling test suite.
No deltas or remote release-note content are emitted. The archive's Info.plist must
match the supplied app.

For a signing-only access check without building an application, use the same public
key/account environment and run `scripts/sparkle-release-signing.sh check-key`.
`scripts/make-appcast.sh` accepts the same account mode for already-prepared archives.

The existing CI interface remains supported for a future explicit provisioning
decision: set `SPARKLE_PRIVATE_ED_KEY` to Sparkle's canonical base64 secret and leave
`SPARKLE_KEYCHAIN_ACCOUNT` unset. Only that mode passes the private value to the signer
through stdin. Setting both modes, or neither, is an error. The local publication path
does not use the environment-key mode and does not upload private material to CI.

Output: `dist/Cairn.app`, `dist/release/Cairn-0.1.0-universal.zip`,
`dist/release/Cairn-0.1.0-universal.dmg`, `appcast.xml`, `SHA256SUMS`,
`RELEASE-INFO.json`, and `RELEASE-NOTES.txt` in the release directory. The latter two
state actual Apple signing and notarization status. Local preparation **does not
upload or publish anything**. Do not modify the archives or appcast after signing.

### Publish finished assets separately

Publication is a separate maintainer action, outside the signing subshell. First
review the generated release notes and verify the asset checksums with
`(cd dist/release && shasum -a 256 -c SHA256SUMS)`. The command below preserves the
generated notes and appends the GUI verification limitation to the public release
description without changing any checksummed file.

After the maintainer has approved publication, ensure the reviewed release commit
is already present on GitHub. Create the remote `v0.1.0` tag through `gh release`
rather than separately pushing a tag, so this local publication path does not
deliberately invoke the tag-push release workflow. Upload only the final public assets:

```sh
release_commit="$(git rev-parse HEAD)"
gh release create v0.1.0 --repo mrashrhodes/cairn --target "$release_commit" \
  --title 'Cairn v0.1.0 — developer preview' \
  --notes "$(cat dist/release/RELEASE-NOTES.txt; printf '\nIntegrated GUI has not yet been manually verified.\n')" \
  dist/release/Cairn-0.1.0-universal.zip \
  dist/release/Cairn-0.1.0-universal.dmg \
  dist/release/appcast.xml dist/release/SHA256SUMS \
  dist/release/RELEASE-INFO.json dist/release/RELEASE-NOTES.txt
```

Do not run a separate `git push` for the tag. Never overwrite or move the tag after
publication. No Keychain item, environment dump, private-key file, certificate or
signing secret belongs in a release asset. The stable updater URL resolves GitHub's latest normal
release; a GitHub draft or prerelease alone does not make that URL available. The
developer-preview label does not imply notarization or completed GUI verification.

For individual packaging steps, while the required signing environment is available:

```sh
CAIRN_WITH_CHROMIUM=0 VERSION=0.1.0 BUILD_NUMBER=0.1.0 ARCH=universal scripts/bundle-app.sh
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

This is a future opt-in path, not the v0.1.0 preview's signing status. With the
Sparkle environment available inside the same non-tracing subshell and an
already-installed local identity, choose a new, unused version higher than the
published preview:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE='cairn-notary' \
VERSION=0.1.1 ARCH=universal scripts/release.sh
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

CI tests on macOS Apple Silicon and Intel, validates workflows/shell scripts, prepares
CEF with `make cef`, runs the development ad-hoc Chromium smoke test
(`engine/smoke.py --development-ad-hoc`), and packages a clearly ad-hoc,
single-architecture Chromium DMG per runner without any secrets. Those DMGs are
short-lived development artifacts, not releases. This is a functional Chromium
check, **not** a Developer ID, notarization, hardened-runtime or CEF security-gap
gate.

**Automatic release signing/publication is not configured for v0.1.0.** Private
signing material has not been uploaded to GitHub and is not uploaded by the local
publishing recipe. If a tag push starts the workflow without the protected `release`
environment's `SPARKLE_PRIVATE_ED_KEY`, release preparation fails closed: the build
job fails and its dependent publish job cannot publish. There is no secret-presence
gate that skips the entire workflow. A checked-in workflow is not evidence that its
signing environment is ready.

The public key alone may be stored as the `SPARKLE_PUBLIC_ED_KEY` GitHub variable.
It cannot sign a release or enable automatic publication.

If the repository owner later explicitly chooses to enable CI signing, that is a
separate user-owned provisioning decision. The workflow accepts stable
`vMAJOR.MINOR.PATCH` tags and requires a protected `release` environment and tag rules
with maintainer approval. Its inputs are:

| Name | Location | Requirement |
| --- | --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | environment/repository variable | Required public key |
| `SPARKLE_PRIVATE_ED_KEY` | environment secret | Required; official Sparkle exported key text |
| `APPLE_CERTIFICATE_P12_BASE64` | environment secret | Optional existing Developer ID certificate, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | environment secret | Required when importing that certificate |
| `APPLE_SIGNING_IDENTITY` | environment secret | Full Developer ID Application identity for that certificate |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | environment secrets | Optional notarization credentials, all three required together |

If configured in the future with only Sparkle keys, CI would produce an
Ed25519-authenticated but **ad-hoc and not notarized** release. Missing keys never
produce an unsigned fallback. Appcast consumers need no GitHub account.

Actions are pinned to reviewed full commit SHAs; checkout does not persist credentials.
The build job has only `contents: read`; the separate publish job has `contents: write`
and no signing secrets. When enabled and supplied with authenticated build artifacts,
it verifies checksums and publishes the versioned ZIP, DMG, appcast, and checksums to
the tag's GitHub release. Update action pins deliberately.
Manual dispatch must select an existing release tag; dispatch from a branch does nothing.
The architecture input defaults to `universal`. Do not mix older manually published
versions into GitHub's `latest` release or overwrite release assets.

## Chromium assembly

`scripts/bundle-app.sh` packages Chromium by default; local `make build`, `make app`,
`make run` and `make dmg` also fetch, verify and build CEF for the host architecture
first. The bundler itself never downloads CEF. `scripts/release.sh` and the release
workflow keep `CAIRN_WITH_CHROMIUM=0`, so published releases do not include Chromium.
Prepare the engine for the architecture being packaged:

```sh
# Host architecture:
make cef
scripts/bundle-app.sh
# Explicit single architecture; prepare the matching engine first:
python3 engine/tool.py fetch --arch arm64
python3 engine/tool.py build --arch arm64
ARCH=arm64 scripts/bundle-app.sh
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
Chromium has its own security/update cadence; `scripts/release.sh` and the release
workflow intentionally build WebKit (`CAIRN_WITH_CHROMIUM=0`) until the engine is
release-ready.

## Validation boundaries

`scripts/test-release.sh` exercises the real updater's fail-closed configuration,
validates a public RFC 8032 signature and rejects tampering without generating private
keys. Signing-mode regression tests use an isolated fake external signer and real
CryptoKit public-signature verification; they never access the user's Keychain or sign
a live app. They cover both modes, ambiguous/missing credentials, inaccessible keys,
key mismatches before building, and suppressed signer diagnostics.
A real local ad-hoc app/DMG and linkage can be verified without Apple credentials.
End-to-end update installation requires a real key, two increasing app versions and an
accessible feed; Apple signing/notarization requires your account. Test those before
broad distribution. The v0.1.0 developer preview has not yet had its integrated GUI
manually verified. No local build or signature validation alone establishes
Gatekeeper trust or interactive GUI correctness.

# Packaging and authenticated updates

Cairn is an independent macOS browser. Its icon is original vector artwork generated
with AppKit (`Resources/ReleaseTools/Icon.swift`), not an asset from another browser.
No account or telemetry service is used. Sparkle system profiling is explicitly
disabled, including any previously saved preference. Update checking contacts
GitHub; automatic checking is **off by default**, opt-in in Settings. Installation
uses Sparkle's native UI and consent flow.

## Release path and status

This guide is for maintainers building, authenticating and publishing Cairn
previews. Current source and future public releases are **Chromium-only**, with
separate arm64 and x86_64 applications and one authenticated update feed. Build
both architectures before finalizing a release; never replace a missing build
with WebKit or publish a one-architecture stable feed.

Local publication uses **Keychain signing followed by a separate, explicit upload**.
GitHub Actions signing is not configured: no private signing material has been
uploaded to GitHub.

The published v0.1.0 artifact is **WebKit, universal arm64/x86_64, ad-hoc signed, and
not notarized**. It is a developer preview, not a Gatekeeper-trusted distribution.
The integrated GUI has **not yet been manually verified**. Build, packaging and
signature checks must not be presented as a completed manual GUI acceptance test.

As of **2026-10-23**, `v0.2.0` is an unpublished draft prerelease with no assets,
not an installable Chromium release or an upgrade available from the stable feed.
The checked-in release machinery does not change that status.

The public update key designated by v0.1.0, and retained for compatible updates, is:

```text
ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8=
```

This public key may be committed or stored as a GitHub variable. Its corresponding
private key stays in the maintainer's local Keychain; never print it, pass it in
command-line arguments, write it to a key file, or upload it to GitHub.

## Public Chromium release gates

Use this checklist to decide whether a candidate may be published, not merely
whether its build succeeded. Record the exact commit, CEF pin, architecture,
signing mode, command or manual steps, result and retained evidence for each gate.
Historical evidence must not be silently carried over to changed engine bytes.

| Gate | Required evidence; current boundary |
| --- | --- |
| CEF currency | The committed pin is CEF 154.0.34 / Chromium 154.0.8037.98. On 2026-10-23 it still failed the fail-closed currency check (exit 2) because it trails Chrome stable. The newest stable CEF, 156.0.8 / Chromium 156.0.8078.48, matches Chrome stable, but a local arm64 trial of it passed the build and unit checks and then failed the runtime smoke on both attempts ([#32](https://github.com/MrAshRhodes/cairn/issues/32)), so it is not adopted. The external-protocol race ([#31](https://github.com/MrAshRhodes/cairn/issues/31)) has a locally verified fix; the integrated 154 smoke still fails the popup Boost gate below. Require a fresh fail-closed check, reviewed security/API changes and a passing smoke on both architectures for the exact pin to ship. Consult the [dated maintenance status](UPDATING_CHROMIUM.md#status-2026-10-23); matching versions are not a CVE/backport audit or a passed release-security gate. A written gap acknowledgement covers only that confirmed gap, never the other gates. |
| Unsaved-page safety | [#22](https://github.com/MrAshRhodes/cairn/issues/22): close asks pages through `beforeunload`, keeps Stay pages and their records, and discards only through explicit Force Close commands. The local arm64 CEF 154.0.34 bundled run on 2026-10-23 emitted `CAIRN_CLOSE_LIFECYCLE_OK`, including immediate re-close after Stay, renderer-crash recovery, independent decisions, popup veto and explicit force close. Native Intel and packaged window/Space close, cancel/approve and multi-tab quit still require acceptance without prematurely removing workspace state. Until that evidence exists, this blocks public Chromium distribution, even a preview. |
| Popup first-document Boosts | [#24](https://github.com/MrAshRhodes/cairn/issues/24) remains blocked: early DevTools registration still misses an adopted popup's first document. The strict bundled smoke reports this failure; do not skip it or pause/replay popup requests. Require exactly-once start/end execution with trust/host guards, preserved opener/POST/named-window semantics and revocation-safe renderer initialization on both architectures. |
| Native Intel and CI | Both macOS jobs passed tests, bundled runtime smoke and ad-hoc packaging at `8a76627` with CEF 154 in [run 39926654607](https://github.com/MrAshRhodes/cairn/actions/runs/39926654607), after the compiler fix for [#30](https://github.com/MrAshRhodes/cairn/issues/30). Full native Intel GUI/signed-runtime acceptance and runner continuity remain open in [#8](https://github.com/MrAshRhodes/cairn/issues/8). Repeat CI for changed candidate code or engine bytes. Cross-build, Mach-O inspection and Rosetta are not native execution evidence. |
| Integrated GUI and real sites | Exercise startup/restoration, navigation, Spaces/splits, popups, sign-in, permissions, native print/save panels, downloads and recovery in the full app. Loopback engine fixtures and fake service tests are useful but do not close this gate. |
| Accessibility | Complete keyboard-only and VoiceOver journeys across browser chrome, prompts, command bar, downloads and web content; verify focus entry/return and announcements. Labels and automated tests alone are insufficient. |
| Soak and recovery | Retain duration, workload and crash/resource observations for long browsing, many tabs, active downloads, sleep/wake, network loss and relaunch. A short smoke run is not a soak. |
| Distribution and updates | Verify the actual downloaded artifacts, increasing-version Sparkle installation on both architectures, architecture selection, profile preservation and rollback/recovery using copies. Confirm the external Homebrew tap uses the per-architecture archives. Synthetic signing tests do not prove this path. |
| Documentation | Keep capability, pin/provenance, validation limits and release notes consistent. Distinguish implemented-but-unverified behavior from missing features; never describe an unpublished draft as an available release. |

The [functional specification](reference/functional-spec.md#release-readiness-boundaries)
defines feature boundaries; the [validation section](#validation-boundaries)
explains what packaging and signing tests do not prove.

**Trust is a separate dimension.** A local or CI ad-hoc build is development
evidence, not an Apple-trusted release. Sparkle Ed25519 signatures authenticate
the update archive and feed; they neither supply Developer ID nor notarization.
A trusted public distribution additionally requires same-team Developer ID
signing, Hardened Runtime, notarization, stapling and Gatekeeper acceptance of
the downloaded app and DMG. An intentionally ad-hoc preview must say so explicitly
and must not be presented as meeting that trust gate. A preview label, draft
release, risk acknowledgement or successful signature check cannot waive the
unsaved-page safety or other public-release gates.

## Weekly release automation

The Release workflow is configured to check the default branch every **Monday at 06:17 UTC**.
GitHub schedules are best-effort, not a guaranteed publication time. It compares
the checked-out commit with the latest published stable release:

- No net product changes: skip testing, building, version creation and publication.
  README, website, test-only and workflow-only edits do not trigger a release.
- Product changes: inspect commits touching the changed product files. A
  conventional `feat:` / `feat(scope):` bumps minor; `type!:` or a
  `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer bumps major. Other changes bump
  patch. The largest applicable bump wins.
- Run the reusable CI workflow on Apple Silicon and Intel and check Chromium's
  security status. Build a Chromium app per architecture, then finalize both
  archives into one authenticated feed. The derived version is embedded in the
  app, archive names and appcast; no version-only commit is pushed.
- Verify transferred checksums, ensure the latest release has not changed, and
  publish a new release/tag targeting the tested commit, without overwriting
  existing artifacts. A failed
  build or signing check publishes nothing. An existing unpublished planned tag
  fails closed instead of overwriting it.

This pipeline publishes **only Chromium**. Public distribution still requires
security review and real-device signing checks in the Chromium guide. Weekly
scheduling does not close an upstream security gap. The release gate fails when
CEF trails Chrome stable or upstream metadata cannot be checked; it never falls
back to WebKit.

In Actions, select **Release → Run workflow**, on the default branch, with
`dry_run` enabled to inspect the next version and run CI without signing or
publication. Dry runs also run the security gate. To accept a confirmed gap,
a maintainer must supply a reviewed, written rationale in the manual
`chromium_risk_acknowledgement` input (20–500 printable characters, one line).
The rationale is recorded with the gate result and release metadata; it cannot
override unavailable or invalid upstream metadata. Scheduled and tag-triggered
runs have no acknowledgement and remain blocked by a gap. Finalization rejects a
gate record older than 24 hours, so an approval that waits longer requires a new run.
Disable `dry_run` only for an intended authenticated release. Pushing an
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

The external Homebrew tap must support the new per-architecture archive names
and checksums before the next release; its existing universal v0.1.0 cask is not
updated by changes in this repository. The product site deploys from `site/` using the Product site
workflow; site-only changes never create a browser release.

## Local development (no Apple account)

Requires macOS 14+, Swift 6+, Python 3, Command Line Tools (or Xcode), and ShellCheck.
Chromium packaging also requires CMake 3.21+ and Python 3.12+ (or a Python with
`tarfile.data_filter`). No Node installation is required. `scripts/swiftw` supports
CLT-only installations.

```sh
make cef
scripts/swiftw test
scripts/test-release.sh
scripts/bundle-app.sh
scripts/make-dmg.sh
open dist/Cairn.app
```

`scripts/bundle-app.sh` packages Chromium for a single architecture, the host's
unless `ARCH=arm64` or `ARCH=x86_64` is set. It never downloads CEF: run `make cef`
first. A missing or stale engine fails packaging; there is no WebKit fallback.
`make app`, `make run` and `make dmg` prepare CEF and bundle in one step. `make cef`,
`make app`, `make run` and `make dmg` take the same `ARCH` variable: `make app ARCH=x86_64`
cross-builds the Intel app on an Apple Silicon Mac, while `make build` and `make test`
compile for this machine and should run without it.
Universal packaging and the old WebKit build targets are removed. Setting
`CAIRN_WITH_CHROMIUM=0` is an error, not an alternate build mode.
Use `CONFIGURATION=debug` for a debug build.

Without `SIGNING_IDENTITY`, everything is explicitly **ad-hoc signed**, not Developer
ID signed, not notarized, and not trusted by Gatekeeper for public distribution.
Do not tell users to disable Gatekeeper globally. The script verifies nested code
signatures, architecture, Sparkle linkage, and the app-relative framework rpath, and
finishes with the [packaging gate](#packaging-gate): `scripts/verify-bundle.sh` fails the
build on any layout, Info.plist, architecture, signature or entitlement problem.
Sparkle symlinks and executable bits are preserved with `ditto`; nested Mach-O files,
XPC services, helper apps, and frameworks are signed inside-out, not with `--deep`.
The main app retains minimal camera, microphone, location and Bluetooth entitlements (a site only
gets them after the user allows it in Cairn's own permission prompt); renderer and
GPU helpers receive the CEF JIT entitlement, and the generic helper, where capture
runs, receives the camera/microphone entitlements. Library validation is not disabled.
Chromium handles web networking itself; the former WebKit-only transport-security
exception is removed. Sparkle's update transport remains HTTPS-only.

The Bluetooth entitlement and its Info.plist usage string mirror Chromium's own app
entitlements. Cairn has no Web Bluetooth chooser, so the entitlement is dormant, but macOS
terminates an app that reaches a privacy-protected API without its usage string, and a
hardened app needs the entitlement for the prompt to appear at all. To run stricter, remove
the entitlement in `Resources/Cairn.entitlements`, the usage string in `Resources/Info.plist`,
and the string's entry in `scripts/verify-bundle.sh` and `Resources/ReleaseTools/VerifyBundleTests.py`
together; the gate compares the signed entitlements with the source plist, so nothing else changes.

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

## Prepare the next release locally

Use the same reviewed commit and an unused version newer than the published
release on both builders. Examples use `0.1.1`; substitute the approved version
consistently. Run commands from the repository root. Resolve Sparkle's tools with
`scripts/swiftw package resolve`; this does not require CEF or build an app.

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

### Build each architecture

The build stage needs the **public** Sparkle key, not the private signing key or
Keychain account. On an Apple Silicon builder, prepare CEF and build arm64:

```bash
(
  set +x
  set -euo pipefail
  unset SPARKLE_PRIVATE_ED_KEY SPARKLE_KEYCHAIN_ACCOUNT
  export SPARKLE_PUBLIC_ED_KEY='ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8='
  # Explicit development-only signing; use the Developer ID recipe below instead
  # when producing a hardened, notarized distribution.
  unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY
  unset APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD NOTARY_KEYCHAIN_PROFILE SIGNING_KEYCHAIN
  python3 engine/tool.py fetch --arch arm64
  python3 engine/tool.py build --arch arm64
  SIGNING_IDENTITY=- VERSION=0.1.1 BUILD_NUMBER=0.1.1 ARCH=arm64 scripts/release.sh
)
```

Repeat on an Intel builder, replacing `arm64` with `x86_64`. Use the same version,
build number, source commit, public key and signing mode. Each invocation writes
`Cairn-0.1.1-ARCH.zip`, `.dmg` and `.json` into `dist/release`; the JSON records
checksums and build provenance. It does not authenticate a feed or publish.
Before it finishes, `scripts/release.sh` runs the [packaging gate](#packaging-gate) on
the ZIP and the DMG themselves (the ZIP is extracted and the image mounted read-only
under `.build`), so what users download is what is verified; a notarized build is also
checked after stapling and before the DMG is built. A failing rule stops the build and
names every problem.
Copy both builders' three files into one clean release directory. Do not mix
versions or retain unrelated files there.

### Check the engine and authenticate both builds

On the finalization Mac, generate a gate record outside the release directory:

```sh
python3 Resources/ReleaseTools/ChromiumGate.py --output dist/chromium-gate.json
```

A confirmed gap blocks this command by default. Review the upstream changes and
validation evidence first. If accepting the known gap, supply your own written
rationale through `CHROMIUM_RISK_ACKNOWLEDGEMENT` (20–500 printable characters,
one line), then rerun the command. Do not use a placeholder acknowledgement.
Unavailable or invalid upstream metadata always blocks release, even with an
acknowledgement. Merge and validate a newer stable CEF pin when one is available;
never promote beta merely to bypass the gap.

Use **Keychain-native signing** to finalize. Neither `generate_keys -p` nor a raw
Keychain password lookup is needed:

```bash
(
  set +x
  set -euo pipefail
  unset SPARKLE_PRIVATE_ED_KEY
  export SPARKLE_KEYCHAIN_ACCOUNT=io.github.mrashrhodes.cairn
  export SPARKLE_PUBLIC_ED_KEY='ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8='
  export CAIRN_CHROMIUM_GATE_RECORD="$PWD/dist/chromium-gate.json"
  scripts/finalize-release.sh dist/release
  scripts/sparkle-release-signing.sh verify-feed dist/release/appcast.xml
  swift Resources/ReleaseTools/VerifySignature.swift --feed \
    "$SPARKLE_PUBLIC_ED_KEY" dist/release/appcast.xml
)
```

Finalization checks the per-architecture metadata and checksums, requires a gate
record matching the built Chromium, and signs a nonsecret probe to verify that
the signer matches the public key. A missing/denied Keychain item, signer failure
or mismatched public key stops finalization. The probe is removed afterward.

macOS may still ask for permission for the official Sparkle signer to access its
Keychain item. Allow access only to the expected signer. If access is blocked, unlock
the appropriate Keychain or cancel and resolve its access controls; do not work around
it by exporting the secret. There is no automatic fallback to a different account,
unsigned output, or raw password extraction.

Do not use `echo`, `tee`, shell tracing, an argument such as `--body`, or a file
redirect to expose or persist private material. Do not add a `gh secret set` step.

The finalizer signs both ZIPs and the shared appcast with Sparkle 2.10's resolved
`sign_update` tool. In Keychain-native mode, only the official signer accesses the
private item; the shell never receives it. Each archived app is extracted and
verified before signing; its metadata determines the feed entries. CryptoKit
verifies ZIP and feed signatures against the public key embedded in both apps;
Sparkle also verifies the signed feed. No deltas or remote release-note content
are emitted. The two apps must agree on version, build, bundle ID, minimum macOS,
public key and signing mode.

For a signing-only access check without building an application, use the same public
key/account environment and run `scripts/sparkle-release-signing.sh check-key`.
`scripts/make-appcast.sh` accepts the same account mode for already-prepared archives.

The existing CI interface remains supported for a future explicit provisioning
decision: set `SPARKLE_PRIVATE_ED_KEY` to Sparkle's canonical base64 secret and leave
`SPARKLE_KEYCHAIN_ACCOUNT` unset. Only that mode passes the private value to the signer
through stdin. Setting both modes, or neither, is an error. The local publication path
does not use the environment-key mode and does not upload private material to CI.

Final public assets are `Cairn-0.1.1-arm64.zip`, `Cairn-0.1.1-x86_64.zip`, both
matching DMGs, `appcast.xml`, `SHA256SUMS` and `RELEASE-INFO.json`.
`RELEASE-NOTES.txt` supplies the release description. Metadata and notes state the
actual Apple signing/notarization status, engine versions and any accepted risk.
The per-architecture JSON files and gate record are build inputs, not download
assets. Local preparation **does not upload or publish anything**. Do not modify
the archives or appcast after signing.

### Publish finished assets separately

Publication is a separate maintainer action, outside the signing subshell, and
is blocked while the [public-release gates](#public-chromium-release-gates) remain unmet.
The following stages a draft for review; it is not approval to publish the current
candidate. First review the generated release notes and verify the asset checksums with
`(cd dist/release && shasum -a 256 -c SHA256SUMS)`. The command below preserves the
generated notes and appends the currently unmet GUI verification limitation to the draft
description without changing any checksummed file.

After the maintainer has approved staging the artifacts, ensure the reviewed release commit
is already present on GitHub. Target `v0.1.1` through `gh release`
rather than separately pushing a tag, so this local publication path does not
deliberately invoke the tag-push release workflow. Upload only the final public assets:

```sh
release_commit="$(git rev-parse HEAD)"
gh release create v0.1.1 --repo mrashrhodes/cairn --target "$release_commit" \
  --draft --prerelease \
  --title 'Cairn v0.1.1 — Chromium developer preview' \
  --notes "$(cat dist/release/RELEASE-NOTES.txt; printf '\nIntegrated GUI has not yet been manually verified.\n')" \
  dist/release/Cairn-0.1.1-arm64.zip \
  dist/release/Cairn-0.1.1-arm64.dmg \
  dist/release/Cairn-0.1.1-x86_64.zip \
  dist/release/Cairn-0.1.1-x86_64.dmg \
  dist/release/appcast.xml dist/release/SHA256SUMS \
  dist/release/RELEASE-INFO.json
```

Keep the draft unpublished while any public-release gate remains unmet. Before
publication, replace the GUI limitation with the actual accepted result and
references to the retained gate evidence; do not just delete the warning.
Publishing a prerelease still does not update the stable feed. Promote to a normal
release only when deliberately making the accepted candidate available to stable
updaters, retaining its actual Apple signing/notarization status.

Do not run a separate `git push` for the tag. Never overwrite or move the tag after
publication. No Keychain item, environment dump, private-key file, certificate or
signing secret belongs in a release asset. The stable updater URL resolves GitHub's latest normal
release; a GitHub draft or prerelease alone does not make that URL available. The
developer-preview label does not imply notarization or completed GUI verification.

For an individual appcast step, while the required signing environment is
available, pass the output feed first and both prepared archives afterward:

```sh
scripts/make-appcast.sh dist/appcast.xml \
  dist/release/Cairn-0.1.1-arm64.zip \
  dist/release/Cairn-0.1.1-x86_64.zip
```

This lower-level command does not generate release metadata or checksums, or
enforce the Chromium security gate. Use `scripts/finalize-release.sh` for a
distributable release; do not replace a finalized feed without re-finalizing.

`CFBundleVersion` must increase on every update; by default it matches the numeric
release version. Never reissue the same tag/version with different bytes or a new key.

### One feed, two architectures

The stable feed must contain **both** same-version archives. The arm64 item comes
first, with `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`;
the x86_64 item follows without a hardware requirement. Sparkle 2.10.0 retains the
first eligible item when versions are equal. Native Intel rejects the arm64 item;
Apple Silicon, including a client running under Rosetta, selects it. Do not reorder
the items or invent an Intel-only hardware attribute. Re-verify these selection
semantics when upgrading Sparkle.

The historical universal v0.1.0 client already uses this Sparkle version and the
same feed URL. It can migrate to the matching Chromium application without a new
update key. Its legacy engine preference is ignored; website cookies and storage
are not migrated from WebKit profiles. One-architecture feeds, mismatched versions,
duplicate architectures and non-Chromium archives are rejected.

**Known limitation.** Sparkle has no `x86_64` hardware requirement, so the arm64 item's
exclusion of Intel Macs and the item order are all that keep an Apple Silicon Mac off the
Intel app. A hard separation would give each architecture its own Sparkle channel and have
the updater (`Sources/CairnUpdater`) return its own channel from `allowedChannels`. That
needs an app release first: clients that predate it see only items without a channel, so
the feed cannot move to channels until the installed clients have the new updater. It is an
application change, not something the packaging scripts can add.

### Building and testing the Intel app

CI and Release are configured to build and test x86_64 natively on `macos-15-intel`, GitHub's last x86_64
macOS runner image: GitHub lists it as available until **August 2027**
([actions/runner-images#13045](https://github.com/actions/runner-images/issues/13045)).
Decide before then how the Intel app is built and tested, because Apple Silicon runners
cannot run it natively.

**Native CI evidence, 2026-10-23:**
[run 39926654607](https://github.com/MrAshRhodes/cairn/actions/runs/39926654607)
passed on both `macos-15` (arm64) and `macos-15-intel` (x86_64), using macOS 15.7.9,
Swift 6.1.2, commit `8a76627` and CEF `154.0.34+g14c5a08+chromium-154.0.8037.98`.
Each job passed 335 Swift tests, 46 offline engine tests, all six lifecycle tests
after CEF preparation (including the two initially skipped native fixtures),
107 release-tooling tests, the bundled smoke on its first attempt and ad-hoc app/DMG
packaging with bundle verification. Both disk-image upload steps were skipped and
the run produced zero workflow artifacts. This is native runtime evidence, not
interactive Cairn UI acceptance, Intel performance qualification or signed/notarized
release acceptance; [#8](https://github.com/MrAshRhodes/cairn/issues/8) remains open.

The cross-build fallback was verified on an Apple Silicon Mac (macOS 26.6,
Command Line Tools, 2026-10-22):

```sh
python3 engine/tool.py fetch --arch x86_64
python3 engine/tool.py build --arch x86_64      # cross-builds the CEF wrapper (CMAKE_OSX_ARCHITECTURES)
ARCH=x86_64 scripts/bundle-app.sh               # `make app ARCH=x86_64` runs all three steps
scripts/make-dmg.sh
```

* `Cairn`, the helpers and CEF are thin x86_64 binaries (Sparkle stays universal).
  `scripts/verify-bundle.sh --arch x86_64` passes for the app, the ZIP and the DMG, and
  `--arch arm64` rejects the same app.
* Under Rosetta 2 the Intel helper loaded the x86_64 CEF and the bundled smoke test passed
  (23 assertions, orderly exit). Chromium logs that Rosetta is "neither tested nor
  maintained", and `engine/smoke.py` packages only the host architecture, so that run used a
  throwaway wrapper that reported an x86_64 host and passed `--arch x86_64` to SwiftPM. Treat
  it as a sanity check, not as Intel validation.
* That cross-build trial did not verify real Intel hardware, performance, or Developer ID
  signing/notarization of an Intel app built on Apple Silicon (`scripts/release.sh` applies unchanged).
  The later native CI evidence above does not establish those cross-built artifacts' runtime acceptance.

A lasting answer requires access to native Intel hardware, such as a self-hosted
Intel Mac runner. Cross-building can supply its artifacts; Rosetta can add a
sanity check but cannot replace native runtime acceptance. Record the decision
here before the image is retired; never claim an Intel gate passed without a
successful native run of the candidate.

## Developer ID and notarization for trusted distribution

This is optional for local/ad-hoc development, but required for a trusted public
distribution. It is not the v0.1.0 preview's signing status. With the
public Sparkle key available inside a non-tracing subshell and an
already-installed local identity, choose a new, unused version higher than the
published preview:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE='cairn-notary' \
VERSION=0.1.1 ARCH=arm64 scripts/release.sh
```

Repeat for x86_64 on an Intel builder with the same version, identity and signing
mode, then finalize both sets of assets. Prepare CEF on each builder first.

Provision the profile yourself with Apple's `notarytool`; Xcode/notarytool must be
available. Without a notary profile/credentials the release is **not notarized** even
if it is Developer ID signed. Partial credentials or notarization failure stop release
preparation rather than silently downgrading. App and DMG are separately submitted,
accepted, stapled, and validated. The app is checked with `spctl` after stapling. The
[packaging gate](#packaging-gate) then runs with `--require-developer-id --notarized` on the
stapled app, the ZIP and the DMG: hardened runtime, a Developer ID authority, a secure
timestamp and one Team ID on every nested code object, stapled tickets and Gatekeeper
acceptance. A Developer ID build without notarization still has to pass `--require-developer-id`.

CI can import an existing Developer ID certificate into a short-lived keychain under
`.build/release-signing`, which is deleted on exit. It never changes the default
keychain or the user's keychain search list. Do not enable shell tracing around secrets.

## GitHub Actions (maintainer setup, not automatic secret provisioning)

CI is configured to test on macOS Apple Silicon and Intel, validate workflows/shell scripts, prepare
CEF with `make cef` (the pinned archive is cached), run the native Chromium lifecycle
regressions, run the development ad-hoc Chromium smoke test through `scripts/run-smoke.sh`
(one retry, only for the documented teardown flake; its logs and any crash reports are kept as
`smoke-logs-<runner>` when a step fails or a retry was needed), and package a clearly ad-hoc,
single-architecture Chromium DMG per runner without any secrets. The bundle must pass the
[packaging gate](#packaging-gate). Packaging and verification run regardless of
artifact-upload choice. Development DMGs are uploaded only for an explicitly
manual dispatch with `upload_development_artifacts=true`; the input defaults to
`false`, and push, pull-request and reusable CI runs do not upload those binaries.
When requested, the seven-day artifacts are ad-hoc development builds, not
releases. Diagnostic smoke logs follow their separate retention policy above.
This is a functional Chromium
check, **not** a Developer ID, notarization, hardened-runtime or CEF security-gap
gate. [CI.md](CI.md) describes every job, cache and artifact.
The current failure evidence and required native validation are recorded in the
[release gates](#public-chromium-release-gates); workflow configuration is not
proof that these jobs have passed.

**Automatic release signing/publication is not configured.** Private
signing material has not been uploaded to GitHub and is not uploaded by the local
publishing recipe. The build matrix needs only the public Sparkle key; if the
protected `release` environment lacks `SPARKLE_PRIVATE_ED_KEY`, finalization
fails closed and the dependent publish job cannot publish. There is no secret-presence
gate that skips the entire workflow. A checked-in workflow is not evidence that its
signing environment is ready.

The public key alone may be stored as the `SPARKLE_PUBLIC_ED_KEY` GitHub variable.
It cannot sign a release or enable automatic publication.

If the repository owner later explicitly chooses to enable CI signing, that is a
separate user-owned provisioning decision. The workflow supports scheduled and
manually dispatched default-branch releases plus explicit stable
`vMAJOR.MINOR.PATCH` tag pushes. It requires a protected `release` environment
and tag rules with maintainer approval. Environment approvals apply separately
to the build and finalization jobs. Its signing configuration is:

| Name | Location | Requirement |
| --- | --- | --- |
| `SPARKLE_PUBLIC_ED_KEY` | environment/repository variable | Required public key |
| `SPARKLE_PRIVATE_ED_KEY` | environment secret | Required for finalization only; official Sparkle exported key text |
| `APPLE_CERTIFICATE_P12_BASE64` | environment secret | Optional existing Developer ID certificate, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | environment secret | Required when importing that certificate |
| `APPLE_SIGNING_IDENTITY` | environment secret | Full Developer ID Application identity for that certificate |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | environment secrets | Optional notarization credentials, all three required together |

If configured in the future with only Sparkle keys, CI would produce an
Ed25519-authenticated but **ad-hoc and not notarized** release. Missing keys never
produce an unsigned fallback. Appcast consumers need no GitHub account.

Actions are pinned to reviewed full commit SHAs; checkout does not persist credentials.
After planning, CI and the Chromium gate must pass before the fixed build matrix
runs: arm64 on `macos-15`, x86_64 on `macos-15-intel`. There is no architecture
selector or universal build. The finalizer combines `release-arm64`,
`release-x86_64` and `chromium-gate` artifacts into `authenticated-release`.
Only finalization receives the Sparkle private key.

The build matrix does not fail fast. If one architecture fails, the other still finishes and
uploads its `release-<arch>` artifact, so **Re-run failed jobs** rebuilds only the failed
architecture and the dependent jobs then continue. A failed build uploads `release-logs-<arch>`
(the notarization verdicts and the packaging test logs, for 14 days). They are copied out of
`.build` first because `upload-artifact` skips hidden directories.

Build and finalization have `contents: read`; the separate publish job has
`contents: write` and no signing secrets. It verifies checksums and publishes
both ZIPs, both DMGs, the shared appcast, checksums and `RELEASE-INFO.json`.
`RELEASE-NOTES.txt` becomes the release body, not a download asset.
Update action pins deliberately. Do not mix older manually published versions
into GitHub's `latest` release or overwrite release assets.

## Chromium assembly

All builds, including public releases, package Chromium. Local `make build`,
`make test`, `make app`, `make run` and `make dmg` fetch, verify and build CEF for
the host architecture first. The bundler itself never downloads CEF.
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

The script sets `CAIRN_CEF_ARCH` from `ARCH` for the SwiftPM manifest and calls
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
Chromium has its own security/update cadence. Passing packaging checks does not
satisfy the release-security gate; review the [maintenance guide](UPDATING_CHROMIUM.md)
and the recorded gate result before distribution.

## Packaging gate

`scripts/verify-bundle.sh` checks a built app against the packaging contract. It is read-only,
reports every problem before it exits non-zero (1; 2 for a usage error), and runs automatically
at the end of `scripts/bundle-app.sh` (so in CI, `make app` and every release build) and in
`scripts/release.sh`: on the stapled app of a notarized build, then on the finished ZIP and DMG.

```sh
scripts/verify-bundle.sh [--arch arm64|x86_64] [--require-developer-id] [--notarized] [APP|ZIP|DMG]
scripts/verify-bundle.sh --arch x86_64 dist/release/Cairn-0.1.1-x86_64.zip
scripts/verify-bundle.sh --arch arm64 --require-developer-id --notarized dist/release/Cairn-0.1.1-arm64.dmg
```

A ZIP is extracted and a DMG is mounted read-only, both under `.build`, so the check runs on the
bytes users download. `--arch` defaults to the architecture the app declares. It verifies:

* **Info.plist:** no `@PLACEHOLDER@` or build-machine path; identifiers, version, the `http`/`https`
  URL types and `CairnBrowserEngine`; the camera, microphone, location, Bluetooth and local-network
  usage strings; the signed-feed settings and a 32-byte Sparkle key (required for Developer ID
  builds); `LSMinimumSystemVersion` equal to `Package.swift`'s platform.
* **Layout:** the CEF framework and resources with only this architecture's V8 snapshot, the sandbox
  library, and exactly the five helper apps with their derived bundle IDs, `LSUIElement`, deployment
  target and the app's camera and microphone usage strings (capture runs in the helpers, and macOS
  names the capturing process). No other app is allowed in `Frameworks`.
* **Architecture:** every Mach-O is a thin binary for `--arch` (Sparkle must contain that slice) and
  needs no newer macOS than `LSMinimumSystemVersion`.
* **Signatures:** `codesign --verify --deep --strict` and every nested code object signed. Developer ID
  builds also need the hardened runtime, a Developer ID Application authority, a secure timestamp and
  one Team ID throughout (a mix fails dyld's library validation).
* **Entitlements:** each process carries exactly the keys of its source plist
  (`Resources/Cairn.entitlements`; `engine/entitlements/renderer.plist` for GPU and Renderer;
  `helper.plist` for the other helpers), including the required ones (`allow-jit` for GPU and Renderer,
  camera and audio input for the generic helper), and never `get-task-allow`,
  `disable-library-validation`, `allow-unsigned-executable-memory`, `disable-executable-page-protection`,
  `allow-dyld-environment-variables`, `debugger` or `app-sandbox`.
* **Stray files:** provisioning profiles, certificates and keys, crash dumps, logs, `.dSYM`s, Chromium
  profile files and `.git`, and symlinks that leave the bundle; in a DMG, anything but `Cairn.app` and
  the `/Applications` link.
* **Notarization** (`--notarized`): a stapled ticket and Gatekeeper acceptance (`spctl`) for the app and
  the DMG.

An ad-hoc build prints a notice that hardened runtime, Developer ID, notarization and Gatekeeper are
**not** verified, and `--require-developer-id` rejects it: only a real Developer ID build can be
verified for those. When a CEF update makes a rule stop matching (a renamed library, say), fix the
script after understanding the change; do not loosen the check to get a build through.
`Resources/ReleaseTools/VerifyBundleTests.py` assembles small ad-hoc Chromium-shaped apps and breaks each
rule once; `scripts/test-release.sh` runs it.

## Validation boundaries

`scripts/test-release.sh` exercises the updater's fail-closed configuration and
rejects signature tampering. Signing-mode tests use public RFC 8032 fixtures and
an isolated fake signer. Release-pipeline tests generate two throwaway Ed25519
key pairs in memory and exercise Sparkle's real `sign_update` against synthetic,
ad-hoc-signed app archives, including mismatched-key rejection and independent
archive/feed verification. They never use the release key or the user's Keychain.
Test private keys pass through child-process environments and signer stdin, not
command-line arguments or files; they remain visible to the same user while the
child runs. Temporary public fixtures are removed afterward. These checks cover
both signing modes, ambiguous/missing credentials, inaccessible keys, key
mismatches and suppressed signer diagnostics. The same script runs the offline tests of
the packaging gate (`VerifyBundleTests.py`), the CI smoke wrapper (`RunSmokeTests.py`)
and the Chromium tracking issue (`ChromiumIssueTests.py`, with a fake `gh`; nothing is
contacted).

A real local ad-hoc app/DMG and linkage can be verified without Apple credentials.
End-to-end update installation requires a real key, two increasing app versions and an
accessible feed; Apple signing/notarization requires your account. Test those before
broad distribution. The v0.1.0 developer preview has not yet had its integrated GUI
manually verified. No local build or signature validation alone establishes
Gatekeeper trust or interactive GUI correctness. In particular no check in this repository has
exercised a hardened-runtime Developer ID build, notarization or Gatekeeper acceptance
(the packaging gate verifies them as soon as such a build exists). Native Intel CI
has passed the automated checks recorded [above](#building-and-testing-the-intel-app);
interactive GUI and signed-runtime acceptance remain separate.

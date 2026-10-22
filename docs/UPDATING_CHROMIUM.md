# Chromium / CEF engine

**Chromium is the only engine for source builds and future public releases;
the historical v0.1.0 download uses WebKit.** This is not a claim of equivalence to
Google Chrome. `make build`, `make test`, `make app` and `make run` prepare CEF for
the host architecture (`make cef`, which runs `python3 engine/tool.py fetch` and
`build`). `scripts/bundle-app.sh` never downloads CEF; run `make cef` first.
Bare `scripts/swiftw build`/`test` also compile Chromium but do not prepare its
native dependencies. Package resolution works without CEF; compilation requires
its headers and wrapper. Always prepare CEF after changing the lock: a bare
SwiftPM build does not validate the downloaded and built pin markers.
There is no WebKit target, engine switch or CEF-free build mode.
Downloaded binaries and build caches stay in ignored `engine/cef/` and
`engine/.cache/`. No Arc executable, private source, branding or resources are used.

## Security status and release gate

Verified against the upstream feeds on **2026-10-21**:

| Feed | Version |
| --- | --- |
| Latest common macOS **stable CEF** | `154.0.34+g14c5a08+chromium-154.0.8037.98` |
| Chromium inside that CEF | `154.0.8037.98` |
| Chrome stable for macOS | `156.0.8078.48` |

**There is a SECURITY GAP. Do not label this pin “current Chrome”, “up to date” or
security-equivalent to Chrome stable.** CEF beta is not automatically promoted to
work around a stable-channel gap. Comparing versions is an alert, not a complete
CVE or backport audit: older branches may contain backports and equal version
numbers do not independently prove safety. Consult
[Chrome releases](https://chromereleases.googleblog.com/),
[ChromiumDash](https://chromiumdash.appspot.com/releases?platform=Mac), the
[CEF build index](https://cef-builds.spotifycdn.com/index.html), and CEF release
notes. Keep Chromium labelled experimental and do not approve a public Chromium-enabled release
until a maintainer has documented the outstanding security risk and validation.

```sh
python3 engine/tool.py check
# Nonzero on a gap (also nonzero on unavailable/invalid metadata; never assumes current):
python3 engine/tool.py check --fail-on-gap
```

The Release workflow runs the same fail-closed check before building either
architecture, including during dry runs. Scheduled and tag-triggered releases
stop on a gap. A manual run can accept a **confirmed** gap only through the
`chromium_risk_acknowledgement` input: a reviewed rationale of 20–500 printable
characters on one line, retained with the gate result and release metadata.
Unavailable or invalid upstream metadata cannot be overridden. Local
finalization requires the equivalent gate record; see
[the release guide](RELEASING.md#check-the-engine-and-authenticate-both-builds).

The scheduled `engine-bump.yml` workflow checks daily and on manual dispatch. It
compares the locked Chromium version **and** the latest stable CEF against Chrome
stable, even when no newer CEF archive is available. A remaining gap produces a
red attention job. A newer common stable CEF creates/updates a **draft** maintenance
PR, never auto-merges. Only the proposing job has `contents: write` and
`pull-requests: write`; checks are read-only. Action versions are immutable commit
pins. There are no signing secrets in this workflow.

Enable “Allow GitHub Actions to create and approve pull requests” in repository
settings for PR creation. `GITHUB_TOKEN`-created PRs may not automatically trigger
other workflows: maintainers must explicitly run the required validation before
approval. A failed feed request must be investigated rather than dismissed.

## Explicit dependency preparation

Requirements: macOS 14+, C++20-capable Apple tools, CMake 3.21+, and Python with
`tarfile.data_filter` (Python 3.12+ recommended). The CEF distribution recommends
full Xcode; the supplied Makefiles path also compiles with the verified macOS 26.6
CLT-only Swift 6.4 environment. Ninja is not required.

```sh
# Host architecture: prepare CEF, build and bundle in one step (`make cef` only prepares CEF):
make app
# Or step by step. Select arm64 or x86_64 explicitly, or omit --arch for the host.
python3 engine/tool.py fetch --arch arm64
python3 engine/tool.py build --arch arm64
scripts/swiftw build
# Explicit product for release scripts that otherwise build only Cairn:
scripts/swiftw build --product CairnHelper
```

Cairn always uses Chromium. Legacy settings files remain readable, but their
engine preference is ignored, including explicit WebKit selections. Other
preferences are preserved. Website cookies and storage are not migrated from
historical WebKit profiles.
The bundler builds the main app and helper with the same architecture/configuration
and passes the resolved helper path, rather than assuming SwiftPM's generic debug path.

`cef.lock.json` pins the stable CEF version, contained Chromium version, exact
minimal archive name, byte size and upstream SHA-1 for **both** macOS architectures.
The fetcher checks size and checksum before extracting, including cached archives;
rejects path/link escapes; and prints the downloaded archive's SHA-256. Spotify's
index currently publishes SHA-1, not a signed SHA-256 manifest. Consequently this
is reproducibility/integrity pinning over HTTPS, **not independent publisher
authentication**. A reviewed `sha256` field can additionally be recorded per
artifact and will be verified. Do not invent stronger provenance guarantees.

Updating the lock invalidates the extracted pin marker and wrapper build marker.
The build command removes its old wrapper build directory when the pin changes.
CEF is loaded at runtime via its wrapper, not linked directly as a framework; this
is required for the macOS subprocess sandbox. The wrapper and bridge select
versioned CEF API `15400`, with C++20 in the package configuration.
Review/update that API number if a future CEF drops it; a compilation failure is
preferable to an incompatible binary.

For Intel builds on an Intel host, use `--arch x86_64` for fetch/build. For a cross
build also set `CAIRN_CEF_ARCH=x86_64` and pass the matching SwiftPM `--arch x86_64`
(or target triple). Do not mix arm64 helper binaries with x86_64 CEF. Bundling
rejects mismatches and universal main/helper binaries. Publish separate,
same-version arm64 and x86_64 apps; a universal CEF packaging pipeline is not
implemented.

## Application integration and lifecycle

In the app's main entry point, before `NSApplication.shared`, Sparkle, or UI setup:

```swift
import CairnChromiumEngine

MainActor.assumeIsolated {
    precondition(ChromiumEngineModule.prepareApplication())
    ChromiumEngineModule.register(in: EngineRegistry.shared)
    CairnApp.run(prepareForTermination: ChromiumEngineModule.prepareForTermination)
}
```

`prepareApplication()` supplies CEF's required `NSApplication` subclass and
`CefAppProtocol` send-event guard. Its `mockKeychain` parameter defaults to `false` and
exists only for unattended test harnesses such as the smoke binary: Chromium then uses a
fixed mock key instead of the user's `Chromium Safe Storage` Keychain item. Shipping apps
must not enable it. The external message pump schedules CEF work on
the AppKit main thread, with reentrancy protection and a 30 Hz bounded idle
fallback in common run-loop modes. Each tab exposes a stable `NSView` container; CEF creates a
**windowed Alloy-style child NSView** when that container is attached to a window.
It is not a screenshot pretending to be a browser.

Request contexts/browser creation are asynchronous. CEF initialization is lazy
when the Chromium factory is used. Missing framework,
incorrect application startup ordering, unbundled `swift run`, architecture,
signing and singleton/profile-lock failures surface as tab initialization errors.
There is no fallback engine. The app must not retry CEF initialization in-process
after a completed CEF shutdown.

`BrowserEngine.shutdown()` closes that engine's tabs, but preserves the
process-wide runtime until application termination. AppKit
first asks the normal application delegate to approve quitting. Unsaved Boost
and persistence-failure checks must complete **before** any CEF teardown; Keep
Editing/Keep Cairn Open leave the browsers and runtime untouched. After approval,
the optional termination hook returns `terminateLater`, closes all CEF browsers,
waits for their `OnBeforeClose` notifications, releases request contexts, and calls
`CefShutdown` outside the CEF callback stack. Only then does the coordinator reply
to AppKit's pending termination request, exactly once. Repeated/nested quit
requests cannot bypass checks or start duplicate teardown. Every app build installs
this hook. Explicit tab/app close currently forces close (beforeunload cancellation
is not supported).

## Profiles and supported operations

Persistent Space data resides at:

```
~/Library/Application Support/Cairn/Chromium/<SHA256 of UTF-8 profileID>/
```

The hash prevents profile IDs from escaping the root. Tabs in the same Space share
one request context; distinct Spaces do not share cookies or web storage. Private
contexts use an empty CEF cache path, separate from persistent contexts, and are
discarded after the last tab in that private Space closes. CEF can still persist
installation metadata/logs in the root: private mode is not a promise of no OS,
network, swap, crash-log or installation artifacts.

Implemented through real CEF APIs: URL/title/loading/back-forward/TLS state,
navigation/reload/stop, load and renderer errors, user-gesture popup requests,
download delegation, close, zoom, find, JS evaluation, document-start/end scripts,
and PNG compositor snapshots. JS values are JSON-compatible results (including
awaited promises); non-serializable values and exceptions are reported as errors.
Internal DevTools messages have a 15-second timeout and **do not open a debugging
port**. Script registration is completed before queued initial navigation; scripts
target future documents. End scripts run at `DOMContentLoaded`. Producers remain
responsible for per-site guards. Snapshot/find require a mounted, ready browser.

Explicit limitations, not silent claims of support:

* Favicons are not yet fetched. There is no CEF permission/authentication UI,
  extension/DRM integration, DevTools frontend, PDF export or native printing API.
* CEF's own downloads are cancelled and URLs are delegated to Cairn. Transferring
  authenticated CEF cookies to a separate downloader is not implemented.
* Popups: a user-gesture `window.open`/`target=_blank` to HTTP(S) or an empty URL is created by CEF in
  the opener's request context (an ephemeral opener gives an ephemeral popup) with `window.opener`,
  `postMessage` and named windows intact, and shown as a new tab in the opener's Space; `window.close()`
  from the popup closes only that tab. Popups without a user gesture, with another scheme, or beyond
  3 per 10 seconds per tab are blocked and counted in a banner on the opener. Chromium's own blocker is
  disabled (`disable-popup-blocking`) so every attempt reaches `OnBeforePopup`; the decision lives in
  `PopupPolicy`. Middle/Cmd-click arrive through `OnOpenURLFromTab` as new tabs. Popup size/position
  features are ignored, a popup's first document is not covered by Boost scripts (CEF starts its
  navigation before Cairn can register scripts), and there is no per-site "always allow".
* Cookies and HTTP cache can be cleared per persistent Space. All-origin local
  storage deletion while running is **unsupported**: requesting it sets
  `lastDataRemovalError`, a visible tab error and a diagnostic. Quit Cairn before
  removing that Space's hashed directory; that removes **all** its Chromium
  cookies/cache/storage too. The frozen engine protocol has no throwing deletion
  result, so callers should present this limitation.
* Signing/notarization, renderer sandbox behavior, certificate failures, private
  browsing, permissions and both CPU architectures require real-device release
  validation. Compilation is not a claim that those release gates passed.

No certificate-error override, `--no-sandbox`, disabled web security, or external
debugging port is configured. Untrusted process command-line overrides are
disabled. `CairnHelper` initializes `CefScopedSandboxContext` **before** loading CEF.

## Release bundle contract

After building both executable products in the **same configuration** and staging
the normal main app and Info.plist:

```sh
python3 engine/bundle.py --app dist/Cairn.app --configuration release --arch arm64 \
  --helper /absolute/path/to/matching/CairnHelper
```

`scripts/bundle-app.sh` supplies that exact helper path automatically.

The helper adds exactly this layout (including all upstream resources/locales):

```
Cairn.app/Contents/
  MacOS/Cairn                         # supplied by the release integrator
  Info.plist                         # supplied by the release integrator
  Resources/cef.lock.json
  Resources/CEF-LICENSE.txt
  Frameworks/
    Chromium Embedded Framework.framework/
      Versions/A/
        Chromium Embedded Framework
        Libraries/                   # includes libcef_sandbox.dylib
        Resources/                   # packs, locales, ICU, snapshots, Info.plist
      Versions/Current -> A
      Chromium Embedded Framework -> Versions/A/Chromium Embedded Framework
      Libraries -> Versions/A/Libraries
      Resources -> Versions/A/Resources
    Cairn Helper.app/Contents/{Info.plist,MacOS/Cairn Helper}
    Cairn Helper (Alerts).app/Contents/{Info.plist,MacOS/Cairn Helper (Alerts)}
    Cairn Helper (GPU).app/Contents/{Info.plist,MacOS/Cairn Helper (GPU)}
    Cairn Helper (Plugin).app/Contents/{Info.plist,MacOS/Cairn Helper (Plugin)}
    Cairn Helper (Renderer).app/Contents/{Info.plist,MacOS/Cairn Helper (Renderer)}
```

Helper IDs derive from the main bundle ID with `.helper`, `.alerts`, `.gpu`,
`.plugin`, `.renderer` suffixes. The bundler never downloads, signs, or modifies the
main executable. Preserve framework symlinks when archiving.

Sign inside-out with one Developer ID identity: framework dylibs (especially
`libcef_sandbox.dylib`), framework, helper apps, then main app. Do not use
`codesign --deep` to sign. `--deep --strict` is appropriate for **verification**.
For hardened signing:

* **Renderer and GPU helpers:** `engine/entitlements/renderer.plist` (`allow-jit`).
* **Generic, Alerts and Plugin helpers:** `engine/entitlements/helper.plist`
  (empty dictionary).
* **Main app:** the release integrator's minimal app entitlements; capabilities
  such as camera/microphone require a separate permission/UI/privacy review.
* Libraries do not receive process JIT entitlements.

Do not add `disable-library-validation`, `allow-unsigned-executable-memory`, or
debugging entitlements to hide failures. Use the same real team identity for all
nested code, sign with Hardened Runtime and timestamp, notarize, staple, and test
the **downloaded** release. See [CEF signing](https://chromiumembedded.github.io/cef/code_signing.html)
and [CEF sandbox setup](https://chromiumembedded.github.io/cef/sandbox_setup).

**Reproduced local restriction:** an ad-hoc signature with Hardened Runtime passes
`codesign --verify --deep --strict` but dyld rejects the CEF framework with
“mapping process and mapped file (non-platform) have different Team IDs.”
Ad-hoc signatures have no Developer ID team. This is not fixed by disabling
library validation. Use a real same-team identity for a hardened release.
Non-hardened ad-hoc builds are **development-only**, even with the Chromium
subprocess sandbox still enabled.

## Source layout

The Chromium code is split by CEF handler family, so a feature or a CEF API change touches
few files. Under `Sources/CairnChromiumBridge/`:

* `include/CairnChromiumBridge.h` is the only header Swift sees. It changes additively:
  each feature owns a `// [Feature]` slot.
* `CCInternal.h` (private shared declarations and the CEF-prepared `#error` guard),
  `CCRuntime.mm` (start/stop, message pump, request contexts), `CCTab.mm` (the tab class)
  and `CCClient.mm` (one factory call per handler family).
* `Handlers/CC<Family>Handler.mm`: one CEF handler family per file. Skeleton families
  return `nullptr`, which is CEF's default behavior. `CCTab+<Feature>.mm` holds tab commands.

On the Swift side `CairnChromiumEngine` has `ChromiumEngine.swift` (engine, profiles) and
`ChromiumTab.swift` (the `EngineTab`), extended by `ChromiumTab+<Feature>.swift`. SwiftPM
compiles every source file below a target, so adding a file needs no manifest edit. After a
CEF update, a compile error points at the one handler file that uses the changed API.

## Updating and verification

```sh
python3 -m unittest discover -s engine/tests -v
python3 engine/tool.py update      # explicit; only latest COMMON STABLE version
git diff -- engine/cef.lock.json   # manually review both archive pins
python3 engine/tool.py fetch
python3 engine/tool.py build
scripts/swiftw build
scripts/swiftw test

# GUI session required. The smoke fixture serves only loopback, using isolated
# profiles under engine/.cache; it does not touch normal Cairn profiles.
python3 engine/smoke.py --identity 'Developer ID Application: YOUR IDENTITY'
# Explicitly weaker local signing, for functional debugging ONLY:
python3 engine/smoke.py --development-ad-hoc

```

The smoke test actually embeds the child view, loads local pages, evaluates JS,
installs/removes scripts, finds text, changes zoom, takes a snapshot, checks Space
and private isolation, clears cookies, blocks unsolicited popups, checks popup adoption (`window.opener`,
`postMessage`, shared/ephemeral context, `window.close()`, empty-URL and `rel=noopener` popups, flood budget)
and closes CEF.
It also verifies CSS grid, container queries, `:has()`, JavaScript modules, fetch,
the network user agent's locked Chromium version, DOM events, viewport resizing
and the captured compositor image dimensions.
It fails if the process exits without the success marker. Retain its diagnostic
logs on failure. It does not replace certificate/permission/manual UI tests,
Developer ID/notarization verification, or testing on Intel hardware.

The smoke binary runs Chromium with a mock Keychain so results do not depend on the
developer's login Keychain. Without it, an ad-hoc binary that did not create the existing
`Chromium Safe Storage` item is asked for Keychain authorization; in an unattended run the
first navigation then never commits (`Timed out waiting for navigation`) and teardown ends
with `Teardown watchdog expired`. Profiles are created under the symlink-resolved
`engine/.cache`: CEF rejects request-context cache paths outside its resolved
`root_cache_path` and silently falls back to in-memory storage (look for
`cache_path is invalid` in the profile root's `cef.log`). Rarely (1 of about 25 recorded
arm64 runs) Chromium's teardown watchdog still terminates the process with exit status 2
after `CAIRN_CEF_SMOKE_OK` was printed; that run is reported as failed, so rerun it.

Recorded validation on 2026-10-21, macOS 26.6 arm64 / CLT Swift 6.4:

* Full Swift builds succeeded for both engine configurations available at that
  time. Current source builds include Chromium unconditionally.
* The sandbox-enabled C++ wrapper and helper built with Makefiles, without Ninja.
* All 16 offline maintenance tests passed; `actionlint` accepted the workflow.
* The explicitly non-hardened development smoke completed all 22 assertions and
  orderly process exit, with no CEF assertion diagnostics. This is **functional
  arm64 evidence**, not notarization, Intel execution or hardened-release proof.
* A hardened ad-hoc launch failed at dyld's Team ID validation, as described above.
  No Developer ID signing identity was supplied for release validation.
* The later quit-cancellation fix was verified with headless approval/deferred
  termination regression tests and a full Chromium build, without relaunching the
  GUI. Repeat interactive cancel/approve/quit testing in release validation.

Before approving an update: review relevant security fixes and CEF API changes;
fetch/check both architectures; build the version-matched wrapper and helper;
run these tests on both hardware architectures; test bad certificates, popup
gestures, authenticated downloads and session restoration; sign/notarize the whole
app; verify the release app reports the locked version. Never replace only the
framework in an installed app: CEF, wrapper, bridge, helper, resources and
signatures ship as one application update.

Rollback means restoring a previously tested complete app/lock and rebuilding
matching artifacts, not blindly downgrading Chromium over a newer profile.
Back up profiles before upgrades; schema changes may make downgrades unsafe.
Security review must explicitly approve any rollback to a vulnerable version.

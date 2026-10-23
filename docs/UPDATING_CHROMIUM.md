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

### Status, 2026-10-23

| Feed | Version |
| --- | --- |
| Committed pin (`engine/cef.lock.json`) | `154.0.34+g14c5a08+chromium-154.0.8037.98` |
| Newest **stable CEF** published for both macOS architectures | `156.0.8+g426920c+chromium-156.0.8078.48` |
| Chrome stable for macOS | `156.0.8078.48` |

**The committed pin still has a SECURITY GAP. Do not label it “current Chrome”,
“up to date” or security-equivalent to Chrome stable.** `python3 engine/tool.py check`
on 2026-10-23 still exited 2 for it, although the newest common stable CEF now
matches Chrome stable (`upstream_security_gap=false` for that build). The
[CEF source commit](https://github.com/chromiumembedded/cef/commit/426920c33ef22551e0b8f48cf343d623ac25642d)
of the newer build, dated 2026-10-22, identifies Chromium `156.0.8078.48`.

**That newer build was tried locally and is not adopted**
([#32](https://github.com/MrAshRhodes/cairn/issues/32)). With an uncommitted scratch
lock on Apple Silicon, `make cef`, the Swift suite (335 tests in 48 suites) and the
engine tests (48) passed, and the refreshed currency report was `ok`. The bundled
runtime smoke then **failed on both attempts**: after the geolocation denial check
passed, the microphone `getUserMedia` probe had not settled when Cairn's 15 s operation
timeout fired. The committed 154 pin passed that microphone check on the same host, so
the failure is specific to the newer build; its cause is not yet known. This was not the
documented post-success teardown flake, so the restricted retry exception does not
apply. Do not commit that lock or call the build validated until the smoke passes and
the evidence below is recorded for those exact bytes.

**The external-protocol race has a local fix.** Earlier 154 runs could pass before
Chromium published `ERR_UNKNOWN_URL_SCHEME`
([#31](https://github.com/MrAshRhodes/cairn/issues/31)). Main-frame external navigations
are now cancelled in `OnBeforeBrowse`, before replacing the current document or
invalidating its pending requests; the app still decides whether to launch an
allow-listed handler after consent. Browser-owned schemes retain normal error handling.
The strengthened smoke waits across a renderer timer and verifies exactly one callback,
unchanged URL/document and no delayed error for both mailto and a declined custom scheme.
A separate failed HTTP request verifies that genuine network errors remain visible.
Both native regression tests and the full bundled 154 arm64 smoke passed locally on
2026-10-23 (first attempt, shutdown 506 ms). This evidence is not final release acceptance;
repeat the strengthened smoke on both architectures for the reviewed shipping commit.

**The integrated backlog candidate is not a passing release candidate.** Its local
arm64 development-ad-hoc bundled run on 2026-10-23 passed download retry/destination
checks and emitted `CAIRN_TRANSIENT_NAVIGATION_OK` and `CAIRN_CLOSE_LIFECYCLE_OK`,
with a 505 ms shutdown. Close recovery now waits for the renderer to acknowledge
Stay. If a renderer crash loses that acknowledgement, `Page.close` dispatches
beforeunload on the recovered frame instead of relying on Alloy's stale pending
close state; it never substitutes implicit approval. Error/stale-response paths
are covered by the native lifecycle fixture.
The run still failed five strict first-document popup Boost assertions (direct,
redirect and POST) in [#24](https://github.com/MrAshRhodes/cairn/issues/24).
No request replay, timeout relaxation or skipped gate was used to make it pass.
Repeat the complete run on both architectures for the integrated commit; the
passing subsets are not full GUI, accessibility, soak or distribution acceptance.

[CI run 39926654607](https://github.com/MrAshRhodes/cairn/actions/runs/39926654607)
subsequently passed on native arm64 and x86_64 runners at commit `8a76627`, with the
committed 154 pin: Swift/engine/release checks, first-attempt bundled smoke and
ad-hoc app/DMG packaging all passed. Binary uploads were skipped. This adds native
Intel runtime evidence but predates the external-protocol fix above and does not close full
interactive/signed-runtime acceptance. See the
[recorded CI evidence](RELEASING.md#building-and-testing-the-intel-app).
Repeat validation for the exact engine bytes to ship; this result does not cover 156.
A version report's `ok` does not mean the release-security gate passed or the build
is validated. Re-run the fail-closed check before release; no complete CVE/backport
audit, hardened signing, notarization or public-release approval is implied. The
[other release gates](RELEASING.md#public-chromium-release-gates), including
unsaved-page close safety, remain mandatory.

### Historical snapshot, 2026-10-22

The previous feed check recorded:

| Feed | Version |
| --- | --- |
| Pin at that time | `154.0.34+g14c5a08+chromium-154.0.8037.98` |
| Newest **stable CEF** published for both macOS architectures | `156.0.7+g47dbc1d+chromium-156.0.8078.17` |
| Chrome stable for macOS | `156.0.8078.48` |

That pin had a **SECURITY GAP** of two major versions, which still applies to the
unchanged committed pin. At that time, even the newest common stable CEF trailed Chrome
stable by a few patch releases; the trial bump below narrowed but did not close the gap.
This dated evidence is retained for the history of the comparison; the 2026-10-23 status
above supersedes its newest-CEF row.

### Gate policy and monitoring

CEF beta is not automatically promoted to work around a stable-channel gap.
Comparing versions is an alert, not a complete
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
# Also write the JSON and Markdown results; they are written when the check fails, too (status "failed"):
python3 engine/tool.py check --report status.json --markdown status.md
```

`tool.py` exits **0** after a successful check (also while a gap exists, unless `--fail-on-gap`
asks otherwise), **2** for a gap under `--fail-on-gap`, and **1** when it could not decide: a
network failure after four attempts, an upstream index or feed whose format changed, or an
invalid lock. Fix a failing check instead of silencing it: while it fails, nobody is watching
for Chromium security releases.

The Release workflow runs the same fail-closed check before building either
architecture, including during dry runs. Scheduled and tag-triggered releases
stop on a gap. A manual run can accept a **confirmed** gap only through the
`chromium_risk_acknowledgement` input: a reviewed rationale of 20–500 printable
characters on one line, retained with the gate result and release metadata.
Unavailable or invalid upstream metadata cannot be overridden. Local
finalization requires the equivalent gate record; see
[the release guide](RELEASING.md#check-the-engine-and-authenticate-both-builds).

The `engine-bump.yml` workflow (“Chromium maintenance”) is configured for daily runs
at 07:23 UTC and manual dispatch; deployment is not yet verified (see the dated
automation status below). It runs the offline updater tests, then compares the locked Chromium version
**and** the newest stable CEF with Chrome stable, even when no newer CEF archive is available,
and writes the result to the run summary and the `chromium-status` artifact:

* A remaining gap makes the `security-gap` job fail (red), so it cannot be missed.
* `tracking-issue` keeps **one** open issue labelled `chromium-security` while the status is
  `security_gap` or `failed` (including when the check itself cannot run), refreshes it on every
  run and closes it once the pin no longer trails Chrome stable (`scripts/chromium-issue.sh`).
* A newer stable CEF that **both** architectures publish makes `propose` pin it (`tool.py update`),
  record the SHA-256 of both archives (`tool.py hash`), run the offline tests against the new pin
  and create or refresh a **draft** pull request on `maintenance/cef-stable` with the review
  checklist (`.github/chromium-bump-pr.md`). It then dispatches `ci.yml` for that branch. Nothing
  is ever merged or released automatically.
* The pin only ever moves to a build both architectures publish. When one architecture lags, the
  report shows the newest build of each, an `ARCHITECTURE GAP` warning appears, and the pin can only
  move to the newest build both publish: never ship one architecture on a newer Chromium than the other.

The workflow is `contents: read`; `propose` adds `contents: write`, `pull-requests: write` and
`actions: write` (to dispatch CI), and `tracking-issue` adds `issues: write`. Action versions are
immutable commit pins and there are no signing secrets.

Enable “Allow GitHub Actions to create and approve pull requests” in the repository settings, or
`propose` cannot open the pull request. Pushes made with `GITHUB_TOKEN` do not start
`pull_request` workflows, which is why `propose` dispatches CI itself (`workflow_dispatch` is
exempt); if those runs are missing, start them with
`gh workflow run ci.yml --ref maintenance/cef-stable`. GitHub disables scheduled workflows in a
public repository after 60 days without repository activity: re-enable them in the Actions tab and
treat a missing daily run as an alarm. A failed feed request (`status: failed`) must be
investigated rather than dismissed.

**Automation status, 2026-10-23:** the workflow described here is part of open
[PR #2](https://github.com/MrAshRhodes/cairn/pull/2), not evidence that daily issue
tracking is active on the default branch. The observed
[maintenance run](https://github.com/MrAshRhodes/cairn/actions/runs/39783441548)
failed because Actions was not permitted to create/approve pull requests. Confirm
the repository permission, merge the reviewed workflow, and retain a successful
maintenance run before relying on automatic proposals or tracking-issue updates.
Until then, maintainers must run the check and record the result themselves.

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
minimal archive name, byte size, upstream SHA-1 and recorded SHA-256 for **both**
macOS architectures. The current lock already includes both SHA-256 values.
The fetcher checks size and the pinned checksums before extracting, including cached archives;
rejects path/link escapes; and prints the downloaded archive's SHA-256. Spotify's
index currently publishes SHA-1, not a signed SHA-256 manifest. Consequently this
is reproducibility/integrity pinning over HTTPS, **not independent publisher
authentication**. The lock format permits an optional `sha256`, but when present
the fetcher enforces it. `python3 engine/tool.py hash`
records it for both archives from a download that already matched the published size and SHA-1, and
the maintenance workflow is configured to do this for every proposed pin.
Run `hash` after selecting a new pin, before review. The hash comes from the same download:
it detects a later substitution of the archive or a damaged cache, not a malicious first download.
Do not invent stronger provenance guarantees. Network access retries four times with growing pauses;
a download goes through a partial file that replaces the cached archive only after the size and
checksums match, and a complete archive with the wrong checksum is never retried.

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
implemented. `make app ARCH=x86_64` runs the whole cross build. CI is configured to build and test the Intel app
natively on `macos-15-intel`; configuration alone is not passing native evidence.
What is verified for Intel and the plan for that runner's retirement
are in [the release guide](RELEASING.md#building-and-testing-the-intel-app).

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
this hook. Approval of Cairn's own Boost/persistence prompts does not mean the web
pages consented to closing, so page approval is a separate step.

**Unsaved-page close ([#22](https://github.com/MrAshRhodes/cairn/issues/22)).**
Ordinary tab, window, Space and app close use `EngineTabCloseControlling.requestClose`,
which calls CEF's `CloseBrowser(false)` so the page's `beforeunload` handler can
answer. The app coordinator has an **unbounded** human page-approval phase before
persistence approval and before any teardown watchdog starts. **Stay** keeps the
tab, its live DOM and its workspace record. Tabs close one at a time: if an earlier
page chose Leave and a later page chooses Stay, the earlier page has genuinely
closed, but its saved record remains and it reloads on demand. This is not an
atomic rollback of a page that already agreed to leave. A fully approved workspace
is suspended until its window reopens, so retained windows cannot recreate browsers.
CEF documents `DoClose` as irreversible, so it is never used as a preflight.
Runtime shutdown refuses unapproved live browsers before starting its watchdogs.
Discarding pages requires the explicit **Window ▸ Force Close Tab** or
**Cairn ▸ Force Close Pages and Quit** commands, each with a discard confirmation.
The bundled smoke runs `checkCloseLifecycle()` against
`engine/fixtures/beforeunload.html` and prints `CAIRN_CLOSE_LIFECYCLE_OK`; its
teardown awaits approvals rather than forcing them. Packaged GUI acceptance of
window close, multi-tab quit, Boost/persistence cancellation and hung teardown is
still required before #22 can be closed.

Quitting is bounded. If browsers have not all closed (or a browser creation is still
pending) 4 s after the hook starts, the bridge logs their counts and retries closing.
It never discards live browsers or pending-creation bookkeeping to call `CefShutdown`.
A watchdog on a background queue terminates with **exit status 1**, an explicit unclean
shutdown diagnostic, and no success completion after 10 s if closing, creation or
`CefShutdown` itself stops making progress. This last resort can lose Chromium writes;
it is a failure, not evidence of a clean profile flush. Pending download destination
callbacks and page prompts are cancelled before teardown.
A browser whose creation is not confirmed within 20 s is abandoned and the tab reports an error.
Lifecycle regressions can be run without launching Chromium:
`scripts/swiftw test --filter 'TabPromptTests|SitePermissionStoreTests'` and
`python3 -m unittest discover -s engine/tests -p test_lifecycle.py -v`.
The latter includes source-contract guards, a native pending-callback registry test and
real CEF DLL-wrapper identity checks (requires the already-prepared CEF headers/wrapper;
it never fetches or initializes CEF). Browser callbacks carry fresh C++ wrapper objects:
use `CefBrowser::IsSame`, never pointer equality, to associate them with a tab.
Real multi-tab/popup/DevTools close, active-download quit and blocked-main-thread shutdown
still require bundled-engine smoke/manual verification; these unit checks do not prove a
profile flush or the native timeout path.

## Tab health and recovery

The bridge reports process-level problems through the optional `EngineTabHealthEvents`
protocol (`Sources/CairnEngineKit/EngineTabEvents+Health.swift`): a crashed, killed or
out-of-memory renderer, an unresponsive renderer (terminated after 10 s if it does not
recover), a stalled navigation and unavailable page automation. `BrowserModel`
(`BrowserModel+Recovery.swift`) reloads a visible tab after its first crash in 60 s,
shows a banner with a Reload action after the second, and stops reloading by itself from
the third; a background tab is reloaded when selected. The DevTools session, including
`Page.enable` and user scripts, survives a renderer crash (verified by the smoke test), but
Page.enable cannot be re-sent until a navigation has revived the renderer, so recovery
reloads first.

A navigation that makes no progress for 30 s (`CAIRN_NAVIGATION_WATCHDOG_SECONDS` shortens
it for tests) reports "stalled". The most common cause on a Mac that already holds a
`Chromium Safe Storage` Keychain item created by a different signer (another Chromium-based
app or an earlier ad-hoc Cairn build) is a pending Keychain authorization prompt: Chromium
reads that item to open the cookie store, and no page loads until the prompt is answered.
Answer it with **Always Allow**; every freshly ad-hoc-signed developer build prompts again.
Cairn must not use `--use-mock-keychain` outside the smoke test.

A second Cairn process on the same data folder exits quietly with CEF's exit code
(21 or 24); the running instance is activated through `OnAlreadyRunningAppRelaunch`.
The data folder is resolved through symlinks once at startup (CEF otherwise silently uses an
in-memory profile for every Space), and a persistent Space whose profile directory CEF
rejects refuses to load instead of losing data.

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
in-engine downloads, close, zoom, find, JS evaluation, document-start/end scripts,
favicons, DevTools, printing/PDF export and PNG compositor snapshots.
JS values are JSON-compatible results (including
awaited promises); non-serializable values and exceptions are reported as errors.
Internal DevTools messages have a 15-second timeout and **do not open a debugging
port**. Script registration is completed before queued initial navigation; scripts
target future documents. End scripts run at `DOMContentLoaded`. Producers remain
responsible for per-site guards. Snapshot/find require a mounted, ready browser.

### Implemented capabilities and evidence limits

| Capability | Implemented behavior | Evidence and remaining acceptance |
| --- | --- | --- |
| Favicons | CEF downloads icon candidates through the page's request context and delivers decoded PNG data. Cairn caches icons per profile and host, with a globe fallback. | The local smoke checks delivery of a decoded image and the request's page origin; unit tests cover profile-separated cache lookup and an in-memory-only store. This is not an audit of every site's icons or a complete private-browsing journey. |
| Developer Tools | A separate Chromium DevTools window supports open, inspect and close; there is no remote debugging port. | The bundled smoke exercises three open/close rounds, including an inspect request. Full interactive tooling and final-release lifecycle acceptance remain separate. |
| Printing and PDFs | Print calls CEF's native macOS print path. Save Page as PDF uses `PrintToPDF` with backgrounds, tagged output and CSS page size; Chromium also has a PDF viewer. | Service tests check dispatch, save cancellation and error reporting with fake tabs. The engine smoke checks PDF bytes, page count/size and basic viewer loading. Native print/save panels, printed output and PDF toolbar interaction remain unverified. Tagged-PDF configuration alone does not establish accessibility conformance. |
| Page downloads | Chromium retains the transfer, preserving the originating request context, cookies, authentication, POST body and `blob:`/`data:` sources. Cairn chooses the destination and displays progress, pause/resume/cancel and terminal state. | The local smoke checks exact bytes for a cookie-gated download, profile isolation, POST/blob transfers, pause/resume/cancel and interruption. Service tests check destination validation, control routing and quarantine handling. Real-site sign-in, native save-panel interaction and downloaded-file handling remain acceptance work; `data:` is not separately exercised by that smoke. |

These are descriptions of implementation and test coverage, not a new test run
or proof that the final release passed. Repeat the checks for the selected CEF
pin and retain the results for both native architectures.

### Runtime-dependent feature qualification

The following investigations are tied to CEF `154.0.34+g14c5a08`, not a promise
that every Chromium or Safari feature is available in this app.

* **Display capture ([#25](https://github.com/MrAshRhodes/cairn/issues/25)): blocked
  on a supported source-selection design.** `CefMediaAccessCallback` accepts a
  permission mask, not a selected source ID. In the
  [pinned implementation](https://github.com/chromiumembedded/cef/blob/14c5a08/libcef/browser/media_access_query.cc),
  `GetRequestedMediaDevices` defaults to the full desktop when a display request
  has no selected device. Simply allowing desktop bits is therefore not a chooser.
  Returning false from Cairn's handler does not supply one either: the public
  permission-handler contract says Alloy default handling denies. Keep display
  bits denied until a supported chooser, origin/gesture checks, indicator, stop
  action and lifecycle revocation are qualified with a consenting OS-permission
  tester. Do not add `--enable-media-stream` or auto-select capture switches.
* **Extensions ([#26](https://github.com/MrAshRhodes/cairn/issues/26)): capability
  and isolation design remain unqualified.** The pinned public headers have no
  dedicated extension-management header. This does **not** mean Alloy cannot
  participate: upstream
  [`GetAlloyTabById`](https://github.com/chromiumembedded/cef/blob/14c5a08/libcef/browser/chrome/extensions/chrome_extension_util.cc)
  explicitly exposes matching-profile Alloy tabs to extension integration.
  Loading an extension globally is not evidence of per-Space permissions,
  revocation, removal or relaunch safety. Before a user-selected local extension
  is enabled, separately decide and test the supported management API/runtime,
  capability subset and profile boundaries. The
  [CEF architecture guide](https://chromiumembedded.github.io/cef/architecture)
  describes Chrome-layer functionality; it is not certification of Cairn's
  embedded UI or Chrome Web Store compatibility. No runtime migration or global
  `--load-extension` shortcut is enabled by this investigation.
* **Codecs and DRM ([#28](https://github.com/MrAshRhodes/cairn/issues/28)):**
  `engine/fixtures/playback-matrix.html` generates its own PCM WAV and VP8/VP9
  WebM content. `PlaybackMatrixChecks.swift` records actual playback time and
  video frames as `PLAYBACK_MATRIX` in the bundled smoke log. An unavailable
  encoder is explicitly `not-tested`, not a decoder failure or a playback pass.
  H.264/AAC/AV1 MIME and EME key-system queries are separately labelled
  capability-only; they do not prove decode, protected playback or redistribution
  rights. Read results with the log's exact CEF version and host architecture,
  and repeat on both shipping architectures. No CDM, license request, protected
  stream or third-party media is acquired by this fixture. Proprietary playback
  remains blocked on official support, licensing and an authorized test corpus.
* **Automatic WebKit DRM fallback
  ([#29](https://github.com/MrAshRhodes/cairn/issues/29)): not enabled.** No
  provider/key-system has yet been demonstrated lawfully in the actual embedded
  WebKit view on both supported architectures. An EME capability result, clear
  media playback, or success in Safari cannot authorize an engine transition.
  A proven provider matrix and the unsaved-page close contract are prerequisites;
  cookies, credentials and POST submissions must never be copied or replayed to
  manufacture apparent compatibility.

These are explicit blockers, not issue closures or release-gate waivers.

### Current behavior and limitations

Explicit limitations and policies, not silent claims of support:

* Chrome extension and DRM integration are not implemented or promised.
* Page prompts are client-implemented (`CCPermissionHandler.mm`, `CCJSDialogHandler.mm`,
  `GetAuthCredentials`/`OnCertificateError` in `CCRequestHandler.mm`) and shown as cards on
  the tab that raised them. Site permissions are denied unless allowed; decisions are
  remembered per Space and origin in `permissions.json` and managed under Settings →
  Permissions. HTTP auth needs `--disable-chrome-login-prompt` (set in `CCRuntime.mm`);
  credentials are never stored. Auth requests arrive on CEF's IO thread and are marshalled
  to the main thread, rejecting requests queued across a navigation. Main-frame navigation
  (including reload), renderer termination and browser close cancel outstanding auth,
  JavaScript and permission callbacks and dismiss their cards. Opaque per-instance request
  IDs and front-of-queue/type checks prevent stale cards answering a new page's prompt.
  Certificate errors are always refused and explained, with no
  proceed option. Not done: screen capture (denied), Chromium-side permission storage.
  `beforeunload` on close is described under the application lifecycle above.
* Page downloads are **not** converted to a URL-only transfer. Cancelling the
  destination chooser cancels that download without a failure notification.
  Only URLs pasted into the Downloads sheet use Cairn's separate downloader,
  which receives no website cookies. Pause/resume of an active transfer is a different
  operation from **Retry** of a failed one. Retry reuses Chromium's retained item and
  original request context only for an unambiguous same-URL HTTP(S) GET; unsafe
  methods, redirects, query-bearing, `blob:`/`data:` and changed-partial cases are
  refused visibly, never replayed ([#21](https://github.com/MrAshRhodes/cairn/issues/21),
  [details](features/downloads.md)).
* Website data can be cleared per Space, per site and per kind (Preferences ▸ Privacy). CEF has no
  "clear browsing data" call, so clearing is layered: cookies, HTTP cache and HTTP-auth credentials
  through CEF; localStorage, IndexedDB, Cache Storage, service workers, File System and WebSQL
  through DevTools `Storage.clearDataForOrigin` on every http(s) origin the profile navigated to
  (recorded in `<profile>/cairn-origins.json`, because DevTools cannot enumerate origins; a hidden
  browser is borrowed when the Space has no open tab). Chromium cannot clear the cache per site, so
  a per-site clear with "Cache" selected clears the whole Space's cache. A profile that predates
  origin tracking also gets a one-time deletion of its storage directories at the next launch
  (reported in Preferences). Partitioned third-party storage keys are not enumerated; deleting the
  Space is the guaranteed erase.
* Removing a Space deletes its profile directory (`<hash>.delete` marker first, honoured at the next
  launch if Chromium still holds files). At startup Cairn also deletes profile directories no Space
  references, only when the saved workspace was read successfully.
* Persistent Spaces keep session cookies across relaunches (`persist_session_cookies`); private
  contexts stay in memory and are discarded after their last tab closes.
* Content blocking uses only a local, user-imported blocklist (hosts file, plain hosts or `||host^`
  rules; nothing is fetched). It cancels third-party subresource and sub-frame requests to listed
  hosts, never main-frame navigations, with a per-site exemption. Cosmetic filtering, HTTPS
  upgrades and regex rules are not implemented.
* Popups: a user-gesture `window.open`/`target=_blank` to HTTP(S) or an empty URL is created by CEF in
  the opener's request context (an ephemeral opener gives an ephemeral popup) with `window.opener`,
  `postMessage` and named windows intact, and shown as a new tab in the opener's Space; `window.close()`
  from the popup closes only that tab. Popups without a user gesture, with another scheme, or beyond
  3 per 10 seconds per tab are blocked and counted in a banner on the opener. Chromium's own blocker is
  disabled (`disable-popup-blocking`) so every attempt reaches `OnBeforePopup`; the decision lives in
  `PopupPolicy`. Middle/Cmd-click arrive through `OnOpenURLFromTab` as new tabs. Popup size/position
  features are ignored. An [exact-origin exception](features/popups.md)
  ([#23](https://github.com/MrAshRhodes/cairn/issues/23)), granted from the blocked-popup banner and
  revoked in Settings, is scoped to one Space and profile. It removes only the gesture requirement
  for the main frame's origin; schemes and the budget still apply, and iframes never inherit it.
* First-document Boosts ([#24](https://github.com/MrAshRhodes/cairn/issues/24)) remain **blocked**:
  an adopted popup's first navigation can commit before its DevTools script registrations.
  Registering scripts before `Page.enable` did not satisfy the strict first-document fixture.
  A request-pausing experiment also stalled ordinary popups and was removed. Main-frame requests
  therefore continue unchanged: Cairn does not cancel/replay them, reconstruct POSTs as GETs, or
  replace intentionally blank documents to work around injection timing. A renderer-side design
  must establish first-context ordering, exactly-once execution and revocation across process
  swaps before this guarantee can ship. Per-site and JavaScript-trust guards still apply.
  `checkPopupBoosts()` records first-document failures and fails the bundled smoke; moving it
  after other scenarios gathers their evidence without waiving this gate.
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
  (camera and microphone only: capture runs in these processes).
* **Main app:** `Resources/Cairn.entitlements`: camera, microphone, location and Bluetooth. They are
  reviewed: every site request goes through `CCPermissionHandler.mm` and is denied unless the user
  allows it. The Bluetooth entitlement mirrors Chromium's own app entitlements and is dormant (Cairn has
  no Web Bluetooth chooser); [RELEASING.md](RELEASING.md#local-development-no-apple-account) says how to
  remove it.
* Libraries do not receive process JIT entitlements.
* `scripts/verify-bundle.sh` fails a build whose processes carry any other entitlement, lack a required
  one, or carry `get-task-allow`, `disable-library-validation` or the other forbidden keys
  ([packaging gate](RELEASING.md#packaging-gate)).

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

## Routine security bump

Chrome ships security fixes every week and CEF publishes a stable build some days behind them, so
keeping the pin current is routine maintenance, not a project. These are **targets, not guarantees**:
they depend on CEF publishing in time and on a maintainer being available.

* **Look** at a newer stable CEF within **24 hours** of the maintenance run that reports it.
* **Validate and ship** it within **72 hours** of CEF publishing it for both architectures, or say on the
  tracking issue why that is not possible.

Once deployed and permitted to open pull requests, the automation ends at a draft
pull request. Merging, releasing and accepting any remaining risk are always a
maintainer's decisions.

1. **Triage.** The daily maintenance run keeps the `chromium-security` tracking issue current while the pin
   trails Chrome stable, and opens or refreshes a draft pull request on `maintenance/cef-stable` whenever
   **both** architectures publish a newer stable CEF. Read the run summary (or the `chromium-status`
   artifact) for the pin, the newest CEF of each architecture and Chrome stable, then the Chrome and CEF
   release notes for every version between the old and the new pin.
   A vulnerability exploited in the wild shortens the targets to hours. Inside one Chromium major version a
   bump is usually mechanical; a major jump is where API drift appears.
2. **Review the pull request.** Only `engine/cef.lock.json` may change, with both architectures on one
   version and each archive's size, SHA-1 and SHA-256. Work through the checklist in the pull request
   (`.github/chromium-bump-pr.md`). CI must be green on **both** architectures: the offline updater tests,
   `make cef`, the native lifecycle tests, `scripts/swiftw test`, the bundled smoke test and the
   [packaging gate](RELEASING.md#packaging-gate). A smoke run that needed its single retry says so in the run
   summary; read the `smoke-logs-*` artifact before accepting it. If CI did not start, dispatch it as
   [described above](#security-status-and-release-gate).
3. **Fix API drift.** If the bridge stops compiling, the error points at one handler file
   ([source layout](#source-layout)). Fix it on the pull request's branch or in a linked pull request, never
   by loosening the build. Keep CEF API `15400` unless the build or a feature you need requires another one.
   A scratch trial of the 156.0.7 build on 2026-10-22 compiled and passed every native and Swift test and the
   packaging gate with no source change ([recorded validation](#updating-and-verification)).
4. **Check by hand what CI cannot:** certificates, profile isolation, private browsing, navigation, popup
   blocking, downloads, scripts, find, snapshots, close and quit, and an upgrade from the previous release
   with rollback. Do it on both architectures, or record which one was not run.
5. **Merge, then dry-run the release.** Run **Release → Run workflow** with `dry_run` enabled. It runs CI and
   the Chromium gate, which passes only when the pin is **not behind Chrome stable**. Even the newest CEF may
   trail it (on 2026-10-22: `156.0.8078.17` against Chrome `156.0.8078.48`), so a bump can narrow the gap
   without closing it. A maintainer then either waits for the next CEF build or accepts the remaining gap in
   a reviewed, written `chromium_risk_acknowledgement` (one line, 20–500 characters, recorded in the gate
   result and the release metadata). Unavailable or invalid upstream metadata cannot be overridden, and a gate
   record older than 24 hours is rejected, so repeat the run if the approval waits.
6. **Release and confirm.** Run the release for real (`dry_run` off, once signing is provisioned) or finalize
   locally; see [the release guide](RELEASING.md#check-the-engine-and-authenticate-both-builds).
   `scripts/release.sh` runs the packaging gate on the ZIP and the DMG of each architecture. Afterwards read
   the `engine` field of the published `RELEASE-INFO.json` (finalization derives it from the lock inside each
   archived app and refuses a release whose two architectures disagree), confirm it names the version you
   merged, and install one downloaded app to see the Chromium version it reports. The tracking issue closes
   itself at the first maintenance run that finds no gap.

### Architecture skew

The pin only moves to a build **both** architectures publish. While one lags, `check` prints an
`ARCHITECTURE GAP` warning and the report lists the newest build of each architecture. The pin can then only
move to the newest build both publish (`propose` still opens a pull request for it when it is newer than the
pin), never to the build only one architecture has. Do not edit the lock by hand to put one architecture on
a newer Chromium: the feed needs same-version archives for both. Wait for the other architecture and
re-check. If a fix for an actively exploited vulnerability is at stake, record the decision on the tracking
issue instead of improvising a one-architecture release.

### When the check itself fails

A `failed` status (a network failure after four attempts, an upstream feed whose format changed, an invalid
lock) keeps the tracking issue open and the run red, and means nobody is watching for Chromium security
releases. Read `status.md` in the `chromium-status` artifact. Re-run for a transient network error; for a
changed feed, fix `engine/tool.py` and add the new shape as a fixture in `engine/tests`. Never silence the
check or let it assume the pin is current.

### Rollback

Sparkle never installs an older version, so a rollback ships as a **new, higher** version:

1. `git revert` the commit that changed `engine/cef.lock.json`; it restores a previously tested pin for both
   architectures.
2. Rebuild and verify both architectures from the reverted lock (`make app` per architecture, which runs the
   packaging gate, and the bundled smoke test), then release it as the next version through the normal
   workflow. Never reissue a published version or tag with different bytes.
3. The Chromium gate blocks it, because the older pin trails Chrome stable by more. Security review must
   explicitly approve returning to a vulnerable version, and the `chromium_risk_acknowledgement` names the
   reason and the validation.
4. Back up profiles before every upgrade, and test the rollback with a copy of a profile the newer Chromium has
   used: a schema change may make the older Chromium misbehave on it. Say so in the release notes.

## Updating and verification

```sh
python3 -m unittest discover -s engine/tests -v
python3 engine/tool.py update      # explicit; only latest COMMON STABLE version
python3 engine/tool.py hash        # records the SHA-256 of both archives (downloads each once)
git diff -- engine/cef.lock.json   # manually review both archive pins
python3 engine/tool.py fetch
python3 engine/tool.py build
python3 -m unittest discover -s engine/tests -p 'test_lifecycle.py' -v   # native fixtures need the prepared CEF
scripts/swiftw build
scripts/swiftw test
scripts/bundle-app.sh              # ends with scripts/verify-bundle.sh, the packaging gate

# GUI session required. The smoke fixture serves only loopback, using isolated
# profiles under engine/.cache; it does not touch normal Cairn profiles.
python3 engine/smoke.py --identity 'Developer ID Application: YOUR IDENTITY'
# Explicitly weaker local signing, for functional debugging ONLY:
python3 engine/smoke.py --development-ad-hoc
# The same ad-hoc run the way CI does it: one retry for the documented teardown flake, logs kept in $SMOKE_LOG_DIR:
scripts/run-smoke.sh

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
`scripts/run-smoke.sh` reruns exactly that case once, never silently, and keeps the logs
([CI smoke retries](CI.md#smoke-retries)).

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

Recorded validation on 2026-10-22, macOS 26.6 arm64 / CLT Swift 6.4. This is pipeline work, not release
evidence:

* **Intel app, cross-built on Apple Silicon** (the committed CEF 154 pin): `tool.py fetch` and `build --arch
  x86_64`, `ARCH=x86_64 scripts/bundle-app.sh` and `scripts/make-dmg.sh`. `scripts/verify-bundle.sh --arch
  x86_64` passed for the app, the ZIP and the DMG, and `--arch arm64` rejected the same app. Under Rosetta 2 the
  bundled smoke test passed all 23 assertions through a throwaway wrapper (`engine/smoke.py` has no
  architecture option, and Chromium logs that Rosetta is "neither tested nor maintained"). That is a sanity
  check, **not** validation on Intel hardware.
* **Trial bump in a scratch copy** to the newest stable CEF, `156.0.7+g47dbc1d+chromium-156.0.8078.17`:
  `tool.py update` and `hash` against the live indexes, the 48 engine tests, `fetch`, the wrapper build,
  `scripts/swiftw build` with **no source change** (API `15400` still compiles), the 6 native lifecycle tests,
  all 329 Swift tests and `ARCH=arm64 scripts/bundle-app.sh` ending in the packaging gate all passed. Not run:
  the GUI smoke test and the x86_64 build on 156, and the manual checks, so the bump is feasible but not
  approved. The committed lock still pins 154. A later local trial of the newer
  156.0.8 build (2026-10-23) passed the build and unit checks but failed the
  bundled runtime smoke, so that build is not adopted either; see the
  [status section](#status-2026-10-23) and
  [#32](https://github.com/MrAshRhodes/cairn/issues/32). The 156.0.7 results above
  do not carry over to it.

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
[Rollback](#rollback) in the routine bump procedure has the steps.

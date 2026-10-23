# Cairn functional specification

This specification is for contributors implementing Cairn's behavior. It
defines an original, local-first macOS browser; it is not recovered Arc source
or a promise of Arc compatibility.

## Product boundaries

Cairn must open without registration, login, subscriptions, a developer-operated
backend or telemetry. Websites may still require their own authentication.
Browsing state belongs to the local user. The app uses its own name, artwork,
storage format and implementation.

Cairn uses Chromium (CEF) exclusively, including future public releases. It has a
pinned dependency and an independent security-update process, and remains
experimental. Release validation must surface any gap against Chrome stable.
There is no engine selector or fallback. Legacy engine preferences are ignored
without discarding other settings; website data is not migrated from historical
WebKit profiles. Publish separate Apple Silicon and Intel applications.

## Workspace behavior

| Concept | Required behavior |
| --- | --- |
| Spaces | Named, colored collections of tabs, with independent cookie/storage profiles. At least one Space always exists. |
| Favorites | Global shortcuts visible from every Space. A global shortcut must not share one live authenticated view across different profiles. |
| Pinned tabs | Persistent per-Space tabs with a saved home URL. Closing unloads the view without deleting the pin. |
| Today tabs | Ordinary tabs, with selection and ordering persisted. Closing removes the tab. |
| Archive | Inactive ordinary tabs move here after a configurable interval. Selected/split-visible tabs must not be archived while in use. Restoring moves a tab into the active list. |
| Split view | Two to four distinct live tabs in a resizable layout. Closing/moving/removing a participating tab must leave a valid layout. |

Changing a Space must not silently navigate or mutate tabs in another Space.
Popups inherit the originating tab's profile. Moving a tab between profiles
recreates its engine view; it must not carry the old profile's cookies.

Restore tabs lazily. A corrupt or newer workspace file must be preserved, with
a visible error rather than replaced with empty state.

## Navigation and commands

The command bar accepts a URL/search query and filters tabs and commands.
Opening a new tab and changing the current tab's address are distinct actions.
Search-query encoding must preserve literal query characters instead of turning
them into extra URL parameters.

Provide back/forward, stop/reload, find-in-page and zoom. Expose loading progress
and errors. A security indicator is not an assertion that a website is safe;
failed TLS must never be bypassed to make navigation work.

Keyboard operation and accessibility labels are part of the interface, not
optional alternatives to pointer input.

Tabs show the site's own icon, fetched by Chromium through the Space's network
stack. Icons are cached on disk per profile (never across profiles; a private
store would keep them in memory only) and fall back to a globe. A tab playing
sound shows a speaker in the sidebar that toggles mute; "Mute Tab", "Mute Other
Tabs" and "Play or Pause Media" are commands. Mute survives navigation. The
keyboard play/pause key controls the audible tab while it is playing by driving
its first media element; custom players without one are out of reach.
Picture-in-Picture: `requestPictureInPicture()` works inside Chromium's Alloy
runtime (verified in the bundled smoke), so pages' own PiP controls function; an
automatic mini player on leaving a tab and a floating-panel fallback are not
built. Per-site zoom persistence is described below.

### Page tools

Commands (command bar; menus bind them): *Toggle Developer Tools* (⌥⌘I), *View
Page Source* (⌥⌘U), *Print…* (⌘P), *Save Page as PDF…* and *Reset Zoom for All Sites*.

- **DevTools** opens in Chromium's own window (CEF 154 only supports its Chrome-style
  window; an Alloy child view is rejected). It is never a Cairn tab. The remote
  debugging port stays disabled. Closing is asynchronous: reopening before the window
  has finished closing only focuses it. `inspectElement(at:)` is the hook for a
  context-menu *Inspect*.
- **View source** opens a new tab on `view-source:<page>` in the same Space. Only the
  browser can open it (typed addresses and page links cannot); only http(s)/file pages.
- **Print** calls Chromium's native macOS print path, which is intended to show the
  system print panel (Save as PDF is its PDF menu). Native panel interaction and
  printed output still require hands-on acceptance. **Save Page as PDF** uses
  `PrintToPDF` (backgrounds, tagged PDF, `@page` size honored); the local smoke
  checks PDF bytes, page count and size, not tagged-PDF accessibility conformance.
- **PDF viewing**: Chromium has a built-in viewer. The local smoke checks successful
  basic loading with `application/pdf` content or an embedded viewer, not toolbar
  interaction or complete document rendering.
- **Zoom** is remembered per Space profile and host in `site-zoom.json` (factor 1
  removes the entry). It follows navigation between hosts and survives relaunch.
  Unreadable files are kept untouched; the session then runs without persistence.
- **Language and user agent** (Settings ▸ General): `Accept-Language` and
  `navigator.languages` default to the system language list; an optional user agent
  string overrides Chromium's (advanced: client hints are dropped with it). Both are
  applied through DevTools emulation before a tab's first load and to open tabs on
  their next navigation. The Chromium UI language (`CefSettings.locale`) is unchanged.

## Local customization

Swift modules contribute commands through an explicit registry. Declarative
user modules load from the user's local configuration directory; merely loading
a file must not execute a command.

Boosts apply CSS or locally authored JavaScript to selected HTTP(S) hosts.
Domain matching must respect label boundaries, including after navigation.
Custom JavaScript runs in a page's context and is trusted user code, not a
secure extension sandbox. Do not automatically fetch or install remote Boosts.

## Downloads, privacy and updates

Downloads require a destination chosen by the user, safe filename handling and
visible cancellation/failure. Downloads started by a page are performed by the
engine itself (so cookies, authentication, POST and `blob:`/`data:` sources keep
working) and appear in the Downloads sheet with progress, pause, resume and cancel;
a user cancellation is never reported as a failure. Only links pasted into the sheet
use Cairn's cookie-less URL downloader. Completed files keep a quarantine attribute.

History and site data have explicit deletion controls (per Space, per site, per data kind); removing a Space
deletes its profile. A local, user-imported blocklist can block third-party requests, with per-site exemptions.
No history, cookies,
page text or customizations are sent to the project maintainers.

Application updates use Sparkle with an independently generated Ed25519 public
key and signed release artifacts. Missing signing configuration disables updates
with an explanation; it must not enable unsigned update installation. Chromium
updates require rebuilding and publishing an application bundle; installing a
new Chrome app does not update embedded CEF.

## Release-readiness boundaries

The integrated implementation is still a developer preview. Passing the local
arm64 engine smoke is necessary, but not sufficient, for a public Chromium release.
Release engineering must also enforce the Chromium currency, signing and artifact
checks in [the maintenance guide](../UPDATING_CHROMIUM.md) and
[release guide](../RELEASING.md#public-chromium-release-gates). The two-architecture
lock includes SHA-256 values derived from archives checked against the publisher's
size and SHA-1. Those pins establish repeatable bytes, not independent publisher
authentication. Current evidence must identify the tested CEF pin; dated results
for an earlier pin do not validate its replacement.

| Area | Implemented boundary or remaining acceptance |
| --- | --- |
| Startup and recovery | Restored background tabs are lazy; startup, navigation and renderer failures surface recovery state. The bootstrap blank document must never report completion of the requested page. Long-duration browsing, sleep/wake and memory-pressure acceptance remain open. |
| Popups | A user gesture and per-tab budget are required. Adopted browsers preserve the opener, messaging and request context, including intentionally blank documents. No per-site always-allow exception or requested window geometry; first-document Boost injection is not guaranteed. |
| Permissions and dialogs | Secure-origin/default-deny policy, per-Space site decisions, JavaScript dialogs and HTTP authentication prompts are implemented. Real macOS camera/microphone approvals and site sign-in journeys still need interactive acceptance. |
| Unsaved-page close safety | Tab/app close forces closure instead of honoring `beforeunload` cancellation; navigation/reload can prompt. The resulting data-loss risk is a mandatory public-release blocker ([#22](https://github.com/MrAshRhodes/cairn/issues/22)), not merely optional feature parity. Cairn's own quit checks do not protect unsaved web forms. |
| Downloads | Native page downloads preserve cookies, POST and blob sources, with destination choice and pause/resume/cancel. Engine-download retry is not implemented; native save-panel interaction and downloaded-file handling require acceptance. |
| Page tools and icons | Favicons, DevTools, native print dispatch, PDF export/viewing, source, language/UA and site zoom are implemented. Native print/save panels, PDF toolbar interaction and private-session zoom policy remain unverified. Service mocks and local engine fixtures do not establish full native UI acceptance. |
| Workspace and customization | Folders, themes, remappable shortcuts, four-pane splits, Chromium-family import, local Boost editing/sharing and link rules are implemented. Peek overlay, quick window, Safari/Firefox import, cloud sync and Arc account migration are not implemented. |
| Compatibility and accessibility | Native arm64/Intel CI passed bundled runtime smoke and ad-hoc packaging at `8a76627` with CEF 154; see the [recorded evidence](../RELEASING.md#building-and-testing-the-intel-app). Full Intel GUI/signed-runtime acceptance, complete keyboard/VoiceOver journeys, real-site sign-in/permissions and sustained website compatibility remain open. Rosetta is not native Intel evidence. Chrome extension and DRM support are not promised. |
| Distribution and updates | Ad-hoc builds are not Developer ID signed or notarized. Sparkle authentication is separate from Apple trust; downloaded-artifact Gatekeeper acceptance and a real increasing-version update/architecture-selection/profile-preservation journey remain release gates. An unpublished draft does not update the stable feed. |

Do not represent these gaps as completed features or release certification. A
release that cannot satisfy a safety gate must remain unpublished rather than
silently disabling the gate.

## Reference evidence and limits

On 2026-10-21 a bounded, static REA inspection examined the installed Arc 1.169.0
(88758) application. The executable hash was
`24e2aca39abd6645528b5f5e1241555a1ab5c925bb6e6c1e9ecaabdd2b83ed51`.

| Evidence | Observation |
| --- | --- |
| `ev_603d19688d27adf404b33ead82ccbd47c96107ec825b5d7127793d43b74391c8` | Universal Mach-O; the selected arm64 slice exposes native dependency/build metadata. |
| `ev_31e9e4a15b1153ff7117f1f4d225f14463fe8f9852b6c72a79301d0505003764` | Reported dependencies include native UI frameworks, a product core framework and Sparkle. |
| `ev_d84c4a5d756bd414c7e9e051e3560f7f8985f3d3690f32c5337e796bbea2327c` | Bundle metadata declares browser integration and signed-update configuration. |

These are observations of shipped metadata, not observations of execution.
Dependency presence does not establish which engine renders a page or how
accounts, sync, tabs or UI are implemented. Import/export coverage is explicitly
incomplete. No decompilation, source reconstruction, binary modification,
private protocol implementation, user-profile inspection or asset copying was
used. The behavior above is Cairn's design, not something proven by these
metadata observations.

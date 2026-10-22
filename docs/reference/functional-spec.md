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
| Split view | Two distinct live tabs displayed together. Closing/moving/removing a participating tab must leave a valid layout. |

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
- **Print** shows the system print panel (Save as PDF is its PDF menu). **Save Page as
  PDF** uses `PrintToPDF` (backgrounds, tagged PDF, `@page` size honored).
- **PDF viewing**: PDFs load in Chromium's built-in viewer (verified by smoke with a local
  PDF: `application/pdf`, document title). Toolbar interaction is not smoke-tested.
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
visible cancellation/failure. Authenticated downloads should use the engine's
own session, not silently restart a request without its credentials.

History and site data have explicit deletion controls. No history, cookies,
page text or customizations are sent to the project maintainers.

Application updates use Sparkle with an independently generated Ed25519 public
key and signed release artifacts. Missing signing configuration disables updates
with an explanation; it must not enable unsigned update installation. Chromium
updates require rebuilding and publishing an application bundle; installing a
new Chrome app does not update embedded CEF.

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

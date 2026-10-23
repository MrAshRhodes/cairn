# Link destinations

Settings ▸ Links edits `link-rules.json` (its own `schemaVersion` 1): a default destination,
the Peek preference, and ordered `{contains | equals text → Space | most recent |
quick window}` rules. The first matching rule wins. Matching is case-insensitive against the
**whole URL string**; `contains` remains substring matching, not a hostname/security rule.
Empty rules never match. This existing format is unchanged.

## One decision for external and in-app links

`LinkRouter.decision` resolves both links opened from another app (`application(_:open:)`)
and eligible URL-only engine `requestsNewTab` events:

- Cmd-click, Cmd-Shift-click, middle-click and other foreground/background new-tab link actions;
- the page context menu's Open Link in New Tab / Open Link in Background Tab and Open Image in New Tab;
- plain background links that the engine's existing popup policy explicitly converts to URL-only opens.

`BrowserServices` reads the current saved rules for each request, including edits
made without relaunching. `BrowserModel.newTabLinkHandler` consumes quick-window destinations;
`newTabLinkDestination` resolves ordinary Space destinations through the same router. For an
ordinary Space destination, a foreground open selects the new tab and its Space. A background
open adds one lazy Today tab without changing the selected Space or selected tab and creates
its engine view only when selected. Neither path replays or duplicates the source request.

Only valid `http`/`https` URLs pass the existing `URLResolver.isWebURL` boundary. Routing does
**not** intercept same-tab navigation, address-bar entry, explicit `newTab(in:)` destinations,
search-selection actions, tab moves, downloads or adopted popups. It does not broaden allowed
schemes, alter URLs, or make a site comparison into an origin/cookie/permission decision.

Each routed tab is new metadata and, when opened, a new engine tab configured for the destination
Space's profile. The source view and its cookies are never copied or moved into another profile.
`hostsPopup` is deliberately excluded: foreground `window.open` / `target=_blank` popups admitted
by the engine retain their opener's Space, profile, live context and `window.opener`, even when
their URL matches a routing rule. No new popup-security exception is introduced here.

## Unavailable destinations and saved settings

- If a matching rule or default names a Space deleted during this session, that first decision
  falls back to the most recent Space and shows **Link destination is unavailable**, naming the
  fallback Space. It does not try a later rule or lose the link.
- At launch, writable rules for deleted Spaces are pruned and a deleted default becomes
  **Most recent Space**, with a visible **Link destinations were removed** notice. Subsequent
  links use those remaining ordered rules. A failed save is reported instead of ignored.
- A quick-window destination now creates a real native window rather than substituting a
  persistent Today tab. Its profile is the most recent Space's normal persisted profile.
  A background new-window link does not make the quick window key or change workspace selection.
  If page closure is pending, the link is not loaded and a visible retry notice is shown.
- A corrupt rules file is moved aside (`link-rules.corrupt-<time>.json`) with a visible notice.
  A newer schema is preserved, read-only. Decisions can still fall back visibly from deleted
  destinations in a read-only store.

“Most recent” uses the newest `lastActiveAt` across each Space's Today and pinned tabs, excluding
archived tabs; ties (including all-empty Spaces) use workspace order. Normal session persistence
retains routed tabs and foreground/background selection across relaunch.

## Local public-suffix site classification

`SiteMatching` uses the **complete ICANN and PRIVATE Public Suffix List**, including exact,
wildcard and exception rules. There is no network fetch on launch or navigation. Unicode PSL
rules and URL hosts use Foundation's IDNA conversion, so Unicode and punycode names agree.
IPv4 and normalized IPv6 literals compare as addresses, not suffixes. Localhost and other
single-label hosts compare as exact hosts; a suffix by itself also compares only to itself.
Invalid/non-web URLs have no site and never compare as same-site. Unknown suffixes use the
PSL's implicit `*` rule. Scheme and port are intentionally outside this classification;
origin and navigation checks remain separate and unchanged.

The unmodified dataset, MPL-2.0 license and provenance are bundled from
`Sources/CairnCore/Resources/PublicSuffix/` into the `CairnCore` resource bundle:

- Upstream: <https://publicsuffix.org/> / <https://github.com/publicsuffix/list>
- Revision: `8437e5262f13305f94087abe699b4fe2be1d1de8` (2026-10-22)
- SHA-256: `d3e6243b51695327984abb3e2a5aa7077096867f75121e031e6a5a3840ca8bcd`

**Release maintenance:** review and pin a current upstream revision before each release or
when correcting classification. Replace the complete list and license, update `SOURCE.txt`
and this revision/hash, then run the tests below. Keep PRIVATE rules; do not trim the dataset
to popular suffixes. The normal app bundler copies SwiftPM resource bundles and the upstream
license alongside the app.

## Peek: live page, not a URL bookmark

Peek is wired through an optional engine navigation callback and `PeekPolicy`. CEF offers
only ordinary main-frame, user-activated GET links (`TT_LINK`), not redirects, POST/form
submissions or script navigations. Disabled Peek, Today tabs, same-site links, unsupported
URLs, and known OAuth/payment **source or destination** hosts/paths/query parameters navigate normally.
The host/path exception list is conservative, not an exhaustive authentication detector.
Opener-dependent popups stay on CEF's existing popup-adoption path; no popup is reconstructed
from its URL to implement Peek. An adopted popup remains excluded even if the user later pins it.

An eligible link from a pin/favorite cancels that source navigation once and opens a live
Chromium view in the overlay, configured with the originating Space's profile before load.
It is tracked as a live engine, **not** a hidden Today tab or a saved workspace record.
The overlay displays its title, address/security state and non-private profile ownership;
Close/Escape, loading/error/reload and **Expand to Tab** are available. Expanding inserts the
same live engine/view into Today without calling load again: DOM edits, history and page
state are not replaced by a fresh URL navigation.

The background workspace is disabled/hidden from accessibility while Peek is modal. Focus
enters the Close action; keyboard users can reach the page and Expand. Dismissal returns
focus to the owner when still present; expansion keeps it on the promoted page. Closing
the owner first requests approval from its dependent Peek/popup pages. Stay leaves the
owner and preview intact. Space deletion and app/window close also include these live
engines, with transient approvals before ordinary workspace pages.

## Quick windows: ordinary profile, transient presentation

**File ▸ New Quick Window** (default **⌥⌘N**, remappable in both keymaps and available in
the command bar) opens a blank quick window in the selected Space's profile. Routed links
use the most recent Space's profile. The window says **“[Space] profile · Not private”**
before its Chromium view loads; closing it does not erase cookies/storage/history.

The app chooses bounded native geometry and always retains a title bar and address/security
controls. Popup-supplied `width`, `height`, `toolbar=no` and similar strings do not control
this chrome. Escape, Close, address entry, Back, reload/stop and **Open In Space** have
keyboard/accessibility affordances.

- **Open In the originating Space:** transfers the same live view into one Today tab.
- **Open In a different profile:** shows an explicit reload confirmation, asks the old page
  to close (honoring Stay), then creates one fresh target-profile engine for the current web
  address. It does not copy cookies, credentials, form bodies, DOM/history or an authenticated
  view. It is a new GET, not request replay; page state may be lost and sign-in may be required.
- **Close:** no closed-tab-stack entry, session restore or auto-archive. The engine is retained
  until CEF approves closure. The originating profile's data is not deleted.
- **Promoted pages:** become normal persisted Today tabs, subject to the usual archive/restore
  rules. Subsequent quick-window cleanup cannot close the promoted engine.
- **Popups:** a transient page's admitted popup is another native quick window sharing the
  original live opener/profile. Closing its owner first closes those dependents with the
  same beforeunload approval rules.
- **Prompts/downloads/quit:** prompt queues belong to live IDs, including transient ones.
  Approved removal cancels unresolved prompts and detaches callbacks. Downloads stay in the
  application-wide Chromium download manager, not a separate quick-window manager; normal
  CEF cancellation/completion and app shutdown handle their cleanup.

These surfaces share engine ownership/close/promotion primitives, but quick-window routing
does not depend on Peek being enabled.

## Verification

```sh
scripts/swiftw test --filter 'SiteMatchingTests|LinkRoutingTests|LinkRuleStoreTests|LinkRoutingServicesTests|TransientBrowsingTests|CloseLifecycleTests|ShortcutTests|PopupTests|PopupPolicyTests'
```

Fixtures cover compound/private/Unicode suffixes, wildcard exceptions, IP normalization,
localhost, malformed hosts and unknown TLDs. Service tests exercise ordered rules, actual
engine delegate callbacks, fresh destination profile creation, lazy background opens,
same-tab/explicit/popup exclusions, notices, edits, saved selections and bootstrap relaunch.
Transient tests cover eligibility and exceptions, profile selection before loading, no
persistent metadata, one navigation, same-engine expansion, cross-profile recreation,
Stay/Leave/forced dependent closure, prompts, Space/window cleanup and remapped commands.
The offscreen native-window test checks real NSWindow chrome and non-restoration, not CEF.

**Verified boundary:** implementation and deterministic tests are present. Full bundled
CEF/native-UI and VoiceOver acceptance below is still a release gate; a model test or
offscreen NSWindow is not evidence that an end-user overlay journey passed.
`engine/fixtures/transient.html` and `TransientNavigationChecks.swift` provide an additional
native engine probe for trusted-link interception, live view reparenting, profile isolation
and preserved popup opener. The wired probe emitted `CAIRN_TRANSIENT_NAVIGATION_OK`
in the local arm64, development-ad-hoc bundled run on 2026-10-23 with CEF 154.0.34.
Reparenting restores native content focus immediately as well as on the next run loop,
preserving the document's scroll position instead of traversing to its first link.
This is not a test of Cairn's complete SwiftUI overlay or native Intel acceptance.
The overall smoke still failed the independent popup first-document Boost gate.

**Real CEF acceptance (GUI release check):** create Personal and Work Spaces with different
profiles, save a `contains` rule for a local fixture link to Work, and open the fixture as a
Today tab in Personal. Cmd-click / middle-click must add one background Work tab without switching Personal;
Cmd-Shift-click and Open Link in New Tab must select one Work tab. Opening that same URL from
another app must choose Work too. Set a source-only fixture cookie and verify the routed Work
page does not receive it. Ordinary click stays in Personal. A user-gesture `window.open` sign-in
fixture stays in Personal with its opener intact. Repeat after relaunch and verify rule and
selection persistence. Repeat a deleted destination and check the named fallback.

Then pin the local transient fixture (`127.0.0.1` → `localhost` supplies different sites).
With Peek enabled, click its ordinary cross-site link: exactly one overlay, owner unchanged,
same profile, no Today record. Enter a draft, scroll/change history, Expand, and verify the
same draft/history/scroll remain in one Today tab. Repeat with Peek disabled, same-site,
Today, script, form and auth-path links: no overlay. Test loading failure/reload, native
Escape/Close, keyboard traversal and VoiceOver focus entry/return. The “Make unsaved changes”
button activates beforeunload: test Stay/Leave while closing the preview, its owner, Space
and main window. Check no orphan browser or stale prompt after approval.

Finally route an external link to Quick Window and invoke ⌥⌘N: a real titled window, not a
Today tab, with explicit profile label. Check address/reload, keyboard/VoiceOver, and popup
geometry/opener. Open In the same Space must preserve page state; another Space must require
confirmation, honor Stay, and reload with no source-only cookie. Close/relaunch: unpromoted
windows do not restore; promoted tabs do. Repeat with a pending permission/dialog/download
and app quit, verifying approved cleanup and preserved Stay state. Record actual results;
signing/notarization and full release validation remain separate gates.

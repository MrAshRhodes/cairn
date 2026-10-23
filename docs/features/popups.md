# Popup exceptions

Cairn blocks page-initiated popups without a user gesture by default. A blocked-popup
banner offers **Allow for This Site…** when the request came from the current
top-level HTTP(S) page. The confirmation names the exact origin and Space. Retry
the site's action afterwards: Cairn does not replay a lost popup as a URL-only
navigation, which would lose its opener, POST/body or named-window semantics.

Inspect and **Revoke** exceptions in **Settings → Permissions → Popup exceptions**.
Revocation affects the next new popup immediately; it does not close existing
windows or prevent a website from reusing an already-open named window.

## Scope and restrictions

- An origin is **scheme + host + effective port**, not a registrable site.
  `https://example.com:443` and `https://example.com` are the same origin;
  HTTP, subdomains and nondefault ports are separate. No wildcard grants exist.
- Both the Space UUID and its current storage-profile ID must match. Switching
  Spaces, changing profiles or sharing a profile does not transfer a grant.
  Global favorites use the Space in which their live engine tab was created.
- Only the missing-gesture check is bypassed. The same opener budget of **3
  popups in 10 seconds** applies to gesture and granted popups together.
  Only HTTP(S), an empty target or `about:blank` is supported; exceptions cannot
  permit JavaScript, data, file, browser-internal or other unsafe schemes.
- CEF supplies the initiating main-frame URL; it is never inferred from the
  popup's destination. Embedded frames (including same-origin and sandboxed
  frames), unknown origins and opaque pages cannot use or create an exception.
  Ordinary gesture-driven popups retain their existing policy.
- Allowed foreground popups still adopt CEF's actual browser: opener,
  `postMessage`, named targets and the Space's request context are preserved.
  Refused popups return before native pending-creation counters are incremented.
- Requested popup size and position are **not honored**. Existing tab/Quick
  Window presentation and Cairn-controlled security chrome are unchanged.
- The first document of a newly adopted popup can miss Boost injection.
  [#24](https://github.com/MrAshRhodes/cairn/issues/24) remains a failing release
  gate, not a supported first-document guarantee. Cairn does not pause or replay
  the popup request to conceal this limitation.

## Persistence and failures

`popup-exceptions.json` is a local, versioned file beside the workspace. A grant
becomes active only after an atomic save succeeds. Corrupt, unsupported-version
and invalid stores are preserved, reported in the app and Settings, and disabled
for that session. A failed grant save never enables the grant.

Revocation removes the in-memory grant immediately. If saving fails, a visible
warning states that the old grant may return after restarting; further grants
are disabled for that session. Deleting a Space removes its grants **after**
its pages approve closing. Choosing **Stay** preserves them. A successfully
loaded workspace also prunes grants for removed Spaces or replaced profiles.

## Verification

Automated tests cover persistence/relaunch, grant/deny/revoke, exact origin and
Space/profile boundaries, failed saves, preserved corrupt/newer files, stale
confirmation after navigation, tab closure, canceled Space removal and rate limits:

```sh
scripts/swiftw test --filter 'PopupTests|PopupPolicyTests|PopupExceptionStoreTests|PopupServicesTests|SitePermissionStoreTests'
```

`engine/fixtures/popup-exceptions.html` and
`engine/smoke/PopupExceptionChecks.swift` cover native script-popup grant/revoke,
opener/postMessage/named-window reuse, frame isolation, navigation and flood limits.
The local smoke server serves the fixture at `/popup-exceptions.html` and the
native smoke sequence calls `checkPopupExceptions()`. These checks passed in the
2026-10-23 local arm64 ad-hoc run with CEF 154. That evidence is not an Intel,
signed-runtime or integrated banner/Settings acceptance result.

Before release, use an isolated test profile (never a real browser profile) to
exercise the banner confirmation, Settings revoke and relaunch. Serve the fixture
on two loopback ports; compare `localhost`, `sub.localhost` and each port. Confirm
only the explicitly granted origin succeeds, and that rate-limited/unsafe targets
do not offer an exception. Start a confirmation then navigate or close its tab;
it must not authorize the new page. Verify **Stay** versus **Leave** while deleting
a Space and the visible errors for corrupt/newer/unwritable stores.

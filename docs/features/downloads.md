# Downloads and failed-transfer retry

Downloads started by a page stay inside Chromium. Its original request context
provides the Space's cookies and authentication; Cairn never copies cookies or
changes a failed page download into a separate URL-session download. Pasted
public links remain a separate, cookie-less feature.

## Controls

- **Pause / Resume** control a live engine transfer.
- **Cancel** is terminal, not a failure and not eligible for Retry.
- **Retry** appears only on a failed engine item that has a retained retry
  capability. It reuses that item and destination, not a new job or save panel.
  Repeated clicks do not start parallel retries.
- **Show in Finder** is available after completion. Files are not opened
  automatically; the app ensures a quarantine attribute on completion.
- **Clear Finished** discards retained retry capabilities, not saved files.

When Retry is unavailable, the Downloads sheet shows an explanation and asks
the person to start the download again from its page.

The initial save destination is checked before Chromium receives it. A missing or
unwritable parent, nonregular target or symbolic-link target is refused visibly;
Cairn does not let Chromium silently substitute a temporary destination. Download
IDs are unique across Space profiles, even when CEF reuses a profile-local number.

## Deliberately narrow retry boundary

An explicit retry requires all of the following:

1. Chromium reported a transport interruption, not completion, pause, user
   cancellation, a security block, disk error or an authorization refusal.
2. `CefDownloadHandler::CanDownload` supplied an unambiguous **GET** method for
   the original download. The app does not guess the method from a URL.
3. The original and final URLs are identical HTTP(S) URLs without embedded
   credentials, a query or a fragment. Redirects, opaque/query-bearing links,
   POST/other methods, `blob:`, `data:` and missing provenance are refused.
   Native context-menu downloads that bypass `CanDownload` also fail closed.
4. The original tab/browser and Space profile are still present. Approving a
   tab/Space close invalidates its retry capabilities; choosing Stay does not.
   Capabilities are per-launch and are never restored from persisted URLs.
5. The original destination folder remains the same, writable, nonsymlink
   directory. An existing partial must still have the recorded identity,
   metadata and size. A replaced, modified, removed or newly introduced file
   is not overwritten. If it changed, restart from the page and choose a
   different filename.

Cairn never deletes or truncates a partial to make retry work. Chromium owns its
partial-file/range/restart decisions. It may need to restart the same GET from
the beginning. If Chromium discards its partial, retry requires the destination
to be absent; pending cleanup or a replacement file is refused. A retained partial
must still match its recorded path and file identity.
A site can still expire or refuse an otherwise ordinary GET;
Cairn cannot infer arbitrary server-side one-shot semantics. A refusal remains a
visible failure, not a fallback that replays a POST or copies credentials.

CEF 154 exposes `Resume()` but not `CanResume()` or a resume acknowledgement.
Its [pinned implementation][cef-resume] checks the retained download item's
`CanResume()` and invokes `Resume(true)`, preserving that item's request context.
If Chromium does not acknowledge an explicit retry within 15 seconds, Cairn
invalidates it and explains that it must be restarted from the page. Cancellation,
close, clear and shutdown discard callbacks; old attempt updates cannot revive
a cancelled or completed app item.

These are application-level checks at retry/target selection, not an atomic
filesystem guarantee against another process replacing a path concurrently
with Chromium's asynchronous file operations.

## Verification

```sh
scripts/swiftw test --filter 'EngineDownloadTests|EngineDownloadRetryTests|NativeDownloadServicesTests'
python3 -m unittest discover -s engine/tests -p 'test_download_retry*.py' -v
```

The native unit fixture compiles the production download handler with inert CEF
objects. It covers method/URL refusal, callback reuse, duplicate clicks,
attempts, changed/missing/read-only partials, replaced folders, profile mismatch,
profile-local ID collisions, invalid initial destinations, discarded partial
cleanup, close, cancellation and late destination choices at shutdown. It does **not**
initialize Chromium or prove real network resumption.

`engine/download_retry_fixture.py` and `engine/smoke/DownloadRetryChecks.swift`
provide a deterministic real-CEF scenario: an HttpOnly-cookie GET remains
interrupted through automatic and failed manual retries, then an explicit fixture
switch permits an exact-byte/ranged response. Separate checks cover another
Space, one-use POST counts, an expired blob, replaced partials, an invalid initial
destination and a closed origin. These scenarios passed in the local arm64,
development-ad-hoc bundled run on 2026-10-23 with CEF 154.0.34 / Chromium
154.0.8037.98. The overall run still failed the independent popup first-document
Boost gate; it is not a passing release smoke or native Intel evidence.
Native Downloads-sheet/save-panel interaction, keyboard/VoiceOver controls and
real-site expiry/authentication behavior remain separate release acceptance.

[cef-resume]: https://github.com/chromiumembedded/cef/blob/14c5a08/libcef/browser/download_manager_delegate_impl.cc

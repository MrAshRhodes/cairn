# Contributing to Cairn

This guide is for contributors adding a browser feature while keeping UI and
workspace state separate from Chromium implementation details.

Start with the [functional specification](docs/reference/functional-spec.md).
Build with `make build`, run `make test`, and use `make app` (or `make run`) for a
bundled app. These Chromium targets prepare the pinned CEF dependency
automatically, including for tests, and need CMake 3.21+ and Python 3.12+.
Chromium is the only shipped engine; there is no CEF-free build mode.
Use Swift Testing, not XCTest, so tests also work on a Command Line Tools-only
installation.

## Module boundaries

The engine kit defines engine/tab contracts. Core owns workspace state and
persistence. The Chromium engine implements navigation and rendering; it does not
own sidebar state. The native UI composes Core, modules, Boosts and the updater. Put a new
command in a module rather than hard-coding another unrelated dependency into
the window.

Mutable browser state is main-actor isolated. Route tab/Space mutations through
the browser model so persistence and view selection stay consistent. Installing
delegates and user scripts must precede the initial page load.

## Invariants to preserve

- Space profiles isolate cookies and storage, including favorites and popups.
- Moving/deleting tabs leaves valid selected and split-view identifiers.
- Corrupt or unsupported saved files are not overwritten automatically.
- Errors are visible; cancellation is distinguishable from failure.
- No telemetry, compulsory backend, login gate or remote plugin execution.
- Updates never install unsigned application archives.

Add regression tests at the narrowest appropriate layer. Test navigation and
download behavior with local fixtures rather than relying on a public site's
content. Engine stubs in tests must not replace a real bundled-app smoke check
for changes to native view or process lifecycles.

## Submitting a change

Describe the user-visible behavior, affected modules, compatibility concerns
and checks performed. Keep changes focused. Document a new command or setting
where a new user can find it. Do not include browser profiles, cookies, browsing
history, signing keys, binary analysis dumps or proprietary application assets.

Contributions must be independently authored or carry a compatible license.
See [the independent implementation policy](docs/CLEAN_ROOM.md). Report sensitive
bugs using the [security policy](SECURITY.md), not a public issue containing
credentials or private page content.

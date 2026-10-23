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

## Build, test and CI

```sh
make test                                          # prepares the pinned CEF, then runs the Swift tests
scripts/test-release.sh                            # workflows, release scripts, packaging gate and updater tests
python3 -m unittest discover -s engine/tests -v    # Chromium updater; also the native lifecycle tests once CEF is prepared
make app                                           # bundles the app and ends with the packaging gate
scripts/run-smoke.sh                               # bundled Chromium smoke test, as CI runs it (needs a GUI session)
```

Set `ARCH=x86_64` to cross-build the Intel app on an Apple Silicon Mac (`make app ARCH=x86_64`). `make cef`,
`app`, `run` and `dmg` take it; `make build` and `make test` always compile for this machine, so leave it unset
for them. `scripts/bundle-app.sh` finishes with `scripts/verify-bundle.sh`, which fails on any layout,
Info.plist, architecture, signature or entitlement problem; run it on its own against an app, a ZIP or a DMG
to see every problem at once.

CI runs these checks for every pull request on Apple Silicon and Intel runners and keeps the logs of a failed
smoke test. [docs/CI.md](docs/CI.md) says what each step catches and how to reproduce a failure locally.
Updating Chromium is in [docs/UPDATING_CHROMIUM.md](docs/UPDATING_CHROMIUM.md) and releasing in
[docs/RELEASING.md](docs/RELEASING.md).

## Module boundaries

The engine kit defines engine/tab contracts. Core owns workspace state and
persistence. The Chromium engine implements navigation and rendering; it does not
own sidebar state. The native UI composes Core, modules, Boosts and the updater. Put a new
command in a module rather than hard-coding another unrelated dependency into
the window.

Mutable browser state is main-actor isolated. Route tab/Space mutations through
the browser model so persistence and view selection stay consistent. Installing
delegates and user scripts must precede the initial page load.

Chromium features live in their own files so parallel work rarely collides: a CEF
callback in `Sources/CairnChromiumBridge/Handlers/CC<Family>Handler.mm` (skeletons are
already registered), a tab command in `CCTab+<Feature>.mm`, and its public bridge API in
your own `// [Feature]` slot of `include/CairnChromiumBridge.h`. The Swift side is
`ChromiumTab+<Feature>.swift` plus an optional protocol in `EngineTabEvents+<Feature>.swift`;
never change the frozen `EngineTabDelegate`. See `CCInternal.h` and `EngineTabEvents.swift`.

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

# Cairn

An experimental, local-first macOS browser with a vertical workspace: Spaces,
pinned tabs, favorites, a command bar, split browsing and per-site customization.
No Cairn account, login gate or telemetry.

Cairn is an original implementation, not a fork or recompiled version of Arc.
It is not affiliated with The Browser Company. **Do not treat this early project
as a hardened replacement for a maintained mainstream browser.**

## Build on your Mac

Requires macOS 14 or later, Swift 6, and Apple's Command Line Tools or Xcode.
The first build downloads Sparkle through Swift Package Manager.

```sh
git clone https://github.com/mrashrhodes/cairn.git
cd cairn
make build
make test
make app
```

The generated application bundle is `dist/Cairn.app`. A development build is
ad-hoc signed unless you configure your own Developer ID signing. Ad-hoc signing
is not notarization; see the [release guide](docs/RELEASING.md) before distributing
downloads.

## Developer preview status

The current implementation uses system WebKit and includes native Spaces, vertical tabs,
favorites and pins, session restoration and archiving, command search, split
browsing, find/zoom, local history, downloads, and CSS/JavaScript Boosts with an
explicit trust decision. Authenticated WebKit downloads use a native save dialog
and are separate from the URL-only download list.

Automated tests cover the integrated services and real WebKit behavior, including
profile isolation and authenticated downloads. The optional arm64 CEF application
also compiles. Interactive GUI and VoiceOver checks, Intel CEF runtime testing,
Apple Developer ID signing, and notarization are **not yet verified**. This is a
developer preview, not a production-readiness claim.

A signed, auto-updatable download is not published yet. Build from source for now;
local release signing still requires the maintainer's macOS Keychain approval.
Private update-signing material is not uploaded to GitHub.

The build wrapper handles the Command Line Tools-only SwiftPM/Swift Testing
configuration. It does not install or change your system toolchain.

## Engines and security updates

The normal build uses **system WebKit**, updated by Apple through macOS/Safari
updates. Keep macOS and its browser components current.

The optional **Chromium Embedded Framework (CEF)** build has separate dependency,
helper-process, packaging and security requirements. It is not updated by
installing Google Chrome. Follow the [Chromium maintenance guide](docs/UPDATING_CHROMIUM.md);
do not enable an old CEF build just because it compiles. A version-monitoring
workflow cannot guarantee upstream fixes exist or ship them without a release.

Application auto-updates require signed Sparkle releases and the matching public
key embedded in the installed application. An unconfigured source build must
not accept unsigned updates.

## Make it yours

Use local CSS/JavaScript Boosts for site customization and modules for additional
commands. See [Extending Cairn](docs/EXTENDING.md). JavaScript customizations are
trusted page code, not sandboxed Chrome extensions. Chrome extension support,
cloud synchronization, Arc account migration and DRM compatibility are not
promised.

## Project guide

- [Functional specification and reference boundaries](docs/reference/functional-spec.md)
- [Contributing and development invariants](CONTRIBUTING.md)
- [Privacy](PRIVACY.md) and [security policy](SECURITY.md)
- [Independent implementation policy](docs/CLEAN_ROOM.md)
- [Release and update signing](docs/RELEASING.md)
- [Chromium maintenance](docs/UPDATING_CHROMIUM.md)

Cairn's original code is licensed under [Apache-2.0](LICENSE). Third-party
components retain their own licenses; see [NOTICE](NOTICE).

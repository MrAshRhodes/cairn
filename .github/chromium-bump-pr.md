## Required before this pull request is merged

This pin change is **not** proof of Chrome security parity: a newer CEF build can still trail Chrome stable, and a version
comparison is not a CVE or backport audit. The report above is the starting point, not the decision.

- [ ] Read the upstream CEF and Chromium security notes for every version between the old and the new pin.
- [ ] `engine/cef.lock.json` has the SHA-256 of **both** archives. This pull request records them from archives that
      already matched the size and SHA-1 published by the CEF index; later fetches enforce all three.
- [ ] CI is green on both architectures. Pull requests opened with the default token do not start CI by themselves; the
      maintenance workflow dispatched it for this branch, so look for the CI runs on the head commit. If they are missing,
      run the CI workflow on `maintenance/cef-stable`.
- [ ] The bundled sandbox smoke test passed on both architectures. A retry after the known teardown-watchdog flake is
      recorded in the run summary and the `smoke-logs-*` artifact.
- [ ] Manual checks that CI cannot do: certificates, profile isolation, private browsing, navigation, popup blocking,
      downloads, scripts, find, snapshots, close and quit, and an upgrade from the previous release with rollback.
- [ ] If the bridge or entitlements needed changes for the new CEF API, those are in this pull request or a linked one.
- [ ] Release signing and notarization keep the Chromium sandbox: `scripts/verify-bundle.sh --require-developer-id
      --notarized` passes on the signed result.

Nothing is merged or released automatically. The release workflow's Chromium gate keeps blocking releases while the pin
trails Chrome stable. See docs/UPDATING_CHROMIUM.md.

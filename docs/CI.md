# Continuous integration

How the repository's workflows build, test and package Cairn, what they keep when something fails, and how to
reproduce each step on a Mac. Signing, notarization and publication are described in [RELEASING.md](RELEASING.md);
the Chromium security monitor in [UPDATING_CHROMIUM.md](UPDATING_CHROMIUM.md).

## Workflows

| Workflow | Runs on | Triggers | Purpose |
| --- | --- | --- | --- |
| `ci.yml` (CI) | `macos-15` (arm64), `macos-15-intel` (x86_64) | push to `main`, pull requests, manual dispatch, called by Release | Validate, test, smoke-test and package both architectures |
| `engine-bump.yml` (Chromium maintenance) | `ubuntu-latest` | daily 07:23 UTC, manual dispatch | Watch Chromium security releases, propose pin updates, keep the tracking issue |
| `release.yml` (Release) | Ubuntu and both macOS runners | Mondays 06:17 UTC, manual dispatch, `v*` tags | Plan, gate, build both architectures, sign one feed, publish |
| `pages.yml` (Product site) | `ubuntu-24.04` | `site/**` changes on `main` | Deploy the product site |

Every workflow defaults to `contents: read`, and checkout never persists credentials. A job gets more only where it needs
it: the maintenance workflow's `propose` job (`contents`, `pull-requests`, `actions: write`) and `tracking-issue` job
(`issues: write`), and the Release workflow's `publish` job. CI itself uses no secrets, so a pull request from a fork
runs the same checks. Third-party actions are pinned to full commit SHAs; update the pins deliberately.

## What CI runs

`ci.yml` runs one job per architecture (`fail-fast: false`: one architecture failing never cancels the other, and
**Re-run failed jobs** repeats only the one that failed). A new push to the same ref cancels the run in progress.
Each job asserts that the runner really is the architecture it is named for, then:

| Step | Command | Catches |
| --- | --- | --- |
| Validate workflows and release tooling | `actionlint`, `scripts/test-release.sh` | Workflow syntax, ShellCheck and `bash -n` on the release scripts, updater, signing, bundle-gate and smoke-wrapper tests |
| Offline Chromium updater tests | `python3 -m unittest discover -s engine/tests -v` | `engine/tool.py` and the bump flow against fixtures, with no network. The native lifecycle fixtures skip here because CEF is not prepared yet |
| Restore pinned CEF archive | `actions/cache` | See [Caching](#caching) |
| Prepare Chromium | `make cef` | Fetching, verifying and building the pinned CEF |
| Chromium lifecycle regressions | `python3 -m unittest discover -s engine/tests -p 'test_lifecycle.py' -v` | The source-contract guards plus the native fixtures that compile against the prepared CEF headers and wrapper |
| Test | `scripts/swiftw test` | The Swift test suites, compiling the Chromium bridge against the pinned CEF |
| Check Chromium rendering | `scripts/run-smoke.sh` | The sandboxed, bundled Chromium smoke test (`engine/smoke.py --development-ad-hoc`); see [Smoke retries](#smoke-retries) |
| Package and verify | `scripts/bundle-app.sh`, `scripts/make-dmg.sh` | The ad-hoc app and DMG; `bundle-app.sh` ends with `scripts/verify-bundle.sh`, which fails the job on any packaging problem |

Packaging and verification run regardless of the artifact-upload choice. The development DMG is uploaded only for a
manual dispatch with `upload_development_artifacts=true`; the input defaults to `false`, and push, pull-request and
reusable runs do not upload these binaries. When requested, it is kept as `cairn-development-<runner>` for 7 days.
It is ad-hoc signed and not notarized: a functional Chromium check, **not** a Developer ID, hardened-runtime or
notarization gate and not a release.

Release runs the same workflow as its `verify` job, then builds each architecture on its own runner (see
[RELEASING.md](RELEASING.md#github-actions-maintainer-setup-not-automatic-secret-provisioning)).

## Caching

Only the CEF archive is cached: `engine/.cache/cef_binary_*_<platform>_minimal.tar.bz2`, keyed
`cef-archive-<platform>-<hash of engine/cef.lock.json>`. Any change to the lock is a new key, so a pin update downloads
once per architecture and later runs hit the cache. `engine/tool.py fetch` checks the size and checksums of the archive
on every use, cached or not, and downloads it again when the entry is damaged or stale, so a poisoned or truncated cache
cannot be trusted. Extraction and the wrapper build always run. Network access in `tool.py` retries four times with
growing pauses; a complete download with the wrong checksum is never retried.

## Smoke retries

`scripts/run-smoke.sh` retries **once**, and only for the documented shutdown flake: every assertion passed and
`CAIRN_CEF_SMOKE_OK` was printed, then Chromium's teardown watchdog ended the process. The retry is never silent: it adds
a warning annotation and a line to the run summary, and uploads the logs. Any other failure, and a second failure of any
kind, fails the job.

## Artifacts and where logs go

| Artifact | Uploaded | Contents | Kept |
| --- | --- | --- | --- |
| `smoke-logs-<runner>` | any step failed, or the smoke test needed its retry | `result.txt`, and per attempt the console output, Chromium's stdout and stderr, the rendered screenshot, the profile logs (`cef.log`) and Crashpad dumps, plus Cairn and Chromium crash reports from `~/Library/Logs/DiagnosticReports` | 14 days |
| `cairn-development-<runner>` | a green manual dispatch with `upload_development_artifacts=true` | The ad-hoc DMG | 7 days |
| `chromium-status` | every maintenance run | `status.json` and `status.md` (and `update.*` when a pin update was proposed) | 14 days |
| `release-logs-<arch>` | a Release build failed | The notarization verdicts and the packaging test logs | 14 days |
| `release-<arch>`, `chromium-gate` | a Release build | The per-architecture build inputs and the gate record | 14 days |

**Hidden-path trap:** `actions/upload-artifact` skips files under any directory whose name starts with a dot, so a log
left in `.build/` uploads nothing, and a step that tolerates "no files found" reports success. Diagnostics therefore go to
a plain directory first: `SMOKE_LOG_DIR=smoke-logs` for the smoke test, and `release-logs/` for the release step, which
copies the files out of `.build`. Keep that in mind whenever a new artifact is added.

## Reproducing CI locally

```sh
actionlint && scripts/test-release.sh                       # validation
python3 -m unittest discover -s engine/tests -v              # offline updater tests
make cef                                                     # prepare Chromium (ARCH=x86_64 for the Intel build)
python3 -m unittest discover -s engine/tests -p 'test_lifecycle.py' -v
scripts/swiftw test
SMOKE_LOG_DIR=smoke-logs scripts/run-smoke.sh               # needs a GUI session
scripts/bundle-app.sh && scripts/make-dmg.sh                # also runs scripts/verify-bundle.sh
scripts/verify-bundle.sh --arch arm64 dist/Cairn.app        # re-run the bundle gate on its own
```

## Troubleshooting

* **Smoke failure.** Download `smoke-logs-<runner>` and read `attempt-1/console.log` from the end. In
  `attempt-N/profiles/**/cef.log`, `cache_path is invalid` means a profile left CEF's resolved root; a first navigation
  that never commits followed by `Teardown watchdog expired` points at a Keychain authorization prompt (the smoke test
  uses a mock Keychain; Cairn itself must not).
* **Bundle gate failure.** The log lists every problem. Reproduce it with `scripts/verify-bundle.sh` on the same app
  (it also accepts the shipped ZIP or DMG), fix the packaging rather than the check.
* **Cache miss on every run.** The key includes the hash of `engine/cef.lock.json`; a miss right after a pin change is
  expected, and caches are evicted by GitHub after seven days without use.
* **No CI on the Chromium maintenance pull request.** Pushes made with the default token do not start `pull_request`
  workflows. The maintenance workflow dispatches CI for the branch itself; if those runs are missing, start them with
  `gh workflow run ci.yml --ref maintenance/cef-stable`.
* **`macos-15-intel`.** The last x86_64 macOS runner image GitHub offers. Its planned retirement and the fallback are in
  [RELEASING.md](RELEASING.md#building-and-testing-the-intel-app).

#!/usr/bin/env bash
# Run the bundled Chromium smoke test the way CI does and keep what is needed to debug it.
#   scripts/run-smoke.sh [engine/smoke.py arguments; default --development-ad-hoc]
# Console output, the smoke binary's own logs and any crash reports go to $SMOKE_LOG_DIR (default .build/smoke-logs).
# Exactly one failure is retried, once: the documented shutdown flake, where every assertion passed and
# CAIRN_CEF_SMOKE_OK was printed before Chromium's teardown watchdog ended the process. Any other failure,
# and a second failure of any kind, fails the run.
set -euo pipefail
cd "$(dirname "$0")/.."
logs="${SMOKE_LOG_DIR:-$PWD/.build/smoke-logs}"
rm -rf "$logs"
mkdir -p "$logs/crash-reports"
marker="$logs/.started"
: > "$marker"
(( $# )) || set -- --development-ad-hoc

known_flake() {
  grep -q 'CAIRN_CEF_SMOKE_OK' "$1" && grep -q 'Teardown watchdog expired' "$1" \
    && ! grep -q -e 'Check failed:' -e 'CEF SMOKE FAILED' "$1"
}

note() {
  echo "smoke: $*"
  echo "$*" >> "$logs/result.txt"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "- Chromium smoke: $*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Copy the diagnostics of one attempt out of the (330 MB) smoke work directory, which smoke.py names in its output.
collect() {
  local target="$1" file relative
  work="$(sed -n 's/^Smoke bundle and diagnostic logs: //p' "$target/console.log" | tail -n 1)"
  if [[ -n "$work" && -d "$work" ]]; then
    for file in stdout.log stderr.log rendering.png; do
      [[ -f "$work/$file" ]] && cp "$work/$file" "$target/"
    done
    # Chromium's per-profile logs (a rejected cache_path shows up here) and any Crashpad minidumps.
    while IFS= read -r -d '' file; do
      relative="${file#"$work/profiles/"}"
      mkdir -p "$target/profiles/$(dirname "$relative")"
      cp "$file" "$target/profiles/$relative"
    done < <(find "$work/profiles" -type f \( -name '*.log' -o -name '*.dmp' \) -size -20M -print0 2>/dev/null)
  fi
  if [[ -d "$HOME/Library/Logs/DiagnosticReports" ]]; then
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -newer "$marker" \
      \( -name 'Cairn*' -o -name 'Chromium*' \) -exec cp {} "$logs/crash-reports/" \;
  fi
  return 0
}

attempt=1
while :; do
  target="$logs/attempt-$attempt"
  mkdir -p "$target"
  work=""
  set +e
  python3 engine/smoke.py "$@" 2>&1 | tee "$target/console.log"
  status=${PIPESTATUS[0]}
  set -e
  collect "$target"
  if (( status == 0 )); then
    note "passed on attempt $attempt"
    [[ -n "$work" ]] && rm -rf "$work"
    exit 0
  fi
  if (( attempt == 1 )) && known_flake "$target/console.log"; then
    note "attempt 1 hit the known teardown-watchdog flake after CAIRN_CEF_SMOKE_OK (exit $status); retrying once"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "::warning title=Chromium smoke flake::The smoke test ended in the known teardown-watchdog flake and was retried once; logs are in the smoke-logs artifact."
    fi
    [[ -n "$work" ]] && rm -rf "$work"
    attempt=2
    continue
  fi
  note "attempt $attempt failed (exit $status); logs are in $logs"
  exit "$status"
done

#!/usr/bin/env bash
# Keeps one tracking issue in step with the Chromium maintenance check (engine/tool.py check --report/--markdown).
#   scripts/chromium-issue.sh [REPORT_JSON [REPORT_MARKDOWN]]
# A status of security_gap or failed, or no report at all (the check itself could not run), opens the issue or
# refreshes the body of the one that is open. Any other status closes it. Needs GH_TOKEN with issues: write and
# GH_REPO (or a checkout with a GitHub remote).
set -euo pipefail
report="${1:-}"
markdown="${2:-}"
label="chromium-security"
title="Chromium security: the pinned engine needs attention"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

status=failed
if [[ -f "$report" ]]; then
  status="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status") or "failed")' "$report" 2>/dev/null || echo failed)"
fi

body="$(
  if [[ -f "$markdown" ]]; then
    cat "$markdown"
  else
    echo "The Chromium maintenance check produced no report, so nobody is watching for Chromium security releases."
  fi
  printf '\n---\nLatest run: %s\n\nThis issue is maintained by scripts/chromium-issue.sh and closes itself once the pinned engine is no longer behind Chrome stable. See docs/UPDATING_CHROMIUM.md.\n' "$run_url"
)"

number="$(gh issue list --label "$label" --state open --limit 100 --json number,title | python3 -c '
import json, sys
title = sys.argv[1]
print(next((str(issue["number"]) for issue in json.load(sys.stdin) if issue["title"] == title), ""))' "$title")"

case "$status" in
  security_gap|failed)
    if [[ -n "$number" ]]; then
      gh issue edit "$number" --body "$body"
      echo "Refreshed issue #$number ($status)."
    else
      gh label create "$label" --color B60205 --force \
        --description "The pinned Chromium engine is behind Chrome stable or cannot be checked" >/dev/null || true
      gh issue create --title "$title" --label "$label" --body "$body"
    fi ;;
  *)
    if [[ -n "$number" ]]; then
      gh issue close "$number" --comment "Resolved: the maintenance check now reports \`$status\`. $run_url"
    else
      echo "Status is $status and no tracking issue is open."
    fi ;;
esac

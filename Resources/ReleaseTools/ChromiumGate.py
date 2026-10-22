#!/usr/bin/env python3
"""Fail-closed Chromium (CEF) release gate; Chromium is the only engine, so there is no fallback.

Runs `engine/tool.py check --fail-on-gap`. A pinned CEF that is current with Chrome stable passes. A
confirmed security gap blocks the release unless the maintainer supplied a written acknowledgement
(CHROMIUM_RISK_ACKNOWLEDGEMENT). Unavailable or contradictory metadata always blocks: an unknown risk
cannot be acknowledged. A small JSON record is written only on success; finalize-release.sh folds it
into RELEASE-NOTES.txt and RELEASE-INFO.json.

Usage: ChromiumGate.py --output FILE [-- extra engine/tool.py check arguments]
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 1
ACKNOWLEDGEMENT_LENGTH = (20, 500)
# Control, format (zero-width/bidi), surrogate, private-use, unassigned and line/paragraph separators.
FORBIDDEN_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp"}
CEF_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+)*\+g[0-9a-f]+\+chromium-[0-9]+(?:\.[0-9]+){3}")
CHROMIUM_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){3}")
ACTOR = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\[bot\])?")
TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
RUN_FIELDS = {"repository": re.compile(r"[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}"),
              "run_id": re.compile(r"[0-9]{1,20}"), "run_attempt": re.compile(r"[0-9]{1,5}"),
              "sha": re.compile(r"[0-9a-f]{40}")}
ASSESSMENT_VERSIONS = {"pinned_cef": CEF_VERSION, "pinned_chromium": CHROMIUM_VERSION,
                       "latest_stable_cef": CEF_VERSION, "latest_cef_chromium": CHROMIUM_VERSION,
                       "chrome_stable": CHROMIUM_VERSION}
ASSESSMENT_FLAGS = ("update_available", "security_gap", "upstream_security_gap")
RECORD_KEYS = {"schema", "status", "outcome", "engine", "check", "acknowledgement", "actor", "checked_at"}


def validate_acknowledgement(value):
    """The normalized one-line acknowledgement, or None when blank; ValueError when unacceptable."""
    text = (value or "").strip()
    if not text:
        return None
    if any(unicodedata.category(character) in FORBIDDEN_CATEGORIES for character in text):
        raise ValueError("it must be a single line of printable text without control or formatting characters")
    low, high = ACKNOWLEDGEMENT_LENGTH
    if not low <= len(text) <= high:
        raise ValueError(f"it must be {low}-{high} characters long (got {len(text)})")
    return text


def validate_assessment(data):
    if not isinstance(data, dict):
        raise ValueError("the report is not a JSON object")
    assessment = {}
    for name, pattern in ASSESSMENT_VERSIONS.items():
        value = data.get(name)
        if not isinstance(value, str) or not pattern.fullmatch(value):
            raise ValueError(f"the report has no valid {name}")
        assessment[name] = value
    for name in ASSESSMENT_FLAGS:
        if not isinstance(data.get(name), bool):
            raise ValueError(f"the report has no valid {name}")
        assessment[name] = data[name]
    return assessment


def summarize(assessment):
    relation = "older than" if assessment["security_gap"] else "not older than"
    return f"Pinned Chromium {assessment['pinned_chromium']} is {relation} Chrome stable {assessment['chrome_stable']}"


def classify(exit_code, stdout):
    """('current' | 'gap' | 'unavailable', validated assessment or None, reason)."""
    if exit_code is None:
        return "unavailable", None, "engine/tool.py check could not run or timed out"
    if exit_code not in (0, 2):
        return "unavailable", None, f"engine/tool.py check exited with status {exit_code}"
    try:
        assessment = validate_assessment(json.loads(stdout))
    except ValueError as error:
        return "unavailable", None, f"engine/tool.py check produced no usable report: {error}"
    if (exit_code == 2) != assessment["security_gap"]:
        return "unavailable", None, "engine/tool.py check exit status contradicts its report"
    return ("gap" if assessment["security_gap"] else "current"), assessment, ""


def validate_record(record):
    """Strictly re-validate a gate record (also used by finalize); returns it or raises ValueError."""
    try:
        return _validate_record(record)
    except (TypeError, KeyError, AttributeError) as error:
        raise ValueError(f"malformed Chromium gate record ({type(error).__name__})") from error


def _validate_record(record):
    if not isinstance(record, dict) or set(record) - {"run"} != RECORD_KEYS or record["schema"] != SCHEMA:
        raise ValueError("unrecognized Chromium gate record")
    status, outcome, acknowledgement = record["status"], record["outcome"], record["acknowledgement"]
    if (status, outcome) not in {("current", "passed"), ("gap", "acknowledged")}:
        raise ValueError("inconsistent Chromium gate status and outcome")
    check = record["check"]
    if not isinstance(check, dict) or set(check) != {"exit_code", "summary", "assessment"}:
        raise ValueError("invalid Chromium gate check")
    assessment = validate_assessment(check["assessment"])
    if (status == "gap") != assessment["security_gap"] or type(check["exit_code"]) is not int \
            or check["exit_code"] != (2 if status == "gap" else 0):
        raise ValueError("Chromium gate record contradicts its own check")
    if check["summary"] != summarize(assessment):
        raise ValueError("invalid Chromium gate summary")
    engine = record["engine"]
    if engine != {"cef": assessment["pinned_cef"], "chromium": assessment["pinned_chromium"]}:
        raise ValueError("Chromium gate engine versions do not match its check")
    if status == "gap":
        if not isinstance(acknowledgement, str) or validate_acknowledgement(acknowledgement) != acknowledgement:
            raise ValueError("a Chromium security gap requires a valid written acknowledgement")
    elif acknowledgement is not None:
        raise ValueError("a passing Chromium gate must not carry an acknowledgement")
    if not isinstance(record["actor"], str) or not (ACTOR.fullmatch(record["actor"]) or record["actor"] == "unknown"):
        raise ValueError("invalid Chromium gate actor")
    if not isinstance(record["checked_at"], str) or not TIMESTAMP.fullmatch(record["checked_at"]):
        raise ValueError("invalid Chromium gate timestamp")
    run = record.get("run", {})
    if not isinstance(run, dict) or any(
            key not in RUN_FIELDS or not isinstance(value, str) or not RUN_FIELDS[key].fullmatch(value)
            for key, value in run.items()):
        raise ValueError("invalid Chromium gate run context")
    return record


def describe(record):
    """Release-note lines for a validated record; the acknowledgement is JSON-quoted on one line."""
    engine, check = record["engine"], record["check"]["assessment"]
    if record["outcome"] == "passed":
        return [f"Chromium engine gate: passed. {record['check']['summary']} (checked {record['checked_at']})."]
    return [
        "CHROMIUM SECURITY GAP ACKNOWLEDGED BY A MAINTAINER.",
        f"This release ships Chromium {engine['chromium']} (CEF {engine['cef']}), which was older than "
        f"Chrome stable {check['chrome_stable']} when it was built. Version comparison is not a CVE/backport audit.",
        f"Acknowledged by {record['actor']} at {record['checked_at']}: {json.dumps(record['acknowledgement'])}",
    ]


def run_tool(arguments):
    command = [sys.executable, str(ROOT / "engine/tool.py"), "check", "--fail-on-gap", *arguments]
    try:
        completed = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, "", f"{type(error).__name__}"
    return completed.returncode, completed.stdout, completed.stderr


def printable(text, limit=300):
    return "".join(character if character.isprintable() else "?" for character in text)[:limit]


def blocked(title, message):
    print(f"::error title={title}::{message}")
    print(f"BLOCKED: {message}", file=sys.stderr)
    return 1


def run_gate(output, tool_arguments, environment, runner=run_tool, now=None):
    output.unlink(missing_ok=True)
    exit_code, stdout, stderr = runner(tool_arguments)
    for line in stderr.splitlines()[:20]:
        print(f"  engine/tool.py: {printable(line)}")
    status, assessment, reason = classify(exit_code, stdout)
    if status == "unavailable":
        return blocked("Chromium gate unavailable",
                       f"The Chromium release gate could not assess the pinned CEF ({printable(reason)}). "
                       "Failing closed; an unknown risk cannot be acknowledged. Fix the metadata or retry.")
    print(f"  Pinned CEF {assessment['pinned_cef']} (Chromium {assessment['pinned_chromium']}); "
          f"Chrome stable {assessment['chrome_stable']}.")
    supplied = environment.get("CHROMIUM_RISK_ACKNOWLEDGEMENT", "")
    acknowledgement = None
    if status == "current":
        if supplied.strip():
            print("NOTICE: the pinned Chromium is current; the supplied risk acknowledgement is not needed and is ignored.")
    else:
        advice = ("There is no WebKit fallback. Merge the engine-bump pull request to move to a newer stable CEF, "
                  "or re-run this workflow with the chromium_risk_acknowledgement input: your written "
                  "acknowledgement of the outstanding risk and the validation you performed "
                  "(see docs/UPDATING_CHROMIUM.md)")
        problem = (f"{summarize(assessment)}; this is a Chromium SECURITY GAP.")
        try:
            acknowledgement = validate_acknowledgement(supplied)
        except ValueError as error:
            return blocked("Chromium security gap", f"{problem} The supplied acknowledgement was rejected: "
                           f"{error}. {advice}.")
        if acknowledgement is None:
            return blocked("Chromium security gap", f"{problem} {advice}.")
    actor = environment.get("GATE_ACTOR") or environment.get("GITHUB_ACTOR") or "unknown"
    actor = actor if ACTOR.fullmatch(actor) else "unknown"
    run = {key: environment[name] for key, name in (("repository", "GITHUB_REPOSITORY"), ("run_id", "GITHUB_RUN_ID"),
                                                    ("run_attempt", "GITHUB_RUN_ATTEMPT"), ("sha", "GITHUB_SHA"))
           if RUN_FIELDS[key].fullmatch(environment.get(name, ""))}
    record = {
        "schema": SCHEMA, "status": status, "outcome": "passed" if status == "current" else "acknowledged",
        "engine": {"cef": assessment["pinned_cef"], "chromium": assessment["pinned_chromium"]},
        "check": {"exit_code": exit_code, "summary": summarize(assessment), "assessment": assessment},
        "acknowledgement": acknowledgement, "actor": actor,
        "checked_at": (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if run:
        record["run"] = run
    validate_record(record)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, indent=2) + "\n")
    if status == "gap":
        print("::warning title=Chromium security gap acknowledged::This release ships a Chromium older than "
              "Chrome stable. A maintainer acknowledged the risk; it is recorded in the release notes.")
        print("============ CHROMIUM SECURITY GAP ACKNOWLEDGED ============")
        print(f"  {summarize(assessment)}")
        print(f"  Acknowledged by {actor}: {json.dumps(acknowledgement)}")
        print("  Version comparison is not a CVE/backport audit. The acknowledgement is published in the release notes.")
        print("============================================================")
    else:
        print("Chromium gate passed: the pinned CEF is current with Chrome stable.")
    return 0


def main(argv=None, environment=None, runner=run_tool, now=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    tool_arguments = []
    if "--" in argv:
        split = argv.index("--")
        argv, tool_arguments = argv[:split], argv[split + 1:]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", required=True, type=Path, help="gate record to write on success")
    args = parser.parse_args(argv)
    return run_gate(args.output, tool_arguments, os.environ if environment is None else environment, runner, now)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Offline tests for the fail-closed Chromium release gate; no network and no real metadata."""
import contextlib
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("chromium_gate", HERE / "ChromiumGate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

CEF = "154.0.34+g14c5a08+chromium-154.0.8037.98"
CHROMIUM = "154.0.8037.98"
NOW = datetime(2026, 7, 1, 12, 30, 5, tzinfo=timezone.utc)
ACKNOWLEDGEMENT = "Reviewed Chrome 156 security fixes; none reachable in Cairn. Re-pin next week."


def report(gap=False, **changes):
    data = {"pinned_cef": CEF, "pinned_chromium": CHROMIUM, "latest_stable_cef": CEF,
            "latest_cef_chromium": CHROMIUM, "chrome_stable": "156.0.8078.48" if gap else CHROMIUM,
            "update_available": False, "security_gap": gap, "upstream_security_gap": gap}
    data.update(changes)
    return data


def fake_tool(code, data=None, stderr="", stdout=None):
    def runner(arguments):
        runner.calls.append(arguments)
        return code, json.dumps(data) if stdout is None else stdout, stderr
    runner.calls = []
    return runner


class ChromiumGateTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="chromium-gate-")
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        self.output = self.work / "gate/chromium-gate.json"

    def run_gate(self, runner, acknowledgement="", **environment):
        values = {"CHROMIUM_RISK_ACKNOWLEDGEMENT": acknowledgement, "GITHUB_ACTOR": "maintainer",
                  "GITHUB_REPOSITORY": "example/cairn", "GITHUB_RUN_ID": "42", **environment}
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = gate.main(["--output", str(self.output)], values, runner, NOW)
        return status, out.getvalue(), err.getvalue()

    def record(self):
        return json.loads(self.output.read_text())

    def acknowledged_record(self):
        self.assertEqual(self.run_gate(fake_tool(2, report(True)), ACKNOWLEDGEMENT)[0], 0)
        return self.record()

    def test_current_pin_passes_and_writes_a_validated_record(self):
        runner = fake_tool(0, report())
        status, out, _ = self.run_gate(runner)
        self.assertEqual(status, 0)
        self.assertEqual(runner.calls, [[]])
        record = gate.validate_record(self.record())
        self.assertEqual((record["status"], record["outcome"], record["acknowledgement"]), ("current", "passed", None))
        self.assertEqual(record["engine"], {"cef": CEF, "chromium": CHROMIUM})
        self.assertEqual(record["actor"], "maintainer")
        self.assertEqual(record["checked_at"], "2026-07-01T12:30:05Z")
        self.assertEqual(record["run"], {"repository": "example/cairn", "run_id": "42"})
        self.assertIn("passed", out)

    def test_current_pin_ignores_an_unneeded_acknowledgement(self):
        status, out, _ = self.run_gate(fake_tool(0, report()), ACKNOWLEDGEMENT)
        self.assertEqual(status, 0)
        self.assertIsNone(self.record()["acknowledgement"])
        self.assertIn("not needed", out)

    def test_extra_arguments_reach_the_tool(self):
        runner = fake_tool(0, report())
        status = self.run_gate(runner)[0]
        self.assertEqual(status, 0)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            gate.main(["--output", str(self.output), "--", "--index", "offline.json"], {}, runner, NOW)
        self.assertEqual(runner.calls[-1], ["--index", "offline.json"])

    def test_gap_without_acknowledgement_blocks_with_actionable_advice(self):
        for blank in ("", "   ", "\n\t "):
            status, out, err = self.run_gate(fake_tool(2, report(True)), blank)
            self.assertEqual(status, 1)
            self.assertFalse(self.output.exists())
            for needle in ("SECURITY GAP", "no WebKit fallback", "engine-bump", "chromium_risk_acknowledgement",
                           CHROMIUM, "156.0.8078.48"):
                self.assertIn(needle, out)
            self.assertIn("BLOCKED", err)

    def test_invalid_acknowledgements_block(self):
        invalid = {
            "too short": "x" * 19, "too long": "x" * 501, "newline": ACKNOWLEDGEMENT + "\n" + ACKNOWLEDGEMENT,
            "carriage return": ACKNOWLEDGEMENT + "\r" + ACKNOWLEDGEMENT, "tab": ACKNOWLEDGEMENT + "\t" + "more text",
            "nul": ACKNOWLEDGEMENT + "\x00" + "more text", "escape": ACKNOWLEDGEMENT + "\x1b[2J" + "more text",
            "zero width": ACKNOWLEDGEMENT[:10] + "\u200b" + ACKNOWLEDGEMENT[10:],
            "bidi override": ACKNOWLEDGEMENT + "\u202e" + "more text",
            "line separator": ACKNOWLEDGEMENT + "\u2028" + "more text",
            "paragraph separator": ACKNOWLEDGEMENT + "\u2029" + "more text",
            "private use": ACKNOWLEDGEMENT + "\ue000" + "more text",
            "unassigned": ACKNOWLEDGEMENT + "\u0378" + "more text",
            "surrogate": ACKNOWLEDGEMENT + "\ud800" + "more text",
        }
        for label, value in invalid.items():
            with self.subTest(label):
                status, out, _ = self.run_gate(fake_tool(2, report(True)), value)
                self.assertEqual(status, 1)
                self.assertFalse(self.output.exists())
                self.assertIn("rejected", out)
                self.assertNotIn(value, out)

    def test_valid_acknowledgement_passes_with_a_prominent_recorded_warning(self):
        status, out, _ = self.run_gate(fake_tool(2, report(True)), f"  {ACKNOWLEDGEMENT}\n")
        self.assertEqual(status, 0)
        record = gate.validate_record(self.record())
        self.assertEqual((record["status"], record["outcome"]), ("gap", "acknowledged"))
        self.assertEqual(record["acknowledgement"], ACKNOWLEDGEMENT)
        self.assertEqual(record["check"]["exit_code"], 2)
        self.assertEqual(record["check"]["assessment"]["chrome_stable"], "156.0.8078.48")
        self.assertIn("::warning title=Chromium security gap acknowledged::", out)
        self.assertIn("CHROMIUM SECURITY GAP ACKNOWLEDGED", out)
        self.assertIn(json.dumps(ACKNOWLEDGEMENT), out)

    def test_acknowledgement_length_limits_are_inclusive(self):
        for length in (20, 500):
            with self.subTest(length=length):
                self.assertEqual(self.run_gate(fake_tool(2, report(True)), "a" * length)[0], 0)
                self.assertEqual(self.record()["acknowledgement"], "a" * length)

    def test_acknowledgement_cannot_inject_workflow_commands(self):
        hostile = "::add-mask::the-entire-release-environment ::stop-commands::token"
        status, out, err = self.run_gate(fake_tool(2, report(True)), hostile)
        self.assertEqual(status, 0)
        for line in (out + err).splitlines():
            self.assertFalse(line.startswith(hostile[:2]) and "add-mask" in line, line)
            self.assertTrue(not line.startswith("::") or line.startswith(
                ("::warning title=Chromium", "::error title=Chromium")), line)

    def test_unavailable_or_contradictory_metadata_always_fails_closed(self):
        cases = {
            "tool failure": fake_tool(1, stdout="", stderr="engine: network down"),
            "tool timeout": lambda arguments: (None, "", "TimeoutExpired"),
            "unexpected status": fake_tool(3, report()),
            "not json": fake_tool(0, stdout="<html>"),
            "empty report": fake_tool(0, stdout=""),
            "not an object": fake_tool(0, stdout="[]"),
            "missing field": fake_tool(0, {k: v for k, v in report().items() if k != "chrome_stable"}),
            "bad version": fake_tool(0, report(chrome_stable="stable")),
            "bad flag": fake_tool(0, report(security_gap="false")),
            "clean exit but gap reported": fake_tool(0, report(True)),
            "gap exit but none reported": fake_tool(2, report()),
        }
        for label, runner in cases.items():
            for acknowledgement in ("", ACKNOWLEDGEMENT):
                with self.subTest(label, acknowledged=bool(acknowledgement)):
                    status, out, _ = self.run_gate(runner, acknowledgement)
                    self.assertEqual(status, 1)
                    self.assertFalse(self.output.exists())
                    self.assertIn("could not assess", out)
                    self.assertIn("cannot be acknowledged", out)

    def test_a_failed_run_removes_a_stale_record(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_text("stale")
        self.assertEqual(self.run_gate(fake_tool(2, report(True)))[0], 1)
        self.assertFalse(self.output.exists())

    def test_tool_diagnostics_are_prefixed_and_sanitized(self):
        stderr = "::set-output name=x::y\nengine: \x1b[31mbad\x1b[0m"
        _, out, _ = self.run_gate(fake_tool(1, stdout="", stderr=stderr))
        self.assertIn("  engine/tool.py: ::set-output name=x::y", out)
        self.assertNotIn("\x1b", out)

    def test_untrusted_actor_and_run_context_are_dropped(self):
        self.run_gate(fake_tool(0, report()), GITHUB_ACTOR="bad actor\n::error::x", GITHUB_RUN_ID="4 2",
                      GITHUB_REPOSITORY="not-a-repo", GITHUB_SHA="G" * 40)
        record = self.record()
        self.assertEqual(record["actor"], "unknown")
        self.assertNotIn("run", record)
        self.run_gate(fake_tool(0, report()), GITHUB_ACTOR="dependabot[bot]", GITHUB_SHA="a" * 40)
        self.assertEqual(self.record()["actor"], "dependabot[bot]")
        self.assertEqual(self.record()["run"]["sha"], "a" * 40)

    def test_record_validation_rejects_tampering(self):
        good = self.acknowledged_record()
        gate.validate_record(good)

        def mutate(change):
            record = json.loads(json.dumps(good))
            change(record)
            return record

        tampered = {
            "dropped field": lambda r: r.pop("actor"),
            "extra field": lambda r: r.update(extra=True),
            "other schema": lambda r: r.update(schema=2),
            "status and outcome disagree": lambda r: r.update(outcome="passed"),
            "unknown status": lambda r: r.update(status="unknown"),
            "unhashable status": lambda r: r.update(status=["gap"]),
            "gap without acknowledgement": lambda r: r.update(acknowledgement=None),
            "gap with weak acknowledgement": lambda r: r.update(acknowledgement="ok"),
            "unnormalized acknowledgement": lambda r: r.update(acknowledgement=" " + ACKNOWLEDGEMENT),
            "multiline acknowledgement": lambda r: r.update(acknowledgement=ACKNOWLEDGEMENT + "\nmore text"),
            "passing record with acknowledgement": lambda r: r.update(
                status="current", outcome="passed", check=dict(r["check"], exit_code=0)),
            "forged summary": lambda r: r["check"].update(summary="Everything is fine"),
            "exit code mismatch": lambda r: r["check"].update(exit_code=0),
            "boolean exit code": lambda r: r["check"].update(exit_code=True),
            "engine mismatch": lambda r: r["engine"].update(chromium="155.0.1.2"),
            "assessment mismatch": lambda r: r["check"]["assessment"].update(security_gap=False),
            "actor": lambda r: r.update(actor="bad actor"),
            "timestamp": lambda r: r.update(checked_at="yesterday"),
            "run context": lambda r: r.update(run={"sha": "xyz"}),
            "unknown run field": lambda r: r.update(run={"token": "1"}),
            "not an object": lambda r: r.update(check=[]),
        }
        for label, change in tampered.items():
            with self.subTest(label), self.assertRaises(ValueError):
                gate.validate_record(mutate(change))
        for value in (None, [], "record", 1):
            with self.assertRaises(ValueError):
                gate.validate_record(value)

    def test_release_notes_quote_the_acknowledgement_on_one_line(self):
        lines = gate.describe(self.acknowledged_record())
        self.assertIn("SECURITY GAP ACKNOWLEDGED", lines[0])
        self.assertTrue(all("\n" not in line for line in lines))
        self.assertIn(json.dumps(ACKNOWLEDGEMENT), lines[-1])
        self.run_gate(fake_tool(0, report()))
        passed = gate.describe(self.record())
        self.assertEqual(len(passed), 1)
        self.assertIn("passed", passed[0])

    def offline_tool_arguments(self, chrome_version):
        lock = json.loads((ROOT / "engine/cef.lock.json").read_text())
        chrome = self.work / "chrome.json"
        chrome.write_text(json.dumps([{"version": chrome_version or lock["chromium_version"]}]))
        fixtures = ROOT / "engine/tests/fixtures"
        return ["--index", str(fixtures / "index.json"), "--chrome", str(chrome)], lock["chromium_version"]

    def offline_cli(self, chrome_version, acknowledgement=""):
        arguments, pinned = self.offline_tool_arguments(chrome_version)
        environment = dict(os.environ, CHROMIUM_RISK_ACKNOWLEDGEMENT=acknowledgement, GITHUB_ACTOR="maintainer")
        result = subprocess.run([sys.executable, str(HERE / "ChromiumGate.py"), "--output", str(self.output),
                                 "--", *arguments], cwd=ROOT, env=environment, capture_output=True, text=True)
        return result, pinned

    def test_real_tool_against_offline_fixtures(self):
        lock = json.loads((ROOT / "engine/cef.lock.json").read_text())
        current, pinned = self.offline_cli(None)
        self.assertEqual(current.returncode, 0, current.stdout + current.stderr)
        self.assertEqual(self.record()["engine"]["chromium"], pinned)
        self.assertEqual(self.record()["engine"]["cef"], lock["cef_version"])
        newer = ".".join(pinned.split(".")[:3] + [str(int(pinned.split(".")[3]) + 1)])
        blocked, _ = self.offline_cli(newer)
        self.assertEqual(blocked.returncode, 1, blocked.stdout + blocked.stderr)
        self.assertFalse(self.output.exists())
        self.assertIn("SECURITY GAP", blocked.stdout)
        acknowledged, _ = self.offline_cli(newer, ACKNOWLEDGEMENT)
        self.assertEqual(acknowledged.returncode, 0, acknowledged.stdout + acknowledged.stderr)
        self.assertEqual(self.record()["outcome"], "acknowledged")

    def test_real_tool_with_unreadable_metadata_fails_closed(self):
        environment = dict(os.environ, CHROMIUM_RISK_ACKNOWLEDGEMENT=ACKNOWLEDGEMENT)
        result = subprocess.run([sys.executable, str(HERE / "ChromiumGate.py"), "--output", str(self.output), "--",
                                 "--index", str(self.work / "missing.json"), "--chrome", str(self.work / "missing.json")],
                                cwd=ROOT, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()

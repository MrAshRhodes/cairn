#!/usr/bin/env python3
"""scripts/run-smoke.sh against a fake engine/smoke.py: what is retried, what is not, and what is kept for debugging.

The real smoke test needs a GUI session and a prepared Chromium; the wrapper only reads its exit status and output."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

FAKE_SMOKE = '''
import os
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
counter = root / "attempts"
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
outcomes = os.environ["FAKE_SMOKE_OUTCOMES"].split(",")
outcome = outcomes[min(attempt, len(outcomes)) - 1]
work = root / f"work-{attempt}"
(work / "profiles/Default").mkdir(parents=True)
(work / "stdout.log").write_text(f"stdout of attempt {attempt}\\n")
(work / "stderr.log").write_text(f"stderr of attempt {attempt}\\n")
(work / "profiles/Default/cef.log").write_text("cef log\\n")
(work / "Cairn.app").write_text("pretend this is a 330 MB bundle\\n")
reports = pathlib.Path(os.environ["HOME"]) / "Library/Logs/DiagnosticReports"
if outcome.endswith("+crash"):
    outcome = outcome.removesuffix("+crash")
    (reports / "Cairn Helper (GPU)-2026-10-22-120000.ips").write_text("crash")
    (reports / "Unrelated-2026-10-22-120000.ips").write_text("not ours")
print(f"Smoke bundle and diagnostic logs: {work}", flush=True)
print("PASS: navigation")
if outcome == "pass":
    print("CAIRN_CEF_SMOKE_OK")
elif outcome == "flake":
    print("CAIRN_CEF_SMOKE_OK")
    print("Teardown watchdog expired; recording dump and terminating.", file=sys.stderr)
    sys.exit(2)
elif outcome == "assertion":
    print("CEF SMOKE FAILED: Timed out waiting for navigation")
    print("Teardown watchdog expired; recording dump and terminating.")
    sys.exit(2)
elif outcome == "chromium-check":
    print("CAIRN_CEF_SMOKE_OK")
    print("Check failed: !sandbox_failed", file=sys.stderr)
    print("Teardown watchdog expired; recording dump and terminating.", file=sys.stderr)
    sys.exit(2)
elif outcome == "other-exit":
    print("CAIRN_CEF_SMOKE_OK")
    sys.exit(1)
sys.exit(0)
'''


class RunSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".build").mkdir(exist_ok=True)
        cls.directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="run-smoke-")

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.tree = Path(self.directory.name) / self.id().rsplit(".", 1)[-1]
        (self.tree / "scripts").mkdir(parents=True)
        (self.tree / "engine").mkdir()
        shutil.copy2(ROOT / "scripts/run-smoke.sh", self.tree / "scripts/run-smoke.sh")
        (self.tree / "engine/smoke.py").write_text(FAKE_SMOKE)
        self.home = self.tree / "home"
        self.reports = self.home / "Library/Logs/DiagnosticReports"
        self.reports.mkdir(parents=True)
        (self.reports / "Cairn-older-run.ips").write_text("from an earlier run")
        os.utime(self.reports / "Cairn-older-run.ips", (1_000_000_000, 1_000_000_000))
        self.logs = self.tree / "logs"

    def run_script(self, outcomes, *arguments, **environment):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("GITHUB_", "SMOKE_"))}
        env.update(HOME=str(self.home), FAKE_SMOKE_OUTCOMES=outcomes, SMOKE_LOG_DIR=str(self.logs), **environment)
        return subprocess.run(["bash", str(self.tree / "scripts/run-smoke.sh"), *arguments],
                              capture_output=True, text=True, env=env, timeout=60)

    @property
    def attempts(self):
        return int((self.tree / "attempts").read_text())

    def test_a_passing_run_is_not_repeated_and_removes_the_large_bundle(self):
        result = self.run_script("pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.attempts, 1)
        self.assertIn("CAIRN_CEF_SMOKE_OK", (self.logs / "attempt-1/console.log").read_text())
        self.assertEqual((self.logs / "attempt-1/stdout.log").read_text(), "stdout of attempt 1\n")
        self.assertFalse((self.tree / "work-1").exists())
        self.assertIn("passed on attempt 1", (self.logs / "result.txt").read_text())

    def test_the_known_teardown_flake_is_retried_once_and_both_attempts_are_kept(self):
        summary = self.tree / "summary.md"
        result = self.run_script("flake,pass", GITHUB_ACTIONS="true", GITHUB_STEP_SUMMARY=str(summary))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.attempts, 2)
        self.assertIn("::warning title=Chromium smoke flake::", result.stdout)
        for attempt in (1, 2):
            self.assertTrue((self.logs / f"attempt-{attempt}/console.log").is_file())
            self.assertEqual((self.logs / f"attempt-{attempt}/stderr.log").read_text(), f"stderr of attempt {attempt}\n")
            self.assertEqual((self.logs / f"attempt-{attempt}/profiles/Default/cef.log").read_text(), "cef log\n")
            self.assertFalse((self.tree / f"work-{attempt}").exists())
        self.assertIn("known teardown-watchdog flake", (self.logs / "result.txt").read_text())
        self.assertIn("passed on attempt 2", summary.read_text())

    def test_a_second_failure_fails_the_run_and_keeps_the_last_bundle(self):
        result = self.run_script("flake,flake")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.attempts, 2)
        self.assertTrue((self.tree / "work-2").exists())
        self.assertIn("attempt 2 failed (exit 2)", (self.logs / "result.txt").read_text())

    def test_only_the_flake_signature_is_retried(self):
        for outcome in ("assertion", "chromium-check", "other-exit"):
            with self.subTest(outcome=outcome):
                (self.tree / "attempts").unlink(missing_ok=True)
                result = self.run_script(f"{outcome},pass")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.attempts, 1)
                self.assertIn("attempt 1 failed", (self.logs / "result.txt").read_text())

    def test_crash_reports_from_this_run_are_collected_and_old_or_foreign_ones_are_not(self):
        result = self.run_script("flake+crash,pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        collected = sorted(path.name for path in (self.logs / "crash-reports").iterdir())
        self.assertEqual(collected, ["Cairn Helper (GPU)-2026-10-22-120000.ips"])

    def test_arguments_default_to_development_ad_hoc_and_are_otherwise_passed_through(self):
        recorder = self.tree / "engine/smoke.py"
        recorder.write_text("import pathlib, sys\n"
                            "pathlib.Path(__file__).with_name('args').write_text(' '.join(sys.argv[1:]))\n")
        self.assertEqual(self.run_script("pass").returncode, 0)
        self.assertEqual((self.tree / "engine/args").read_text(), "--development-ad-hoc")
        self.assertEqual(self.run_script("pass", "--identity", "Developer ID Application: Example").returncode, 0)
        self.assertEqual((self.tree / "engine/args").read_text(), "--identity Developer ID Application: Example")


if __name__ == "__main__":
    unittest.main()

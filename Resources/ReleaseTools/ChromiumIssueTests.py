#!/usr/bin/env python3
"""scripts/chromium-issue.sh against a fake `gh`: when the tracking issue is opened, refreshed, closed or left alone."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCRIPT = ROOT / "scripts/chromium-issue.sh"
TITLE = "Chromium security: the pinned engine needs attention"

FAKE_GH = '''#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["issue", "list"]:
    print(os.environ.get("FAKE_GH_LIST", "[]"))
elif sys.argv[1:3] == ["issue", "create"]:
    print("https://github.com/example/cairn/issues/99")
'''


class ChromiumIssueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".build").mkdir(exist_ok=True)
        cls.directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="chromium-issue-")
        cls.work = Path(cls.directory.name)
        bin_dir = cls.work / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        cls.bin = bin_dir

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.log = self.work / f"{self.id().rsplit('.', 1)[-1]}.log"
        self.log.unlink(missing_ok=True)

    def run_script(self, status, issues=(), markdown="## Chromium security monitor\n- Pinned: old\n"):
        arguments = []
        if status is not None:
            report = self.work / "status.json"
            report.write_text(json.dumps({"status": status}))
            arguments.append(str(report))
            if markdown is not None:
                summary = self.work / "status.md"
                summary.write_text(markdown)
                arguments.append(str(summary))
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_GH_LOG=str(self.log),
                   FAKE_GH_LIST=json.dumps(list(issues)), GITHUB_REPOSITORY="example/cairn", GITHUB_RUN_ID="4242")
        result = subprocess.run(["bash", str(SCRIPT), *arguments], capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [call for call in calls if call[:2] != ["issue", "list"]]

    def test_a_security_gap_opens_the_issue_with_the_report_and_run_link(self):
        calls = self.run_script("security_gap")
        self.assertEqual([call[:2] for call in calls], [["label", "create"], ["issue", "create"]])
        create = calls[1]
        self.assertEqual(create[create.index("--title") + 1], TITLE)
        self.assertEqual(create[create.index("--label") + 1], "chromium-security")
        body = create[create.index("--body") + 1]
        self.assertIn("Chromium security monitor", body)
        self.assertIn("https://github.com/example/cairn/actions/runs/4242", body)

    def test_an_open_issue_is_refreshed_not_duplicated_and_unrelated_issues_are_ignored(self):
        issues = [{"number": 3, "title": "Unrelated"}, {"number": 7, "title": TITLE}]
        calls = self.run_script("security_gap", issues)
        self.assertEqual([call[:3] for call in calls], [["issue", "edit", "7"]])
        self.assertIn("Chromium security monitor", calls[0][calls[0].index("--body") + 1])

    def test_a_failed_check_is_an_issue_too(self):
        calls = self.run_script("failed", markdown="## Chromium maintenance check failed\nindex unreachable\n")
        self.assertEqual([call[:2] for call in calls], [["label", "create"], ["issue", "create"]])
        self.assertIn("index unreachable", calls[1][calls[1].index("--body") + 1])

    def test_a_missing_report_means_nobody_is_watching_and_opens_the_issue(self):
        calls = self.run_script(None)
        self.assertEqual([call[:2] for call in calls], [["label", "create"], ["issue", "create"]])
        self.assertIn("produced no report", calls[1][calls[1].index("--body") + 1])

    def test_a_current_or_updatable_pin_closes_the_open_issue(self):
        for status in ("ok", "update_available"):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                calls = self.run_script(status, [{"number": 7, "title": TITLE}])
                self.assertEqual([call[:3] for call in calls], [["issue", "close", "7"]])
                self.assertIn(status, calls[0][calls[0].index("--comment") + 1])

    def test_nothing_changes_when_the_pin_is_fine_and_no_issue_is_open(self):
        self.assertEqual(self.run_script("ok", [{"number": 3, "title": "Unrelated"}]), [])


if __name__ == "__main__":
    unittest.main()

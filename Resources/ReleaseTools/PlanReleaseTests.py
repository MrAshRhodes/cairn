import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("planner", Path(__file__).with_name("PlanRelease.py"))
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class ReleasePlanningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.commit("Sources/App.swift", "original", "Initial product")
        self.git("tag", "v0.1.0")

    def git(self, *args):
        return planner.git(self.repo, *args)

    def commit(self, path, content, message):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        self.git("add", "--", path)
        self.git("commit", "-qm", message)

    def test_docs_site_tests_and_workflows_do_not_release(self):
        for path in ("README.md", "site/index.html", "Tests/Smoke.swift", ".github/workflows/ci.yml", "engine/smoke.py"):
            self.commit(path, "documentation", "feat: a docs-only change")
        self.assertFalse(planner.plan(self.repo, "v0.1.0")["release"])

    def test_product_change_defaults_to_patch(self):
        self.commit("Sources/App.swift", "fixed", "Correct browser defaults")
        result = planner.plan(self.repo, "v0.1.0")
        self.assertEqual(result["tag"], "v0.1.1")
        self.assertEqual(result["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(result["product_paths"], ["Sources/App.swift"])

    def test_feature_is_minor_and_unrelated_breaking_docs_are_ignored(self):
        self.commit("README.md", "docs", "docs!: rewrite guide")
        self.commit("Sources/App.swift", "feature", "feat(tabs): add a feature")
        self.commit("Sources/App.swift", "fixed feature", "fix: adjust the feature")
        self.assertEqual(planner.plan(self.repo, "v0.1.0")["tag"], "v0.2.0")

    def test_breaking_header_and_footer_are_major(self):
        for message in ("feat(api)!: incompatible", "fix: change\n\nBREAKING CHANGE: incompatible",
                        "fix: change\n\nBREAKING-CHANGE: incompatible"):
            self.assertEqual(planner.next_version("v1.2.3", [message]), "v2.0.0")

    def test_deleted_product_file_counts(self):
        self.git("rm", "-q", "Sources/App.swift")
        self.git("commit", "-qm", "Remove old product")
        self.assertTrue(planner.plan(self.repo, "v0.1.0")["release"])

    def test_reverted_product_change_does_not_release(self):
        self.commit("Sources/App.swift", "temporary", "feat: temporary")
        self.commit("Sources/App.swift", "original", "Revert feature")
        self.assertFalse(planner.plan(self.repo, "v0.1.0")["release"])

    def test_existing_unpublished_tag_stops_automatic_release(self):
        self.commit("Sources/App.swift", "fixed", "fix: changed")
        self.git("tag", "v0.1.1")
        with self.assertRaisesRegex(ValueError, "already exists"):
            planner.plan(self.repo, "v0.1.0")
        self.assertEqual(planner.plan(self.repo, "v0.1.0", "v0.1.1")["tag"], "v0.1.1")

    def test_explicit_tag_cannot_relabel_other_commit_or_go_backwards(self):
        self.git("tag", "v0.1.1")
        self.commit("Sources/App.swift", "fixed", "fix: changed")
        with self.assertRaisesRegex(ValueError, "checked-out"):
            planner.plan(self.repo, "v0.1.0", "v0.1.1")
        with self.assertRaisesRegex(ValueError, "newer"):
            planner.plan(self.repo, "v0.1.0", "v0.1.0")

    def test_invalid_or_missing_baseline_stops(self):
        for tag in ("v1.0.0-beta", "v01.0.0", "1.0.0", "--all"):
            with self.assertRaises(ValueError):
                planner.plan(self.repo, tag)
        with self.assertRaises(subprocess.CalledProcessError):
            planner.plan(self.repo, "v9.0.0")

    def test_dependency_and_packaging_changes_are_product_changes(self):
        for path in ("Package.resolved", "engine/cef.lock.json", "engine/bundle.py",
                     "Resources/Info.plist", "scripts/bundle-app.sh",
                     "Resources/ReleaseTools/bundle.py", "Resources/ReleaseTools/appcast.py",
                     "Resources/ReleaseTools/validate-key.py"):
            self.assertTrue(planner.is_product(path), path)
        self.assertFalse(planner.is_product("Resources/ReleaseTools/PlanReleaseTests.py"))


if __name__ == "__main__":
    unittest.main()

import copy
import hashlib
import importlib.util
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tarfile
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("engine_tool", ROOT / "engine/tool.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
FIXTURES = pathlib.Path(__file__).parent / "fixtures"


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.index = tool.read_json(FIXTURES / "index.json")
        self.chrome = tool.read_json(FIXTURES / "releases.json")
        self.pin = tool.select_pin(self.index)
        self.work = ROOT / "engine/.cache" / ("test-" + str(uuid.uuid4()))
        self.work.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.work)

    def test_stable_does_not_select_newer_beta(self):
        self.assertEqual(self.pin["chromium_version"], "154.0.8037.98")
        self.assertEqual(set(self.pin["artifacts"]), {"arm64", "x86_64"})

    def test_security_gap_even_when_no_cef_update(self):
        result = tool.assess(self.pin, self.pin, self.chrome)
        self.assertFalse(result["update_available"])
        self.assertTrue(result["security_gap"])
        self.assertTrue(result["upstream_security_gap"])

    def test_numeric_versions_and_patch_gaps(self):
        self.assertGreater(tool.version("154.0.8037.100"), tool.version("154.0.8037.98"))
        chrome = [{"version": "154.0.8037.99"}]
        self.assertTrue(tool.assess(self.pin, self.pin, chrome)["security_gap"])
        self.assertFalse(tool.assess(self.pin, self.pin, [{"version": "154.0.8037.98"}])["security_gap"])

    def test_no_common_architecture_fails_closed(self):
        self.index["macosx64"]["versions"] = []
        with self.assertRaises(ValueError):
            tool.select_pin(self.index)

    def test_missing_minimal_fails_closed(self):
        self.index["macosarm64"]["versions"][1]["files"][0]["type"] = "standard"
        with self.assertRaises(ValueError):
            tool.select_pin(self.index)

    def test_unsorted_index_selects_newest_common(self):
        for platform_name in tool.PLATFORMS.values():
            row = copy.deepcopy(self.index[platform_name]["versions"][-1])
            row["cef_version"] = row["cef_version"].replace("154.0.34+", "154.0.35+")
            row["files"][0]["name"] = row["files"][0]["name"].replace("154.0.34+", "154.0.35+")
            self.index[platform_name]["versions"].insert(0, row)
        latest = tool.select_pin(self.index)
        self.assertIn("154.0.35+", latest["cef_version"])
        self.assertTrue(tool.assess(self.pin, latest, self.chrome)["update_available"])
        self.assertFalse(tool.assess(latest, self.pin, self.chrome)["update_available"])

    def test_lock_rejects_untrusted_archive_names(self):
        self.pin["artifacts"]["arm64"]["name"] = "../../escape.tar.bz2"
        with self.assertRaises(ValueError):
            tool.validate_lock(self.pin)

    def test_lock_rejects_malformed_checksums(self):
        self.pin["artifacts"]["arm64"]["sha1"] = "not-a-hash"
        with self.assertRaises(ValueError):
            tool.validate_lock(self.pin)

    def test_architecture_chromium_mismatch_rejected(self):
        self.index["macosx64"]["versions"][0]["chromium_version"] = "155.0.8000.100"
        with self.assertRaises(ValueError):
            tool.select_pin(self.index)

    def test_checksum_and_size_enforced(self):
        archive = self.work / "archive"
        archive.write_bytes(b"verified")
        artifact = {"size": 8, "sha1": hashlib.sha1(b"verified").hexdigest(),
                    "sha256": hashlib.sha256(b"verified").hexdigest()}
        tool.verify_archive(archive, artifact)
        artifact["size"] = 7
        with self.assertRaises(ValueError):
            tool.verify_archive(archive, artifact)
        artifact["size"] = 8
        archive.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            tool.verify_archive(archive, artifact)

    def test_archive_traversal_and_link_escape_rejected(self):
        for name, target in [("../escape", None), ("/escape", None),
                             ("top/link", "../../escape"), ("top/link", "/escape")]:
            archive = self.work / "unsafe.tar.bz2"
            with tarfile.open(archive, "w:bz2") as tar:
                member = tarfile.TarInfo(name)
                if target:
                    member.type = tarfile.SYMTYPE
                    member.linkname = target
                tar.addfile(member, io.BytesIO())
            with self.assertRaises(ValueError):
                tool.extract_archive(archive, self.work / "out", "top")

    def test_archive_valid_framework_symlink(self):
        archive = self.work / "safe.tar.bz2"
        with tarfile.open(archive, "w:bz2") as tar:
            file = tarfile.TarInfo("top/Versions/A/resource")
            file.size = 2
            tar.addfile(file, io.BytesIO(b"ok"))
            link = tarfile.TarInfo("top/Versions/Current")
            link.type = tarfile.SYMTYPE
            link.linkname = "A"
            tar.addfile(link)
        tool.extract_archive(archive, self.work / "out", "top")
        self.assertEqual((self.work / "out/top/Versions/Current/resource").read_text(), "ok")

    def test_offline_cli_fails_on_gap_without_mutating_lock(self):
        lock = self.work / "lock.json"
        lock.write_text(json.dumps(self.pin))
        original = lock.read_bytes()
        run = subprocess.run([sys.executable, str(ROOT / "engine/tool.py"), "check",
                              "--lock", str(lock), "--index", str(FIXTURES / "index.json"),
                              "--chrome", str(FIXTURES / "releases.json"), "--fail-on-gap"],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertIn("SECURITY GAP", run.stderr)
        self.assertEqual(lock.read_bytes(), original)

    def test_offline_update_persists_exact_common_stable_pin(self):
        old = copy.deepcopy(self.pin)
        old["cef_version"] = old["cef_version"].replace("154.0.34+", "154.0.33+")
        for artifact in old["artifacts"].values():
            artifact["name"] = artifact["name"].replace("154.0.34+", "154.0.33+")
        lock = self.work / "lock.json"
        lock.write_text(json.dumps(old))
        run = subprocess.run([sys.executable, str(ROOT / "engine/tool.py"), "update",
                              "--lock", str(lock), "--index", str(FIXTURES / "index.json"),
                              "--chrome", str(FIXTURES / "releases.json")], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(tool.read_json(lock), self.pin)
        self.assertTrue(json.loads(run.stdout)["update_available"])
        self.assertIn("SECURITY GAP", run.stderr)

    def test_lock_rejects_conflicting_embedded_chromium_version(self):
        self.pin["chromium_version"] = "156.0.8078.48"
        with self.assertRaises(ValueError):
            tool.validate_lock(self.pin)

    def test_invalid_chrome_feed_cannot_assert_current(self):
        for feed in [[], [{"version": "unknown"}]]:
            with self.assertRaises(ValueError):
                tool.assess(self.pin, self.pin, feed)


if __name__ == "__main__":
    unittest.main()

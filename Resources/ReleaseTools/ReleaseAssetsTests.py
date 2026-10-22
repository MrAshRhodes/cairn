#!/usr/bin/env python3
"""Offline tests for per-architecture release records and the finalized file set; nothing is signed or uploaded."""
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


assets = load("release_assets", "ReleaseAssets.py")
gate = load("chromium_gate", "ChromiumGate.py")

CEF = "154.0.34+g14c5a08+chromium-154.0.8037.98"
CHROMIUM = "154.0.8037.98"
OTHER_CEF = "154.0.35+g0123abc+chromium-154.0.8037.100"
OTHER_CHROMIUM = "154.0.8037.100"
NOW = datetime.now(timezone.utc).replace(microsecond=0)
ACKNOWLEDGEMENT = "Reviewed Chrome 156 security fixes; none reachable in Cairn. Re-pin next week."
OTHER_COMMIT = "0123456789abcdef0123456789abcdef01234567"
FINAL = {"appcast.xml", "RELEASE-INFO.json", "RELEASE-NOTES.txt", "SHA256SUMS"}


def report(gap=False, cef=CEF, chromium=CHROMIUM):
    return {"pinned_cef": cef, "pinned_chromium": chromium, "latest_stable_cef": cef,
            "latest_cef_chromium": chromium, "chrome_stable": "156.0.8078.48" if gap else chromium,
            "update_available": False, "security_gap": gap, "upstream_security_gap": gap}


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="release-assets-")
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)
        self.release = self.work / "release"

    def fake_app(self, arch, version="0.2.0", build="7", signing="ad-hoc", engine="chromium", cef=CEF,
                 chromium=CHROMIUM, lock=True):
        app = Path(tempfile.mkdtemp(dir=self.work, prefix=f"app-{arch}-")) / "Cairn.app"
        (app / "Contents/Resources").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version, "CFBundleVersion": build, "CairnBuildArchitecture": arch,
            "CairnSigningMode": signing, "CairnBrowserEngine": engine}))
        if lock:
            (app / "Contents/Resources/cef.lock.json").write_text(
                json.dumps({"cef_version": cef, "chromium_version": chromium}))
        return app

    def build(self, arch, into=None, version="0.2.0", notarized=False, **app):
        """One architecture's fake app and archives, described the way scripts/release.sh does."""
        directory = into or self.release
        directory.mkdir(parents=True, exist_ok=True)
        names = assets.file_names(version, arch)
        (directory / names["zip"]).write_bytes(f"zip {arch} {version}".encode())
        (directory / names["dmg"]).write_bytes(f"dmg {arch} {version}".encode())
        return assets.record(self.fake_app(arch, version, **app), directory / names["zip"], directory / names["dmg"],
                             notarized, directory / names["json"])

    def complete(self, into=None, **second):
        self.build("arm64", into)
        self.build("x86_64", into, **second)
        return into or self.release

    def edit_record(self, directory, arch, changes):
        path = directory / assets.file_names("0.2.0", arch)["json"]
        data = json.loads(path.read_text())
        data.update(changes)
        path.write_text(json.dumps(data))

    def gate_record(self, gap=False, **engine):
        path = self.work / "chromium-gate/chromium-gate.json"
        environment = {"CHROMIUM_RISK_ACKNOWLEDGEMENT": ACKNOWLEDGEMENT if gap else "", "GITHUB_ACTOR": "maintainer"}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = gate.main(["--output", str(path)], environment,
                               lambda arguments: (2 if gap else 0, json.dumps(report(gap, **engine)), ""), NOW)
        self.assertEqual(status, 0)
        return path

    def ready(self, gap=False, signing="ad-hoc", notarized=False):
        self.build("arm64", signing=signing, notarized=notarized)
        self.build("x86_64", signing=signing, notarized=notarized)
        (self.release / "appcast.xml").write_text("<rss/>")
        return self.gate_record(gap)

    def run_cli(self, *arguments):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assets.main(list(arguments))
        return out.getvalue()

    def test_record_describes_an_architecture_and_its_hashed_assets(self):
        data = self.build("arm64")
        names = assets.file_names("0.2.0", "arm64")
        self.assertEqual(json.loads((self.release / names["json"]).read_text()), data)
        self.assertEqual((data["schema"], data["version"], data["build"], data["architecture"]),
                         (1, "0.2.0", "7", "arm64"))
        self.assertEqual((data["signing"], data["notarized"]), ("ad-hoc", False))
        self.assertEqual(data["engine"], {"name": "chromium", "cef": CEF, "chromium": CHROMIUM})
        self.assertTrue(data["commit"] is None or len(data["commit"]) == 40)
        for kind in ("zip", "dmg"):
            content = (self.release / names[kind]).read_bytes()
            self.assertEqual(data["assets"][kind], {"name": names[kind],
                                                    "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)})
        assets.validate_record(data)

    def test_record_keeps_developer_id_notarization(self):
        data = self.build("x86_64", signing="developer-id", notarized=True)
        self.assertEqual((data["architecture"], data["signing"], data["notarized"]), ("x86_64", "developer-id", True))

    def test_record_rejects_what_must_never_be_released(self):
        cases = {
            "webkit engine": dict(engine="webkit"),
            "empty engine": dict(engine=""),
            "unknown architecture": dict(arch="universal"),
            "non-numeric version": dict(version="0.2.0-beta"),
            "non-numeric build": dict(build="seven"),
            "unknown signing mode": dict(signing="self-signed"),
            "notarized ad-hoc build": dict(notarized=True),
            "missing engine lock": dict(lock=False),
            "malformed Chromium version": dict(chromium="latest"),
            "malformed CEF version": dict(cef="154"),
        }
        for label, changes in cases.items():
            with self.subTest(label), self.assertRaises(ValueError):
                self.build(**{"arch": "arm64", "into": self.work / label.replace(" ", "-"), **changes})

    def test_record_requires_its_canonical_file_names(self):
        app = self.fake_app("arm64")
        names = assets.file_names("0.2.0", "arm64")
        (self.work / names["zip"]).write_bytes(b"z")
        (self.work / names["dmg"]).write_bytes(b"d")
        with self.assertRaisesRegex(ValueError, "must be named Cairn-0.2.0-arm64.json"):
            assets.record(app, self.work / names["zip"], self.work / names["dmg"], False, self.work / "record.json")
        self.assertFalse((self.work / "record.json").exists())
        with self.assertRaisesRegex(ValueError, "invalid zip asset"):
            assets.record(app, self.work / names["dmg"], self.work / names["dmg"], False, self.work / names["json"])

    def test_record_commit_is_null_without_a_usable_git(self):
        with mock.patch.object(assets.subprocess, "run", side_effect=FileNotFoundError):
            self.assertIsNone(self.build("arm64")["commit"])
        with mock.patch.object(assets.subprocess, "run", return_value=types.SimpleNamespace(stdout="HEAD\n")):
            self.assertIsNone(self.build("arm64")["commit"])

    def test_validate_accepts_the_exact_release_and_prints_its_version(self):
        self.complete()
        records = assets.load_release(self.release, "0.2.0")
        self.assertEqual(sorted(records), ["arm64", "x86_64"])
        self.assertEqual(self.run_cli("validate", str(self.release)), "0.2.0\n")
        self.assertEqual(self.run_cli("validate", str(self.release), "--version", "0.2.0"), "0.2.0\n")

    def test_validate_rejects_an_unexpected_version(self):
        self.complete()
        with self.assertRaisesRegex(ValueError, "not the expected 0.2.1"):
            assets.load_release(self.release, "0.2.1")

    def test_validate_can_also_require_the_gate_for_the_built_chromium(self):
        self.complete()
        accepted = self.gate_record()
        self.assertEqual(self.run_cli("validate", str(self.release), "--chromium-gate", str(accepted)), "0.2.0\n")
        stale = self.gate_record(cef=OTHER_CEF, chromium=OTHER_CHROMIUM)
        with self.assertRaisesRegex(SystemExit, "does not match the Chromium the release gate assessed"):
            self.run_cli("validate", str(self.release), "--chromium-gate", str(stale))
        with self.assertRaisesRegex(SystemExit, "Chromium gate record .*missing.json"):
            self.run_cli("validate", str(self.release), "--chromium-gate", str(self.work / "missing.json"))

    def test_validate_rejects_missing_or_extra_files(self):
        def without(name):
            return lambda directory: (directory / name).unlink()

        def with_file(name):
            return lambda directory: (directory / name).write_bytes(b"x")

        cases = {
            "missing arm64 record": without("Cairn-0.2.0-arm64.json"),
            "missing x86_64 record": without("Cairn-0.2.0-x86_64.json"),
            "missing arm64 zip": without("Cairn-0.2.0-arm64.zip"),
            "missing x86_64 dmg": without("Cairn-0.2.0-x86_64.dmg"),
            "extra file": with_file("notes.txt"),
            "hidden file": with_file(".DS_Store"),
            "stale other version": with_file("Cairn-0.1.0-arm64.zip"),
            "universal archive": with_file("Cairn-0.2.0-universal.zip"),
            "leftover appcast": with_file("appcast.xml"),
            "leftover checksums": with_file("SHA256SUMS"),
            "extra directory": lambda directory: (directory / "extra").mkdir(),
            "second arm64 record": lambda directory: (directory / "Cairn-0.1.0-arm64.json").write_text(
                (directory / "Cairn-0.2.0-arm64.json").read_text()),
        }
        for label, change in cases.items():
            directory = self.work / label.replace(" ", "-")
            self.complete(directory)
            change(directory)
            with self.subTest(label), self.assertRaises(ValueError):
                assets.load_release(directory)

    def test_validate_rejects_a_missing_directory_and_an_empty_one(self):
        with self.assertRaisesRegex(ValueError, "not a directory"):
            assets.load_release(self.work / "nowhere")
        (self.work / "empty").mkdir()
        with self.assertRaisesRegex(ValueError, "exactly one Cairn-VERSION-arm64.json"):
            assets.load_release(self.work / "empty")

    def test_validate_rejects_tampered_archives(self):
        for label, content in {"same size": b"zip arm64 0.2.1", "different size": b"tampered"}.items():
            directory = self.work / label.replace(" ", "-")
            self.complete(directory)
            (directory / "Cairn-0.2.0-arm64.zip").write_bytes(content)
            with self.subTest(label), self.assertRaisesRegex(ValueError, "recorded size and SHA-256"):
                assets.load_release(directory)

    def test_validate_rejects_a_tampered_record_hash(self):
        self.complete()
        path = self.release / "Cairn-0.2.0-x86_64.json"
        data = json.loads(path.read_text())
        data["assets"]["dmg"]["sha256"] = "0" * 64
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "Cairn-0.2.0-x86_64.dmg does not match"):
            assets.load_release(self.release)

    def test_validate_rejects_architectures_that_disagree(self):
        cases = {
            "version": dict(version="0.2.1"),
            "build": dict(build="8"),
            "signing": dict(signing="developer-id"),
            "notarized": dict(signing="developer-id", notarized=True),
            "Chromium": dict(cef=OTHER_CEF, chromium=OTHER_CHROMIUM),
        }
        for label, changes in cases.items():
            directory = self.work / label
            self.complete(directory, **changes)
            with self.subTest(label), self.assertRaisesRegex(ValueError, "disagree|must contain exactly"):
                assets.load_release(directory)

    def test_validate_rejects_architectures_from_different_commits(self):
        self.complete()
        self.edit_record(self.release, "x86_64", {"commit": OTHER_COMMIT})
        self.edit_record(self.release, "arm64", {"commit": None})
        with self.assertRaisesRegex(ValueError, "disagree on commit"):
            assets.load_release(self.release)

    def test_validate_rejects_malformed_records(self):
        good = self.build("arm64", self.work / "template")
        cases = {
            "unknown schema": dict(schema=2),
            "extra key": dict(unexpected=True),
            "numeric version": dict(version=2),
            "wrong architecture": dict(architecture="x86_64"),
            "universal architecture": dict(architecture="universal"),
            "webkit engine": dict(engine={"name": "webkit", "cef": CEF, "chromium": CHROMIUM}),
            "engine extra key": dict(engine={"name": "chromium", "cef": CEF, "chromium": CHROMIUM, "x": 1}),
            "malformed commit": dict(commit="HEAD"),
            "unsigned": dict(signing="none"),
            "string notarized": dict(notarized="false"),
            "notarized ad-hoc": dict(notarized=True),
            "missing dmg asset": dict(assets={"zip": good["assets"]["zip"]}),
            "short hash": dict(assets={**good["assets"], "dmg": {**good["assets"]["dmg"], "sha256": "ab"}}),
            "uppercase hash": dict(assets={**good["assets"], "dmg": {
                **good["assets"]["dmg"], "sha256": good["assets"]["dmg"]["sha256"].upper()}}),
            "empty asset": dict(assets={**good["assets"], "zip": {**good["assets"]["zip"], "size": 0}}),
            "boolean size": dict(assets={**good["assets"], "zip": {**good["assets"]["zip"], "size": True}}),
            "renamed asset": dict(assets={**good["assets"], "zip": {**good["assets"]["zip"], "name": "Cairn.zip"}}),
        }
        for label, changes in cases.items():
            directory = self.work / label.replace(" ", "-")
            self.complete(directory)
            self.edit_record(directory, "arm64", changes)
            with self.subTest(label), self.assertRaises(ValueError):
                assets.load_release(directory)
        for label, text in {"not json": "{", "not an object": "[]", "empty": ""}.items():
            directory = self.work / label.replace(" ", "-")
            self.complete(directory)
            (directory / "Cairn-0.2.0-arm64.json").write_text(text)
            with self.subTest(label), self.assertRaisesRegex(ValueError, "Cairn-0.2.0-arm64.json"):
                assets.load_release(directory)

    def test_validate_rejects_a_record_that_describes_another_file_name(self):
        other = self.work / "other"
        self.build("x86_64", other)
        self.build("arm64", other, version="0.2.1")
        for label, source in {"architecture": "Cairn-0.2.0-x86_64.json", "version": "Cairn-0.2.1-arm64.json"}.items():
            directory = self.work / label
            self.complete(directory)
            (directory / "Cairn-0.2.0-arm64.json").write_text((other / source).read_text())
            with self.subTest(label), self.assertRaisesRegex(ValueError, "does not describe its own file name"):
                assets.load_release(directory)

    def test_validate_rejects_symlinks_in_place_of_files(self):
        for name in ("Cairn-0.2.0-arm64.zip", "Cairn-0.2.0-x86_64.dmg", "Cairn-0.2.0-x86_64.json"):
            directory = self.work / name
            self.complete(directory)
            target = self.work / f"target-{name}"
            (directory / name).rename(target)
            (directory / name).symlink_to(target)
            with self.subTest(name), self.assertRaisesRegex(ValueError, "must be a regular file"):
                assets.load_release(directory)

    def test_publish_writes_release_info_notes_and_checksums(self):
        gate_path = self.ready()
        self.assertEqual(assets.publish(self.release, gate_path), "0.2.0")
        info = json.loads((self.release / "RELEASE-INFO.json").read_text())
        self.assertEqual((info["version"], info["build"], info["architectures"]), ("0.2.0", "7", ["arm64", "x86_64"]))
        self.assertEqual(info["engine"], {"name": "chromium", "cef": CEF, "chromium": CHROMIUM})
        self.assertEqual((info["signing"], info["notarized"]), ("ad-hoc", False))
        self.assertEqual(info["chromium_gate"], json.loads(gate_path.read_text()))
        listed = [(asset["name"], asset["kind"], asset.get("architecture")) for asset in info["assets"]]
        self.assertEqual(listed, [
            ("Cairn-0.2.0-arm64.zip", "zip", "arm64"), ("Cairn-0.2.0-arm64.dmg", "dmg", "arm64"),
            ("Cairn-0.2.0-x86_64.zip", "zip", "x86_64"), ("Cairn-0.2.0-x86_64.dmg", "dmg", "x86_64"),
            ("appcast.xml", "appcast", None)])
        for asset in info["assets"]:
            content = (self.release / asset["name"]).read_bytes()
            self.assertEqual((asset["sha256"], asset["size"]), (hashlib.sha256(content).hexdigest(), len(content)))
        notes = (self.release / "RELEASE-NOTES.txt").read_text()
        for expected in (f"Chromium {CHROMIUM} (CEF {CEF})", "NOT notarized by Apple", "Apple signing: ad-hoc",
                         "Cairn-0.2.0-arm64.dmg (Apple silicon)", "Cairn-0.2.0-x86_64.dmg (Intel)",
                         "verified Sparkle Ed25519 signatures", "no Apple Gatekeeper trust",
                         "Chromium engine gate: passed"):
            self.assertIn(expected, notes)
        self.assertNotIn("ACKNOWLEDGED", notes)
        sums = (self.release / "SHA256SUMS").read_text().splitlines()
        self.assertEqual([line.split("  ")[1] for line in sums], sorted([
            "Cairn-0.2.0-arm64.zip", "Cairn-0.2.0-arm64.dmg", "Cairn-0.2.0-x86_64.zip", "Cairn-0.2.0-x86_64.dmg",
            "appcast.xml", "RELEASE-INFO.json", "RELEASE-NOTES.txt"]))
        for line in sums:
            checksum, name = line.split("  ")
            self.assertEqual(checksum, hashlib.sha256((self.release / name).read_bytes()).hexdigest())

    def test_publish_can_be_repeated_and_describes_developer_id_notarization(self):
        gate_path = self.ready(signing="developer-id", notarized=True)
        assets.publish(self.release, gate_path)
        first = (self.release / "SHA256SUMS").read_text()
        assets.publish(self.release, gate_path)
        self.assertEqual((self.release / "SHA256SUMS").read_text(), first)
        self.assertIn("Apple signing: Developer ID. Notarized by Apple.", (self.release / "RELEASE-NOTES.txt").read_text())
        info = json.loads((self.release / "RELEASE-INFO.json").read_text())
        self.assertEqual((info["signing"], info["notarized"]), ("Developer ID", True))

    def test_publish_records_an_acknowledged_security_gap(self):
        gate_path = self.ready(gap=True)
        assets.publish(self.release, gate_path)
        notes = (self.release / "RELEASE-NOTES.txt").read_text()
        self.assertIn("CHROMIUM SECURITY GAP ACKNOWLEDGED BY A MAINTAINER.", notes)
        self.assertIn(json.dumps(ACKNOWLEDGEMENT), notes)
        self.assertIn("Chrome stable 156.0.8078.48", notes)
        info = json.loads((self.release / "RELEASE-INFO.json").read_text())
        self.assertEqual((info["chromium_gate"]["outcome"], info["chromium_gate"]["acknowledgement"]),
                         ("acknowledged", ACKNOWLEDGEMENT))

    def assert_publish_fails(self, gate_path, message):
        with self.assertRaisesRegex(ValueError, message):
            assets.publish(self.release, gate_path)
        for name in ("RELEASE-INFO.json", "RELEASE-NOTES.txt", "SHA256SUMS"):
            self.assertFalse((self.release / name).exists(), name)

    def test_publish_requires_the_appcast(self):
        gate_path = self.ready()
        (self.release / "appcast.xml").unlink()
        self.assert_publish_fails(gate_path, "appcast.xml is missing")
        (self.release / "appcast.xml").write_text("")
        self.assert_publish_fails(gate_path, "appcast.xml is missing or empty")

    def test_publish_requires_a_valid_gate_for_the_built_chromium(self):
        gate_path = self.ready()
        self.assert_publish_fails(self.work / "chromium-gate/missing.json", "Chromium gate record")
        stale = self.gate_record(cef=OTHER_CEF, chromium=OTHER_CHROMIUM)
        self.assert_publish_fails(stale, "does not match the Chromium the release gate assessed")
        self.gate_record()
        record = json.loads(gate_path.read_text())
        for label, changes in {
            "acknowledged without a gap": dict(status="current", outcome="acknowledged"),
            "acknowledgement on a current pin": dict(acknowledgement=ACKNOWLEDGEMENT),
            "schema": dict(schema=2),
            "forged timestamp": dict(checked_at="yesterday"),
            "expired assessment": dict(checked_at=(NOW - timedelta(hours=25)).strftime("%Y-%m-%dT%H:%M:%SZ")),
            "future assessment": dict(checked_at=(NOW + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")),
        }.items():
            forged = self.work / "chromium-gate/forged.json"
            forged.write_text(json.dumps(dict(record, **changes)))
            with self.subTest(label):
                self.assert_publish_fails(forged, "Chromium gate record")
        forged.write_text("not json")
        self.assert_publish_fails(forged, "Chromium gate record")

    def test_publish_rejects_an_incomplete_release_before_writing_anything(self):
        gate_path = self.ready()
        (self.release / "Cairn-0.2.0-x86_64.zip").unlink()
        self.assert_publish_fails(gate_path, "missing: Cairn-0.2.0-x86_64.zip")

    def test_publish_rejects_files_that_changed_after_validation(self):
        gate_path = self.ready()
        (self.release / "Cairn-0.2.0-arm64.dmg").write_bytes(b"swapped")
        self.assert_publish_fails(gate_path, "recorded size and SHA-256")

    def test_command_line_reports_failures_without_a_traceback(self):
        self.complete()
        command = [sys.executable, str(HERE / "ReleaseAssets.py")]
        done = subprocess.run(command + ["validate", str(self.release), "--version", "0.2.0"], capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "0.2.0\n", ""))
        (self.release / "extra.txt").write_text("x")
        done = subprocess.run(command + ["validate", str(self.release)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 1)
        self.assertIn("ERROR: ", done.stderr)
        self.assertIn("unexpected: extra.txt", done.stderr)
        self.assertNotIn("Traceback", done.stderr)

    def test_command_line_publishes_a_release(self):
        gate_path = self.ready()
        out = self.run_cli("publish", str(self.release), "--chromium-gate", str(gate_path))
        self.assertIn("Wrote RELEASE-INFO.json, RELEASE-NOTES.txt and SHA256SUMS for 0.2.0", out)
        self.assertTrue(FINAL <= {entry.name for entry in self.release.iterdir()})

    def test_command_line_records_an_architecture(self):
        app = self.fake_app("x86_64", "0.3.0", build="9", signing="developer-id")
        (self.work / "Cairn-0.3.0-x86_64.zip").write_bytes(b"zip")
        (self.work / "Cairn-0.3.0-x86_64.dmg").write_bytes(b"dmg")
        out = self.run_cli("record", "--app", str(app), "--zip", str(self.work / "Cairn-0.3.0-x86_64.zip"),
                           "--dmg", str(self.work / "Cairn-0.3.0-x86_64.dmg"), "--notarized", "true",
                           "--output", str(self.work / "out/Cairn-0.3.0-x86_64.json"))
        self.assertIn("Recorded 0.3.0 (x86_64)", out)
        data = json.loads((self.work / "out/Cairn-0.3.0-x86_64.json").read_text())
        self.assertEqual((data["signing"], data["notarized"]), ("developer-id", True))


if __name__ == "__main__":
    unittest.main()

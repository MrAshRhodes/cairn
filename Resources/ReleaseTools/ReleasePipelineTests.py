#!/usr/bin/env python3
"""Runs the real signing, verification and feed path once: make-appcast.sh and finalize-release.sh with a throwaway
Ed25519 key, Sparkle's own sign_update and fake ad-hoc signed Chromium apps built with clang. Nothing is released."""
import contextlib
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGN_UPDATE = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
CEF = "154.0.34+g14c5a08+chromium-154.0.8037.98"
CHROMIUM = "154.0.8037.98"
FRAMEWORK = "Chromium Embedded Framework.framework"
HELPERS = ("", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)")
ARCHITECTURES = ("arm64", "x86_64")
FINAL_FILES = {"appcast.xml", "RELEASE-INFO.json", "RELEASE-NOTES.txt", "SHA256SUMS"}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("chromium_gate", "ChromiumGate.py")


def run(*command, env=None, timeout=900):
    return subprocess.run([str(part) for part in command], cwd=ROOT, env=env or os.environ.copy(),
                          capture_output=True, text=True, timeout=timeout)


def environment(**changes):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("SPARKLE_", "APPLE_", "CAIRN_", "SIGNING_", "NOTARY_"))}
    env.update(changes)
    return {key: value for key, value in env.items() if value is not None}


def ephemeral_key():
    result = run("swift", HERE / "EphemeralKey.swift")
    assert result.returncode == 0, result.stderr
    private, public = result.stdout.split()
    return private, public


def verify_signature(public, signature, path):
    return run("swift", HERE / "VerifySignature.swift", public, signature, path)


class ReleasePipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SIGN_UPDATE.exists():
            subprocess.run([str(ROOT / "scripts/swiftw"), "package", "resolve"], cwd=ROOT, check=True,
                           capture_output=True)
        (ROOT / ".build").mkdir(exist_ok=True)
        cls.directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="release-pipeline-")
        cls.work = Path(cls.directory.name)
        cls.private, cls.public = ephemeral_key()
        cls.other_private, _ = ephemeral_key()
        cls.binaries = {arch: cls.compile(arch) for arch in ARCHITECTURES}
        cls.template = cls.work / "template"
        cls.template.mkdir()
        for arch in ARCHITECTURES:
            cls.add_architecture(cls.template, arch)
        cls.gate = cls.work / "chromium-gate/chromium-gate.json"
        report = {"pinned_cef": CEF, "pinned_chromium": CHROMIUM, "latest_stable_cef": CEF,
                  "latest_cef_chromium": CHROMIUM, "chrome_stable": CHROMIUM, "update_available": False,
                  "security_gap": False, "upstream_security_gap": False}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = gate.main(["--output", str(cls.gate)], {"GITHUB_ACTOR": "maintainer"},
                               lambda arguments: (0, json.dumps(report), ""),
                               datetime.now(timezone.utc))
        assert status == 0

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    @classmethod
    def compile(cls, arch):
        source = cls.work / f"source-{arch}"
        source.mkdir()
        (source / "stub.c").write_text("int stub(void) { return 0; }\n")
        (source / "main.c").write_text("extern int stub(void);\nint main(void) { return stub(); }\n")
        (source / "helper.c").write_text("int main(void) { return 0; }\n")

        def cc(*arguments):
            subprocess.run(["clang", "-arch", arch, *map(str, arguments)], check=True, capture_output=True)

        cc("-dynamiclib", source / "stub.c", "-install_name", "@rpath/Sparkle.framework/Versions/B/Sparkle",
           "-o", source / "sparkle")
        cc("-dynamiclib", source / "stub.c", "-install_name",
           f"@executable_path/../Frameworks/{FRAMEWORK}/Chromium Embedded Framework", "-o", source / "cef")
        cc(source / "main.c", source / "sparkle", "-Wl,-rpath,@executable_path/../Frameworks", "-o", source / "cairn")
        cc(source / "helper.c", "-o", source / "helper")
        return {name: source / name for name in ("sparkle", "cef", "cairn", "helper")}

    @staticmethod
    def framework(path, letter, name, binary):
        version = path / "Versions" / letter
        (version / "Resources").mkdir(parents=True)
        shutil.copy2(binary, version / name)
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": name, "CFBundleIdentifier": "io.test." + name.replace(" ", ""),
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1"}))
        os.symlink(letter, path / "Versions/Current")
        os.symlink(f"Versions/Current/{name}", path / name)
        os.symlink("Versions/Current/Resources", path / "Resources")

    @classmethod
    def assemble(cls, arch, version="0.2.0", build="7"):
        """A minimal but structurally complete ad-hoc signed Chromium app for ARCH."""
        app = Path(tempfile.mkdtemp(dir=cls.work)) / "Cairn.app"
        contents, binaries = app / "Contents", cls.binaries[arch]
        for directory in ("MacOS", "Resources", "Frameworks"):
            (contents / directory).mkdir(parents=True)
        shutil.copy2(binaries["cairn"], contents / "MacOS/Cairn")
        (contents / "Resources/Cairn.icns").write_bytes(b"icon")
        (contents / "Resources/CEF-LICENSE.txt").write_text("license\n")
        (contents / "Resources/cef.lock.json").write_text(json.dumps({"cef_version": CEF, "chromium_version": CHROMIUM}))
        cls.framework(contents / "Frameworks/Sparkle.framework", "B", "Sparkle", binaries["sparkle"])
        cls.framework(contents / "Frameworks" / FRAMEWORK, "A", "Chromium Embedded Framework", binaries["cef"])
        components = [contents / "Frameworks/Sparkle.framework", contents / "Frameworks" / FRAMEWORK]
        for suffix in HELPERS:
            name = f"Cairn Helper{suffix}"
            helper = contents / "Frameworks" / f"{name}.app"
            (helper / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(binaries["helper"], helper / "Contents/MacOS" / name)
            (helper / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
                "CFBundleIdentifier": "io.test." + "".join(character for character in name if character.isalnum())}))
            components.append(helper)
        configured = run(sys.executable, HERE / "bundle.py", "configure", app, env=environment(
            ARCH=arch, VERSION=version, BUILD_NUMBER=build, SIGNING_IDENTITY="-", SPARKLE_PUBLIC_ED_KEY=cls.public))
        assert configured.returncode == 0, configured.stderr
        for target in [*components, app]:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)], check=True,
                           capture_output=True)
        return app

    @classmethod
    def add_architecture(cls, directory, arch, version="0.2.0"):
        app = cls.assemble(arch, version)
        names = {kind: f"Cairn-{version}-{arch}.{kind}" for kind in ("zip", "dmg", "json")}
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(directory / names["zip"])], check=True)
        (directory / names["dmg"]).write_bytes(f"disk image {arch}".encode())
        recorded = run(sys.executable, HERE / "ReleaseAssets.py", "record", "--app", app, "--zip",
                       directory / names["zip"], "--dmg", directory / names["dmg"], "--notarized", "false",
                       "--output", directory / names["json"])
        assert recorded.returncode == 0, recorded.stderr

    def setUp(self):
        self.release = Path(tempfile.mkdtemp(dir=self.work)) / "release"
        shutil.copytree(self.template, self.release)

    def finalize(self, **changes):
        env = environment(SPARKLE_PUBLIC_ED_KEY=self.public, SPARKLE_PRIVATE_ED_KEY=self.private,
                          CAIRN_CHROMIUM_GATE_RECORD=str(self.gate), VERSION="0.2.0")
        env.update(changes)
        env = {key: value for key, value in env.items() if value is not None}
        result = run(ROOT / "scripts/finalize-release.sh", self.release, env=env)
        for secret in (self.private, self.other_private):
            self.assertNotIn(secret, result.stdout + result.stderr, "a private key was echoed")
        return result

    def assertNothingFinalized(self):
        self.assertEqual(FINAL_FILES & {path.name for path in self.release.iterdir()}, set())

    def test_finalize_authenticates_both_architectures_into_one_signed_feed(self):
        result = self.finalize()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({path.name for path in self.release.iterdir()} - FINAL_FILES,
                         {f"Cairn-0.2.0-{arch}.{kind}" for arch in ARCHITECTURES for kind in ("zip", "dmg", "json")})
        feed = self.release / "appcast.xml"
        self.assertEqual(run("swift", HERE / "VerifySignature.swift", "--feed", self.public, feed).returncode, 0)
        first, second = ET.parse(feed).getroot().findall("./channel/item")
        self.assertEqual(first.findtext(f"{SPARKLE}hardwareRequirements"), "arm64")
        self.assertIsNone(second.find(f"{SPARKLE}hardwareRequirements"))
        for item, arch in ((first, "arm64"), (second, "x86_64")):
            enclosure = item.find("enclosure")
            archive = self.release / f"Cairn-0.2.0-{arch}.zip"
            self.assertTrue(enclosure.get("url").endswith(f"/v0.2.0/{archive.name}"))
            self.assertEqual(int(enclosure.get("length")), archive.stat().st_size)
            verified = verify_signature(self.public, enclosure.get(f"{SPARKLE}edSignature"), archive)
            self.assertEqual(verified.returncode, 0, verified.stderr)
        info = json.loads((self.release / "RELEASE-INFO.json").read_text())
        self.assertEqual((info["version"], info["architectures"]), ("0.2.0", ["arm64", "x86_64"]))
        self.assertEqual(info["engine"], {"name": "chromium", "cef": CEF, "chromium": CHROMIUM})
        self.assertEqual(info["chromium_gate"]["outcome"], "passed")
        self.assertIn(CHROMIUM, (self.release / "RELEASE-NOTES.txt").read_text())
        sums = dict(line.split("  ")[::-1] for line in (self.release / "SHA256SUMS").read_text().splitlines())
        self.assertEqual(set(sums), {f"Cairn-0.2.0-{arch}.{kind}" for arch in ARCHITECTURES for kind in ("zip", "dmg")}
                         | {"appcast.xml", "RELEASE-INFO.json", "RELEASE-NOTES.txt"})
        for name, checksum in sums.items():
            self.assertEqual(hashlib.sha256((self.release / name).read_bytes()).hexdigest(), checksum, name)
        feed.write_bytes(feed.read_bytes().replace(b"Cairn updates", b"Cairn updated", 1))
        tampered = run("swift", HERE / "VerifySignature.swift", "--feed", self.public, feed)
        self.assertNotEqual(tampered.returncode, 0)

    def test_a_key_that_does_not_match_the_public_key_signs_nothing(self):
        result = self.finalize(SPARKLE_PRIVATE_ED_KEY=self.other_private)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertNothingFinalized()

    def test_finalize_requires_an_exact_intact_release_and_a_gate_record(self):
        def drop_record(directory):
            (directory / "Cairn-0.2.0-x86_64.json").unlink()

        def corrupt_archive(directory):
            with (directory / "Cairn-0.2.0-arm64.zip").open("ab") as stream:
                stream.write(b"x")

        def add_extra(directory):
            (directory / "extra.txt").write_text("unexpected")

        for label, change, changes, message in (
            ("missing architecture", drop_record, {}, "expected exactly one Cairn-VERSION-x86_64.json"),
            ("modified archive", corrupt_archive, {}, "does not match its recorded size and SHA-256"),
            ("extra file", add_extra, {}, "unexpected: extra.txt"),
            ("wrong version", lambda directory: None, dict(VERSION="0.3.0"), "is not the expected 0.3.0"),
            ("no gate record", lambda directory: None, dict(CAIRN_CHROMIUM_GATE_RECORD=None),
             "set CAIRN_CHROMIUM_GATE_RECORD"),
        ):
            with self.subTest(label):
                shutil.rmtree(self.release)
                shutil.copytree(self.template, self.release)
                change(self.release)
                result = self.finalize(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertNothingFinalized()

    def test_make_appcast_rejects_an_application_modified_after_signing(self):
        extracted = self.work / "tampered"
        shutil.rmtree(extracted, ignore_errors=True)
        extracted.mkdir()
        subprocess.run(["ditto", "-x", "-k", str(self.release / "Cairn-0.2.0-arm64.zip"), str(extracted)], check=True)
        (extracted / "Cairn.app/Contents/Resources/Cairn.icns").write_bytes(b"swapped icon")
        archive = self.release / "Cairn-0.2.0-arm64.zip"
        archive.unlink()
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(extracted / "Cairn.app"), str(archive)], check=True)
        feed = self.work / "tampered-appcast.xml"
        result = run(ROOT / "scripts/make-appcast.sh", feed, archive, self.release / "Cairn-0.2.0-x86_64.zip",
                     env=environment(SPARKLE_PUBLIC_ED_KEY=self.public, SPARKLE_PRIVATE_ED_KEY=self.private))
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr, r"modified|sealed resource|invalid signature|not valid")
        self.assertNotIn(self.private, result.stdout + result.stderr)
        self.assertFalse(feed.exists())


if __name__ == "__main__":
    unittest.main()

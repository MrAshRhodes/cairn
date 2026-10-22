#!/usr/bin/env python3
"""scripts/verify-bundle.sh against small but structurally complete ad-hoc signed Chromium apps built with clang.

Each test starts from a valid bundle, breaks exactly one rule of the packaging contract and expects the gate to name it.
Nothing is released and no network, Developer ID or Keychain is used."""
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCRIPT = ROOT / "scripts/verify-bundle.sh"
FRAMEWORK = "Chromium Embedded Framework.framework"
HELPERS = (("", ""), (" (Alerts)", ".alerts"), (" (GPU)", ".gpu"), (" (Plugin)", ".plugin"), (" (Renderer)", ".renderer"))
ARCHITECTURES = ("arm64", "x86_64")
PUBLIC_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="  # RFC 8032 test vector; never a real key
ENTITLEMENTS = ROOT / "engine/entitlements"


def run(*command, **kwargs):
    return subprocess.run([str(part) for part in command], capture_output=True, text=True, **kwargs)


def sign(path, entitlements=None):
    command = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    result = run(*command, path)
    assert result.returncode == 0, result.stderr


class VerifyBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".build").mkdir(exist_ok=True)
        cls.directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="verify-bundle-")
        cls.work = Path(cls.directory.name)
        cls.binaries = {(arch, target): cls.compile(arch, target) for arch in ARCHITECTURES for target in ("13.0", "15.0")}

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    @classmethod
    def compile(cls, arch, target):
        source = cls.work / f"source-{arch}-{target}"
        source.mkdir()
        (source / "stub.c").write_text("int stub(void) { return 0; }\n")
        (source / "main.c").write_text("int main(void) { return 0; }\n")
        flags = ["clang", "-arch", arch, f"-mmacosx-version-min={target}"]
        subprocess.run([*flags, "-dynamiclib", source / "stub.c", "-o", source / "dylib"], check=True, capture_output=True)
        subprocess.run([*flags, source / "main.c", "-o", source / "exe"], check=True, capture_output=True)
        return {"dylib": source / "dylib", "exe": source / "exe"}

    @staticmethod
    def write_plist(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def assemble(self, arch="arm64", binary_arch=None, cef_target="13.0", signing=None, skip=()):
        """A valid ad-hoc Chromium app for ARCH; binary_arch/cef_target let a test lie about what is inside."""
        binary_arch = binary_arch or arch
        signing = signing or {}
        app = Path(tempfile.mkdtemp(dir=self.work)) / "Cairn.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        shutil.copy2(self.binaries[(binary_arch, "13.0")]["exe"], contents / "MacOS/Cairn")
        for name in ("Cairn.icns", "CEF-LICENSE.txt", "Sparkle-LICENSE"):
            (contents / "Resources" / name).write_text("fixture\n")
        (contents / "Resources/cef.lock.json").write_text("{}\n")
        configured = run(sys.executable, HERE / "bundle.py", "configure", app, cwd=ROOT, env=dict(
            os.environ, ARCH=arch, VERSION="0.2.0", BUILD_NUMBER="7", SIGNING_IDENTITY="-", SPARKLE_PUBLIC_ED_KEY=PUBLIC_KEY))
        self.assertEqual(configured.returncode, 0, configured.stderr)
        info = plistlib.loads((contents / "Info.plist").read_bytes())

        def framework(path, version, name, binary):
            versioned = path / "Versions" / version
            (versioned / "Resources").mkdir(parents=True)
            shutil.copy2(binary, versioned / name)
            self.write_plist(versioned / "Resources/Info.plist", {
                "CFBundleExecutable": name, "CFBundleIdentifier": "io.test." + name.replace(" ", ""),
                "CFBundlePackageType": "FMWK", "CFBundleVersion": "1"})
            os.symlink(version, path / "Versions/Current")
            os.symlink(f"Versions/Current/{name}", path / name)
            os.symlink("Versions/Current/Resources", path / "Resources")
            return versioned

        frameworks = contents / "Frameworks"
        sparkle = frameworks / "Sparkle.framework"
        framework(sparkle, "B", "Sparkle", self.binaries[(binary_arch, "13.0")]["dylib"])
        cef = frameworks / FRAMEWORK
        versioned = framework(cef, "A", "Chromium Embedded Framework", self.binaries[(binary_arch, cef_target)]["dylib"])
        (versioned / "Libraries").mkdir()
        os.symlink("Versions/Current/Libraries", cef / "Libraries")
        for library in ("libcef_sandbox.dylib", "libvk_swiftshader.dylib"):
            shutil.copy2(self.binaries[(binary_arch, "13.0")]["dylib"], versioned / "Libraries" / library)
        (versioned / "Libraries/vk_swiftshader_icd.json").write_text("{}\n")
        for resource in ("icudtl.dat", "resources.pak", f"v8_context_snapshot.{arch}.bin"):
            (versioned / "Resources" / resource).write_bytes(b"fixture")
        helpers = []
        for suffix, identifier in HELPERS:
            name = "Cairn Helper" + suffix
            if name in skip:
                continue
            helper = frameworks / f"{name}.app"
            (helper / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(self.binaries[(binary_arch, "13.0")]["exe"], helper / "Contents/MacOS" / name)
            self.write_plist(helper / "Contents/Info.plist", {
                "CFBundleExecutable": name, "CFBundleName": name, "CFBundlePackageType": "APPL",
                "CFBundleIdentifier": info["CFBundleIdentifier"] + ".helper" + identifier,
                "LSUIElement": True, "LSMinimumSystemVersion": info["LSMinimumSystemVersion"]})
            helpers.append((suffix, helper))
        for library in (versioned / "Libraries").glob("*.dylib"):
            sign(library)
        sign(cef)
        sign(sparkle)
        for suffix, helper in helpers:
            default = "renderer.plist" if suffix in (" (GPU)", " (Renderer)") else "helper.plist"
            sign(helper, signing.get(suffix.strip(" ()") or "helper", ENTITLEMENTS / default))
        sign(app, signing.get("app", ROOT / "Resources/Cairn.entitlements"))
        return app

    def verify(self, app, *arguments):
        return run(SCRIPT, *arguments, app)

    def verify_all(self, *jobs):
        """The gate is process-bound and the bundles are independent, so they are verified concurrently.
        Each job is (app, *arguments)."""
        with ThreadPoolExecutor(max_workers=min(len(jobs), os.cpu_count() or 2, 8)) as pool:
            return list(pool.map(lambda job: self.verify(job[0], *job[1:]), jobs))

    def assertRejected(self, app, message, *arguments):
        result = self.verify(app, *arguments)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        return result

    def assertEachRejected(self, cases, *arguments):
        """cases: [(message the gate must report, bundle that breaks exactly that rule)]"""
        for (message, _), result in zip(cases, self.verify_all(*[(app, *arguments) for _, app in cases])):
            self.assertEqual(result.returncode, 1, f"{message}\n{result.stdout}{result.stderr}")
            self.assertIn(message, result.stderr)

    def test_valid_bundles_pass_for_each_architecture(self):
        apps = {arch: self.assemble(arch) for arch in ARCHITECTURES}
        detected = self.verify_all(*[(app,) for app in apps.values()])
        requested = self.verify_all(*[(app, "--arch", arch) for arch, app in apps.items()])
        for arch, result, explicit in zip(apps, detected, requested):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"({arch}, ad-hoc)", result.stdout)
            self.assertIn("NOT verified", result.stdout)
            self.assertEqual(explicit.returncode, 0, explicit.stderr)

    def test_arguments_are_validated(self):
        app = self.assemble()
        self.assertEqual(run(SCRIPT, "--bogus", app).returncode, 2)
        self.assertEqual(run(SCRIPT, self.work / "missing.app").returncode, 2)
        self.assertRejected(app, "requested", "--arch", "x86_64")

    def test_a_missing_helper_is_rejected(self):
        self.assertRejected(self.assemble(skip=("Cairn Helper (GPU)",)), "missing helper executable Cairn Helper (GPU)")

    def test_unexpected_applications_and_stray_files_are_rejected(self):
        app = self.assemble()
        shutil.copytree(app / "Contents/Frameworks/Cairn Helper.app", app / "Contents/Frameworks/Other.app", symlinks=True)
        cases = [("unexpected application in Frameworks: Other.app", app)]
        for stray in ("embedded.provisionprofile", "certificate.p12", "Cookies", "profile.har"):
            app = self.assemble()
            (app / "Contents/Resources" / stray).write_text("secret\n")
            cases.append(("stray file(s)", app))
        self.assertEachRejected(cases)

    def test_symlinks_may_not_leave_the_bundle(self):
        app = self.assemble()
        os.symlink("/etc/hosts", app / "Contents/Resources/escape")
        self.assertRejected(app, "symlink that leaves the bundle")

    def test_per_process_entitlements_are_enforced(self):
        cases = []
        for suffix, helper_key, extra in (
                (" (GPU)", "GPU", "com.apple.security.get-task-allow"),
                (" (Renderer)", "Renderer", "com.apple.security.cs.disable-library-validation"),
                (" (Plugin)", "Plugin", "com.apple.security.cs.allow-unsigned-executable-memory")):
            path = self.work / f"extra-{helper_key}.plist"
            baseline = ENTITLEMENTS / ("renderer.plist" if helper_key != "Plugin" else "helper.plist")
            entitlements = plistlib.loads(baseline.read_bytes())
            entitlements[extra] = True
            path.write_bytes(plistlib.dumps(entitlements))
            cases.append((f"Cairn Helper{suffix}: forbidden entitlement {extra}", self.assemble(signing={helper_key: path})))
        missing_jit = "required entitlement com.apple.security.cs.allow-jit is missing"
        cases += [
            (f"Cairn Helper (Renderer): {missing_jit}", self.assemble(signing={"Renderer": ENTITLEMENTS / "helper.plist"})),
            (f"Cairn Helper (GPU): {missing_jit}", self.assemble(signing={"GPU": ENTITLEMENTS / "helper.plist"})),
            ("Cairn Helper: entitlements", self.assemble(signing={"helper": ENTITLEMENTS / "renderer.plist"})),
        ]
        self.assertEachRejected(cases)

    def test_the_browser_needs_capture_and_location_entitlements(self):
        entitlements = plistlib.loads((ROOT / "Resources/Cairn.entitlements").read_bytes())
        cases = []
        for key in ("com.apple.security.device.camera", "com.apple.security.personal-information.location"):
            path = self.work / f"without-{key.rsplit('.', 1)[-1]}.plist"
            path.write_bytes(plistlib.dumps({name: value for name, value in entitlements.items() if name != key}))
            cases.append((f"required entitlement {key} is missing", self.assemble(signing={"app": path})))
        self.assertEachRejected(cases)

    def test_info_plist_contract_is_enforced(self):
        changes = (
            ("NSCameraUsageDescription is missing", lambda info: info.pop("NSCameraUsageDescription")),
            ("NSLocationWhenInUseUsageDescription is missing", lambda info: info.pop("NSLocationWhenInUseUsageDescription")),
            ("NSBluetoothAlwaysUsageDescription is missing", lambda info: info.pop("NSBluetoothAlwaysUsageDescription")),
            ("does not register https", lambda info: info.update(CFBundleURLTypes=[{"CFBundleURLSchemes": ["http"]}])),
            ("does not register public.html", lambda info: info.pop("CFBundleDocumentTypes")),
            ("Package.swift requires macOS 14", lambda info: info.update(LSMinimumSystemVersion="15.0")),
            ("SUFeedURL must be an https URL", lambda info: info.update(SUFeedURL="http://example.invalid/appcast.xml")),
            ("SURequireSignedFeed must be true", lambda info: info.update(SURequireSignedFeed=False)),
            ("SUPublicEDKey is not a 32-byte", lambda info: info.update(SUPublicEDKey="AAAA")),
            ("CairnBrowserEngine must be chromium", lambda info: info.update(CairnBrowserEngine="webkit")),
            ("unsubstituted", lambda info: info.update(CFBundleShortVersionString="@CAIRN_VERSION@")),
        )
        cases = []
        for message, change in changes:
            app = self.assemble()
            path = app / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes())
            change(info)
            path.write_bytes(plistlib.dumps(info))
            sign(app, ROOT / "Resources/Cairn.entitlements")
            cases.append((message, app))
        self.assertEachRejected(cases)

    def test_architecture_and_deployment_target_must_match(self):
        self.assertEachRejected([
            ("must be a thin arm64 binary", self.assemble("arm64", binary_arch="x86_64")),
            ("must be a thin x86_64 binary", self.assemble("x86_64", binary_arch="arm64")),
            ("requires macOS 15.0, newer than the declared LSMinimumSystemVersion 14.0", self.assemble("arm64", cef_target="15.0")),
        ])

    def test_the_cef_snapshot_must_belong_to_the_architecture(self):
        app = self.assemble("arm64")
        resources = app / "Contents/Frameworks" / FRAMEWORK / "Versions/A/Resources"
        (resources / "v8_context_snapshot.arm64.bin").rename(resources / "v8_context_snapshot.x86_64.bin")
        self.assertRejected(app, "v8_context_snapshot.arm64.bin")

    def test_tampering_after_signing_is_rejected(self):
        app = self.assemble()
        (app / "Contents/Resources/cef.lock.json").write_text('{"tampered": true}\n')
        self.assertRejected(app, "codesign --verify --deep --strict failed")

    def test_a_release_requires_a_developer_id_signature(self):
        self.assertRejected(self.assemble(), "a Developer ID build is required", "--require-developer-id")
        self.assertRejected(self.assemble(), "--notarized needs a Developer ID build", "--notarized")


if __name__ == "__main__":
    unittest.main()

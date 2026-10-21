#!/usr/bin/env python3
"""Signing CLI integration with a fake external signer, never the user's Keychain."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
SIGNATURE = "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
ACCOUNT = "io.github.mrashrhodes.cairn.test-only"


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / ".build/release-signing-tests" / self._testMethodName
        if self.root.exists():
            shutil.rmtree(self.root)
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "Resources/ReleaseTools").mkdir(parents=True)
        for name in ["sparkle-release-signing.sh", "release.sh", "make-appcast.sh"]:
            source = ROOT / "scripts" / name
            if source.exists():
                shutil.copy2(source, self.root / "scripts" / name)
        for name in ["VerifySignature.swift", "validate-key.py"]:
            shutil.copy2(ROOT / "Resources/ReleaseTools" / name,
                         self.root / "Resources/ReleaseTools" / name)
        signer = self.root / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        signer.parent.mkdir(parents=True)
        signer.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys
args = sys.argv[1:]
data = sys.stdin.read()
with pathlib.Path(os.environ["SIGNER_LOG"]).open("a") as log:
    log.write(json.dumps({{"args": args, "empty_stdin": not data,
                         "public_fixture_stdin": data == {PUBLIC_KEY!r}}}) + "\\n")
if os.environ.get("MOCK_SIGNER_FAILURE"):
    print("MOCK_SENSITIVE_DIAGNOSTIC_DO_NOT_FORWARD")
    sys.exit(1)
if "-p" in args:
    print({SIGNATURE!r})
elif "--verify" not in args:
    feed = pathlib.Path(args[-1])
    content = feed.read_bytes()
    feed.write_bytes(content + ("<!-- sparkle-signatures:\\nedSignature: "
                               + {SIGNATURE!r} + "\\nlength: "
                               + str(len(content)) + "\\n-->\\n").encode())
""")
        signer.chmod(0o755)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("SPARKLE_", "APPLE_", "SIGNING_", "NOTARY_"))
        }
        self.environment.update(
            SPARKLE_KEYCHAIN_ACCOUNT=ACCOUNT, SPARKLE_PUBLIC_ED_KEY=PUBLIC_KEY,
            SIGNER_LOG=str(self.root / "signer.jsonl"), VERSION="0.1.0"
        )

    def call(self, *args):
        return subprocess.run(["bash", "scripts/sparkle-release-signing.sh", *args],
                              cwd=self.root, env=self.environment, capture_output=True, text=True)

    def calls(self):
        log = self.root / "signer.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_keychain_account_checks_public_key_without_exporting_private_data(self):
        result = self.call("check-key")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matches", result.stdout)
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][:2], ["--account", ACCOUNT])
        self.assertTrue(calls[0]["empty_stdin"])

    def test_ci_environment_mode_passes_only_stdin_to_the_signer(self):
        self.environment.pop("SPARKLE_KEYCHAIN_ACCOUNT")
        # The mock's credential is public fixture data, not any private signing key.
        self.environment["SPARKLE_PRIVATE_ED_KEY"] = PUBLIC_KEY
        result = self.call("check-key")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(calls[0]["args"][:2], ["--ed-key-file", "-"])
        self.assertTrue(calls[0]["public_fixture_stdin"])
        self.assertNotIn(PUBLIC_KEY, calls[0]["args"])

    def test_two_authentication_modes_are_rejected_before_signing(self):
        self.environment["SPARKLE_PRIVATE_ED_KEY"] = PUBLIC_KEY
        result = self.call("check-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_archive_and_feed_signing_and_verification_use_the_selected_account(self):
        archive = self.root / "public-fixture.zip"
        feed = self.root / "public-fixture.xml"
        archive.write_bytes(b"")
        feed.write_bytes(b"")
        result = self.call("sign", str(archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), SIGNATURE)
        for action in ["sign-feed", "verify-feed"]:
            result = self.call(action, str(feed))
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 3)
        for call in self.calls():
            self.assertEqual(call["args"][:2], ["--account", ACCOUNT])
            self.assertTrue(call["empty_stdin"])
        subprocess.run(["swift", "Resources/ReleaseTools/VerifySignature.swift",
                        "--feed", PUBLIC_KEY, str(feed)], cwd=self.root, check=True, capture_output=True)

    def test_release_checks_keychain_key_before_starting_any_build(self):
        swiftw = self.root / "scripts/swiftw"
        swiftw.write_text("#!/bin/sh\nprintf 'build requested' > build-marker\nexit 73\n")
        swiftw.chmod(0o755)
        result = subprocess.run(["bash", "scripts/release.sh"], cwd=self.root,
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue((self.root / "build-marker").exists())

    def test_appcast_rejects_keychain_key_that_does_not_match_the_bundle(self):
        archive = self.root / "public-fixture.zip"
        archive.write_bytes(b"")
        app = self.root / "Fixture.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "SUPublicEDKey": "ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8="
        }))
        result = subprocess.run(["bash", "scripts/make-appcast.sh", str(archive), str(app)],
                                cwd=self.root, env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("does not match", result.stderr)
        self.assertFalse((self.root / "dist/appcast.xml").exists())

    def test_absent_or_denied_keychain_key_fails_without_forwarding_diagnostics(self):
        self.environment["MOCK_SIGNER_FAILURE"] = "1"
        result = self.call("check-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Keychain access", result.stderr)
        self.assertNotIn("MOCK_SENSITIVE_DIAGNOSTIC", result.stdout + result.stderr)
        self.assertEqual(list((self.root / ".build").glob("sparkle-key-check-*")), [])

    def test_mismatching_key_blocks_release_before_any_build(self):
        self.environment["SPARKLE_PUBLIC_ED_KEY"] = "ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8="
        swiftw = self.root / "scripts/swiftw"
        swiftw.write_text("#!/bin/sh\nprintf 'unexpected build' > build-marker\nexit 73\n")
        swiftw.chmod(0o755)
        result = subprocess.run(["bash", "scripts/release.sh"], cwd=self.root,
                                env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertFalse((self.root / "build-marker").exists())
        self.assertEqual(list((self.root / ".build").glob("sparkle-key-check-*")), [])

    def test_missing_signing_mode_fails_before_calling_signer(self):
        self.environment.pop("SPARKLE_KEYCHAIN_ACCOUNT")
        result = self.call("check-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_malformed_environment_key_is_not_logged_or_passed_to_signer(self):
        self.environment.pop("SPARKLE_KEYCHAIN_ACCOUNT")
        self.environment["SPARKLE_PRIVATE_ED_KEY"] = "MOCK_BAD_PRIVATE_VALUE_DO_NOT_LOG"
        result = self.call("check-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("MOCK_BAD_PRIVATE_VALUE", result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])

    def test_feed_signing_and_verification_failure_are_not_silent(self):
        self.environment["MOCK_SIGNER_FAILURE"] = "1"
        feed = self.root / "public-fixture.xml"
        feed.write_bytes(b"")
        for action in ["sign-feed", "verify-feed"]:
            result = self.call(action, str(feed))
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("MOCK_SENSITIVE_DIAGNOSTIC", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

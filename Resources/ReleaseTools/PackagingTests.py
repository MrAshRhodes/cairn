#!/usr/bin/env python3
"""Offline checks of Chromium-only packaging and the two-architecture feed rules with public fixtures.

Nothing here signs a release: archives hold only an Info.plist and signatures are the public RFC 8032 vector.
The real signing path is exercised once, with an ephemeral key, by ReleasePipelineTests.py.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import warnings
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "Resources/ReleaseTools"
PUBLIC_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
OTHER_PUBLIC_KEY = "ugn8YkRCxDuzUN63cb+sFMayO6As26BL/1FBbbUs9a8="
SIGNATURE = "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def environment(**changes):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("SPARKLE_", "APPLE_", "CAIRN_", "SIGNING_", "NOTARY_"))}
    env.update(VERSION="0.2.0", BUILD_NUMBER="7", ARCH="arm64", SIGNING_IDENTITY="-", SPARKLE_PUBLIC_ED_KEY=PUBLIC_KEY)
    env.update(changes)
    return {key: value for key, value in env.items() if value is not None}


def run(*command, env=None, timeout=300):
    return subprocess.run([str(part) for part in command], cwd=ROOT, env=env or environment(),
                          capture_output=True, text=True, timeout=timeout)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        directory = tempfile.TemporaryDirectory(dir=ROOT / ".build", prefix="packaging-")
        self.addCleanup(directory.cleanup)
        self.work = Path(directory.name)

    def configure(self, arch="arm64", **changes):
        app = Path(tempfile.mkdtemp(dir=self.work)) / "Cairn.app"
        (app / "Contents").mkdir(parents=True)
        result = run(sys.executable, TOOLS / "bundle.py", "configure", app, env=environment(ARCH=arch, **changes))
        return app, result

    def release_item(self, arch, version="0.2.0", build="7", name=None, public_key=PUBLIC_KEY, identity="-",
                     archived=None, **plist):
        """A fake archive and extracted app whose Info.plist comes from the real `bundle.py configure`."""
        app, result = self.configure(arch, VERSION=version, BUILD_NUMBER=build, SPARKLE_PUBLIC_ED_KEY=public_key,
                                     SIGNING_IDENTITY=identity)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        info.update(plist)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        archive = app.parent / (name or f"Cairn-{version}-{arch}.zip")
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("Cairn.app/Contents/Info.plist", plistlib.dumps(archived or info))
        return archive, app

    def pairs(self, *items):
        return [str(path) for item in items for path in item]

    def appcast(self, *arguments):
        return run(sys.executable, TOOLS / "appcast.py", *arguments)

    def valid_release(self):
        return self.release_item("arm64"), self.release_item("x86_64")

    def built_feed(self):
        arm64, x86_64 = self.valid_release()
        feed = self.work / "appcast.xml"
        # Pass the architectures out of order: the feed must still put arm64 first.
        result = self.appcast("build", feed, *(str(part) for item in (x86_64, arm64) for part in (*item, SIGNATURE)))
        self.assertEqual(result.returncode, 0, result.stderr)
        return feed, arm64, x86_64

    def test_configure_writes_chromium_for_each_architecture(self):
        for arch in ("arm64", "x86_64"):
            for switch in (None, "1"):
                with self.subTest(arch=arch, switch=switch):
                    app, result = self.configure(arch, CAIRN_WITH_CHROMIUM=switch)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                    self.assertEqual((info["CairnBrowserEngine"], info["CairnBuildArchitecture"]), ("chromium", arch))
                    self.assertEqual((info["SUPublicEDKey"], info["CairnSigningMode"], info["CFBundleVersion"]),
                                     (PUBLIC_KEY, "ad-hoc", "7"))
                    self.assertTrue(info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"])
                    self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
                    self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["http", "https"])
                    self.assertEqual(info["CFBundleDocumentTypes"][0]["LSItemContentTypes"], ["public.html", "public.xhtml"])
                    # Only WKWebView honoured this key and WebKit is gone.
                    self.assertNotIn("NSAppTransportSecurity", info)

    def test_signing_identity_selects_developer_id_mode(self):
        app, result = self.configure("x86_64", SIGNING_IDENTITY="Developer ID Application: Example (ABCDE12345)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads((app / "Contents/Info.plist").read_bytes())["CairnSigningMode"], "developer-id")

    def test_universal_other_architectures_and_the_webkit_switch_are_rejected(self):
        for label, changes, message in (
            ("universal", dict(ARCH="universal"), "single architecture"),
            ("unknown architecture", dict(ARCH="ppc64"), "ARCH must be arm64 or x86_64"),
            ("WebKit switch", dict(CAIRN_WITH_CHROMIUM="0"), "WebKit builds were removed"),
            ("invalid switch", dict(CAIRN_WITH_CHROMIUM="invalid"), "WebKit builds were removed"),
        ):
            with self.subTest(label):
                for command in (["configure", str(self.work / "Cairn.app")], ["check"]):
                    result = run(sys.executable, TOOLS / "bundle.py", *command, env=environment(**changes))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                script = run("scripts/bundle-app.sh", env=environment(**changes), timeout=120)
                self.assertNotEqual(script.returncode, 0)
                self.assertIn(message, script.stdout + script.stderr)

    def test_feed_has_one_item_per_architecture_with_arm64_first(self):
        feed, arm64, x86_64 = self.built_feed()
        first, second = ET.parse(feed).getroot().findall("./channel/item")
        for item, (archive, _), arch in ((first, arm64, "arm64"), (second, x86_64, "x86_64")):
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.get("url"),
                             f"https://github.com/mrashrhodes/cairn/releases/download/v0.2.0/Cairn-0.2.0-{arch}.zip")
            self.assertEqual(int(enclosure.get("length")), archive.stat().st_size)
            self.assertEqual(enclosure.get(f"{{{SPARKLE}}}edSignature"), SIGNATURE)
            self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "7")
            self.assertEqual(item.findtext(f"{{{SPARKLE}}}shortVersionString"), "0.2.0")
        self.assertEqual(first.findtext(f"{{{SPARKLE}}}hardwareRequirements"), "arm64")
        self.assertIsNone(second.find(f"{{{SPARKLE}}}hardwareRequirements"))
        self.assertEqual(first.findtext(f"{{{SPARKLE}}}minimumSystemVersion"),
                         second.findtext(f"{{{SPARKLE}}}minimumSystemVersion"))
        result = self.appcast("check-feed", feed, arm64[0], x86_64[0])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_inconsistent_or_incomplete_releases_are_rejected(self):
        arm64 = self.release_item("arm64")
        cases = {
            "only arm64": [arm64],
            "only x86_64": [self.release_item("x86_64")],
            "duplicate architecture": [arm64, self.release_item("arm64")],
            "different version": [arm64, self.release_item("x86_64", version="0.2.1")],
            "different build number": [arm64, self.release_item("x86_64", build="8")],
            "different bundle identifier": [arm64, self.release_item("x86_64", CFBundleIdentifier="com.example.other")],
            "different public key": [arm64, self.release_item("x86_64", public_key=OTHER_PUBLIC_KEY)],
            "different signing mode": [arm64, self.release_item("x86_64", identity="Developer ID Application: X (Y)")],
            "different minimum system": [arm64, self.release_item("x86_64", LSMinimumSystemVersion="99.0")],
            "WebKit engine": [arm64, self.release_item("x86_64", CairnBrowserEngine="webkit")],
            "file name names the other architecture": [arm64, self.release_item("x86_64", name="Cairn-0.2.0-arm64.zip")],
            "universal": [arm64, self.release_item("x86_64", name="Cairn-0.2.0-universal.zip",
                                                   CairnBuildArchitecture="universal")],
            "archive differs from the app": [arm64, self.release_item("x86_64", archived={"CFBundleVersion": "7"})],
            "non-numeric version": [arm64, self.release_item("x86_64", CFBundleShortVersionString="latest")],
        }
        for label, items in cases.items():
            with self.subTest(label):
                result = self.appcast("validate", *self.pairs(*items))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
                feed = self.work / "rejected.xml"
                built = self.appcast("build", feed, *(str(p) for item in items for p in (*item, SIGNATURE)))
                self.assertNotEqual(built.returncode, 0)
                self.assertFalse(feed.exists(), "a rejected release must not leave a feed behind")
        self.assertEqual(self.appcast("validate", *self.pairs(*self.valid_release())).returncode, 0)

    def test_the_configured_public_key_must_match_every_app(self):
        arm64, x86_64 = self.valid_release()
        result = run(sys.executable, TOOLS / "appcast.py", "validate", *self.pairs(arm64, x86_64),
                     env=environment(SPARKLE_PUBLIC_ED_KEY=OTHER_PUBLIC_KEY))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match SPARKLE_PUBLIC_ED_KEY", result.stderr)
        for bad in ("", "not base64!", "AAAA", "A" * 43 + "="):
            with self.subTest(bad=bad):
                result = run(sys.executable, TOOLS / "appcast.py", "validate", *self.pairs(arm64, x86_64),
                             env=environment(SPARKLE_PUBLIC_ED_KEY=bad))
                self.assertNotEqual(result.returncode, 0)

    def test_malformed_signatures_are_rejected(self):
        arm64, x86_64 = self.valid_release()
        for signature in ("", "short", "A" * 87 + "="):
            result = self.appcast("build", self.work / "bad.xml", *(str(p) for item in (arm64, x86_64)
                                                                       for p in (*item, signature)))
            self.assertNotEqual(result.returncode, 0, signature)

    def test_tampered_feeds_are_rejected(self):
        feed, arm64, x86_64 = self.built_feed()
        archives = (str(arm64[0]), str(x86_64[0]))

        def swap_order(channel, items):
            channel.remove(items[0])
            channel.append(items[0])

        def set_length(channel, items):
            items[0].find("enclosure").set("length", "1")

        def set_url(channel, items):
            items[1].find("enclosure").set("url", "https://example.com/Cairn-0.2.0-x86_64.zip")

        def drop_requirement(channel, items):
            items[0].remove(items[0].find(f"{{{SPARKLE}}}hardwareRequirements"))

        def restrict_intel(channel, items):
            ET.SubElement(items[1], f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"

        def drop_signature(channel, items):
            del items[1].find("enclosure").attrib[f"{{{SPARKLE}}}edSignature"]

        def drop_item(channel, items):
            channel.remove(items[1])

        for mutate in (swap_order, set_length, set_url, drop_requirement, restrict_intel, drop_signature, drop_item):
            with self.subTest(mutate.__name__):
                tree = ET.parse(feed)
                channel = tree.getroot().find("channel")
                mutate(channel, channel.findall("item"))
                altered = self.work / f"{mutate.__name__}.xml"
                tree.write(altered, encoding="utf-8", xml_declaration=True)
                result = self.appcast("check-feed", altered, *archives)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)

    def test_unsafe_archives_are_rejected_before_extraction(self):
        info = plistlib.dumps({"CFBundleVersion": "7"})

        def make(entries, symlink=None):
            archive = self.work / "Cairn-0.2.0-arm64.zip"
            archive.unlink(missing_ok=True)
            with zipfile.ZipFile(archive, "w") as zipped, warnings.catch_warnings():
                warnings.simplefilter("ignore")  # the duplicate-entry case is deliberate
                for name, data in entries:
                    zipped.writestr(name, data)
                if symlink:
                    link = zipfile.ZipInfo("Cairn.app/Contents/Frameworks/link")
                    link.external_attr = 0o120777 << 16
                    zipped.writestr(link, symlink)
            return archive

        good = [("Cairn.app/Contents/Info.plist", info)]
        self.assertEqual(self.appcast("check-archive", make(good)).returncode, 0)
        cases = {
            "path traversal": good + [("Cairn.app/../../evil", b"x")],
            "absolute path": good + [("/etc/evil", b"x")],
            "outside the app": good + [("Other/evil", b"x")],
            "duplicate entry": good + good,
            "escaping symbolic link": good,
            "no Info.plist": [("Cairn.app/Contents/Other", b"x")],
            "invalid Info.plist": [("Cairn.app/Contents/Info.plist", b"not a plist")],
        }
        for label, entries in cases.items():
            with self.subTest(label):
                archive = make(entries, "../../../outside" if label == "escaping symbolic link" else None)
                result = self.appcast("check-archive", archive)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
        self.assertNotEqual(self.appcast("check-archive", self.work / "Cairn-0.2.0-universal.zip").returncode, 0)

    def test_feed_trailer_verification_uses_the_rfc_vector_and_detects_tampering(self):
        fixture = self.work / "signature-fixture.xml"
        fixture.write_text(f"<!-- sparkle-signatures:\nedSignature: {SIGNATURE}\nlength: 0\n-->\n")
        verify = ["swift", TOOLS / "VerifySignature.swift", "--feed", PUBLIC_KEY, fixture]
        self.assertEqual(run(*verify).returncode, 0)
        fixture.write_text("tampered" + fixture.read_text())
        self.assertNotEqual(run(*verify).returncode, 0)

    def test_make_appcast_validates_input_and_never_echoes_secrets(self):
        archive, _ = self.release_item("arm64")
        feed = self.work / "out/appcast.xml"
        sentinel = "NOT-A-PRIVATE-KEY-DO-NOT-LOG"
        for label, arguments, changes in (
            ("malformed private key", [feed, archive], dict(SPARKLE_PRIVATE_ED_KEY=sentinel)),
            ("no signing mode", [feed, archive], {}),
            ("no archive", [feed], dict(SPARKLE_PRIVATE_ED_KEY=sentinel)),
            ("feed is not xml", [self.work / "feed.txt", archive], dict(SPARKLE_PRIVATE_ED_KEY=sentinel)),
        ):
            with self.subTest(label):
                result = run("scripts/make-appcast.sh", *arguments, env=environment(**changes))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(sentinel, result.stdout + result.stderr)
                self.assertFalse(feed.exists())


if __name__ == "__main__":
    unittest.main()

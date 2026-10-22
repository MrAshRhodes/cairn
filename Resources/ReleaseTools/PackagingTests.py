#!/usr/bin/env python3
"""Public-fixture metadata checks; this does not create signed releases."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

work = Path(sys.argv[1]) / "appcast-tests"
app = work / "Cairn.app"
contents = app / "Contents"
contents.mkdir(parents=True, exist_ok=True)
archive = work / "Cairn-0.1.0-universal.zip"
feed = work / "appcast.xml"
public_key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
signature = "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
environment = dict(os.environ, VERSION="0.1.0", BUILD_NUMBER="1", ARCH="universal",
                   SIGNING_IDENTITY="-", SPARKLE_PUBLIC_ED_KEY=public_key,
                   CAIRN_WITH_CHROMIUM="0",
                   CAIRN_ARCHIVE_SIGNATURE=signature)
subprocess.run([sys.executable, "Resources/ReleaseTools/bundle.py", "configure", str(app)],
               env=environment, check=True)
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["SUPublicEDKey"] == public_key
assert info["CairnSigningMode"] == "ad-hoc"
assert info["CairnBrowserEngine"] == "webkit"
assert info["CFBundleVersion"] == "1"
assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]
assert info["SUSignedFeedFailureExpirationInterval"] == 0
assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["http", "https"]
assert info["CFBundleDocumentTypes"][0]["LSItemContentTypes"] == ["public.html", "public.xhtml"]
assert info["NSAppTransportSecurity"] == {"NSAllowsArbitraryLoadsInWebContent": True}

chromium_environment = dict(environment, ARCH="arm64")
del chromium_environment["CAIRN_WITH_CHROMIUM"]
subprocess.run([sys.executable, "Resources/ReleaseTools/bundle.py", "configure", str(app)],
               env=chromium_environment, check=True)
assert plistlib.loads((contents / "Info.plist").read_bytes())["CairnBrowserEngine"] == "chromium"
invalid_engine = subprocess.run(
    [sys.executable, "Resources/ReleaseTools/bundle.py", "configure", str(app)],
    env=dict(environment, CAIRN_WITH_CHROMIUM="invalid"), capture_output=True)
assert invalid_engine.returncode != 0, "Invalid engine configuration must fail"
(contents / "Info.plist").write_bytes(plistlib.dumps(info))


def write_archive():
    with zipfile.ZipFile(archive, "w") as zipped:
        zipped.write(contents / "Info.plist", "Cairn.app/Contents/Info.plist")


def generate():
    return subprocess.run([sys.executable, "Resources/ReleaseTools/appcast.py",
                           str(archive), str(app), str(feed)], env=environment, capture_output=True)


write_archive()
assert generate().returncode == 0
item = ET.parse(feed).getroot().find("./channel/item")
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
enclosure = item.find("enclosure")
assert enclosure.get("url") == "https://github.com/mrashrhodes/cairn/releases/download/v0.1.0/Cairn-0.1.0-universal.zip"
assert enclosure.get(namespace + "edSignature") == signature
assert int(enclosure.get("length")) == archive.stat().st_size
assert item.find(namespace + "hardwareRequirements") is None
info["CairnBuildArchitecture"] = "arm64"
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
assert generate().returncode != 0, "Metadata mismatch must fail"
write_archive()
assert generate().returncode == 0
assert ET.parse(feed).getroot().find("./channel/item/" + namespace + "hardwareRequirements").text == "arm64"
info["CairnBuildArchitecture"] = "x86_64"
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
write_archive()
assert generate().returncode != 0, "Unsafe Intel-only feed must fail"

# Verify the exact Sparkle trailer format using the public RFC empty-message vector.
signed_fixture = work / "signature-fixture.xml"
signed_fixture.write_text(f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: 0\n-->\n")
verify = ["swift", "Resources/ReleaseTools/VerifySignature.swift", "--feed", public_key, str(signed_fixture)]
subprocess.run(verify, check=True)
signed_fixture.write_text("tampered" + signed_fixture.read_text())
assert subprocess.run(verify, capture_output=True).returncode != 0

# A malformed secret sentinel must never be echoed, even on errors.
sentinel = "NOT-A-PRIVATE-KEY-DO-NOT-LOG"
result = subprocess.run(["scripts/make-appcast.sh", str(archive), str(app), str(feed)],
                        env=dict(os.environ, SPARKLE_PRIVATE_ED_KEY=sentinel), capture_output=True)
assert result.returncode != 0 and sentinel.encode() not in result.stdout + result.stderr
print("Packaging metadata, architecture, feed tamper and secret-redaction checks passed.")

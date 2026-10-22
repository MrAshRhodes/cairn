#!/usr/bin/env python3
"""Authenticated two-architecture Sparkle feed for one Cairn release; no deltas or release-note content.

Chromium (CEF) builds are single-architecture, so a release is an arm64 and an x86_64 app with identical
versions. The feed has one item per architecture, arm64 first with the only hardware requirement Sparkle
supports (arm64); the unrestricted x86_64 item serves Intel Macs. Every value comes from a verified
Info.plist, never from the environment alone, and every inconsistency fails closed.

  appcast.py check-archive ARCHIVE
  appcast.py validate ARCHIVE APP [ARCHIVE APP]...
  appcast.py build FEED ARCHIVE APP SIGNATURE [ARCHIVE APP SIGNATURE]...   (needs SPARKLE_PUBLIC_ED_KEY)
  appcast.py check-feed FEED ARCHIVE [ARCHIVE]...
"""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import posixpath
import re
import sys
from urllib.parse import quote
import xml.etree.ElementTree as ET
from xml.parsers.expat import ExpatError
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ARCHITECTURES = ("arm64", "x86_64")  # feed order: Sparkle keeps the first eligible item of equal version
SIGNING_MODES = {"ad-hoc", "developer-id"}
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DOWNLOADS = "https://github.com/mrashrhodes/cairn/releases/download"
NUMERIC = r"[0-9]+(?:\.[0-9]+){0,2}"
ARCHIVE_NAME = re.compile(rf"Cairn-({NUMERIC})-({'|'.join(ARCHITECTURES)})\.zip")
ARCHIVE_ROOTS = ("Cairn.app", "__MACOSX")
ARCHIVE_INFO = "Cairn.app/Contents/Info.plist"


def fail(message):
    raise SystemExit(f"ERROR: {message}")


def public_key():
    key = os.environ.get("SPARKLE_PUBLIC_ED_KEY", "")
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError:
        decoded = b""
    if len(decoded) != 32 or not any(decoded) or base64.b64encode(decoded).decode() != key:
        fail("SPARKLE_PUBLIC_ED_KEY must encode a nonzero 32-byte Ed25519 public key")
    return key


def is_symlink(entry):
    return (entry.external_attr >> 28) == 0o12


def load_plist(data, label):
    try:
        info = plistlib.loads(data)
    except (ExpatError, ValueError):
        fail(f"{label}: Info.plist is not a valid property list")
    if not isinstance(info, dict):
        fail(f"{label}: Info.plist is not a dictionary")
    return info


def check_archive(archive):
    """Zip hygiene before extraction; returns the archived Info.plist and the (version, arch) in the file name."""
    match = ARCHIVE_NAME.fullmatch(archive.name)
    if not match:
        fail(f"{archive.name}: archives must be named Cairn-VERSION-ARCH.zip with ARCH {' or '.join(ARCHITECTURES)}")
    try:
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip() is not None:
                fail(f"{archive.name}: corrupt archive entry")
            entries = zipped.infolist()
            names = [entry.filename for entry in entries]
            if len(set(names)) != len(names):
                fail(f"{archive.name}: duplicate archive entries")
            for entry in entries:
                name = entry.filename
                parts = name.split("/")
                if (name.startswith("/") or "\\" in name or "\0" in name or ".." in parts
                        or parts[0] not in ARCHIVE_ROOTS):
                    fail(f"{archive.name}: unexpected archive path {name!r}")
                if is_symlink(entry) and parts[0] == "Cairn.app":
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(name), zipped.read(entry).decode()))
                    if target.startswith("/") or not (target == "Cairn.app" or target.startswith("Cairn.app/")):
                        fail(f"{archive.name}: symbolic link escapes the application: {name!r}")
            info = load_plist(zipped.read(ARCHIVE_INFO), archive.name)
    except (zipfile.BadZipFile, KeyError, UnicodeError, OSError):
        fail(f"{archive.name}: not a valid Cairn.app ZIP archive")
    return info, match.groups()


def validate(pairs):
    """Validate (archive, app) pairs as one release; returns release entries in feed order."""
    key = public_key()
    template = load_plist((ROOT / "Resources/Info.plist").read_bytes(), "Resources")
    entries = {}
    for archive, app in pairs:
        try:
            info = load_plist((app / "Contents/Info.plist").read_bytes(), archive.name)
        except OSError:
            fail(f"{archive.name}: the extracted application has no Info.plist")
        archived, (version, name_arch) = check_archive(archive)
        label = archive.name
        if info != archived:
            fail(f"{label}: archive metadata differs from the verified application")
        if info.get("CFBundleIdentifier") != template["CFBundleIdentifier"]:
            fail(f"{label}: unexpected bundle identifier")
        for field in ("CFBundleShortVersionString", "CFBundleVersion"):
            if not isinstance(info.get(field), str) or not re.fullmatch(NUMERIC, info[field]):
                fail(f"{label}: {field} must be a numeric version")
        if not isinstance(info.get("LSMinimumSystemVersion"), str) or not info["LSMinimumSystemVersion"]:
            fail(f"{label}: LSMinimumSystemVersion is missing")
        if info.get("CairnBrowserEngine") != "chromium":
            fail(f"{label}: not a Chromium build")
        arch = info.get("CairnBuildArchitecture")
        if arch not in ARCHITECTURES:
            fail(f"{label}: CairnBuildArchitecture must be one of {', '.join(ARCHITECTURES)}")
        if arch != name_arch or version != info["CFBundleShortVersionString"]:
            fail(f"{label}: file name does not match the application's version and architecture")
        if info.get("CairnSigningMode") not in SIGNING_MODES:
            fail(f"{label}: CairnSigningMode must be one of {', '.join(sorted(SIGNING_MODES))}")
        if info.get("SUPublicEDKey") != key:
            fail(f"{label}: the application's public update key does not match SPARKLE_PUBLIC_ED_KEY")
        if arch in entries:
            fail(f"{label}: duplicate {arch} archive")
        entries[arch] = {"archive": archive, "info": info}
    if set(entries) != set(ARCHITECTURES):
        fail(f"a release needs exactly one archive per architecture ({', '.join(ARCHITECTURES)}); "
             f"got {', '.join(sorted(entries)) or 'none'}")
    ordered = [entries[arch] for arch in ARCHITECTURES]
    for field in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion",
                  "CFBundleIdentifier", "CairnSigningMode"):
        if len({entry["info"][field] for entry in ordered}) != 1:
            fail(f"the architectures disagree on {field}")
    return ordered


def item_url(entry):
    version = entry["info"]["CFBundleShortVersionString"]
    return f"{DOWNLOADS}/v{quote(version)}/{quote(entry['archive'].name)}"


def build(feed, triples):
    entries = validate([(archive, app) for archive, app, _ in triples])
    signatures = {archive: signature for archive, _, signature in triples}
    for signature in signatures.values():
        try:
            valid = len(base64.b64decode(signature, validate=True)) == 64
        except ValueError:
            valid = False
        if not valid:
            fail("every archive needs a base64 Ed25519 signature")
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Cairn updates"
    ET.SubElement(channel, "link").text = "https://github.com/mrashrhodes/cairn"
    ET.SubElement(channel, "description").text = "Authenticated Cairn releases"
    published = format_datetime(datetime.now(timezone.utc), usegmt=True)
    for entry in entries:
        info = entry["info"]
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"Cairn {info['CFBundleShortVersionString']} ({info['CairnBuildArchitecture']})"
        ET.SubElement(item, "pubDate").text = published
        ET.SubElement(item, f"{{{SPARKLE}}}version").text = info["CFBundleVersion"]
        ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = info["CFBundleShortVersionString"]
        ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
        if info["CairnBuildArchitecture"] == "arm64":
            ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
        ET.SubElement(item, "enclosure", {
            "url": item_url(entry),
            "length": str(entry["archive"].stat().st_size),
            "type": "application/octet-stream",
            f"{{{SPARKLE}}}edSignature": signatures[entry["archive"]],
        })
    ET.indent(rss)
    feed.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)


def check_feed(feed, archives):
    """Re-read a (signed) feed and confirm it describes exactly these archives, arm64 first."""
    entries = []
    for archive in archives:
        info, (_, arch) = check_archive(archive)
        entries.append({"archive": archive, "info": dict(info, CairnBuildArchitecture=arch)})
    entries.sort(key=lambda entry: ARCHITECTURES.index(entry["info"]["CairnBuildArchitecture"]))
    if [entry["info"]["CairnBuildArchitecture"] for entry in entries] != list(ARCHITECTURES):
        fail("the feed must describe exactly one archive per architecture")
    items = ET.parse(feed).getroot().findall("./channel/item")
    if len(items) != len(entries):
        fail(f"the feed has {len(items)} items; expected {len(entries)}")
    for item, entry in zip(items, entries):
        info, arch = entry["info"], entry["info"]["CairnBuildArchitecture"]
        enclosure = item.find("enclosure")
        requirement = item.find(f"{{{SPARKLE}}}hardwareRequirements")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "") if enclosure is not None else ""
        try:
            signed = len(base64.b64decode(signature, validate=True)) == 64
        except ValueError:
            signed = False
        checks = (
            enclosure is not None and enclosure.get("url") == item_url(entry),
            enclosure is not None and enclosure.get("length") == str(entry["archive"].stat().st_size),
            signed,
            item.findtext(f"{{{SPARKLE}}}version") == info["CFBundleVersion"],
            item.findtext(f"{{{SPARKLE}}}shortVersionString") == info["CFBundleShortVersionString"],
            item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") == info["LSMinimumSystemVersion"],
            (requirement is not None and requirement.text == "arm64") if arch == "arm64" else requirement is None,
        )
        if not all(checks):
            fail(f"the feed item for {arch} does not match {entry['archive'].name}")


def main(arguments):
    command, rest = (arguments[0], arguments[1:]) if arguments else ("", [])
    paths = [Path(argument) for argument in rest]
    if command == "check-archive" and len(rest) == 1:
        check_archive(paths[0])
    elif command == "validate" and rest and len(rest) % 2 == 0:
        validate(list(zip(paths[::2], paths[1::2])))
    elif command == "build" and len(rest) >= 4 and (len(rest) - 1) % 3 == 0:
        build(paths[0], [(paths[i], paths[i + 1], rest[i + 2]) for i in range(1, len(rest), 3)])
    elif command == "check-feed" and len(rest) >= 2:
        check_feed(paths[0], paths[1:])
    else:
        fail("use check-archive ARCHIVE | validate (ARCHIVE APP)... | build FEED (ARCHIVE APP SIGNATURE)... "
             "| check-feed FEED ARCHIVE...")


if __name__ == "__main__":
    main(sys.argv[1:])

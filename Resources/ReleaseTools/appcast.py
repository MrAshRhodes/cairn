#!/usr/bin/env python3
"""A single stable release, no unsigned deltas or external release-note content."""
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import sys
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile

archive, app, feed = map(Path, sys.argv[1:])
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
with zipfile.ZipFile(archive) as zipped:
    archived_info = plistlib.loads(zipped.read("Cairn.app/Contents/Info.plist"))
if info != archived_info:
    raise SystemExit("ERROR: archive metadata differs from the signed application")
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Cairn updates"
ET.SubElement(channel, "link").text = "https://github.com/mrashrhodes/cairn"
ET.SubElement(channel, "description").text = "Authenticated Cairn releases"
item = ET.SubElement(channel, "item")
version = info["CFBundleShortVersionString"]
ET.SubElement(item, "title").text = f"Cairn {version}"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
ET.SubElement(item, f"{{{sparkle}}}version").text = info["CFBundleVersion"]
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = version
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
if info["CairnBuildArchitecture"] == "x86_64":
    raise SystemExit("ERROR: use a universal release; Sparkle has no Intel-only hardware requirement")
if info["CairnBuildArchitecture"] == "arm64":
    ET.SubElement(item, f"{{{sparkle}}}hardwareRequirements").text = info["CairnBuildArchitecture"]
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/mrashrhodes/cairn/releases/download/v{quote(version)}/{quote(archive.name)}",
    "length": str(archive.stat().st_size),
    "type": "application/octet-stream",
    f"{{{sparkle}}}edSignature": os.environ["CAIRN_ARCHIVE_SIGNATURE"],
})
ET.indent(rss)
feed.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)

#!/usr/bin/env python3
"""Assemble CEF into an existing app; does not download, sign or alter the main executable."""
import argparse
import pathlib
import platform
import plistlib
import shutil
import subprocess

from tool import ROOT, LOCK, identity, read_json, validate_lock

FRAMEWORK = "Chromium Embedded Framework.framework"
HELPERS = [("", ""), (" (Alerts)", ".alerts"), (" (GPU)", ".gpu"),
           (" (Plugin)", ".plugin"), (" (Renderer)", ".renderer")]


def architecture(path, expected):
    found = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    if found != [expected]:
        raise ValueError(f"{path}: expected single-architecture {expected}, found {found}")


def bundle(app, arch, configuration, helper=None):
    lock = validate_lock(read_json(LOCK))
    cef = ROOT / "engine/cef" / arch
    if read_json(cef / ".cairn-pin.json") != identity(lock["artifacts"][arch]):
        raise ValueError("Downloaded CEF does not match lock; run engine/tool.py fetch")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    main = app / "Contents/MacOS" / info["CFBundleExecutable"]
    helper = helper or ROOT / ".build" / configuration / "CairnHelper"
    source = cef / "Release" / FRAMEWORK
    for binary in [main, helper, source / "Chromium Embedded Framework"]:
        architecture(binary, arch)
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    target = frameworks / FRAMEWORK
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target / "Versions/A", symlinks=True)
    for name in ["Chromium Embedded Framework", "Libraries", "Resources"]:
        (target / name).symlink_to(f"Versions/A/{name}")
    (target / "Versions/Current").symlink_to("A")
    for suffix, identifier in HELPERS:
        name = "Cairn Helper" + suffix
        contents = frameworks / (name + ".app") / "Contents"
        (contents / "MacOS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(helper, contents / "MacOS" / name)
        plist = {
            "CFBundleExecutable": name, "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": info["CFBundleIdentifier"] + ".helper" + identifier,
            "CFBundleVersion": info.get("CFBundleVersion", "1"),
            "CFBundleShortVersionString": info.get("CFBundleShortVersionString", "0.1"),
            "LSUIElement": True, "LSMinimumSystemVersion": info.get("LSMinimumSystemVersion", "14.0"),
        }
        # Capture runs in these helper processes; the prompt macOS shows names the main app.
        for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
            if key in info:
                plist[key] = info[key]
        (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(LOCK, resources / "cef.lock.json")
    shutil.copy2(cef / "LICENSE.txt", resources / "CEF-LICENSE.txt")
    print(f"Bundled CEF {lock['cef_version']} ({arch}). Sign nested code and app before distribution.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default=platform.machine())
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--helper", type=pathlib.Path, help="Matching helper from SwiftPM's --show-bin-path")
    args = parser.parse_args()
    bundle(args.app.resolve(), args.arch, args.configuration, args.helper)

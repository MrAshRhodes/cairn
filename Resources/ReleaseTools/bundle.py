#!/usr/bin/env python3
"""Materialize and validate Cairn's native application bundle."""
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise SystemExit(f"ERROR: {message}")


def configure(app):
    version = os.environ["VERSION"]
    build = os.environ["BUILD_NUMBER"]
    for label, value in (("VERSION", version), ("BUILD_NUMBER", build)):
        require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), f"{label} must be a numeric version")
    key = os.environ.get("SPARKLE_PUBLIC_ED_KEY", "")
    if key:
        try:
            decoded = base64.b64decode(key, validate=True)
        except ValueError:
            raise SystemExit("ERROR: SPARKLE_PUBLIC_ED_KEY must be base64")
        require(len(decoded) == 32 and any(decoded) and base64.b64encode(decoded).decode() == key,
                "SPARKLE_PUBLIC_ED_KEY must encode a nonzero 32-byte Ed25519 public key")
    else:
        print("NOTICE: no public update key. Check for Updates will explain why updates are disabled.")
    with Path("Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for name, value in info.items():
        if isinstance(value, str):
            info[name] = (value.replace("@CAIRN_VERSION@", version)
                          .replace("@CAIRN_BUILD_NUMBER@", build)
                          .replace("@SPARKLE_PUBLIC_ED_KEY@", key))
    info["CairnBuildArchitecture"] = os.environ["ARCH"]
    info["CairnSigningMode"] = "ad-hoc" if os.environ["SIGNING_IDENTITY"] == "-" else "developer-id"
    chromium = os.environ.get("CAIRN_WITH_CHROMIUM", "1")
    require(chromium in {"0", "1"}, "CAIRN_WITH_CHROMIUM must be 0 or 1")
    info["CairnBrowserEngine"] = "chromium" if chromium == "1" else "webkit"
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


def portable_rpaths(app):
    executable = app / "Contents/MacOS/Cairn"
    commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    paths = re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset", commands)
    for path in set(paths):
        if path.startswith("/") and path != "/usr/lib/swift":
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(executable)], check=True)


def verify(app):
    executable = app / "Contents/MacOS/Cairn"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    wanted = info["CairnBuildArchitecture"]
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    require(set(architectures) == ({"arm64", "x86_64"} if wanted == "universal" else {wanted}),
            "bundle architectures do not match ARCH")
    loads = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    require("@rpath/Sparkle.framework/Versions/B/Sparkle" in loads, "Sparkle is not dynamically linked")
    commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    require("@executable_path/../Frameworks" in commands, "app-relative framework rpath is missing")
    for path in re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset", commands):
        require(not path.startswith("/") or path == "/usr/lib/swift", f"nonportable rpath: {path}")
    for line in loads.splitlines():
        if " (compatibility version " not in line:
            continue
        dependency = line.strip().split(" (")[0]
        if dependency.startswith("/"):
            require(dependency.startswith(("/System/Library/", "/usr/lib/")), f"nonportable link: {dependency}")
    framework = app / "Contents/Frameworks/Sparkle.framework"
    require((framework / "Versions/Current").is_symlink(), "Sparkle symlinks were not preserved")
    require((framework / "Sparkle").is_file(), "Sparkle runtime binary is missing")
    require((app / "Contents/Resources/Cairn.icns").is_file(), "app icon is missing")
    if info["CairnBrowserEngine"] == "chromium":
        cef = app / "Contents/Frameworks/Chromium Embedded Framework.framework"
        require((cef / "Chromium Embedded Framework").is_file(), "Chromium runtime binary is missing")
        for suffix in ["", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)"]:
            name = "Cairn Helper" + suffix
            helper = app / "Contents/Frameworks" / (name + ".app")
            require((helper / "Contents/MacOS" / name).is_file(), f"{name} executable is missing")
        for name in ["cef.lock.json", "CEF-LICENSE.txt"]:
            require((app / "Contents/Resources" / name).is_file(), f"Chromium resource is missing: {name}")
    subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
    print(f"Verified {info['CairnBrowserEngine']} bundle, {wanted} executable, Sparkle linkage and relative rpath.")


if __name__ == "__main__":
    require(len(sys.argv) == 3 and sys.argv[1] in {"configure", "rpaths", "verify"}, "use configure|rpaths|verify APP")
    {"configure": configure, "rpaths": portable_rpaths, "verify": verify}[sys.argv[1]](Path(sys.argv[2]))

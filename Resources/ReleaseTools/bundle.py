#!/usr/bin/env python3
"""Materialize and validate Cairn's native application bundle (Chromium is the only engine)."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ARCHITECTURES = ("arm64", "x86_64")
FRAMEWORK = "Chromium Embedded Framework.framework"
HELPER_SUFFIXES = ("", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)")


def require(condition, message):
    if not condition:
        raise SystemExit(f"ERROR: {message}")


def check_engine_selection():
    # The old WebKit/Chromium switch survives only as an accepted no-op spelling of "Chromium".
    require(os.environ.get("CAIRN_WITH_CHROMIUM", "") in {"", "1"},
            "WebKit builds were removed; Chromium is the only engine. Unset CAIRN_WITH_CHROMIUM (or set it to 1).")


def check_architecture(arch):
    require(arch != "universal",
            "Chromium packaging requires a single architecture: universal bundles are not supported. "
            "Build arm64 and x86_64 separately.")
    require(arch in ARCHITECTURES, "ARCH must be arm64 or x86_64")
    return arch


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def check_engine(arch):
    """Fail fast, before any compilation, unless the pinned CEF is prepared for exactly this arch."""
    check_architecture(arch)
    pin = ((read_json(ROOT / "engine/cef.lock.json") or {}).get("artifacts") or {}).get(arch)
    # The markers record name, sha1 and size; a SHA-256 added to the lock later must not invalidate a prepared tree.
    identity = {key: pin.get(key) for key in ("name", "sha1", "size")} if pin else None
    cef = ROOT / "engine/cef" / arch
    build = ROOT / "engine/.cache" / f"build-{arch}"
    prepared = (identity is not None and read_json(cef / ".cairn-pin.json") == identity
                and read_json(build / ".cairn-pin.json") == identity
                and (cef / "Release" / FRAMEWORK / "Chromium Embedded Framework").is_file()
                and (build / "libcef_dll_wrapper/libcef_dll_wrapper.a").is_file())
    require(prepared, f"Chromium (CEF) is not prepared for {arch} or does not match engine/cef.lock.json. "
            f"Run: python3 engine/tool.py fetch --arch {arch} && python3 engine/tool.py build --arch {arch} "
            "(make cef prepares the host architecture). Nothing is downloaded implicitly.")
    print(f"Chromium (CEF) is prepared for {arch}.")


def check_public_key():
    key = os.environ.get("SPARKLE_PUBLIC_ED_KEY", "")
    if key:
        try:
            decoded = base64.b64decode(key, validate=True)
        except ValueError:
            raise SystemExit("ERROR: SPARKLE_PUBLIC_ED_KEY must be base64")
        require(len(decoded) == 32 and any(decoded) and base64.b64encode(decoded).decode() == key,
                "SPARKLE_PUBLIC_ED_KEY must encode a nonzero 32-byte Ed25519 public key")
    return key


def check_environment():
    """Everything `configure` takes from the environment, so callers can fail before a long build."""
    check_engine_selection()
    arch = check_architecture(os.environ.get("ARCH", ""))
    version, build = os.environ.get("VERSION", ""), os.environ.get("BUILD_NUMBER", "")
    for label, value in (("VERSION", version), ("BUILD_NUMBER", build)):
        require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), f"{label} must be a numeric version")
    return arch, version, build, check_public_key()


def configure(app):
    arch, version, build, key = check_environment()
    if not key:
        print("NOTICE: no public update key. Check for Updates will explain why updates are disabled.")
    with Path("Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    for name, value in info.items():
        if isinstance(value, str):
            info[name] = (value.replace("@CAIRN_VERSION@", version)
                          .replace("@CAIRN_BUILD_NUMBER@", build)
                          .replace("@SPARKLE_PUBLIC_ED_KEY@", key))
    info["CairnBuildArchitecture"] = arch
    info["CairnSigningMode"] = "ad-hoc" if os.environ["SIGNING_IDENTITY"] == "-" else "developer-id"
    info["CairnBrowserEngine"] = "chromium"
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


def portable_rpaths(app):
    executable = app / "Contents/MacOS/Cairn"
    commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    paths = re.findall(r"cmd LC_RPATH\n.*?\n\s*path (.*?) \(offset", commands)
    for path in set(paths):
        if path.startswith("/") and path != "/usr/lib/swift":
            subprocess.run(["install_name_tool", "-delete_rpath", path, str(executable)], check=True)


def single_architecture(binary):
    return subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()


def verify(app):
    executable = app / "Contents/MacOS/Cairn"
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CairnBrowserEngine") == "chromium", "bundle is not a Chromium build")
    wanted = check_architecture(info.get("CairnBuildArchitecture", ""))
    require(single_architecture(executable) == [wanted], "bundle architecture does not match ARCH")
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
    cef = app / "Contents/Frameworks" / FRAMEWORK
    require((cef / "Chromium Embedded Framework").is_file(), "Chromium runtime binary is missing")
    require(single_architecture(cef / "Chromium Embedded Framework") == [wanted],
            "Chromium runtime architecture does not match ARCH")
    for suffix in HELPER_SUFFIXES:
        name = "Cairn Helper" + suffix
        helper = app / "Contents/Frameworks" / (name + ".app") / "Contents/MacOS" / name
        require(helper.is_file(), f"{name} executable is missing")
        require(single_architecture(helper) == [wanted], f"{name} architecture does not match ARCH")
    for name in ["cef.lock.json", "CEF-LICENSE.txt"]:
        require((app / "Contents/Resources" / name).is_file(), f"Chromium resource is missing: {name}")
    subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
    print(f"Verified chromium bundle, {wanted} executable, Sparkle linkage and relative rpath.")


COMMANDS = {"configure": configure, "rpaths": portable_rpaths, "verify": verify}
USAGE = "use check | engine ARCH | configure|rpaths|verify APP"

if __name__ == "__main__":
    arguments = sys.argv[1:]
    if arguments == ["check"]:
        check_environment()
    elif len(arguments) == 2 and arguments[0] == "engine":
        check_engine(arguments[1])
    else:
        require(len(arguments) == 2 and arguments[0] in COMMANDS, USAGE)
        COMMANDS[arguments[0]](Path(arguments[1]))

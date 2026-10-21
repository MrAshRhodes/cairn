#!/usr/bin/env python3
"""Explicit, dependency-free CEF maintenance. Never invoked by the default build."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = "https://cef-builds.spotifycdn.com/index.json"
CHROME = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1"
BASE = "https://cef-builds.spotifycdn.com/"
PLATFORMS = {"arm64": "macosarm64", "x86_64": "macosx64"}
LOCK = ROOT / "engine/cef.lock.json"


def read_json(source):
    if str(source).startswith("https://"):
        with urllib.request.urlopen(source, timeout=60) as response:
            return json.load(response)
    return json.loads(pathlib.Path(source).read_text())


def version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", value):
        raise ValueError(f"Invalid Chromium version: {value!r}")
    return tuple(map(int, value.split(".")))


def validate_lock(lock):
    if lock["schema"] != 1 or lock["channel"] != "stable":
        raise ValueError("Only schema 1 stable pins are accepted")
    version(lock["chromium_version"])
    if not re.fullmatch(r"[\d.]+\+g[0-9a-f]+\+chromium-[\d.]+", lock["cef_version"]):
        raise ValueError("Invalid CEF version")
    if lock["cef_version"].split("+chromium-")[1] != lock["chromium_version"]:
        raise ValueError("CEF and Chromium versions disagree")
    for arch, platform_name in PLATFORMS.items():
        artifact = lock["artifacts"][arch]
        expected = f"cef_binary_{lock['cef_version']}_{platform_name}_minimal.tar.bz2"
        if artifact["name"] != expected or not re.fullmatch("[0-9a-f]{40}", artifact["sha1"]):
            raise ValueError(f"Invalid locked artifact for {arch}")
        if not isinstance(artifact["size"], int) or artifact["size"] <= 0:
            raise ValueError("Invalid archive size")
        if "sha256" in artifact and not re.fullmatch("[0-9a-f]{64}", artifact["sha256"]):
            raise ValueError("Invalid SHA-256")
    return lock


def select_pin(index):
    candidates = {}
    for arch, platform_name in PLATFORMS.items():
        candidates[arch] = {
            row["cef_version"]: row for row in index[platform_name]["versions"]
            if row.get("channel") == "stable" and any(f["type"] == "minimal" for f in row["files"])
        }
    common = set.intersection(*(set(rows) for rows in candidates.values()))
    if not common:
        raise ValueError("No stable CEF version is published for both macOS architectures")
    latest = max(common, key=lambda key: (
        version(candidates["arm64"][key]["chromium_version"]),
        tuple(map(int, key.split("+")[0].split("."))),
    ))
    pin = {"schema": 1, "channel": "stable", "cef_version": latest,
           "chromium_version": candidates["arm64"][latest]["chromium_version"], "artifacts": {}}
    for arch, rows in candidates.items():
        if rows[latest]["chromium_version"] != pin["chromium_version"]:
            raise ValueError("Architecture version mismatch")
        artifact = next(f for f in rows[latest]["files"] if f["type"] == "minimal")
        pin["artifacts"][arch] = {k: artifact[k] for k in ("name", "sha1", "size")}
    return validate_lock(pin)


def assess(current, latest, chrome):
    stable = max((row["version"] for row in chrome), key=version)
    return {
        "pinned_cef": current["cef_version"], "pinned_chromium": current["chromium_version"],
        "latest_stable_cef": latest["cef_version"], "latest_cef_chromium": latest["chromium_version"],
        "chrome_stable": stable,
        "update_available": (
            version(latest["chromium_version"]) >= version(current["chromium_version"])
            and latest["cef_version"] != current["cef_version"]
            and tuple(map(int, latest["cef_version"].split("+")[0].split(".")))
            > tuple(map(int, current["cef_version"].split("+")[0].split(".")))
        ),
        "security_gap": version(current["chromium_version"]) < version(stable),
        "upstream_security_gap": version(latest["chromium_version"]) < version(stable),
    }


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_archive(path, artifact):
    if path.stat().st_size != artifact["size"]:
        raise ValueError("Archive size does not match lock")
    for algorithm in ("sha1", "sha256"):
        if algorithm in artifact and digest(path, algorithm) != artifact[algorithm]:
            raise ValueError(f"Archive {algorithm} does not match lock")


def extract_archive(archive, destination, top):
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("Safe extraction requires Python 3.12+ or a Python with backported tarfile.data_filter")
    with tarfile.open(archive, "r:bz2") as tar:
        for item in tar.getmembers():
            name = pathlib.PurePosixPath(item.name)
            if not name.parts or name.is_absolute() or ".." in name.parts or name.parts[0] != top:
                raise ValueError("Unsafe archive path")
            if not (item.isfile() or item.isdir() or item.issym() or item.islnk()):
                raise ValueError("Unsafe archive member type")
            if item.issym() or item.islnk():
                base = name.parent if item.issym() else pathlib.PurePosixPath()
                target = pathlib.PurePosixPath(os.path.normpath(str(base / item.linkname)))
                if target.is_absolute() or ".." in target.parts or target.parts[0] != top:
                    raise ValueError("Unsafe archive link")
        tar.extractall(destination, filter="data")


def fetch(lock, arch):
    artifact = lock["artifacts"][arch]
    cache = ROOT / "engine/.cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / artifact["name"]
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        try:
            with urllib.request.urlopen(BASE + urllib.parse.quote(artifact["name"]), timeout=120) as src:
                with partial.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
            verify_archive(partial, artifact)
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    verify_archive(archive, artifact)
    target = ROOT / "engine/cef" / arch
    marker = target / ".cairn-pin.json"
    if marker.exists() and read_json(marker) == artifact:
        print(f"Verified cached CEF: {target}")
        return
    top = artifact["name"].removesuffix(".tar.bz2")
    extracted = cache / top
    if extracted.exists():
        shutil.rmtree(extracted)
    extract_archive(archive, cache, top)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        shutil.rmtree(target)
    extracted.replace(target)
    marker.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"Verified CEF {arch}; SHA-256 {digest(archive, 'sha256')}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "update", "fetch", "build"])
    parser.add_argument("--arch", choices=PLATFORMS, default=platform.machine())
    parser.add_argument("--index", default=INDEX, help="HTTPS index or offline fixture")
    parser.add_argument("--chrome", default=CHROME, help="HTTPS releases or offline fixture")
    parser.add_argument("--lock", type=pathlib.Path, default=LOCK)
    parser.add_argument("--report", type=pathlib.Path)
    parser.add_argument("--fail-on-gap", action="store_true")
    args = parser.parse_args()
    current = validate_lock(read_json(args.lock))
    if args.command in ("check", "update"):
        latest = select_pin(read_json(args.index))
        result = assess(current, latest, read_json(args.chrome))
        if args.command == "update" and result["update_available"]:
            args.lock.write_text(json.dumps(latest, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        if args.report:
            args.report.write_text(json.dumps(result, indent=2) + "\n")
        if result["security_gap"]:
            print("SECURITY GAP: pinned CEF Chromium is older than Chrome stable; "
                  "version comparison is not a CVE/backport audit.", file=sys.stderr)
        if args.fail_on_gap and result["security_gap"]:
            return 2
    elif args.command == "fetch":
        fetch(current, args.arch)
    else:
        if sys.platform != "darwin":
            raise ValueError("CEF wrapper build requires macOS")
        cef = ROOT / "engine/cef" / args.arch
        if not (cef / ".cairn-pin.json").exists() or read_json(cef / ".cairn-pin.json") != current["artifacts"][args.arch]:
            raise ValueError("Run engine/tool.py fetch for the locked architecture first")
        build = ROOT / "engine/.cache" / f"build-{args.arch}"
        marker = build / ".cairn-pin.json"
        if build.exists() and (not marker.exists() or read_json(marker) != current["artifacts"][args.arch]):
            shutil.rmtree(build)
        subprocess.run(["cmake", "-S", str(ROOT / "engine"), "-B", str(build),
                        "-G", "Unix Makefiles", f"-DCEF_ROOT={cef}", "-DCMAKE_BUILD_TYPE=Release",
                        f"-DCMAKE_OSX_ARCHITECTURES={args.arch}", "-DUSE_SANDBOX=ON"], check=True)
        subprocess.run(["cmake", "--build", str(build), "--parallel", "4"], check=True)
        marker.write_text(json.dumps(current["artifacts"][args.arch], indent=2) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"engine: {error}", file=sys.stderr)
        sys.exit(1)

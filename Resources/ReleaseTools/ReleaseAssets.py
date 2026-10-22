#!/usr/bin/env python3
"""Per-architecture release records and the finalized release file set; never signs or uploads anything.

  ReleaseAssets.py record --app APP --zip ZIP --dmg DMG --notarized true|false --output RECORD.json
      Describe one architecture's built and hashed assets (run by scripts/release.sh).
  ReleaseAssets.py validate DIR [--version VERSION] [--chromium-gate GATE.json]
      Require exactly both architectures' Cairn-VERSION-ARCH.{zip,dmg,json}, intact and mutually
      consistent (and, with --chromium-gate, a valid gate record for the built Chromium); prints the
      version. Run by scripts/finalize-release.sh before anything is signed.
  ReleaseAssets.py publish DIR --chromium-gate GATE.json
      Once appcast.xml exists, write RELEASE-INFO.json, RELEASE-NOTES.txt and SHA256SUMS.
"""
import argparse
import datetime
import functools
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
GATE_MAX_AGE = datetime.timedelta(hours=24)
ARCHITECTURES = ("arm64", "x86_64")
SIGNING = {"ad-hoc": "ad-hoc", "developer-id": "Developer ID"}
NUMERIC = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")
SHA256 = re.compile(r"[0-9a-f]{64}")
COMMIT = re.compile(r"[0-9a-f]{40}")
SCHEMA = 1
RECORD_KEYS = {"schema", "version", "build", "architecture", "signing", "notarized", "engine", "commit", "assets"}
FINAL_OUTPUTS = ("appcast.xml", "RELEASE-INFO.json", "RELEASE-NOTES.txt", "SHA256SUMS")
RECORD_NAME = re.compile(rf"Cairn-({NUMERIC.pattern})-({'|'.join(ARCHITECTURES)})\.json")


@functools.lru_cache(maxsize=None)
def load_gate():
    spec = importlib.util.spec_from_file_location("chromium_gate", HERE / "ChromiumGate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def file_names(version, arch):
    return {"zip": f"Cairn-{version}-{arch}.zip", "dmg": f"Cairn-{version}-{arch}.dmg",
            "json": f"Cairn-{version}-{arch}.json"}


def record_architecture(name):
    match = RECORD_NAME.fullmatch(name)
    return match.group(2) if match else None


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(block)
    return checksum.hexdigest()


def describe_file(path):
    return {"name": path.name, "sha256": digest(path), "size": path.stat().st_size}


def source_commit():
    try:
        value = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
                               check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return value if COMMIT.fullmatch(value) else None


def validate_record(data):
    """Strictly validate one architecture's record; returns it or raises ValueError."""
    try:
        return _validate_record(data)
    except (TypeError, KeyError, AttributeError) as error:
        raise ValueError(f"malformed release record ({type(error).__name__})") from error


def _validate_record(data):
    gate = load_gate()
    if not isinstance(data, dict) or set(data) != RECORD_KEYS or data["schema"] != SCHEMA:
        raise ValueError("unrecognized release record")
    for field in ("version", "build"):
        if not isinstance(data[field], str) or not NUMERIC.fullmatch(data[field]):
            raise ValueError(f"release record {field} must be a numeric version")
    if data["architecture"] not in ARCHITECTURES:
        raise ValueError(f"release record architecture must be one of {', '.join(ARCHITECTURES)}")
    if data["signing"] not in SIGNING or not isinstance(data["notarized"], bool):
        raise ValueError("release record has an invalid signing state")
    if data["notarized"] and data["signing"] != "developer-id":
        raise ValueError("only Developer ID builds can be notarized")
    engine = data["engine"]
    if (not isinstance(engine, dict) or set(engine) != {"name", "cef", "chromium"} or engine["name"] != "chromium"
            or not isinstance(engine["cef"], str) or not gate.CEF_VERSION.fullmatch(engine["cef"])
            or not isinstance(engine["chromium"], str) or not gate.CHROMIUM_VERSION.fullmatch(engine["chromium"])):
        raise ValueError("release record has an invalid engine")
    if data["commit"] is not None and not (isinstance(data["commit"], str) and COMMIT.fullmatch(data["commit"])):
        raise ValueError("release record has an invalid commit")
    names = file_names(data["version"], data["architecture"])
    assets = data["assets"]
    if not isinstance(assets, dict) or set(assets) != {"zip", "dmg"}:
        raise ValueError("release record needs exactly a zip and a dmg asset")
    for kind, asset in assets.items():
        if (not isinstance(asset, dict) or set(asset) != {"name", "sha256", "size"} or asset["name"] != names[kind]
                or not isinstance(asset["sha256"], str) or not SHA256.fullmatch(asset["sha256"])
                or type(asset["size"]) is not int or asset["size"] <= 0):
            raise ValueError(f"release record has an invalid {kind} asset")
    return data


def record(app, archive, image, notarized, output):
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        lock = json.loads((app / "Contents/Resources/cef.lock.json").read_text())
        data = {
            "schema": SCHEMA, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "architecture": info["CairnBuildArchitecture"], "signing": info["CairnSigningMode"],
            "notarized": notarized,
            "engine": {"name": info["CairnBrowserEngine"], "cef": lock["cef_version"],
                       "chromium": lock["chromium_version"]},
            "commit": source_commit(),
            "assets": {"zip": describe_file(archive), "dmg": describe_file(image)},
        }
    except (OSError, KeyError, ValueError) as error:
        raise ValueError(f"cannot describe {app}: {type(error).__name__}: {error}") from error
    validate_record(data)
    if output.name != file_names(data["version"], data["architecture"])["json"]:
        raise ValueError(f"the record must be named {file_names(data['version'], data['architecture'])['json']}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n")
    return data


def load_release(directory, version=None, allowed=()):
    """The exact, intact, consistent two-architecture file set in DIRECTORY, as {arch: record}."""
    if not directory.is_dir():
        raise ValueError(f"{directory} is not a directory")
    entries = {entry.name: entry for entry in directory.iterdir()}
    records = {}
    for arch in ARCHITECTURES:
        candidates = [name for name in entries if record_architecture(name) == arch]
        if len(candidates) != 1:
            raise ValueError(f"expected exactly one Cairn-VERSION-{arch}.json in {directory}, found {len(candidates)}")
        try:
            data = validate_record(json.loads(entries[candidates[0]].read_text()))
        except (OSError, ValueError) as error:
            raise ValueError(f"{candidates[0]}: {error}") from error
        if data["architecture"] != arch or file_names(data["version"], arch)["json"] != candidates[0]:
            raise ValueError(f"{candidates[0]} does not describe its own file name")
        records[arch] = data
    first, second = (records[arch] for arch in ARCHITECTURES)
    for field in ("version", "build", "signing", "notarized", "commit", "engine"):
        if first[field] != second[field]:
            raise ValueError(f"the architectures disagree on {field}")
    if version is not None and first["version"] != version:
        raise ValueError(f"the built version {first['version']} is not the expected {version}")
    expected = {name for data in records.values() for name in file_names(data["version"], data["architecture"]).values()}
    unexpected = sorted(set(entries) - expected - set(allowed))
    missing = sorted(expected - set(entries))
    if unexpected or missing:
        raise ValueError(f"{directory} must contain exactly both architectures' assets"
                         + (f"; unexpected: {', '.join(unexpected)}" if unexpected else "")
                         + (f"; missing: {', '.join(missing)}" if missing else ""))
    for name in sorted(set(entries) & (expected | set(allowed))):
        if entries[name].is_symlink() or not entries[name].is_file():
            raise ValueError(f"{name} must be a regular file")
    for data in records.values():
        for asset in data["assets"].values():
            if describe_file(directory / asset["name"]) != asset:
                raise ValueError(f"{asset['name']} does not match its recorded size and SHA-256")
    return records


def notes(version, engine, signing, notarized, gate_lines):
    notice = "Notarized by Apple." if notarized else "NOT notarized by Apple."
    return "\n".join([
        f"Cairn {version} (macOS, Apple silicon and Intel)", "",
        f"Engine: Chromium {engine['chromium']} (CEF {engine['cef']}).",
        f"Apple signing: {SIGNING[signing]}. {notice}",
        f"Downloads: {file_names(version, 'arm64')['dmg']} (Apple silicon) and "
        f"{file_names(version, 'x86_64')['dmg']} (Intel), or the matching ZIPs.",
        "The ZIPs and appcast have verified Sparkle Ed25519 signatures.",
        "Ad-hoc builds have no Apple Gatekeeper trust. Prefer a Developer ID notarized release for distribution.",
        "", *gate_lines, ""])


def load_gate_record(path, engine):
    """The validated Chromium gate record at PATH; it must have assessed exactly the Chromium that was built."""
    try:
        record = load_gate().validate_record(json.loads(path.read_text()))
    except (OSError, ValueError) as error:
        raise ValueError(f"Chromium gate record {path}: {error}") from error
    if record["engine"] != {"cef": engine["cef"], "chromium": engine["chromium"]}:
        raise ValueError("the built Chromium does not match the Chromium the release gate assessed")
    checked = datetime.datetime.strptime(record["checked_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    age = datetime.datetime.now(datetime.timezone.utc) - checked
    if age > GATE_MAX_AGE or age < -datetime.timedelta(minutes=5):
        raise ValueError("the Chromium gate record is stale; rerun the release so the gate is re-evaluated")
    return record


def publish(directory, gate_path):
    records = load_release(directory, allowed=FINAL_OUTPUTS)
    appcast = directory / "appcast.xml"
    if not appcast.is_file() or appcast.is_symlink() or appcast.stat().st_size == 0:
        raise ValueError("appcast.xml is missing or empty; run make-appcast.sh first")
    first = records["arm64"]
    gate_record = load_gate_record(gate_path, first["engine"])
    version = first["version"]
    assets = [dict(data["assets"][kind], architecture=arch, kind=kind)
              for arch, data in sorted(records.items()) for kind in ("zip", "dmg")]
    assets.append(dict(describe_file(appcast), kind="appcast"))
    info = {
        "version": version, "build": first["build"], "architectures": list(ARCHITECTURES),
        "engine": first["engine"], "signing": SIGNING[first["signing"]], "notarized": first["notarized"],
        "sparkle": "Ed25519 archive and feed", "commit": first["commit"], "assets": assets,
        "chromium_gate": gate_record,
    }
    (directory / "RELEASE-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
    (directory / "RELEASE-NOTES.txt").write_text(
        notes(version, first["engine"], first["signing"], first["notarized"], load_gate().describe(gate_record)))
    published = sorted(asset["name"] for asset in assets) + ["RELEASE-INFO.json", "RELEASE-NOTES.txt"]
    (directory / "SHA256SUMS").write_text("".join(f"{digest(directory / name)}  {name}\n" for name in sorted(published)))
    return version


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("record")
    make.add_argument("--app", required=True, type=Path)
    make.add_argument("--zip", required=True, type=Path)
    make.add_argument("--dmg", required=True, type=Path)
    make.add_argument("--notarized", required=True, choices=["true", "false"])
    make.add_argument("--output", required=True, type=Path)
    check = commands.add_parser("validate")
    check.add_argument("directory", type=Path)
    check.add_argument("--version")
    check.add_argument("--chromium-gate", type=Path)
    final = commands.add_parser("publish")
    final.add_argument("directory", type=Path)
    final.add_argument("--chromium-gate", required=True, type=Path)
    args = parser.parse_args(arguments)
    try:
        if args.command == "record":
            data = record(args.app, args.zip, args.dmg, args.notarized == "true", args.output)
            print(f"Recorded {data['version']} ({data['architecture']}) in {args.output}")
        elif args.command == "validate":
            records = load_release(args.directory, args.version)
            if args.chromium_gate:
                load_gate_record(args.chromium_gate, records["arm64"]["engine"])
            print(records["arm64"]["version"])
        else:
            print(f"Wrote RELEASE-INFO.json, RELEASE-NOTES.txt and SHA256SUMS for {publish(args.directory, args.chromium_gate)}")
    except ValueError as error:
        sys.exit(f"ERROR: {error}")


if __name__ == "__main__":
    main()

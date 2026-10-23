#!/usr/bin/env python3
"""Explicit, dependency-free CEF maintenance. Never invoked by the default build."""
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = "https://cef-builds.spotifycdn.com/index.json"
CHROME = "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1"
BASE = "https://cef-builds.spotifycdn.com/"
PLATFORMS = {"arm64": "macosarm64", "x86_64": "macosx64"}
LOCK = ROOT / "engine/cef.lock.json"
ATTEMPTS = 4  # per network operation, with 2, 4 and 8 second pauses between attempts
RETRY_DELAY = 2
METADATA_TIMEOUT = 60
DOWNLOAD_TIMEOUT = 120  # per socket read, not for the whole archive
RETRYABLE_HTTP = {408, 425, 429, 500, 502, 503, 504}
FAILURES = (ValueError, KeyError, OSError, subprocess.CalledProcessError)


class Transient(Exception):
    """A network failure worth another attempt: a truncated or garbled body, not only a refused connection."""


def retrying(label, operation):
    for attempt in range(1, ATTEMPTS + 1):
        try:
            return operation()
        except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError, Transient) as error:
            permanent = isinstance(error, urllib.error.HTTPError) and error.code not in RETRYABLE_HTTP
            if permanent or attempt == ATTEMPTS:
                raise OSError(f"{label}: {error}" + ("" if permanent else f" (gave up after {attempt} attempts)")) from error
            delay = RETRY_DELAY * 2 ** (attempt - 1)
            print(f"engine: {label}: {error}; retrying in {delay}s", file=sys.stderr)
            time.sleep(delay)


def read_json(source):
    if not str(source).startswith("https://"):
        return json.loads(pathlib.Path(source).read_text())

    def load():
        with urllib.request.urlopen(source, timeout=METADATA_TIMEOUT) as response:
            try:
                return json.load(response)
            except ValueError as error:
                raise Transient(f"the response is not valid JSON ({error})") from error
    return retrying(source, load)


def identity(artifact):
    """What binds an extracted or built tree to its archive; a SHA-256 added later does not invalidate it."""
    return {key: artifact[key] for key in ("name", "sha1", "size")}


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


MODERN_CEF = re.compile(r"\d+\.\d+\.\d+\+g[0-9a-f]+\+chromium-\d+\.\d+\.\d+\.\d+")


def stable_builds(index, arch):
    """The stable rows that ship a minimal archive for ARCH, keyed by CEF version. Historical rows in the old
    `3.<branch>.<commit>.g<hash>` format can never be a pin and are ignored."""
    section = index.get(PLATFORMS[arch]) if isinstance(index, dict) else None
    if not isinstance(section, dict) or not isinstance(section.get("versions"), list):
        raise ValueError(f"The CEF index has no versions for {PLATFORMS[arch]}; its format may have changed")
    return {
        row["cef_version"]: row for row in section["versions"]
        if row.get("channel") == "stable" and MODERN_CEF.fullmatch(str(row.get("cef_version")))
        and any(f.get("type") == "minimal" for f in row.get("files", []))
    }


def build_order(row):
    return version(row["chromium_version"]), tuple(map(int, row["cef_version"].split("+")[0].split(".")))


def newest_builds(index):
    """The newest stable minimal build each architecture publishes, even when the other has not caught up."""
    return {arch: max(stable_builds(index, arch).values(), key=build_order, default=None) for arch in PLATFORMS}


def select_pin(index):
    candidates = {arch: stable_builds(index, arch) for arch in PLATFORMS}
    common = set.intersection(*(set(rows) for rows in candidates.values()))
    if not common:
        raise ValueError("No stable CEF version is published for both macOS architectures")
    latest = max(common, key=lambda key: build_order(candidates["arm64"][key]))
    pin = {"schema": 1, "channel": "stable", "cef_version": latest,
           "chromium_version": candidates["arm64"][latest]["chromium_version"], "artifacts": {}}
    for arch, rows in candidates.items():
        if rows[latest]["chromium_version"] != pin["chromium_version"]:
            raise ValueError("Architecture version mismatch")
        artifact = next(f for f in rows[latest]["files"] if f["type"] == "minimal")
        pin["artifacts"][arch] = {k: artifact[k] for k in ("name", "sha1", "size")}
    return validate_lock(pin)


def assess(current, latest, chrome, newest=None):
    """Compare the pin with the newest common build and Chrome stable; NEWEST (newest_builds) adds the per-architecture view."""
    stable = max((row["version"] for row in chrome), key=version)
    report = {
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
    report["status"] = "security_gap" if report["security_gap"] else "update_available" if report["update_available"] else "ok"
    report["failure"] = None
    if newest is not None:
        top = max((row for row in newest.values() if row), key=build_order, default=None)
        report["architectures"] = {
            arch: row and {"cef_version": row["cef_version"], "chromium_version": row["chromium_version"]}
            for arch, row in newest.items()}
        report["newest_stable_cef"] = top and top["cef_version"]
        # A pin must exist for every architecture, so the newest build one architecture lacks cannot be adopted yet.
        report["missing_architectures"] = sorted(
            arch for arch, row in newest.items() if row is None or build_order(row) < build_order(top))
    return report


def render_markdown(report):
    """The human summary used for the run summary, the bump pull request and the tracking issue."""
    if report.get("status") == "failed":
        return ("## Chromium maintenance check failed\n\n"
                f"`engine/tool.py` could not assess the pinned engine: {report.get('failure') or 'unknown error'}\n\n"
                "Until it succeeds nobody is watching for Chromium security releases. "
                "See docs/UPDATING_CHROMIUM.md.\n")
    headline = {"ok": "pinned engine is current", "update_available": "a newer pin is available",
                "security_gap": "SECURITY GAP"}[report["status"]]
    lines = [f"## Chromium security monitor: {headline}", "",
             f"- Pinned: CEF `{report['pinned_cef']}` (Chromium {report['pinned_chromium']})",
             f"- Newest stable CEF published for both architectures: `{report['latest_stable_cef']}` "
             f"(Chromium {report['latest_cef_chromium']})",
             f"- Chrome stable: {report['chrome_stable']}",
             f"- Pin update available: {'yes' if report['update_available'] else 'no'}",
             f"- Pinned Chromium older than Chrome stable: {'**yes**' if report['security_gap'] else 'no'}"]
    if "architectures" in report:
        lines += ["", "| Architecture | Newest stable CEF | Chromium |", "| --- | --- | --- |"]
        for arch, row in report["architectures"].items():
            lines.append(f"| {arch} | " + (f"`{row['cef_version']}` | {row['chromium_version']} |" if row else "none | none |"))
        if report["missing_architectures"]:
            lines += ["", "**Architecture skew:** " + ", ".join(report["missing_architectures"])
                      + " has no build of the newest stable CEF yet, so the pin can only move to the newest build "
                      "both architectures publish. Re-check later; do not ship one architecture on a newer Chromium."]
    lines += ["", "Version comparison is not a CVE or backport audit. See docs/UPDATING_CHROMIUM.md.", ""]
    return "\n".join(lines)


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


def download(artifact, archive):
    """Stream ARTIFACT into ARCHIVE through a partial file. Transport failures and truncated bodies are retried;
    a complete download with the wrong checksum is a bad pin or tampering and is never retried."""
    partial = archive.with_suffix(".partial")
    url = BASE + urllib.parse.quote(artifact["name"])

    def transfer():
        with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as source, partial.open("wb") as target:
            shutil.copyfileobj(source, target)
        received = partial.stat().st_size
        if received != artifact["size"]:
            raise Transient(f"truncated download ({received} of {artifact['size']} bytes)")

    try:
        retrying(artifact["name"], transfer)
        verify_archive(partial, artifact)
        partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)


def cached_archive(artifact):
    """The verified archive in the cache. A missing or corrupt entry (for example a damaged CI cache) is downloaded again."""
    cache = ROOT / "engine/.cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / artifact["name"]
    if archive.exists():
        try:
            verify_archive(archive, artifact)
            return archive
        except ValueError as error:
            print(f"engine: cached {archive.name} is unusable ({error}); downloading it again", file=sys.stderr)
            archive.unlink()
    download(artifact, archive)
    return archive


def pin_hashes(lock):
    """Add the SHA-256 of each archive to LOCK. The CEF index only publishes SHA-1, so the hash is taken from a
    download that already matched the published size and SHA-1; later fetches then enforce all three."""
    for artifact in lock["artifacts"].values():
        artifact["sha256"] = digest(cached_archive(artifact), "sha256")
    return validate_lock(lock)


def fetch(lock, arch):
    artifact = lock["artifacts"][arch]
    target = ROOT / "engine/cef" / arch
    marker = target / ".cairn-pin.json"
    if marker.exists() and read_json(marker) == identity(artifact):
        print(f"Verified cached CEF: {target}")
        return
    archive = cached_archive(artifact)
    cache = archive.parent
    top = artifact["name"].removesuffix(".tar.bz2")
    extracted = cache / top
    if extracted.exists():
        shutil.rmtree(extracted)
    extract_archive(archive, cache, top)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        shutil.rmtree(target)
    extracted.replace(target)
    marker.write_text(json.dumps(identity(artifact), indent=2) + "\n")
    print(f"Verified CEF {arch}; SHA-256 {digest(archive, 'sha256')}")


def build(lock, arch):
    if sys.platform != "darwin":
        raise ValueError("CEF wrapper build requires macOS")
    pin = identity(lock["artifacts"][arch])
    cef = ROOT / "engine/cef" / arch
    if not (cef / ".cairn-pin.json").exists() or read_json(cef / ".cairn-pin.json") != pin:
        raise ValueError(f"Run engine/tool.py fetch --arch {arch} for the locked architecture first")
    directory = ROOT / "engine/.cache" / f"build-{arch}"
    marker = directory / ".cairn-pin.json"
    if directory.exists() and (not marker.exists() or read_json(marker) != pin):
        shutil.rmtree(directory)
    # CMAKE_OSX_ARCHITECTURES also cross-compiles the wrapper: an arm64 host can build and check x86_64.
    subprocess.run(["cmake", "-S", str(ROOT / "engine"), "-B", str(directory),
                    "-G", "Unix Makefiles", f"-DCEF_ROOT={cef}", "-DCMAKE_BUILD_TYPE=Release",
                    f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DUSE_SANDBOX=ON"], check=True)
    subprocess.run(["cmake", "--build", str(directory), "--parallel", "4"], check=True)
    marker.write_text(json.dumps(pin, indent=2) + "\n")


def write_outputs(args, report):
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    if args.markdown:
        args.markdown.write_text(render_markdown(report))


def execute(args):
    current = validate_lock(read_json(args.lock))
    if args.command in ("check", "update"):
        index = read_json(args.index)
        latest = select_pin(index)
        report = assess(current, latest, read_json(args.chrome), newest_builds(index))
        if args.command == "update" and report["update_available"]:
            args.lock.write_text(json.dumps(latest, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        write_outputs(args, report)
        if report["security_gap"]:
            print("SECURITY GAP: pinned CEF Chromium is older than Chrome stable; "
                  "version comparison is not a CVE/backport audit.", file=sys.stderr)
        if report["missing_architectures"]:
            print(f"ARCHITECTURE GAP: {', '.join(report['missing_architectures'])} has no build of the newest stable CEF "
                  f"({report['newest_stable_cef']}); the pin can only move to a version both architectures publish.",
                  file=sys.stderr)
        if args.fail_on_gap and report["security_gap"]:
            return 2
    elif args.command == "fetch":
        fetch(current, args.arch)
    elif args.command == "hash":
        args.lock.write_text(json.dumps(pin_hashes(current), indent=2) + "\n")
        for arch, artifact in current["artifacts"].items():
            print(f"{arch}: sha256 {artifact['sha256']}")
    else:
        build(current, args.arch)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "update", "fetch", "build", "hash"],
                        help="check: compare the pin with the newest CEF and Chrome stable (exit 2 with --fail-on-gap "
                             "when it is behind); update: rewrite the lock to the newest build both architectures "
                             "publish; fetch/build: prepare --arch; hash: record the SHA-256 of both archives in the lock")
    parser.add_argument("--arch", choices=PLATFORMS, default=platform.machine())
    parser.add_argument("--index", default=INDEX, help="HTTPS index or offline fixture")
    parser.add_argument("--chrome", default=CHROME, help="HTTPS releases or offline fixture")
    parser.add_argument("--lock", type=pathlib.Path, default=LOCK)
    parser.add_argument("--report", type=pathlib.Path, help="machine-readable JSON, also written when the check fails")
    parser.add_argument("--markdown", type=pathlib.Path, help="human-readable summary of the same result")
    parser.add_argument("--fail-on-gap", action="store_true")
    args = parser.parse_args(argv)
    try:
        return execute(args)
    except FAILURES as error:
        message = f"missing key {error}" if isinstance(error, KeyError) else str(error) or type(error).__name__
        print(f"engine: {message}", file=sys.stderr)
        if args.command in ("check", "update"):
            write_outputs(args, {"status": "failed", "failure": message, "command": args.command})
        return 1


if __name__ == "__main__":
    sys.exit(main())

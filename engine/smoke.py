#!/usr/bin/env python3
"""Build and run a local bundled, sandbox-enabled smoke test (requires a macOS GUI session)."""
import argparse
import http.server
import json
import os
import pathlib
import platform
import re
import plistlib
import shutil
import subprocess
import threading
import time
import uuid

from bundle import FRAMEWORK, HELPERS, bundle
from tool import ROOT


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        content_type = "text/html; charset=utf-8"
        if self.path == "/probe.json":
            body = json.dumps({"userAgent": self.headers.get("User-Agent", "")}).encode()
            content_type = "application/json"
        elif self.path == "/hang":
            time.sleep(6)  # outlasts the shortened navigation watchdog without blocking server shutdown for long
            body = b"late"
        else:
            body = (ROOT / "engine/fixtures/rendering.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def check_second_instance(app, env, stdout_log, first):
    """Starts a second process on the running instance's profile and returns its exit code."""
    deadline = time.monotonic() + 60
    while "CAIRN_SMOKE_READY" not in stdout_log.read_text():
        if first.poll() is not None or time.monotonic() > deadline:
            return None
        time.sleep(0.2)
    second = subprocess.run([str(app / "Contents/MacOS/Cairn")], env=env, cwd=ROOT, capture_output=True, timeout=30)
    return second.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--identity", help="Same-team Developer ID signing identity (hardened runtime)")
    signing.add_argument("--development-ad-hoc", action="store_true",
                         help="Local functional testing only: ad-hoc signatures without hardened runtime; Chromium sandbox remains enabled")
    args = parser.parse_args()
    if args.development_ad_hoc:
        print("DEVELOPMENT ONLY: no Hardened Runtime. This is NOT a release-security validation. Chromium sandbox remains enabled.", flush=True)
    env = dict(os.environ)
    for product in ["CairnHelper", "CairnChromiumSmoke"]:
        subprocess.run([str(ROOT / "scripts/swiftw"), "build", "--product", product], cwd=ROOT, env=env, check=True)
    # CEF resolves root_cache_path but not per-profile cache paths; a symlinked engine/.cache
    # (shared between worktrees) would otherwise silently demote every profile to in-memory storage.
    work = (ROOT / "engine/.cache").resolve() / ("smoke-" + str(uuid.uuid4()))
    app = work / "Cairn.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(ROOT / ".build/debug/CairnChromiumSmoke", app / "Contents/MacOS/Cairn")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Cairn", "CFBundleIdentifier": "org.cairn.cefsmoke",
        "CFBundleName": "Cairn CEF Smoke", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "NSHighResolutionCapable": True,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }))
    bundle(app, platform.machine(), "debug")

    def sign(path, entitlements=None):
        command = ["codesign", "--force", "--sign", args.identity or "-"]
        if args.identity:
            command += ["--options", "runtime", "--timestamp"]
        if entitlements:
            command += ["--entitlements", str(ROOT / "engine/entitlements" / entitlements)]
        subprocess.run(command + [str(path)], check=True, capture_output=True)

    framework = app / "Contents/Frameworks" / FRAMEWORK
    for dylib in (framework / "Versions/A/Libraries").glob("*.dylib"):
        sign(dylib)
    sign(framework)
    for suffix, _ in HELPERS:
        helper = app / "Contents/Frameworks" / ("Cairn Helper" + suffix + ".app")
        sign(helper, "renderer.plist" if suffix in [" (GPU)", " (Renderer)"] else "helper.plist")
    sign(app)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # The data root deliberately crosses a symlink: Cairn must resolve it, or CEF demotes every Space to memory.
    (work / "real").mkdir()
    (work / "via-link").symlink_to(work / "real")
    env["CAIRN_SMOKE_DATA_ROOT"] = str(work / "via-link" / "profiles")
    env["CAIRN_SMOKE_SNAPSHOT"] = str(work / "rendering.png")
    env["CAIRN_SMOKE_CHROMIUM_MAJOR"] = json.loads((ROOT / "engine/cef.lock.json").read_text())["chromium_version"].split(".")[0]
    env["CAIRN_NAVIGATION_WATCHDOG_SECONDS"] = "3"
    env["CAIRN_SMOKE_URL"] = f"http://127.0.0.1:{server.server_port}/"
    print(f"Smoke bundle and diagnostic logs: {work}", flush=True)
    try:
        status = -1
        with (work / "stdout.log").open("w") as stdout, (work / "stderr.log").open("w") as stderr:
            process = subprocess.Popen([str(app / "Contents/MacOS/Cairn")], env=env, cwd=ROOT, stdout=stdout, stderr=stderr)
            try:
                second_instance_exit = check_second_instance(app, env, work / "stdout.log", process)
                status = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                process.kill()
                print("CEF process exceeded 90 seconds; terminated.", flush=True)
        output = (work / "stdout.log").read_text()
        errors = (work / "stderr.log").read_text()
        print(output)
        print(errors[-12000:])
        if status != 0 or "CAIRN_CEF_SMOKE_OK" not in output or "Check failed:" in errors:
            raise SystemExit(f"Sandbox smoke failed (exit {status}); inspect {work}")
        if second_instance_exit not in (21, 24):
            raise SystemExit(f"A second instance on the same profile must exit quietly with 21 or 24, got {second_instance_exit}; inspect {work}")
        print(f"PASS: second instance on the same profile exits quietly ({second_instance_exit})")
        shutdown = re.search(r"SHUTDOWN_MS=(\d+)", output)
        if not shutdown or int(shutdown.group(1)) > 8000:
            raise SystemExit(f"Shutdown must finish within 8 s, got {shutdown and shutdown.group(1)} ms; inspect {work}")
        print(f"PASS: shutdown with live tabs finished in {shutdown.group(1)} ms")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()

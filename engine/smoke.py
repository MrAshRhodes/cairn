#!/usr/bin/env python3
"""Build and run a local bundled, sandbox-enabled smoke test (requires a macOS GUI session)."""
import argparse
import http.server
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import threading
import uuid

from bundle import FRAMEWORK, HELPERS, bundle
from tool import ROOT


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Cairn CEF smoke</title><body>Find this needle. <a href='/second'>Next</a></body>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--identity", help="Same-team Developer ID signing identity (hardened runtime)")
    signing.add_argument("--development-ad-hoc", action="store_true",
                         help="Local functional testing only: ad-hoc signatures without hardened runtime; Chromium sandbox remains enabled")
    args = parser.parse_args()
    if args.development_ad_hoc:
        print("DEVELOPMENT ONLY: no Hardened Runtime. This is NOT a release-security validation. Chromium sandbox remains enabled.", flush=True)
    env = dict(os.environ, CAIRN_WITH_CHROMIUM="1")
    for product in ["CairnHelper", "CairnChromiumSmoke"]:
        subprocess.run([str(ROOT / "scripts/swiftw"), "build", "--product", product], cwd=ROOT, env=env, check=True)
    work = ROOT / "engine/.cache" / ("smoke-" + str(uuid.uuid4()))
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
    env["CAIRN_SMOKE_DATA_ROOT"] = str(work / "profiles")
    env["CAIRN_SMOKE_URL"] = f"http://127.0.0.1:{server.server_port}/"
    print(f"Smoke bundle and diagnostic logs: {work}", flush=True)
    try:
        status = -1
        with (work / "stdout.log").open("w") as stdout, (work / "stderr.log").open("w") as stderr:
            try:
                run = subprocess.run([str(app / "Contents/MacOS/Cairn")], env=env, cwd=ROOT,
                                     stdout=stdout, stderr=stderr, timeout=90)
                status = run.returncode
            except subprocess.TimeoutExpired:
                print("CEF process exceeded 90 seconds; terminated.", flush=True)
        output = (work / "stdout.log").read_text()
        errors = (work / "stderr.log").read_text()
        print(output)
        print(errors[-12000:])
        if status != 0 or "CAIRN_CEF_SMOKE_OK" not in output or "Check failed:" in errors:
            raise SystemExit(f"Sandbox smoke failed (exit {status}); inspect {work}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()

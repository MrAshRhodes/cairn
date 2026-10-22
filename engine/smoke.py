#!/usr/bin/env python3
"""Build and run a local bundled, sandbox-enabled smoke test (requires a macOS GUI session)."""
import argparse
import http.server
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import threading
import time
import uuid

from bundle import FRAMEWORK, HELPERS, bundle
from tool import ROOT


DOWNLOAD_PAGE = b"""<!doctype html><title>Downloads</title>
<a id="secret" href="/dl/secret.bin">secret</a>
<a id="slow" href="/dl/slow.bin">slow</a>
<a id="truncated" href="/dl/truncated.bin">truncated</a>
<form method="post" action="/dl/post"><input name="posted" value="cairn"><button id="post">post</button></form>
<button id="blob" onclick="const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob-bytes'],{type:'application/octet-stream'}));a.download='blob.txt';document.body.appendChild(a);a.click();a.remove()">blob</button>
"""
SECRET = b"S" * 200_000


class Fixture(http.server.BaseHTTPRequestHandler):
    def attachment(self, name, length, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def do_download(self, method):
        cookie = self.headers.get("Cookie", "")
        if self.path == "/dl/login" or self.path == "/dl/anon":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            if self.path == "/dl/login":
                self.send_header("Set-Cookie", "cairn_dl=ok; Path=/; HttpOnly")
            self.send_header("Content-Length", str(len(DOWNLOAD_PAGE)))
            self.end_headers()
            self.wfile.write(DOWNLOAD_PAGE)
        elif self.path == "/dl/secret.bin" and "cairn_dl=ok" in cookie:
            self.attachment("secret.bin", len(SECRET))
            self.wfile.write(SECRET)
        elif self.path == "/dl/secret.bin":
            body = b"forbidden"
            self.send_response(403)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/dl/post" and method == "POST":
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.attachment("post.txt", len(body))
            self.wfile.write(body)
        elif self.path == "/dl/slow.bin":
            self.attachment("slow.bin", 400_000)
            try:
                for _ in range(40):
                    self.wfile.write(b"x" * 10_000)
                    self.wfile.flush()
                    time.sleep(0.15)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/dl/truncated.bin":
            self.attachment("truncated.bin", 100_000)
            self.wfile.write(b"t" * 10_000)
            self.wfile.flush()
            self.close_connection = True
        else:
            self.send_error(404)

    def do_POST(self):
        try:
            self.do_download("POST")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.startswith("/dl/"):
            try:
                self.do_download("GET")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        content_type = "text/html; charset=utf-8"
        if self.path == "/probe.json":
            body = json.dumps({"userAgent": self.headers.get("User-Agent", "")}).encode()
            content_type = "application/json"
        else:
            body = (ROOT / "engine/fixtures/rendering.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
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
    env["CAIRN_SMOKE_DATA_ROOT"] = str(work / "profiles")
    env["CAIRN_SMOKE_SNAPSHOT"] = str(work / "rendering.png")
    env["CAIRN_SMOKE_CHROMIUM_MAJOR"] = json.loads((ROOT / "engine/cef.lock.json").read_text())["chromium_version"].split(".")[0]
    env["CAIRN_SMOKE_URL"] = f"http://127.0.0.1:{server.server_port}/"
    print(f"Smoke bundle and diagnostic logs: {work}", flush=True)
    try:
        status = -1
        with (work / "stdout.log").open("w") as stdout, (work / "stderr.log").open("w") as stderr:
            try:
                run = subprocess.run([str(app / "Contents/MacOS/Cairn")], env=env, cwd=ROOT,
                                     stdout=stdout, stderr=stderr, timeout=150)
                status = run.returncode
            except subprocess.TimeoutExpired:
                print("CEF process exceeded 150 seconds; terminated.", flush=True)
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

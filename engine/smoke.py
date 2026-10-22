#!/usr/bin/env python3
"""Build and run a local bundled, sandbox-enabled smoke test (requires a macOS GUI session)."""
import argparse
import base64
import http.server
import json
import os
import pathlib
import platform
import re
import plistlib
import shutil
import struct
import ssl
import subprocess
import threading
import zlib
import time
import uuid

from bundle import FRAMEWORK, HELPERS, bundle
from tool import ROOT


def _png(size=32):
    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))
    rows = b"".join(b"\x00" + b"\xc8\x32\x32\xff" * size for _ in range(size))
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


ICON_PNG = _png()


DOWNLOAD_PAGE = b"""<!doctype html><title>Downloads</title>
<a id="secret" href="/dl/secret.bin">secret</a>
<a id="slow" href="/dl/slow.bin">slow</a>
<a id="truncated" href="/dl/truncated.bin">truncated</a>
<form method="post" action="/dl/post"><input name="posted" value="cairn"><button id="post">post</button></form>
<button id="blob" onclick="const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob-bytes'],{type:'application/octet-stream'}));a.download='blob.txt';document.body.appendChild(a);a.click();a.remove()">blob</button>
"""
SECRET = b"S" * 200_000


def minimal_pdf():
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R >>",
               b"<< /Length 0 >>\nstream\n\nendstream"]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


class Fixture(http.server.BaseHTTPRequestHandler):
    icon_requests = []

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
        extra_headers = {}
        route = self.path.split("?")[0]
        if route == "/icon.png":
            Fixture.icon_requests.append({"cookie": self.headers.get("Cookie"), "referer": self.headers.get("Referer")})
            body = ICON_PNG
            content_type = "image/png"
        elif route == "/icon-requests.json":
            body = json.dumps(Fixture.icon_requests).encode()
            content_type = "application/json"
        elif route in ("/media.html", "/media-again.html"):
            body = (ROOT / "engine/fixtures/media.html").read_bytes()
            extra_headers["Set-Cookie"] = "fixture=1; Path=/"
        elif route.startswith("/popups/"):
            body = (ROOT / "engine/fixtures/popups.html").read_bytes()
        elif route.startswith("/prompts/"):
            return self.prompts_fixture()
        elif route == "/probe.json":
            body = json.dumps({"userAgent": self.headers.get("User-Agent", "")}).encode()
            content_type = "application/json"
        elif self.path == "/hang":
            time.sleep(6)  # outlasts the shortened navigation watchdog without blocking server shutdown for long
            body = b"late"
        elif self.path == "/echo.html":
            body = ("<!doctype html><title>echo</title><pre id=h>Accept-Language: %s\nUser-Agent: %s</pre>" % (
                self.headers.get("Accept-Language", ""), self.headers.get("User-Agent", ""))).encode()
        elif self.path == "/print.html":
            body = (b"<!doctype html><title>print</title><style>@page{size:5in 7in;margin:0.5in}"
                    b"h1{page-break-after:always}</style><h1>Page one</h1><h1>Page two</h1>")
        elif self.path == "/doc.pdf":
            body = minimal_pdf()
            content_type = "application/pdf"
        else:
            body = (ROOT / "engine/fixtures/rendering.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra_headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def prompts_fixture(self):
        """Local pages for the permission, dialog and HTTP-auth checks (engine/smoke/PromptChecks.swift)."""
        status, headers, body = 200, {}, b"<!doctype html><title>prompts</title><p>fixture</p>"
        if self.path.startswith("/prompts/auth"):
            if self.headers.get("Authorization") == "Basic " + base64.b64encode(b"ada:secret").decode():
                body = b"<!doctype html><title>authed</title><p>signed in</p>"
            else:
                status, headers = 401, {"WWW-Authenticate": 'Basic realm="Cairn Smoke"'}
                body = b"<!doctype html><title>denied</title><p>denied</p>"
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class TLSFixture(http.server.BaseHTTPRequestHandler):
    """Served over a self-signed certificate: the browser must refuse it."""

    def do_GET(self):
        body = b"<!doctype html><title>TLS fixture reached</title><p>TLS fixture reached</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost", "-keyout", str(work / "tls.key"), "-out", str(work / "tls.crt")],
                   check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "tls.crt", work / "tls.key")
    tls_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TLSFixture)
    tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
    tls_thread = threading.Thread(target=tls_server.serve_forever, daemon=True)
    tls_thread.start()
    env["CAIRN_SMOKE_TLS_URL"] = f"https://localhost:{tls_server.server_port}/"
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
                status = process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                print("CEF process exceeded 180 seconds; terminated.", flush=True)
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
        tls_server.shutdown()
        tls_server.server_close()
        tls_thread.join()


if __name__ == "__main__":
    main()

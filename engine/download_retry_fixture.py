"""Loopback-only, explicitly armed interrupted downloads for the native retry smoke."""
import json
import re
import threading
from urllib.parse import urlsplit

PAYLOAD = b"Cairn signed-in retry\n" * 10_000
PAGE = b"""<!doctype html><title>Download retry</title>
<a id="interrupted" href="/dl-retry/interrupted.bin">Interrupted signed-in GET</a>
<a id="replaced" href="/dl-retry/replaced.bin">Changed partial</a>
<a id="closed" href="/dl-retry/closed.bin">Closed origin</a>
<form method="post" action="/dl-retry/post.bin">
<input name="one-use" value="do-not-repeat"><button id="post">One-use POST</button></form>
<button id="blob" onclick="window.retryBlobURL=window.URL.createObjectURL(new Blob(['one-use blob'],{type:'application/octet-stream'}));
const a=document.createElement('a');a.href=window.retryBlobURL;a.download='retry-blob.bin';document.body.appendChild(a);a.click();a.remove()">Blob</button>
"""
_state_lock = threading.Lock()


def handle_download_retry(handler, method):
    """Return False for unrelated routes; called before the regular smoke fixture handler."""
    route = urlsplit(handler.path).path
    if not route.startswith("/dl-retry/"):
        return False
    with _state_lock:
        if not hasattr(handler.server, "download_retry_state"):
            handler.server.download_retry_state = {"armed": False, "requests": []}
        state = handler.server.download_retry_state

    def respond(body, status=200, content_type="application/json", headers=()):
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        for key, value in headers:
            handler.send_header(key, value)
        handler.end_headers()
        handler.wfile.write(body)

    if route in ("/dl-retry/login", "/dl-retry/anon"):
        headers = [("Set-Cookie", "cairn_retry=signed-in; Path=/dl-retry/; HttpOnly; SameSite=Strict")]
        respond(PAGE, content_type="text/html; charset=utf-8", headers=headers if route.endswith("/login") else ())
    elif route == "/dl-retry/arm" and method == "POST":
        with _state_lock:
            state["armed"] = True
        respond(b'{"armed":true}')
    elif route == "/dl-retry/state":
        with _state_lock:
            body = json.dumps(state).encode()
        respond(body)
    elif route.endswith(".bin"):
        cookie = "cairn_retry=signed-in" in handler.headers.get("Cookie", "").split("; ")
        body = handler.rfile.read(int(handler.headers.get("Content-Length", "0"))) if method == "POST" else b""
        with _state_lock:
            state["requests"].append({"path": route, "method": method, "authenticated": cookie,
                                      "range": handler.headers.get("Range"), "body": body.decode()})
            armed = state["armed"]
        if not cookie:
            respond(b"sign in first", status=403, content_type="text/plain")
        elif route == "/dl-retry/post.bin" and method != "POST":
            respond(b"POST only; do not replay", status=405, content_type="text/plain")
        else:
            match = re.fullmatch(r"bytes=(\d+)-", handler.headers.get("Range", ""))
            offset = int(match.group(1)) if match else 0
            if offset >= len(PAYLOAD):
                respond(b"", status=416, headers=[("Content-Range", f"bytes */{len(PAYLOAD)}")])
                return True
            handler.send_response(206 if match else 200)
            handler.send_header("Content-Type", "application/octet-stream")
            handler.send_header("Content-Disposition", f'attachment; filename="{route.rsplit("/", 1)[-1]}"')
            handler.send_header("Content-Length", str(len(PAYLOAD) - offset))
            handler.send_header("Accept-Ranges", "bytes")
            handler.send_header("ETag", '"cairn-retry-v1"')
            if match:
                handler.send_header("Content-Range", f"bytes {offset}-{len(PAYLOAD) - 1}/{len(PAYLOAD)}")
            handler.end_headers()
            complete = armed and route == "/dl-retry/interrupted.bin" and method == "GET"
            handler.wfile.write(PAYLOAD[offset:] if complete else PAYLOAD[offset:offset + 4096])
            handler.wfile.flush()
            if not complete:
                handler.close_connection = True
    else:
        respond(b"not found", status=404)
    return True

"""Verify deterministic local fixture behavior independently of the GUI/CEF smoke."""
import http.client
import http.server
import pathlib
import sys
import threading
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from download_retry_fixture import PAYLOAD, handle_download_retry


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        handle_download_retry(self, "GET")

    def do_POST(self):
        handle_download_retry(self, "POST")

    def log_message(self, *_):
        pass


class DownloadRetryFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, path, method="GET", cookie=True, body=None, range_=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        self.addCleanup(connection.close)
        headers = {"Cookie": "cairn_retry=signed-in"} if cookie else {}
        if range_:
            headers["Range"] = range_
        connection.request(method, "/dl-retry/" + path, body=body, headers=headers)
        return connection.getresponse()

    def test_interrupted_authenticated_get_recovers_only_after_explicit_arming(self):
        self.assertEqual(self.request("interrupted.bin", cookie=False).status, 403)
        login = self.request("login", cookie=False)
        self.assertIn("HttpOnly", login.getheader("Set-Cookie"))
        for _ in range(3):
            with self.assertRaises(http.client.IncompleteRead):
                self.request("interrupted.bin").read()
        self.assertEqual(self.request("arm", method="POST").status, 200)
        full = self.request("interrupted.bin")
        self.assertEqual(full.read(), PAYLOAD)
        resumed = self.request("interrupted.bin", range_="bytes=4096-")
        self.assertEqual(resumed.status, 206)
        self.assertEqual(resumed.read(), PAYLOAD[4096:])
        self.assertTrue(all(row["authenticated"] for row in self.server.download_retry_state["requests"][1:]))

    def test_one_use_post_is_counted_and_never_exposed_as_get(self):
        with self.assertRaises(http.client.IncompleteRead):
            self.request("post.bin", method="POST", body=b"one-use=do-not-repeat").read()
        self.assertEqual(self.request("post.bin").status, 405)
        posts = [row for row in self.server.download_retry_state["requests"] if row["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["body"], "one-use=do-not-repeat")


if __name__ == "__main__":
    unittest.main()

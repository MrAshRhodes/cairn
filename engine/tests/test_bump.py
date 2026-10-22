"""Engine bump pipeline: per-architecture gaps, retries, SHA-256 pinning, reports and cross-builds, all offline.

The network is replaced by `Network`, which serves canned bodies and failures; nothing here touches a real index."""
import contextlib
import copy
import hashlib
import http.client
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.error
import urllib.parse
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("engine_tool_bump", ROOT / "engine/tool.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
FIXTURES = pathlib.Path(__file__).parent / "fixtures"
INDEX_URL = "https://cef.example.invalid/index.json"
CHROME_URL = "https://chrome.example.invalid/releases.json"
PINNED = "154.0.34+g14c5a08+chromium-154.0.8037.98"
MIDDLE = "154.0.37+g1111111+chromium-154.0.8037.103"
NEWER = "154.0.40+g2222222+chromium-154.0.8037.110"


def archive_bytes(top, payload):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:bz2") as tar:
        member = tarfile.TarInfo(f"{top}/Release/payload")
        member.size = len(payload)
        tar.addfile(member, io.BytesIO(payload))
    return buffer.getvalue()


def make_release(cef_version, architectures=("arm64", "x86_64")):
    """Index rows and archive bodies for one stable CEF version, with sizes and SHA-1 that match the bodies."""
    rows, bodies = {}, {}
    for arch in architectures:
        name = f"cef_binary_{cef_version}_{tool.PLATFORMS[arch]}_minimal.tar.bz2"
        body = archive_bytes(name.removesuffix(".tar.bz2"), arch.encode())
        rows[arch] = {"cef_version": cef_version, "chromium_version": cef_version.split("+chromium-")[1], "channel": "stable",
                      "files": [{"type": "minimal", "name": name, "sha1": hashlib.sha1(body).hexdigest(), "size": len(body)}]}
        bodies[name] = body
    return rows, bodies


def index_of(*releases):
    index = {platform_name: {"versions": []} for platform_name in tool.PLATFORMS.values()}
    for rows in releases:
        for arch, row in rows.items():
            index[tool.PLATFORMS[arch]]["versions"].append(row)
    return index


def archive_url(name):
    return tool.BASE + urllib.parse.quote(name)


class Interrupted(io.BytesIO):
    def read(self, size=-1):
        raise http.client.IncompleteRead(b"partial")


class Network:
    """Stands in for urlopen. Each URL maps to steps used in order (the last repeats): bytes are served, exceptions
    are raised when the connection is opened and Interrupted bodies fail while being read."""

    def __init__(self, routes):
        self.routes = {url: list(steps) if isinstance(steps, list) else [steps] for url, steps in routes.items()}
        self.calls = []

    def __call__(self, url, timeout=None):
        self.calls.append((url, timeout))
        steps = self.routes[url]
        step = steps.pop(0) if len(steps) > 1 else steps[0]
        if isinstance(step, BaseException):
            raise step
        return Interrupted() if step is Interrupted else io.BytesIO(step)

    def requested(self, url):
        return sum(1 for called, _ in self.calls if called == url)


def offline(network):
    stack = contextlib.ExitStack()
    stack.enter_context(contextlib.redirect_stderr(io.StringIO()))  # keeps the retry notices out of the test output
    stack.enter_context(mock.patch.object(tool.urllib.request, "urlopen", network))
    sleep = stack.enter_context(mock.patch.object(tool.time, "sleep"))
    return stack, sleep


def unavailable(code=503):
    return urllib.error.HTTPError(INDEX_URL, code, "unavailable", {}, None)


class TemporaryTree(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.work = pathlib.Path(directory.name)
        self.root = mock.patch.object(tool, "ROOT", self.work)
        self.root.start()
        self.addCleanup(self.root.stop)


class ArchitectureSkewTests(unittest.TestCase):
    def setUp(self):
        self.index = tool.read_json(FIXTURES / "index.json")
        self.chrome = tool.read_json(FIXTURES / "releases.json")
        self.pin = tool.select_pin(self.index)

    def add_release(self, cef_version, architectures):
        rows, _ = make_release(cef_version, architectures)
        for arch, row in rows.items():
            self.index[tool.PLATFORMS[arch]]["versions"].insert(0, row)

    def assess(self, latest=None):
        return tool.assess(self.pin, latest or tool.select_pin(self.index), self.chrome, tool.newest_builds(self.index))

    def test_matching_stable_builds_have_no_skew_and_betas_are_ignored(self):
        report = self.assess()
        self.assertEqual(report["missing_architectures"], [])
        self.assertEqual(report["newest_stable_cef"], PINNED)
        self.assertEqual(report["status"], "security_gap")
        self.assertIsNone(report["failure"])

    def test_a_newest_build_missing_for_one_architecture_is_reported_but_never_pinned(self):
        for published, lagging in (("arm64", "x86_64"), ("x86_64", "arm64")):
            self.setUp()
            self.add_release(NEWER, [published])
            latest = tool.select_pin(self.index)
            self.assertEqual(latest["cef_version"], PINNED, "the pin must be a build both architectures publish")
            report = self.assess(latest)
            self.assertEqual(report["missing_architectures"], [lagging])
            self.assertEqual(report["newest_stable_cef"], NEWER)
            self.assertEqual(report["architectures"][published]["cef_version"], NEWER)
            self.assertEqual(report["architectures"][lagging]["cef_version"], PINNED)
            self.assertFalse(report["update_available"])
            markdown = tool.render_markdown(report)
            self.assertIn("Architecture skew", markdown)
            self.assertIn(lagging, markdown)

    def test_the_newest_common_build_wins_over_a_newer_single_architecture_build(self):
        self.add_release(NEWER, ["arm64"])
        self.add_release(MIDDLE, ["arm64", "x86_64"])
        latest = tool.select_pin(self.index)
        self.assertEqual(latest["cef_version"], MIDDLE)
        report = self.assess(latest)
        self.assertTrue(report["update_available"])
        self.assertEqual(report["status"], "security_gap")
        self.assertEqual(report["missing_architectures"], ["x86_64"])

    def test_an_architecture_without_any_stable_build_is_flagged(self):
        self.index["macosx64"]["versions"] = []
        newest = tool.newest_builds(self.index)
        self.assertIsNone(newest["x86_64"])
        report = tool.assess(self.pin, self.pin, self.chrome, newest)
        self.assertEqual(report["missing_architectures"], ["x86_64"])
        self.assertIsNone(report["architectures"]["x86_64"])
        self.assertIn("none", tool.render_markdown(report))

    def test_historical_index_rows_in_the_old_version_format_are_ignored(self):
        ancient = {"cef_version": "3.3626.1895.g9f41a27", "chromium_version": "69.0.3497.100", "channel": "stable",
                   "files": [{"type": "minimal", "name": "old", "sha1": "0" * 40, "size": 1}]}
        for section in self.index.values():
            section["versions"].append(copy.deepcopy(ancient))
        self.assertEqual(tool.select_pin(self.index), self.pin)
        self.assertEqual(self.assess()["missing_architectures"], [])

    def test_an_index_without_a_platform_section_fails_with_a_clear_message(self):
        for broken in ([], {}, {"macosarm64": {"versions": []}}, {"macosarm64": {}, "macosx64": {"versions": []}}):
            for function in (tool.select_pin, tool.newest_builds):
                with self.assertRaisesRegex(ValueError, "format may have changed"):
                    function(broken)


class ReportTests(TemporaryTree):
    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, str(ROOT / "engine/tool.py"), *arguments], capture_output=True, text=True)

    def setUp(self):
        super().setUp()
        self.index = self.work / "index.json"
        self.index.write_text((FIXTURES / "index.json").read_text())
        self.chrome = self.work / "releases.json"
        self.chrome.write_text((FIXTURES / "releases.json").read_text())
        self.lock = self.work / "lock.json"
        self.lock.write_text(json.dumps(tool.select_pin(json.loads(self.index.read_text()))))
        self.report = self.work / "report.json"
        self.markdown = self.work / "report.md"

    def check(self, *extra):
        return self.run_tool("check", "--lock", str(self.lock), "--index", str(self.index), "--chrome", str(self.chrome),
                             "--report", str(self.report), "--markdown", str(self.markdown), *extra)

    def test_check_writes_a_machine_readable_report_and_a_human_summary(self):
        run = self.check()
        self.assertEqual(run.returncode, 0, run.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual(report, json.loads(run.stdout))
        self.assertEqual((report["status"], report["failure"], report["missing_architectures"]), ("security_gap", None, []))
        self.assertIn("SECURITY GAP", self.markdown.read_text())

    def test_status_distinguishes_ok_update_and_gap(self):
        self.chrome.write_text(json.dumps([{"version": "154.0.8037.98"}]))
        self.assertEqual(json.loads(self.check().stdout)["status"], "ok")
        newer = copy.deepcopy(json.loads(self.index.read_text()))
        rows, _ = make_release(MIDDLE)
        for arch, row in rows.items():
            newer[tool.PLATFORMS[arch]]["versions"].insert(0, row)
        self.index.write_text(json.dumps(newer))
        run = self.check()
        self.assertEqual(json.loads(run.stdout)["status"], "update_available")
        self.assertIn("a newer pin is available", self.markdown.read_text())

    def test_a_missing_architecture_build_is_announced_without_failing_the_check(self):
        self.chrome.write_text(json.dumps([{"version": "154.0.8037.98"}]))
        rows, _ = make_release(NEWER, ["arm64"])
        newer = json.loads(self.index.read_text())
        newer["macosarm64"]["versions"].insert(0, rows["arm64"])
        self.index.write_text(json.dumps(newer))
        run = self.check("--fail-on-gap")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("ARCHITECTURE GAP: x86_64", run.stderr)
        self.assertEqual(json.loads(run.stdout)["missing_architectures"], ["x86_64"])

    def test_failures_are_reported_in_the_same_machine_readable_form(self):
        original = self.lock.read_bytes()
        self.index.write_text(json.dumps({"unexpected": "format"}))
        run = self.check()
        self.assertEqual(run.returncode, 1)
        self.assertIn("format may have changed", run.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual((report["status"], report["command"]), ("failed", "check"))
        self.assertIn("format may have changed", report["failure"])
        self.assertIn("check failed", self.markdown.read_text())
        self.assertEqual(self.lock.read_bytes(), original)

    def test_an_unreadable_lock_is_a_reported_failure_too(self):
        self.lock.write_text("{not json")
        run = self.check()
        self.assertEqual(run.returncode, 1)
        self.assertEqual(json.loads(self.report.read_text())["status"], "failed")

    def test_the_release_gate_still_understands_the_report(self):
        sys.path.insert(0, str(ROOT / "Resources/ReleaseTools"))
        try:
            import ChromiumGate
        finally:
            sys.path.pop(0)
        run = self.check("--fail-on-gap")
        self.assertEqual(run.returncode, 2)
        status, assessment, _ = ChromiumGate.classify(run.returncode, run.stdout)
        self.assertEqual(status, "gap")
        self.assertTrue(assessment["security_gap"])


class NetworkResilienceTests(TemporaryTree):
    def test_metadata_is_retried_with_backoff_and_a_timeout(self):
        body = json.dumps({"ok": True}).encode()
        network = Network({INDEX_URL: [urllib.error.URLError("connection reset"), unavailable(), body]})
        stack, sleep = offline(network)
        with stack:
            self.assertEqual(tool.read_json(INDEX_URL), {"ok": True})
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 4])
        self.assertEqual(network.calls, [(INDEX_URL, tool.METADATA_TIMEOUT)] * 3)

    def test_truncated_or_garbled_metadata_is_retried(self):
        network = Network({INDEX_URL: [b'{"truncated": ', b"<html>proxy error</html>", b'{"ok": 1}']})
        stack, _ = offline(network)
        with stack:
            self.assertEqual(tool.read_json(INDEX_URL), {"ok": 1})
        self.assertEqual(len(network.calls), 3)

    def test_persistent_outages_fail_after_a_bounded_number_of_attempts(self):
        network = Network({INDEX_URL: unavailable()})
        stack, sleep = offline(network)
        with stack, self.assertRaisesRegex(OSError, f"{INDEX_URL}: .*503.*gave up after {tool.ATTEMPTS} attempts"):
            tool.read_json(INDEX_URL)
        self.assertEqual(len(network.calls), tool.ATTEMPTS)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 4, 8])

    def test_permanent_http_errors_are_not_retried(self):
        network = Network({INDEX_URL: unavailable(404)})
        stack, sleep = offline(network)
        with stack, self.assertRaisesRegex(OSError, "404"):
            tool.read_json(INDEX_URL)
        self.assertEqual(len(network.calls), 1)
        sleep.assert_not_called()

    def artifact(self, body, name="cef_binary_x.tar.bz2"):
        return {"name": name, "size": len(body), "sha1": hashlib.sha1(body).hexdigest()}

    def test_interrupted_and_short_downloads_are_retried_and_leave_no_partial_file(self):
        body = b"x" * 4096
        artifact = self.artifact(body)
        archive = self.work / artifact["name"]
        network = Network({archive_url(artifact["name"]): [Interrupted, body[:100], body]})
        stack, _ = offline(network)
        with stack:
            tool.download(artifact, archive)
        self.assertEqual(archive.read_bytes(), body)
        self.assertEqual(len(network.calls), 3)
        self.assertEqual(network.calls[0][1], tool.DOWNLOAD_TIMEOUT)
        self.assertEqual([path.name for path in self.work.iterdir()], [artifact["name"]])

    def test_a_complete_download_with_the_wrong_checksum_is_never_retried(self):
        body = b"x" * 4096
        artifact = self.artifact(body)
        archive = self.work / artifact["name"]
        network = Network({archive_url(artifact["name"]): b"y" * 4096})
        stack, _ = offline(network)
        with stack, self.assertRaisesRegex(ValueError, "sha1"):
            tool.download(artifact, archive)
        self.assertEqual(len(network.calls), 1)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_a_corrupt_cached_archive_is_downloaded_again_but_must_still_verify(self):
        rows, bodies = make_release(PINNED)
        artifact = tool.select_pin(index_of(rows))["artifacts"]["arm64"]
        cache = self.work / "engine/.cache"
        cache.mkdir(parents=True)
        (cache / artifact["name"]).write_bytes(b"damaged by a stale CI cache")
        network = Network({archive_url(artifact["name"]): bodies[artifact["name"]]})
        stack, _ = offline(network)
        with stack:
            archive = tool.cached_archive(artifact)
        self.assertEqual(archive.read_bytes(), bodies[artifact["name"]])
        self.assertEqual(len(network.calls), 1)
        network = Network({archive_url(artifact["name"]): b"z" * artifact["size"]})
        archive.write_bytes(b"damaged again")
        stack, _ = offline(network)
        with stack, self.assertRaisesRegex(ValueError, "sha1"):
            tool.cached_archive(artifact)


class BumpFlowTests(TemporaryTree):
    """check -> update -> hash -> fetch against a fully mocked index and CDN."""

    def setUp(self):
        super().setUp()
        old_rows, old_bodies = make_release(PINNED)
        new_rows, new_bodies = make_release(MIDDLE)
        self.bodies = {**old_bodies, **new_bodies}
        self.lock = self.work / "engine/cef.lock.json"
        self.lock.parent.mkdir(parents=True)
        self.lock.write_text(json.dumps(tool.select_pin(index_of(old_rows))))
        routes = {INDEX_URL: [urllib.error.URLError("temporary failure"), json.dumps(index_of(old_rows, new_rows)).encode()],
                  CHROME_URL: json.dumps([{"version": "154.0.8037.103"}]).encode()}
        routes.update({archive_url(name): body for name, body in self.bodies.items()})
        self.network = Network(routes)

    def main(self, *arguments):
        stack, self.sleep = offline(self.network)
        output = io.StringIO()
        with stack, contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            status = tool.main(list(arguments))
        return status, output.getvalue()

    def test_the_full_bump_pins_hashes_and_fetches_both_architectures(self):
        report = self.work / "report.json"
        status, _ = self.main("update", "--lock", str(self.lock), "--index", INDEX_URL, "--chrome", CHROME_URL,
                              "--report", str(report))
        self.assertEqual(status, 0)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2], "the first index request fails once")
        reported = json.loads(report.read_text())
        self.assertTrue(reported["update_available"])
        self.assertEqual(reported["status"], "security_gap", "the pin being replaced is behind Chrome stable")
        pinned = json.loads(self.lock.read_text())
        self.assertEqual(pinned["cef_version"], MIDDLE)
        self.assertTrue(all("sha256" not in artifact for artifact in pinned["artifacts"].values()))

        status, _ = self.main("hash", "--lock", str(self.lock))
        self.assertEqual(status, 0)
        hashed = tool.validate_lock(json.loads(self.lock.read_text()))
        for artifact in hashed["artifacts"].values():
            self.assertEqual(artifact["sha256"], hashlib.sha256(self.bodies[artifact["name"]]).hexdigest())

        for arch in tool.PLATFORMS:
            status, _ = self.main("fetch", "--lock", str(self.lock), "--arch", arch)
            self.assertEqual(status, 0)
            self.assertEqual((self.work / "engine/cef" / arch / "Release/payload").read_bytes(), arch.encode())
            self.assertEqual(json.loads((self.work / "engine/cef" / arch / ".cairn-pin.json").read_text()),
                             tool.identity(hashed["artifacts"][arch]))
        downloads = len(self.network.calls)
        status, output = self.main("fetch", "--lock", str(self.lock), "--arch", "x86_64")
        self.assertEqual(status, 0)
        self.assertIn("Verified cached CEF", output)
        self.assertEqual(len(self.network.calls), downloads, "an extracted, pinned tree needs no network")

    def test_recording_a_sha256_does_not_invalidate_prepared_trees(self):
        self.network.routes[INDEX_URL] = self.network.routes[INDEX_URL][-1:]
        self.main("update", "--lock", str(self.lock), "--index", INDEX_URL, "--chrome", CHROME_URL)
        self.main("fetch", "--lock", str(self.lock), "--arch", "arm64")
        marker = self.work / "engine/cef/arm64/.cairn-pin.json"
        before = marker.read_bytes()
        self.main("hash", "--lock", str(self.lock))
        self.assertEqual(self.main("fetch", "--lock", str(self.lock), "--arch", "arm64")[0], 0)
        self.assertEqual(marker.read_bytes(), before)

    def test_fetch_enforces_a_recorded_sha256(self):
        self.network.routes[INDEX_URL] = self.network.routes[INDEX_URL][-1:]
        self.main("update", "--lock", str(self.lock), "--index", INDEX_URL, "--chrome", CHROME_URL)
        lock = json.loads(self.lock.read_text())
        lock["artifacts"]["arm64"]["sha256"] = "0" * 64
        self.lock.write_text(json.dumps(lock))
        status, _ = self.main("fetch", "--lock", str(self.lock), "--arch", "arm64")
        self.assertEqual(status, 1)
        self.assertFalse((self.work / "engine/cef/arm64").exists())


class BuildTests(TemporaryTree):
    def setUp(self):
        super().setUp()
        self.lock = tool.select_pin(index_of(make_release(PINNED)[0]))
        self.pin = tool.identity(self.lock["artifacts"]["x86_64"])
        self.cef = self.work / "engine/cef/x86_64"
        self.cef.mkdir(parents=True)

    def build(self):
        def cmake(command, check):
            if "-B" in command:
                pathlib.Path(command[command.index("-B") + 1]).mkdir(parents=True, exist_ok=True)

        with mock.patch.object(tool.sys, "platform", "darwin"), \
                mock.patch.object(tool.subprocess, "run", side_effect=cmake) as run:
            tool.build(self.lock, "x86_64")
        return run

    def test_the_wrapper_is_cross_compiled_for_the_requested_architecture(self):
        (self.cef / ".cairn-pin.json").write_text(json.dumps(self.pin))
        run = self.build()
        configure, compile_ = (call.args[0] for call in run.call_args_list)
        self.assertIn("-DCMAKE_OSX_ARCHITECTURES=x86_64", configure)
        self.assertIn(f"-DCEF_ROOT={self.cef}", configure)
        self.assertIn(str(self.work / "engine/.cache/build-x86_64"), compile_)
        self.assertEqual(json.loads((self.work / "engine/.cache/build-x86_64/.cairn-pin.json").read_text()), self.pin)

    def test_a_build_needs_the_locked_archive_to_be_fetched_first(self):
        with self.assertRaisesRegex(ValueError, "fetch --arch x86_64"):
            self.build()
        (self.cef / ".cairn-pin.json").write_text(json.dumps({**self.pin, "sha1": "0" * 40}))
        with self.assertRaisesRegex(ValueError, "fetch --arch x86_64"):
            self.build()

    def test_a_wrapper_built_for_another_pin_is_discarded(self):
        (self.cef / ".cairn-pin.json").write_text(json.dumps(self.pin))
        stale = self.work / "engine/.cache/build-x86_64"
        stale.mkdir(parents=True)
        (stale / ".cairn-pin.json").write_text(json.dumps({**self.pin, "sha1": "0" * 40}))
        (stale / "leftover.o").write_text("old objects")
        self.build()
        self.assertFalse((stale / "leftover.o").exists())

    def test_lock_accepts_and_validates_an_optional_sha256(self):
        lock = copy.deepcopy(self.lock)
        lock["artifacts"]["arm64"]["sha256"] = "a" * 64
        tool.validate_lock(lock)
        lock["artifacts"]["arm64"]["sha256"] = "A" * 64
        with self.assertRaises(ValueError):
            tool.validate_lock(lock)


if __name__ == "__main__":
    unittest.main()

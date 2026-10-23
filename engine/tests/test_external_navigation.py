"""External navigation regressions; runtime document preservation is covered by the bundled smoke."""
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HANDLERS = ROOT / "Sources/CairnChromiumBridge/Handlers"


class ExternalNavigationTests(unittest.TestCase):
    def test_smoke_labels_each_await_without_changing_navigation_or_promise_timing(self):
        source = (ROOT / "engine/smoke/ExternalProtocolChecks.swift").read_text()
        ordered = [
            'progress("marker.begin")',
            'try await js(tab, "window.__externalProtocolDocument',
            'progress("marker.end")',
            'progress("assign.begin", targetIndex: index)',
            'try await js(tab, "location.href =',
            'progress("assign.end", targetIndex: index)',
            'progress("handoff-wait.begin", targetIndex: index)',
            "try await wait { self.externalURLs.count > count && !tab.state.isLoading }",
            'progress("handoff-wait.end", targetIndex: index)',
            'progress("timer.begin", targetIndex: index)',
            "let timerProbe = Task { @MainActor in",
            "preserved = try await js(tab,",
            "new Promise(resolve => {",
            "}, 500);",
            'progress("timer.end", targetIndex: index)',
            "try require(externalURLs.count == count + 1",
            "try require(preserved == true",
        ]
        positions = [source.index(token) for token in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("resolve(window.__externalProtocolDocument === 'preserved');", source)
        self.assertIn('["mailto:smoke@example.com", "cairn-smoke-unknown://declined"].enumerated()', source)

    def test_timer_probe_observes_but_never_settles_or_replaces_the_original_timer(self):
        source = (ROOT / "engine/smoke/ExternalProtocolChecks.swift").read_text()
        probe = source.split("let timerProbe = Task", 1)[1].split("let preserved: Bool?", 1)[0]
        timer = source.split("let preserved: Bool?", 1)[1].split('progress("timer.end"', 1)[0]
        self.assertIn("Task.sleep(for: .seconds(2))", probe)
        self.assertIn("if timerSettled.value || Task.isCancelled { return }", probe)
        self.assertNotIn("setTimeout", probe)
        self.assertNotIn("resolve(", probe)
        self.assertEqual(timer.count("setTimeout("), 1)
        self.assertEqual(timer.count("resolve(window.__externalProtocolDocument === 'preserved')"), 1)
        self.assertIn("}, 500);", timer)
        self.assertEqual(timer.count("timerProbe.cancel()"), 2)
        self.assertIn("throw error", timer)
        self.assertNotIn("sleep", timer)
        self.assertNotIn("Date()", timer)
        report = source.split("func reportTimerProbe(", 1)[1].split("func checkExternalProtocols", 1)[0]
        self.assertIn('["visible", "hidden", "prerender"]', report)
        self.assertIn('["loading", "interactive", "complete"]', report)
        self.assertNotIn(r"\(reply", report)
        self.assertNotIn(r"\(parts[1])", report)
        self.assertNotIn(r"\(parts[2])", report)

    def test_smoke_progress_contains_only_synthetic_labels_indices_and_monotonic_time(self):
        source = (ROOT / "engine/smoke/ExternalProtocolChecks.swift").read_text()
        progress = source.split("func progress(", 1)[1].split("let originalURL", 1)[0]
        self.assertIn("_ phase: StaticString", progress)
        self.assertIn("targetIndex: Int = -1", progress)
        self.assertIn("ProcessInfo.processInfo.systemUptime", progress)
        self.assertIn(r"phase=\(phase) case=\(targetIndex)", progress)
        self.assertIn("fflush(stderr)", progress)
        self.assertNotIn(r"\(target)", progress)
        self.assertNotIn(r"\(originalURL)", progress)

    def test_handoff_cancels_before_invalidating_the_current_document(self):
        source = (HANDLERS / "CCRequestHandler.mm").read_text()
        browse = source.split("bool OnBeforeBrowse(", 1)[1].split("bool OnOpenURLFromTab", 1)[0]
        handoff = browse.split("IsExternalNavigationURL(url)", 1)[1].split("++navigationGeneration_", 1)[0]
        self.assertIn("openExternalURL:url", handoff)
        self.assertIn("return true;", handoff)
        self.assertNotIn("CancelPending(tab)", handoff)
        resource = (HANDLERS / "CCResourceRequestHandler.mm").read_text()
        self.assertIn("allow_os_execution = false;", resource)
        load = (HANDLERS / "CCLoadHandler.mm").read_text()
        self.assertNotIn("ERR_UNKNOWN_URL_SCHEME", load)

    @unittest.skipUnless(platform.system() == "Darwin", "Foundation fixture requires macOS")
    def test_browser_owned_schemes_are_not_external_handoffs(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="external-navigation-", dir=ROOT / ".build") as work:
            executable = pathlib.Path(work) / "external-navigation"
            subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-fobjc-arc",
                 str(ROOT / "engine/tests/external_navigation.mm"),
                 "-framework", "Foundation", "-o", str(executable)],
                check=True, capture_output=True, text=True,
            )
            subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()

"""External navigation regressions; runtime document preservation is covered by the bundled smoke."""
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HANDLERS = ROOT / "Sources/CairnChromiumBridge/Handlers"


class ExternalNavigationTests(unittest.TestCase):
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

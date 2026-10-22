"""Lifecycle unit/source-contract regressions. These do not initialize CEF or run its UI."""
import os
import pathlib
import platform
import shutil
import subprocess
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "Sources/CairnChromiumBridge"


class LifecycleContractTests(unittest.TestCase):
    def test_shutdown_waits_for_all_browsers_without_fabricating_completion(self):
        source = (BRIDGE / "CCRuntime.mm").read_text()
        finish = source.split("void FinishShutdown()", 1)[1].split("\n}\n}", 1)[0]
        self.assertIn("if (!clients.empty() || pendingBrowsers) return;", finish)
        self.assertLess(finish.index("if (pumping)"), finish.index("CefShutdown();"))
        self.assertNotIn("clients.clear()", finish)
        self.assertNotIn("pendingBrowsers = 0", finish)
        self.assertNotIn("FinishShutdown(true)", source)
        self.assertIn("_exit(EXIT_FAILURE);", source)
        self.assertNotIn("_exit(0)", source)
        shutdown = source.split("+ (void)shutdown {", 1)[1]
        self.assertLess(shutdown.index("kHardExitSeconds"), shutdown.index("ReleaseDownloads();"))
        self.assertLess(shutdown.index("ReleaseDownloads();"), shutdown.index("CloseBrowser(true)"))
        self.assertLess(finish.index("CefShutdown();"), finish.index("completion();"))

    def test_prompt_invalidation_is_before_navigation_and_close(self):
        request = (BRIDGE / "Handlers/CCRequestHandler.mm").read_text()
        browse = request.split("bool OnBeforeBrowse(", 1)[1].split("bool OnOpenURLFromTab", 1)[0]
        self.assertIn("frame->IsMain()", browse)
        self.assertIn("++navigationGeneration_", browse)
        self.assertIn("CancelPending(tab)", browse)
        auth = request.split("bool GetAuthCredentials(", 1)[1].split("bool OnCertificateError", 1)[0]
        self.assertLess(auth.index("CefPostTask(TID_UI"), auth.index("Pending(tab)"))
        self.assertNotIn("dispatch_async(", auth)
        self.assertIn("generation != keepAlive->navigationGeneration_.load()", auth)
        self.assertIn("current->GetIdentifier() != browserID", auth)
        close = (BRIDGE / "Handlers/CCLifeSpanHandler.mm").read_text().split("void OnBeforeClose(", 1)[1]
        self.assertLess(close.index("CancelPending(tab)"), close.index("clients.erase("))

    def test_late_download_destination_answer_does_not_own_cef_callback(self):
        source = (BRIDGE / "Handlers/CCDownloadHandler.mm").read_text()
        decision = source.split("decide:^(NSString *path) {", 1)[1].split("}];", 1)[0]
        self.assertIn("pendingChoices.find(identifier)", decision)
        self.assertIn("pendingChoices.erase(found)", decision)
        self.assertIn("!stopping", decision)
        release = source.split("void ReleaseDownloads()", 1)[1]
        self.assertIn("pendingChoices.clear()", release)
        self.assertIn("callback->Cancel()", release)

    @unittest.skipUnless(platform.system() == "Darwin", "Objective-C registry test requires macOS")
    def test_pending_registry_cancels_and_dismisses_once_without_loading_cef(self):
        architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
        cef = ROOT / "engine/cef" / architecture
        wrapper = ROOT / "engine/.cache" / f"build-{architecture}"
        if not (cef / "include/cef_version.h").is_file() or not (
            wrapper / "libcef_dll_wrapper/libcef_dll_wrapper.a"
        ).is_file():
            self.skipTest("prepared CEF headers/wrapper are required; no fetch is performed")
        work = ROOT / ".build" / f"lifecycle-test-{uuid.uuid4()}"
        work.mkdir(parents=True)
        try:
            executable = work / "pending-callbacks"
            environment = dict(os.environ, TMPDIR=str(work))
            subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-fno-rtti",
                 "-Wno-incomplete-implementation", "-Wno-protocol",
                 "-DCEF_USE_SANDBOX", "-DCEF_API_VERSION=15400",
                 f"-I{cef}", f"-I{wrapper}", f"-I{BRIDGE / 'include'}",
                 str(ROOT / "engine/tests/pending_callbacks.mm"),
                 "-framework", "AppKit", "-o", str(executable)],
                check=True, cwd=ROOT, env=environment, capture_output=True, text=True,
            )
            subprocess.run([str(executable)], check=True, cwd=ROOT, env=environment, timeout=10)
        except subprocess.CalledProcessError as error:
            self.fail(f"Native pending-callback regression failed:\n{error.stdout}\n{error.stderr}")
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()

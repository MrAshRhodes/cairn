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
        before_download = source.split("bool OnBeforeDownload(", 1)[1].split("void OnDownloadUpdated(", 1)[0]
        # Nested Objective-C messages may contain the same terminator; decide closes the final message.
        decision = before_download.split("decide:^(NSString *path) {", 1)[1].rsplit("}];", 1)[0]
        self.assertIn("pendingChoices.find(identifier)", decision)
        self.assertIn("pendingChoices.erase(found)", decision)
        self.assertIn("!stopping", decision)
        self.assertLess(decision.index("pendingChoices.erase(found)"), decision.index("pending->Continue("))
        release = source.split("void ReleaseDownloads()", 1)[1]
        self.assertIn("pendingChoices.clear()", release)
        self.assertIn("callback->Cancel()", release)

    def test_prompt_handlers_compare_browser_handles_not_wrapper_addresses(self):
        for handler in ("CCRequestHandler.mm", "CCJSDialogHandler.mm", "CCPermissionHandler.mm"):
            with self.subTest(handler=handler):
                source = (BRIDGE / "Handlers" / handler).read_text()
                self.assertNotRegex(source, r"cefBrowser\s*[!=]=\s*browser")
                self.assertIn("SameBrowser(tab.cefBrowser, browser)", source)

    @unittest.skipUnless(platform.system() == "Darwin", "Objective-C registry test requires macOS")
    def test_pending_registry_cancels_and_dismisses_once_without_loading_cef(self):
        self.run_native_fixture("pending_callbacks")

    @unittest.skipUnless(platform.system() == "Darwin", "CEF wrapper test requires macOS")
    def test_browser_identity_survives_distinct_cef_callback_wrappers(self):
        self.run_native_fixture("browser_identity", link_wrapper=True)

    @unittest.skipUnless(platform.system() == "Darwin", "CEF close fixture requires macOS")
    def test_close_approval_stay_invalidation_and_explicit_force(self):
        self.run_native_fixture("close_lifecycle", link_wrapper=True)

    def test_boot_registers_scripts_without_pausing_main_frame_requests(self):
        resource = (BRIDGE / "Handlers/CCResourceRequestHandler.mm").read_text()
        # An adopted popup's first request is already in flight; pausing it deadlocks Page.enable.
        self.assertIn("if (type == RT_MAIN_FRAME) return RV_CONTINUE;", resource)
        self.assertNotIn("RV_CONTINUE_ASYNC", resource)
        tab = (BRIDGE / "CCTab.mm").read_text()
        boot = tab.split("- (void)beginBoot {", 1)[1].split("- (void)settleBoot", 1)[0]
        self.assertLess(boot.index("setScripts:self.configuredScripts"), boot.index("enablePage:0"))
        enable = tab.split("- (void)enablePage:", 1)[1].split("- (void)publish ", 1)[0]
        self.assertNotIn("setScripts:", enable)
        scripts = tab.split("- (void)setScripts:", 1)[1].split("- (void)snapshot:", 1)[0]
        self.assertNotIn("self.pageEnabled", scripts.split("NSUInteger generation", 1)[0])

    def test_close_cannot_start_teardown_before_page_approval(self):
        close = (BRIDGE / "CCTab+Closing.mm").read_text()
        request = close.split("- (void)requestCloseWithCompletion:", 1)[1].split("- (void)cancelCloseRequest", 1)[0]
        self.assertIn("CloseBrowser(false)", request)
        self.assertNotIn("CloseBrowser(true)", request)
        self.assertNotIn("self.closing = YES", request)
        runtime = (BRIDGE / "CCRuntime.mm").read_text().split("+ (void)shutdown {", 1)[1]
        self.assertLess(runtime.index("!pair.second->closeApproved"), runtime.index("stopping = true"))
        life = (BRIDGE / "Handlers/CCLifeSpanHandler.mm").read_text()
        do_close = life.split("bool DoClose(", 1)[1].split("void OnBeforeClose(", 1)[0]
        self.assertIn("[tab approveClose]", do_close)
        self.assertIn("CloseDevTools()", do_close)
        self.assertIn("[native removeFromSuperview]", do_close)

    def run_native_fixture(self, name, link_wrapper=False):
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
            executable = work / name
            environment = dict(os.environ, TMPDIR=str(work))
            subprocess.run(
                ["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-fno-rtti",
                 "-Wno-incomplete-implementation", "-Wno-protocol",
                 "-DCEF_USE_SANDBOX", "-DCEF_API_VERSION=15400",
                 f"-I{cef}", f"-I{wrapper}", f"-I{BRIDGE / 'include'}",
                 str(ROOT / "engine/tests" / f"{name}.mm"),
                 *([str(wrapper / "libcef_dll_wrapper/libcef_dll_wrapper.a")] if link_wrapper else []),
                 "-framework", "AppKit", "-o", str(executable)],
                check=True, cwd=ROOT, env=environment, capture_output=True, text=True,
            )
            subprocess.run([str(executable)], check=True, cwd=ROOT, env=environment, timeout=10)
        except subprocess.CalledProcessError as error:
            self.fail(f"Native {name} regression failed:\n{error.stdout}\n{error.stderr}")
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    unittest.main()

#if !__has_include("include/cef_version.h") || !__has_include("libcef_dll_wrapper/libcef_dll_wrapper.a")
#error "Chromium (CEF) is not prepared for this build. Run `make cef` (python3 engine/tool.py fetch && python3 engine/tool.py build) first; when CAIRN_CEF_ARCH selects a non-host architecture, add --arch <arm64|x86_64> to both commands."
#endif

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // The sandbox library must run before Chromium or AppKit is loaded.
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) {
    return 1;
  }
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) {
    return 2;
  }
  return CefExecuteProcess(CefMainArgs(argc, argv), nullptr, nullptr);
}

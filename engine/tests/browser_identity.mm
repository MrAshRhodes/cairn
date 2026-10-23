// Use the real CEF DLL wrappers around inert C handles: no framework load, process or UI.
#define WRAPPING_CEF_SHARED
#import "../../Sources/CairnChromiumBridge/CCInternal.h"
#include "libcef_dll/ctocpp/browser_ctocpp.h"
#include <cassert>

cef_browser_t MakeBrowserHandle() {
  cef_browser_t handle{};
  handle.base.size = sizeof(handle);
  handle.base.add_ref = [](cef_base_ref_counted_t *) {};
  handle.base.release = [](cef_base_ref_counted_t *) { return 0; };
  handle.base.has_one_ref = [](cef_base_ref_counted_t *) { return 1; };
  handle.base.has_at_least_one_ref = [](cef_base_ref_counted_t *) { return 1; };
  handle.is_same = [](cef_browser_t *self, cef_browser_t *other) { return self == other ? 1 : 0; };
  return handle;
}

int main() {
  cef_browser_t handle = MakeBrowserHandle(), replacementHandle = MakeBrowserHandle();
  auto stored = CefBrowserCToCpp_Wrap(&handle);
  auto callback = CefBrowserCToCpp_Wrap(&handle);
  auto replacement = CefBrowserCToCpp_Wrap(&replacementHandle);
  assert(stored != callback);  // The old navigation guard rejected this legitimate callback.
  assert(stored->IsSame(callback));
  assert(!stored->IsSame(replacement));
  assert(cc::SameBrowser(stored, callback));
  assert(!cc::SameBrowser(stored, replacement));
  assert(!cc::SameBrowser(stored, nullptr));
  assert(!cc::SameBrowser(nullptr, callback));
  assert(!cc::SameBrowser(nullptr, nullptr));
}

// CCRequestHandler.mm — CefRequestHandler: renderer crashes and hangs, plus the hook that gives CEF the
// per-request ResourceRequestHandler (CCResourceRequestHandler.mm; null today, i.e. CEF's default).
// CEF may call GetResourceRequestHandler off the main thread, so this handler keeps the resource
// handler itself and never touches its Client.
#import "../CCInternal.h"

namespace cc {
namespace {
class RequestHandler final : public TabHandler, public CefRequestHandler {
 public:
  RequestHandler(Client& client, CefRefPtr<CefResourceRequestHandler> resource)
      : TabHandler(client), resource_(resource) {}
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool,
      const CefString&, bool&) override {
    return resource_;
  }
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser>,
                                   CefRefPtr<CefUnresponsiveProcessCallback> callback) override {
    auto tab = owner;
    if (!tab) return false;
    [tab renderProcessUnresponsive:callback];
    return true; // The tab ends the hang with Terminate() if the page does not recover.
  }
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser>) override { [owner renderProcessResponsive]; }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int code,
                                 const CefString& error) override {
    NSString *reason;
    switch (status) {
      case TS_PROCESS_WAS_KILLED: reason = @"was stopped by the system"; break;
      case TS_PROCESS_OOM: reason = @"ran out of memory"; break;
      case TS_LAUNCH_FAILED: reason = @"could not be started"; break;
      case TS_INTEGRITY_FAILURE: reason = @"failed an integrity check"; break;
      default: reason = @"crashed"; break;
    }
    NSLog(@"Cairn: renderer terminated (status %d, code %d): %@", (int)status, code, String(error));
    [owner renderProcessTerminated:reason code:code];
  }
 private:
  CefRefPtr<CefResourceRequestHandler> resource_;
  IMPLEMENT_REFCOUNTING(RequestHandler);
};
}

CefRefPtr<CefRequestHandler> MakeRequestHandler(Client& client) {
  return new RequestHandler(client, MakeResourceRequestHandler(client));
}

}  // namespace cc

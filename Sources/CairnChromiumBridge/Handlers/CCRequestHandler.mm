// CCRequestHandler.mm — CefRequestHandler: renderer crashes, plus the hook that gives CEF the
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
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int code,
                                 const CefString& error) override {
    auto tab = owner;
    tab.state[@"error"] = [NSString stringWithFormat:@"Renderer stopped (%d): %@", code, String(error)];
    [tab cancelReplies:@"Renderer stopped"]; [tab publish];
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

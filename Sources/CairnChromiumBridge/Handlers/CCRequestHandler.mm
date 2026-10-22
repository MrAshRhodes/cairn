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
  // Middle- and Cmd-click reach here (not OnBeforePopup); without this CEF navigates the source tab.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& url,
                        WindowOpenDisposition disposition, bool gesture) override {
    bool background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    if (!background && disposition != CEF_WOD_NEW_FOREGROUND_TAB && disposition != CEF_WOD_NEW_WINDOW) return false;
    auto tab = owner;
    if (gesture) [tab.delegate chromiumTab:tab popup:String(url) activate:!background];
    return true;
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

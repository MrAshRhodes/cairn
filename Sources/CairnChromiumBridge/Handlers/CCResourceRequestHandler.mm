// CCResourceRequestHandler.mm — CefResourceRequestHandler: per-request network hooks.
//
// CEF reaches this through CefRequestHandler::GetResourceRequestHandler (CCRequestHandler.mm), once per
// browser, for every request. Callbacks may run on a CEF thread other than the main thread: keep state in
// this handler, keep it thread-safe, keep it fast and never block. Today it implements only external
// protocol handling; request filtering, header rewriting and custom schemes belong here too.
#import "../CCInternal.h"

namespace cc {
namespace {
class ResourceRequestHandler final : public TabHandler, public CefResourceRequestHandler {
 public:
  explicit ResourceRequestHandler(Client& client) : TabHandler(client) {}

  // Chromium never launches another application itself: the page's navigation to mailto:, tel: or a custom
  // scheme is reported to the app, which decides (allow-list, consent prompt) and opens it.
  void OnProtocolExecution(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                           bool& allow_os_execution) override {
    allow_os_execution = false;
    NSString *url = String(request->GetURL());
    __weak CCChromiumTab *weakTab = owner;
    dispatch_async(dispatch_get_main_queue(), ^{
      CCChromiumTab *tab = weakTab;
      if (!tab || tab.closing) return;
      if ([tab.delegate conformsToProtocol:@protocol(CCChromiumTabContextMenuDelegate)])
        [(id<CCChromiumTabContextMenuDelegate>)tab.delegate chromiumTab:tab openExternalURL:url];
    });
  }
 private:
  IMPLEMENT_REFCOUNTING(ResourceRequestHandler);
};
}

CefRefPtr<CefResourceRequestHandler> MakeResourceRequestHandler(Client& client) {
  return new ResourceRequestHandler(client);
}

}  // namespace cc

// CCLifeSpanHandler.mm — CefLifeSpanHandler: browser creation, close and popups. It owns the browser
// lifecycle bookkeeping (Client::browser, the `clients` map, request-context cleanup, shutdown completion),
// so it is the one handler that keeps a reference to its Client.
#import "../CCInternal.h"
#include <algorithm>

namespace cc {
namespace {
class LifeSpanHandler final : public TabHandler, public CefLifeSpanHandler {
 public:
  explicit LifeSpanHandler(Client& client) : TabHandler(client), client_(client) {}
  void OnAfterCreated(CefRefPtr<CefBrowser> created) override {
    pendingBrowsers--;
    client_.browser = created;
    clients[created->GetIdentifier()] = &client_;
    client_.registration = created->GetHost()->AddDevToolsMessageObserver(client_.devToolsObserver());
    auto tab = owner;
    if (!tab || tab.closing || stopping) created->GetHost()->CloseBrowser(true);
    else [tab browserCreated];
  }
  bool DoClose(CefRefPtr<CefBrowser> b) override {
    auto tab = owner;
    if (!tab.closing) [tab.delegate chromiumTabRequestsClose:tab];
    // Closing a tab must not send performClose: to the containing browser window.
    NSView *native = (__bridge NSView *)b->GetHost()->GetWindowHandle();
    [native removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
    CefRefPtr<Client> keepAlive(&client_);
    [owner cancelReplies:@"Tab closed"];
    client_.registration = nullptr;
    client_.browser = nullptr;
    client_.container = nil;
    clients.erase(b->GetIdentifier());
    if (client_.ephemeral && std::none_of(clients.begin(), clients.end(), [&](const auto& item) {
          return item.second->contextKey == client_.contextKey;
        })) contexts.erase(client_.contextKey);
    // Never call CefShutdown from inside a CEF callback stack.
    if (stopping && clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& url, const CefString&, WindowOpenDisposition disposition,
                     bool gesture, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    auto tab = owner;
    if (gesture && !url.empty())
      [tab.delegate chromiumTab:tab popup:String(url) activate:disposition != CEF_WOD_NEW_BACKGROUND_TAB];
    return true; // New tabs are owned by Cairn; no unmanaged CEF windows or unsolicited popups.
  }
 private:
  Client& client_;
  IMPLEMENT_REFCOUNTING(LifeSpanHandler);
};
}

CefRefPtr<CefLifeSpanHandler> MakeLifeSpanHandler(Client& client) { return new LifeSpanHandler(client); }

}  // namespace cc

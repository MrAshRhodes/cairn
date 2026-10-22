// CCLifeSpanHandler.mm — CefLifeSpanHandler: browser creation, close and popups. It owns the browser
// lifecycle bookkeeping (Client::browser, the `clients` map, request-context cleanup, shutdown completion),
// so it is the one handler that keeps a reference to its Client.
#import "../CCInternal.h"
#include <algorithm>
#include <map>

namespace cc {
namespace {
class LifeSpanHandler final : public TabHandler, public CefLifeSpanHandler {
 public:
  explicit LifeSpanHandler(Client& client) : TabHandler(client), client_(client) {}
  void OnAfterCreated(CefRefPtr<CefBrowser> created) override {
    pendingBrowsers--;
    creating[client_.contextKey]--;
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
    if (client_.ephemeral && creating[client_.contextKey] <= 0 && std::none_of(clients.begin(), clients.end(), [&](const auto& item) {
          return item.second->contextKey == client_.contextKey;
        })) contexts.erase(client_.contextKey);
    // Never call CefShutdown from inside a CEF callback stack.
    if (stopping && clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popupID,
                     const CefString& url, const CefString&, WindowOpenDisposition disposition,
                     bool gesture, const CefPopupFeatures&, CefWindowInfo& window, CefRefPtr<CefClient>& client,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    for (auto it = pendingPopups_.begin(); it != pendingPopups_.end();) {
      CCChromiumTab *pending = it->second;
      it = pending && pending.cefBrowser ? pendingPopups_.erase(it) : std::next(it);
    }
    auto tab = owner;
    id<CCChromiumTabLifeSpanDelegate> host = (id)tab.delegate;
    if (stopping || tab.closing || ![host respondsToSelector:@selector(chromiumTab:hostsPopup:disposition:userGesture:)])
      return true;
    CCPopupDisposition kind = CCPopupDispositionUnsupported;
    switch (disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB: case CEF_WOD_NEW_POPUP: case CEF_WOD_NEW_WINDOW:
        kind = CCPopupDispositionForeground; break;
      case CEF_WOD_NEW_BACKGROUND_TAB: kind = CCPopupDispositionBackground; break;
      default: break;
    }
    CCChromiumTab *popup = [host chromiumTab:tab hostsPopup:String(url) disposition:kind userGesture:gesture];
    if (!popup) return true;
    CefRefPtr<CefClient> popupClient = popup.adoptedClient;
    if (!popupClient) return true;
    // CEF creates the browser inside the popup tab's view, in the opener's request context.
    pendingBrowsers++;
    pendingPopups_[popupID] = popup;
    window.SetAsChild((__bridge void *)popup.view,
                      CefRect(0, 0, popup.view.bounds.size.width, popup.view.bounds.size.height));
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = popupClient;
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popupID) override {
    auto it = pendingPopups_.find(popupID);
    if (it == pendingPopups_.end()) return;
    CCChromiumTab *popup = it->second;
    pendingPopups_.erase(it);
    pendingBrowsers--;
    if (popup) [popup.delegate chromiumTabRequestsClose:popup];
    if (stopping && clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  }
 private:
  Client& client_;
  // Popups handed to CEF whose browser does not exist yet; weak so an unfinished popup never outlives its tab.
  std::map<int, __weak CCChromiumTab *> pendingPopups_;
  IMPLEMENT_REFCOUNTING(LifeSpanHandler);
};
}

CefRefPtr<CefLifeSpanHandler> MakeLifeSpanHandler(Client& client) { return new LifeSpanHandler(client); }

}  // namespace cc

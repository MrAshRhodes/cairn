// CCLoadHandler.mm — CefLoadHandler: loading state, load errors and the main-frame security indicator.
// Reference pattern for a handler that publishes tab state: read the tab weakly, mutate `state`, publish.
#import "../CCInternal.h"

namespace cc {
namespace {
class LoadHandler final : public TabHandler, public CefLoadHandler {
 public:
  explicit LoadHandler(Client& client) : TabHandler(client) {}
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    auto tab = owner;
    if (!tab.bootstrapDocument) { if (loading) [tab armNavigationWatchdog]; else [tab disarmNavigationWatchdog]; }
    tab.state[@"isLoading"] = @(loading);
    tab.state[@"canGoBack"] = @(back);
    tab.state[@"canGoForward"] = @(forward);
    if (loading) {
      [tab.state removeObjectForKey:@"error"];
      tab.state[@"isSecure"] = @NO;
    }
    [tab publish];
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain()) return;
    auto tab = owner;
    if (tab.awaitingRecovery) { tab.awaitingRecovery = NO; [tab publishHealth:@"healthy" detail:@"" code:0]; }
    auto entry = b->GetHost()->GetVisibleNavigationEntry();
    auto ssl = entry ? entry->GetSSLStatus() : nullptr;
    tab.state[@"isSecure"] = @(ssl && ssl->IsSecureConnection() && ssl->GetCertStatus() == 0
                               && ssl->GetContentStatus() == SSL_CONTENT_NORMAL_CONTENT);
    [tab publish];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString& text, const CefString&) override {
    if (!frame->IsMain() || code == ERR_ABORTED) return;
    auto tab = owner;
    [tab disarmNavigationWatchdog];
    tab.state[@"error"] = [NSString stringWithFormat:@"%@ (%d)", String(text), code];
    tab.state[@"isSecure"] = @NO;
    [tab publish];
  }
 private:
  IMPLEMENT_REFCOUNTING(LoadHandler);
};
}

CefRefPtr<CefLoadHandler> MakeLoadHandler(Client& client) { return new LoadHandler(client); }

}  // namespace cc

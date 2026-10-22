// CCDevToolsObserver.mm — CefDevToolsMessageObserver: routes DevTools replies back to the tab's
// pending calls (CCChromiumTab call:params:reply:) and cancels them when the page agent detaches.
// Registered per browser by the LifeSpan handler via Client::devToolsObserver(). DevTools *events*
// (OnDevToolsEvent) are not forwarded yet; a feature that needs them overrides it here.
#import "../CCInternal.h"

namespace cc {
namespace {
class DevToolsObserver final : public TabHandler, public CefDevToolsMessageObserver {
 public:
  explicit DevToolsObserver(Client& client) : TabHandler(client) {}
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
                              const void *data, size_t size) override {
    NSData *copy = [NSData dataWithBytes:data length:size];
    __weak CCChromiumTab *tab = owner;
    // Completion handlers may issue another DevTools command. Deliver outside
    // CEF's observer iteration to avoid reentrant DevTools notifications.
    dispatch_async(dispatch_get_main_queue(), ^{ [tab received:id success:success data:copy]; });
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    __weak CCChromiumTab *tab = owner;
    dispatch_async(dispatch_get_main_queue(), ^{ [tab cancelReplies:@"Page debugging agent detached"]; });
  }
 private:
  IMPLEMENT_REFCOUNTING(DevToolsObserver);
};
}

CefRefPtr<CefDevToolsMessageObserver> MakeDevToolsObserver(Client& client) { return new DevToolsObserver(client); }

}  // namespace cc

// CCDisplayHandler.mm — CefDisplayHandler: progress, title and address changes.
// Favicons, fullscreen and console messages belong to this family too: add their overrides here.
#import "../CCInternal.h"

namespace cc {
namespace {
class DisplayHandler final : public TabHandler, public CefDisplayHandler {
 public:
  explicit DisplayHandler(Client& client) : TabHandler(client) {}
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    auto tab = owner; tab.state[@"progress"] = @(progress); [tab publish];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    auto tab = owner; tab.state[@"title"] = String(title); [tab publish];
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (!frame->IsMain()) return;
    auto tab = owner; tab.state[@"url"] = String(url); tab.state[@"isSecure"] = @NO; [tab publish];
  }
  void OnFullscreenModeChange(CefRefPtr<CefBrowser>, bool fullscreen) override {
    [owner pageFullscreenChanged:fullscreen];
  }
 private:
  IMPLEMENT_REFCOUNTING(DisplayHandler);
};
}

CefRefPtr<CefDisplayHandler> MakeDisplayHandler(Client& client) { return new DisplayHandler(client); }

}  // namespace cc

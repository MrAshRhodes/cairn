// CCDisplayHandler.mm — CefDisplayHandler: progress, title and address changes.
// Favicons are fetched here, so the delegate only ever sees PNG bytes. Fullscreen and console messages belong to this family too: add their overrides here.
#import "../CCInternal.h"
#include <memory>
#include "include/cef_parser.h"
#include <vector>

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
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
    std::vector<CefString> candidates = urls;
    // Pages without a declared icon still commonly serve one at the origin root.
    if (candidates.empty()) {
      CefString address = browser->GetMainFrame()->GetURL();
      CefURLParts parts;
      if (CefParseURL(address, parts) && CefString(&parts.scheme).ToString().rfind("http", 0) == 0) {
        candidates.push_back(CefString(CefString(&parts.origin).ToString() + "/favicon.ico"));
      }
    }
    Fetch(browser, std::make_shared<std::vector<CefString>>(candidates), 0, ++generation_);
  }
 private:
  // Tries candidates in order until one decodes; a newer icon list supersedes an in-flight chain.
  void Fetch(CefRefPtr<CefBrowser> browser, std::shared_ptr<std::vector<CefString>> urls, size_t index, int generation) {
    if (index >= urls->size()) { Deliver(nil, nil); return; }
    class Callback final : public CefDownloadImageCallback {
     public:
      Callback(DisplayHandler *handler, CefRefPtr<CefBrowser> b, std::shared_ptr<std::vector<CefString>> u,
               size_t i, int g) : handler_(handler), browser_(b), urls_(u), index_(i), generation_(g) {}
      void OnDownloadImageFinished(const CefString& url, int, CefRefPtr<CefImage> image) override {
        if (generation_ != handler_->generation_) return;
        int width = 0, height = 0;
        CefRefPtr<CefBinaryValue> png = image && !image->IsEmpty() ? image->GetAsPNG(2.0f, true, width, height) : nullptr;
        if (png && png->GetSize() > 0) {
          std::vector<uint8_t> bytes(png->GetSize());
          png->GetData(bytes.data(), bytes.size(), 0);
          handler_->Deliver([NSData dataWithBytes:bytes.data() length:bytes.size()], String(url));
        } else {
          handler_->Fetch(browser_, urls_, index_ + 1, generation_);
        }
      }
     private:
      CefRefPtr<DisplayHandler> handler_;
      CefRefPtr<CefBrowser> browser_;
      std::shared_ptr<std::vector<CefString>> urls_;
      size_t index_;
      int generation_;
      IMPLEMENT_REFCOUNTING(Callback);
    };
    browser->GetHost()->DownloadImage((*urls)[index], true, 64, false,
                                      new Callback(this, browser, urls, index, generation));
  }
  void Deliver(NSData *png, NSString *url) {
    auto tab = owner;
    id<CCChromiumTabFaviconDelegate> delegate = (id)tab.delegate;
    if ([delegate conformsToProtocol:@protocol(CCChromiumTabFaviconDelegate)]) {
      [delegate chromiumTab:tab faviconPNG:png iconURL:url];
    }
  }
  int generation_ = 0;
  IMPLEMENT_REFCOUNTING(DisplayHandler);
};
}

CefRefPtr<CefDisplayHandler> MakeDisplayHandler(Client& client) { return new DisplayHandler(client); }

}  // namespace cc

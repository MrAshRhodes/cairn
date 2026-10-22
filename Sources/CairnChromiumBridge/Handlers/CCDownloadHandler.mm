// CCDownloadHandler.mm — CefDownloadHandler: hands downloads to Cairn's own download manager.
#import "../CCInternal.h"

namespace cc {
namespace {
class DownloadHandler final : public TabHandler, public CefDownloadHandler {
 public:
  explicit DownloadHandler(Client& client) : TabHandler(client) {}
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                        const CefString& filename, CefRefPtr<CefBeforeDownloadCallback>) override {
    auto tab = owner;
    [tab.delegate chromiumTab:tab download:String(item->GetURL()) filename:String(filename)];
    return true; // Not continuing the callback cancels CEF's unmanaged download.
  }
 private:
  IMPLEMENT_REFCOUNTING(DownloadHandler);
};
}

CefRefPtr<CefDownloadHandler> MakeDownloadHandler(Client& client) { return new DownloadHandler(client); }

}  // namespace cc

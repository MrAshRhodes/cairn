// CCDragHandler.mm — CefDragHandler: what may be dragged into a page.
// Dragging links, text and files into and out of pages is Chromium's own native behavior; this only
// refuses drags that would navigate to script, so dropping a javascript: link never runs it.
#import "../CCInternal.h"

namespace cc {
namespace {
class DragHandler final : public TabHandler, public CefDragHandler {
 public:
  explicit DragHandler(Client& client) : TabHandler(client) {}
  bool OnDragEnter(CefRefPtr<CefBrowser>, CefRefPtr<CefDragData> data, DragOperationsMask) override {
    if (!data->IsLink()) return false;
    NSString *scheme = [NSURL URLWithString:String(data->GetLinkURL())].scheme.lowercaseString;
    return [@[@"javascript", @"vbscript", @"data"] containsObject:scheme ?: @""];
  }
 private:
  IMPLEMENT_REFCOUNTING(DragHandler);
};
}

CefRefPtr<CefDragHandler> MakeDragHandler(Client& client) { return new DragHandler(client); }

}  // namespace cc

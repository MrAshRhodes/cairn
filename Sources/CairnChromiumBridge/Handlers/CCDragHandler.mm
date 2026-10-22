// CCDragHandler.mm — SKELETON: dragging into the page and draggable regions.
//
// CEF family: CefDragHandler (OnDragEnter, OnDraggableRegionsChanged).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetDragHandler() and CCClient.mm call MakeDragHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class DragHandler final : public TabHandler, public CefDragHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(DragHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new DragHandler(client);`.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefDragHandler> MakeDragHandler(Client&) { return nullptr; }

}  // namespace cc

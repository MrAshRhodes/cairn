// CCContextMenuHandler.mm — SKELETON: the page context menu (right click).
//
// CEF family: CefContextMenuHandler (OnBeforeContextMenu, RunContextMenu, OnContextMenuCommand,
// OnContextMenuDismissed).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetContextMenuHandler() and CCClient.mm call MakeContextMenuHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class ContextMenuHandler final : public TabHandler, public CefContextMenuHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(ContextMenuHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new ContextMenuHandler(client);`.
// RunContextMenu lets Cairn present a native NSMenu instead of CEF's own.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefContextMenuHandler> MakeContextMenuHandler(Client&) { return nullptr; }

}  // namespace cc

// CCFocusHandler.mm — SKELETON: keyboard focus moving between the page and Cairn's chrome.
//
// CEF family: CefFocusHandler (OnTakeFocus, OnSetFocus, OnGotFocus).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetFocusHandler() and CCClient.mm call MakeFocusHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class FocusHandler final : public TabHandler, public CefFocusHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(FocusHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new FocusHandler(client);`.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefFocusHandler> MakeFocusHandler(Client&) { return nullptr; }

}  // namespace cc

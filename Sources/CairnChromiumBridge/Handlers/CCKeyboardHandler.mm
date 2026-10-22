// CCKeyboardHandler.mm — SKELETON: keyboard events before and after the page sees them.
//
// CEF family: CefKeyboardHandler (OnPreKeyEvent, OnKeyEvent).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetKeyboardHandler() and CCClient.mm call MakeKeyboardHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class KeyboardHandler final : public TabHandler, public CefKeyboardHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(KeyboardHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new KeyboardHandler(client);`.
// OnPreKeyEvent runs before the page and can claim shortcuts; OnKeyEvent sees keys the page left unhandled.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefKeyboardHandler> MakeKeyboardHandler(Client&) { return nullptr; }

}  // namespace cc

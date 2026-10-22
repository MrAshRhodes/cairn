// CCJSDialogHandler.mm — SKELETON: JavaScript dialogs (alert, confirm, prompt, beforeunload).
//
// CEF family: CefJSDialogHandler (OnJSDialog, OnBeforeUnloadDialog, OnResetDialogState, OnDialogClosed).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetJSDialogHandler() and CCClient.mm call MakeJSDialogHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class JSDialogHandler final : public TabHandler, public CefJSDialogHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(JSDialogHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new JSDialogHandler(client);`.
// Dialog callbacks complete asynchronously through the CefJSDialogCallback CEF gives you.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefJSDialogHandler> MakeJSDialogHandler(Client&) { return nullptr; }

}  // namespace cc

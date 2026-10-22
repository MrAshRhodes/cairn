// CCDialogHandler.mm — SKELETON: native file dialogs requested by pages (<input type=file>, uploads).
//
// CEF family: CefDialogHandler (OnFileDialog).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetDialogHandler() and CCClient.mm call MakeDialogHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class DialogHandler final : public TabHandler, public CefDialogHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(DialogHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new DialogHandler(client);`.
// OnFileDialog completes through the CefFileDialogCallback it receives, so keep that until the user answers.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefDialogHandler> MakeDialogHandler(Client&) { return nullptr; }

}  // namespace cc

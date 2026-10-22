// CCPermissionHandler.mm — SKELETON: site permission requests (camera, microphone, geolocation, ...).
//
// CEF family: CefPermissionHandler (OnRequestMediaAccessPermission, OnShowPermissionPrompt,
// OnDismissPermissionPrompt).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: Client::GetPermissionHandler() and CCClient.mm call MakePermissionHandler below.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class PermissionHandler final : public TabHandler, public CefPermissionHandler` in the
//      anonymous namespace, ending with IMPLEMENT_REFCOUNTING(PermissionHandler) (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new PermissionHandler(client);`.
// Prompts are answered later through the callback objects CEF passes in; keep them until then.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefPermissionHandler> MakePermissionHandler(Client&) { return nullptr; }

}  // namespace cc

// CCResourceRequestHandler.mm — SKELETON: per-request network hooks (request filtering and blocking,
// header rewriting, response inspection, custom schemes).
//
// CEF family: CefResourceRequestHandler (GetCookieAccessFilter, OnBeforeResourceLoad,
// GetResourceHandler, OnResourceRedirect, OnResourceResponse, GetResourceResponseFilter,
// OnResourceLoadComplete, OnProtocolExecution).
// Status: not implemented. The factory returns nullptr, which keeps CEF's default behavior.
// Already registered: CEF reaches this through CefRequestHandler::GetResourceRequestHandler, so it has
// no CefClient getter and no line in CCClient.mm; MakeRequestHandler (CCRequestHandler.mm) calls the
// factory below once per browser and hands the result to CEF for every request. Callbacks may run on
// a CEF thread other than the main thread, so keep state in this handler and keep it thread-safe.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. add `class ResourceRequestHandler final : public TabHandler, public CefResourceRequestHandler`
//      in the anonymous namespace, ending with IMPLEMENT_REFCOUNTING(ResourceRequestHandler)
//      (pattern: CCFindHandler.mm);
//   2. replace the factory body with `return new ResourceRequestHandler(client);`.
// Callbacks may run for every subresource of every tab: keep them fast and never block.
#import "../CCInternal.h"

namespace cc {

CefRefPtr<CefResourceRequestHandler> MakeResourceRequestHandler(Client&) { return nullptr; }

}  // namespace cc

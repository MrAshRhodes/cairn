// Factories for the CEF handler families a Client hands out. Included through CCInternal.h.
//
// One family per file, named after its factory: Make<Family>Handler lives in CC<Family>Handler.mm.
// Client's constructor (CCClient.mm) calls every factory once per browser, except
// MakeResourceRequestHandler, which MakeRequestHandler calls because CEF reaches that family through
// CefRequestHandler. A factory that returns nullptr gives CEF's default behavior, which is what the
// skeleton families do until a feature implements them. Implementing a family therefore never edits
// this file, CCInternal.h or CCClient.mm.
#pragma once

namespace cc {

class Client;

// Implemented.
CefRefPtr<CefLifeSpanHandler> MakeLifeSpanHandler(Client& client);
CefRefPtr<CefLoadHandler> MakeLoadHandler(Client& client);
CefRefPtr<CefDisplayHandler> MakeDisplayHandler(Client& client);
CefRefPtr<CefFindHandler> MakeFindHandler(Client& client);
CefRefPtr<CefDownloadHandler> MakeDownloadHandler(Client& client);
CefRefPtr<CefRequestHandler> MakeRequestHandler(Client& client);
CefRefPtr<CefDevToolsMessageObserver> MakeDevToolsObserver(Client& client);

// Skeletons: empty, documented, and registered; each returns nullptr today.
CefRefPtr<CefJSDialogHandler> MakeJSDialogHandler(Client& client);
CefRefPtr<CefPermissionHandler> MakePermissionHandler(Client& client);
CefRefPtr<CefContextMenuHandler> MakeContextMenuHandler(Client& client);
CefRefPtr<CefKeyboardHandler> MakeKeyboardHandler(Client& client);
CefRefPtr<CefFocusHandler> MakeFocusHandler(Client& client);
CefRefPtr<CefAudioHandler> MakeAudioHandler(Client& client);
CefRefPtr<CefDragHandler> MakeDragHandler(Client& client);
CefRefPtr<CefDialogHandler> MakeDialogHandler(Client& client);
CefRefPtr<CefResourceRequestHandler> MakeResourceRequestHandler(Client& client);

}  // namespace cc

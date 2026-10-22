// CCInternal.h — private header of the CairnChromiumBridge target. It deliberately lives outside
// include/: only CairnChromiumBridge.h is visible to Swift.
//
// File map (SwiftPM compiles every .mm below this directory; adding a file needs no manifest edit):
//   include/CairnChromiumBridge.h  public API for Swift. Additive changes only, each in its own slot.
//   CCInternal.h                   shared state, helpers, the CCChromiumTab class extension, Client.
//   CCRuntime.mm                   CEF start/stop, message pump, request contexts.
//   CCRuntime+SiteData.mm          clearing site data, deleting profiles, orphan GC.
//   CCTab.mm                       CCChromiumTab: navigation, DevTools calls, scripts, find, snapshot.
//   CCTab+<Feature>.mm             optional per-feature tab commands, written as categories.
//   CCClient.mm                    Client constructor: the registration list of CEF handler families.
//   Handlers/CC<Family>Handler.mm  one file per CEF handler family (factories: Handlers/CCHandlers.h).
//
// Adding a Chromium feature that needs a CEF handler touches only that family's file:
//   1. Open Handlers/CC<Family>Handler.mm. Skeleton families already exist, and their getter and
//      registration are pre-seeded here and in CCClient.mm.
//   2. Add a `final` class deriving from TabHandler and the CEF handler (copy CCFindHandler.mm), then
//      return it from the family's Make...Handler factory instead of nullptr.
//   3. Report results to Swift through additive API in your own slot of CairnChromiumBridge.h (a
//      CCChromiumTab<Feature>Delegate protocol for events, a CCChromiumTab (<Feature>) category for
//      commands) and the extension files on the Swift side (see Sources/CairnEngineKit/EngineTabEvents.swift).
// Handlers run on the CEF UI thread, which is the AppKit main thread (external message pump). The
// exceptions are named in the CEF headers (e.g. audio packets, resource requests): keep those off tab state.
#pragma once

#if !__has_include("include/cef_version.h") || !__has_include("libcef_dll_wrapper/libcef_dll_wrapper.a")
#error "Chromium (CEF) is not prepared for this build. Run `make cef` (python3 engine/tool.py fetch && python3 engine/tool.py build) first; when CAIRN_CEF_ARCH selects a non-host architecture, add --arch <arm64|x86_64> to both commands."
#endif

#import "CairnChromiumBridge.h"
#include <map>
#include <string>
#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"

// The class extension below predates this header (it lived in the .mm) and is not nullability-audited.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

typedef void (^DevToolsReply)(NSDictionary *_Nullable, NSError *_Nullable);

@interface CCChromiumTab ()
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) NSMutableDictionary *state;
@property(nonatomic, copy) NSString *profile;
@property(nonatomic) BOOL ephemeral;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL pageEnabled;
@property(nonatomic, copy) NSString *pendingURL;
@property(nonatomic, copy) NSArray *configuredScripts;
@property(nonatomic, strong) NSMutableArray<NSString *> *scriptIDs;
@property(nonatomic) NSUInteger scriptGeneration;
@property(nonatomic) NSUInteger scriptOperations;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DevToolsReply> *replies;
@property(nonatomic, copy) void (^findReply)(BOOL);
@property(nonatomic, copy) NSString *lastFind;
- (void)ensureBrowser;
- (void)browserCreated;
- (void)publish;
- (void)call:(NSString *)method params:(NSDictionary *)params reply:(DevToolsReply)reply;
- (void)received:(int)identifier success:(BOOL)success data:(NSData *)data;
- (void)cancelReplies:(NSString *)reason;
- (void)drainNavigation;
- (void)applyAudioMuted;
// The CEF browser, or null until CEF created it. Categories (CCTab+<Feature>.mm) cannot see the
// tab's ivars, so they reach CEF through this.
- (CefRefPtr<CefBrowser>)cefBrowser;
// Popup adoption (CCTab+LifeSpan.mm): the client CEF is handed for a popup, created up front.
- (void)adoptClient;
- (CefRefPtr<CefClient>)adoptedClient;
@end

namespace cc {

class Client;

// Process-wide Chromium state, defined in CCRuntime.mm. Main thread only.
extern bool running;
extern bool ready;
extern bool stopping;
extern int pendingBrowsers;
extern std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
extern std::map<int, CefRefPtr<Client>> clients;
// Browsers being created per request-context key; a private context must outlive them.
extern std::map<std::string, int> creating;

NSString *String(const CefString& value);
NSError *Failure(NSString *message);
CefRefPtr<CefRequestContext> Context(NSString *profile, bool ephemeral);
void FinishShutdown();
NSString *ProfileRoot();
// CCRuntime+SiteData.mm: deferred deletions at launch, and the per-profile list of visited origins.
void ApplyPendingProfileWork(NSString *root);
void LoadTrackedOrigins(NSString *profile);
void TrackOrigin(const std::string& contextKey, const CefString& url);

// One per browser. CEF sees a plain CefClient that hands out one small handler object per family.
// Handlers are created in CCClient.mm and implemented in Handlers/. The public members are the
// browser's lifecycle state, shared with CCChromiumTab and the LifeSpan handler.
class Client final : public CefClient {
 public:
  __weak CCChromiumTab *owner;
  __strong NSView *container;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> registration;
  std::string contextKey;
  bool ephemeral;
  explicit Client(CCChromiumTab *tab);

  CefRefPtr<CefDevToolsMessageObserver> devToolsObserver() { return devTools_; }

  // A null handler means CEF's default behavior, so unimplemented families change nothing.
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return audio_; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return contextMenu_; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return dialog_; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return display_; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return download_; }
  CefRefPtr<CefDragHandler> GetDragHandler() override { return drag_; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return find_; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return focus_; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return jsDialog_; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return keyboard_; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return lifeSpan_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return load_; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return permission_; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return request_; }

 private:
  CefRefPtr<CefAudioHandler> audio_;
  CefRefPtr<CefContextMenuHandler> contextMenu_;
  CefRefPtr<CefDevToolsMessageObserver> devTools_;
  CefRefPtr<CefDialogHandler> dialog_;
  CefRefPtr<CefDisplayHandler> display_;
  CefRefPtr<CefDownloadHandler> download_;
  CefRefPtr<CefDragHandler> drag_;
  CefRefPtr<CefFindHandler> find_;
  CefRefPtr<CefFocusHandler> focus_;
  CefRefPtr<CefJSDialogHandler> jsDialog_;
  CefRefPtr<CefKeyboardHandler> keyboard_;
  CefRefPtr<CefLifeSpanHandler> lifeSpan_;
  CefRefPtr<CefLoadHandler> load_;
  CefRefPtr<CefPermissionHandler> permission_;
  CefRefPtr<CefRequestHandler> request_;
  IMPLEMENT_REFCOUNTING(Client);
};

// Base for handler classes that report to a tab. Handlers hold the tab weakly so that objects CEF
// retains can never keep a tab alive, and read it as `auto tab = owner;` per callback.
class TabHandler {
 protected:
  explicit TabHandler(Client& client) : owner(client.owner) {}
  __weak CCChromiumTab *owner;
};

}  // namespace cc

#pragma clang diagnostic pop

#import "Handlers/CCHandlers.h"

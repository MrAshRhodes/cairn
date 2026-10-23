// CCPermissionHandler.mm — CefPermissionHandler: camera, microphone, geolocation, notifications, ...
//
// Alloy style denies media and ignores every other prompt unless the client answers, so this handler
// forwards each request to Swift (CCChromiumTabPermissionDelegate) and completes the CEF callback when
// Swift calls -resolvePermission:allow:. Anything Swift cannot decide (no delegate, an unsupported kind,
// screen capture) is denied here: nothing is ever allowed by default.
#import "../CCInternal.h"
#import "CCPending.h"

namespace cc {
namespace {

struct KindBit { uint32_t bit; NSString *name; };

// Raw values of SitePermissionKind (CairnEngineKit).
const KindBit kPromptKinds[] = {
  {CEF_PERMISSION_TYPE_CAMERA_STREAM, @"camera"},
  {CEF_PERMISSION_TYPE_MIC_STREAM, @"microphone"},
  {CEF_PERMISSION_TYPE_GEOLOCATION, @"geolocation"},
  {CEF_PERMISSION_TYPE_NOTIFICATIONS, @"notifications"},
  {CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard"},
  {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"multipleDownloads"},
  {CEF_PERMISSION_TYPE_STORAGE_ACCESS, @"storageAccess"},
  {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"storageAccess"},
  {1u << 25, @"localNetwork"},  // LOCAL_NETWORK_ACCESS; its enumerator is renamed in the newest API
  {CEF_PERMISSION_TYPE_LOCAL_NETWORK, @"localNetwork"},
  {CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, @"localNetwork"},
  {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, @"keyboardLock"},
  {CEF_PERMISSION_TYPE_POINTER_LOCK, @"pointerLock"},
  {CEF_PERMISSION_TYPE_MIDI_SYSEX, @"midiSysex"},
  {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"windowManagement"},
  {CEF_PERMISSION_TYPE_LOCAL_FONTS, @"localFonts"},
  {CEF_PERMISSION_TYPE_IDLE_DETECTION, @"idleDetection"},
};

// Names for the requested bits, or nil when any bit is one Cairn does not offer.
NSArray<NSString *> *PromptKinds(uint32_t requested) {
  NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
  uint32_t remaining = requested;
  for (const auto& kind : kPromptKinds) {
    if (requested & kind.bit) { [names addObject:kind.name]; remaining &= ~kind.bit; }
  }
  return (remaining || !names.count) ? nil : names.array;
}

NSArray<NSString *> *MediaKinds(uint32_t requested) {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  uint32_t remaining = requested;
  if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    [names addObject:@"microphone"]; remaining &= ~CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
  }
  if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    [names addObject:@"camera"]; remaining &= ~CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
  }
  return (remaining || !names.count) ? nil : names;
}

class PermissionHandler final : public TabHandler, public CefPermissionHandler {
 public:
  explicit PermissionHandler(Client& client) : TabHandler(client) {}

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString& origin, uint32_t requested,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    NSArray<NSString *> *kinds = MediaKinds(requested);
    NSString *requestID = [@"m" stringByAppendingString:NSUUID.UUID.UUIDString];
    auto finish = ^(NSDictionary *answer) {
      if ([answer[@"allow"] boolValue]) callback->Continue(requested); else callback->Cancel();
    };
    return Forward(browser, requestID, origin, kinds, finish);
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t promptID, const CefString& origin,
                              uint32_t requested, CefRefPtr<CefPermissionPromptCallback> callback) override {
    NSArray<NSString *> *kinds = PromptKinds(requested);
    NSString *requestID = PromptID(promptID);
    auto finish = ^(NSDictionary *answer) {
      callback->Continue([answer[@"allow"] boolValue] ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    };
    return Forward(browser, requestID, origin, kinds, finish);
  }

  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t promptID,
                                 cef_permission_request_result_t) override {
    auto tab = owner;
    NSString *requestID = PromptID(promptID);
    if (!tab || !Pending(tab)[requestID]) return;
    [Pending(tab) removeObjectForKey:requestID];
    if ([tab.delegate conformsToProtocol:@protocol(CCChromiumTabPermissionDelegate)])
      [(id<CCChromiumTabPermissionDelegate>)tab.delegate chromiumTab:tab dismissesPermission:requestID];
  }

 private:
  NSString *PromptID(uint64_t identifier) {
    return [NSString stringWithFormat:@"p%@:%llu", instanceID_, identifier];
  }
  // Returns true: this handler always answers, either now (deny) or through Swift later.
  bool Forward(CefRefPtr<CefBrowser> browser, NSString *requestID, const CefString& origin,
               NSArray<NSString *> *kinds, PendingAnswer finish) {
    auto tab = owner;
    id<CCChromiumTabPermissionDelegate> delegate = nil;
    if ([tab.delegate conformsToProtocol:@protocol(CCChromiumTabPermissionDelegate)])
      delegate = (id<CCChromiumTabPermissionDelegate>)tab.delegate;
    if (!tab || tab.closing || stopping || !SameBrowser(tab.cefBrowser, browser) || !delegate || !kinds) {
      finish(@{@"allow": @NO}); return true;
    }
    Pending(tab)[requestID] = [finish copy];
    CefRefPtr<CefFrame> main = browser->GetMainFrame();
    NSString *topLevel = main ? String(main->GetURL()) : @"";
    [delegate chromiumTab:tab requestsPermission:requestID origin:String(origin) topLevel:topLevel kinds:kinds];
    return true;
  }

  NSString *instanceID_ = NSUUID.UUID.UUIDString;
  IMPLEMENT_REFCOUNTING(PermissionHandler);
};
}

CefRefPtr<CefPermissionHandler> MakePermissionHandler(Client& client) { return new PermissionHandler(client); }

}  // namespace cc

@implementation CCChromiumTab (Permission)
- (void)resolvePermission:(NSString *)requestID allow:(BOOL)allow {
  cc::Answer(self, requestID, @{@"allow": @(allow)});
}
@end

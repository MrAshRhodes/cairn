#if !__has_include("include/cef_version.h") || !__has_include("libcef_dll_wrapper/libcef_dll_wrapper.a")
#error "Chromium (CEF) is not prepared for this build. Run `make cef` (python3 engine/tool.py fetch && python3 engine/tool.py build) first; when CAIRN_CEF_ARCH selects a non-host architecture, add --arch <arm64|x86_64> to both commands."
#endif

#import "CairnChromiumBridge.h"
#import <crt_externs.h>
#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

namespace {
class Client;
bool running = false;
bool ready = false;
bool stopping = false;
bool terminated = false;
typedef void (^ShutdownCompletion)(void);
NSMutableArray<ShutdownCompletion> *shutdownCompletions;
int pendingBrowsers = 0;
bool pumping = false;
NSTimer *pumpTimer;
NSString *rootPath;
std::unique_ptr<CefScopedLibraryLoader> library;
std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
std::map<int, CefRefPtr<Client>> clients;

NSString *String(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

NSError *Failure(NSString *message) {
  return [NSError errorWithDomain:@"org.cairn.Chromium" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

void FinishShutdown();

void Pump() {
  if (!running || pumping) return;
  pumping = true;
  CefDoMessageLoopWork();
  pumping = false;
}

class Application final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { ready = true; }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    // CEF can call this on any thread. Chromium work stays on AppKit's main thread.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, std::clamp<int64_t>(delay, 0, 33) * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      Pump();
    });
  }
 private:
  IMPLEMENT_REFCOUNTING(Application);
};

CefRefPtr<CefRequestContext> Context(NSString *profile, bool ephemeral) {
  std::string key = std::string(ephemeral ? "private:" : "persistent:") + profile.UTF8String;
  auto found = contexts.find(key);
  if (found != contexts.end()) return found->second;
  CefRequestContextSettings settings;
  if (!ephemeral) {
    CefString(&settings.cache_path) = [[rootPath stringByAppendingPathComponent:profile] UTF8String];
  }
  auto context = CefRequestContext::CreateContext(settings, nullptr);
  contexts[key] = context;
  return context;
}
}

@interface CCApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end

@implementation CCApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
@end

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
@end

@interface CCContainerView : NSView
@property(nonatomic, weak) CCChromiumTab *owner;
@end

namespace {
class Client final : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefFindHandler,
                     public CefDownloadHandler,
                     public CefRequestHandler,
                     public CefDevToolsMessageObserver {
 public:
  __weak CCChromiumTab *owner;
  __strong NSView *container;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> registration;
  std::string contextKey;
  bool ephemeral;
  explicit Client(CCChromiumTab *tab) : owner(tab), container(tab.view),
      contextKey(std::string(tab.ephemeral ? "private:" : "persistent:") + tab.profile.UTF8String),
      ephemeral(tab.ephemeral) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> created) override {
    pendingBrowsers--;
    browser = created;
    clients[created->GetIdentifier()] = this;
    registration = created->GetHost()->AddDevToolsMessageObserver(this);
    auto tab = owner;
    if (!tab || tab.closing || stopping) created->GetHost()->CloseBrowser(true);
    else [tab browserCreated];
  }
  bool DoClose(CefRefPtr<CefBrowser> b) override {
    auto tab = owner;
    if (!tab.closing) [tab.delegate chromiumTabRequestsClose:tab];
    // Closing a tab must not send performClose: to the containing browser window.
    NSView *native = (__bridge NSView *)b->GetHost()->GetWindowHandle();
    [native removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
    CefRefPtr<Client> keepAlive(this);
    [owner cancelReplies:@"Tab closed"];
    registration = nullptr;
    browser = nullptr;
    container = nil;
    clients.erase(b->GetIdentifier());
    if (ephemeral && std::none_of(clients.begin(), clients.end(), [&](const auto& item) {
          return item.second->contextKey == contextKey;
        })) contexts.erase(contextKey);
    // Never call CefShutdown from inside a CEF callback stack.
    if (stopping && clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                     const CefString& url, const CefString&, WindowOpenDisposition disposition,
                     bool gesture, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    auto tab = owner;
    if (gesture && !url.empty())
      [tab.delegate chromiumTab:tab popup:String(url) activate:disposition != CEF_WOD_NEW_BACKGROUND_TAB];
    return true; // New tabs are owned by Cairn; no unmanaged CEF windows or unsolicited popups.
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool back, bool forward) override {
    auto tab = owner;
    tab.state[@"isLoading"] = @(loading);
    tab.state[@"canGoBack"] = @(back);
    tab.state[@"canGoForward"] = @(forward);
    if (loading) {
      [tab.state removeObjectForKey:@"error"];
      tab.state[@"isSecure"] = @NO;
    }
    [tab publish];
  }
  void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
    auto tab = owner; tab.state[@"progress"] = @(progress); [tab publish];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    auto tab = owner; tab.state[@"title"] = String(title); [tab publish];
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (!frame->IsMain()) return;
    auto tab = owner; tab.state[@"url"] = String(url); tab.state[@"isSecure"] = @NO; [tab publish];
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain()) return;
    auto tab = owner;
    auto entry = b->GetHost()->GetVisibleNavigationEntry();
    auto ssl = entry ? entry->GetSSLStatus() : nullptr;
    tab.state[@"isSecure"] = @(ssl && ssl->IsSecureConnection() && ssl->GetCertStatus() == 0
                               && ssl->GetContentStatus() == SSL_CONTENT_NORMAL_CONTENT);
    [tab publish];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString& text, const CefString&) override {
    if (!frame->IsMain() || code == ERR_ABORTED) return;
    auto tab = owner;
    tab.state[@"error"] = [NSString stringWithFormat:@"%@ (%d)", String(text), code];
    tab.state[@"isSecure"] = @NO;
    [tab publish];
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int code,
                                 const CefString& error) override {
    auto tab = owner;
    tab.state[@"error"] = [NSString stringWithFormat:@"Renderer stopped (%d): %@", code, String(error)];
    [tab cancelReplies:@"Renderer stopped"]; [tab publish];
  }
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&, int, bool final) override {
    auto tab = owner;
    if (final && tab.findReply) {
      auto callback = tab.findReply; tab.findReply = nil; callback(count > 0);
    }
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                        const CefString& filename, CefRefPtr<CefBeforeDownloadCallback>) override {
    auto tab = owner;
    [tab.delegate chromiumTab:tab download:String(item->GetURL()) filename:String(filename)];
    return true; // Not continuing the callback cancels CEF's unmanaged download.
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
                              const void *data, size_t size) override {
    NSData *copy = [NSData dataWithBytes:data length:size];
    __weak CCChromiumTab *tab = owner;
    // Completion handlers may issue another DevTools command. Deliver outside
    // CEF's observer iteration to avoid reentrant DevTools notifications.
    dispatch_async(dispatch_get_main_queue(), ^{ [tab received:id success:success data:copy]; });
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    __weak CCChromiumTab *tab = owner;
    dispatch_async(dispatch_get_main_queue(), ^{ [tab cancelReplies:@"Page debugging agent detached"]; });
  }
 private:
  IMPLEMENT_REFCOUNTING(Client);
};

void FinishShutdown() {
  if (!running || !stopping || !clients.empty() || pendingBrowsers) return;
  running = false;
  ready = false;
  [pumpTimer invalidate];
  pumpTimer = nil;
  contexts.clear();
  CefShutdown();
  library.reset();
  terminated = true; // CEF may only be initialized once per process.
  NSArray<ShutdownCompletion> *completions = [shutdownCompletions copy];
  shutdownCompletions = nil;
  for (ShutdownCompletion completion in completions) completion();
}

class Done final : public CefCompletionCallback {
 public:
  explicit Done(void (^block)(void)) : block_([block copy]) {}
  void OnComplete() override { block_(); }
 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(Done);
};
class CookiesDone final : public CefDeleteCookiesCallback {
 public:
  explicit CookiesDone(void (^block)(void)) : block_([block copy]) {}
  void OnComplete(int) override {
    auto callback = block_;
    dispatch_async(dispatch_get_main_queue(), callback);
  }
 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(CookiesDone);
};
}

@implementation CCContainerView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) [self.owner ensureBrowser];
}
@end

@implementation CCChromiumRuntime
+ (BOOL)prepareApplication {
  if (NSApp && ![NSApp isKindOfClass:CCApplication.class]) return NO;
  [CCApplication sharedApplication];
  return YES;
}
+ (BOOL)startWithRoot:(NSString *)root error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"CEF must initialize on the main thread");
  if (running && !stopping) {
    if ([rootPath isEqualToString:root]) return YES;
    if (error) *error = Failure(@"CEF is already initialized with a different data root.");
    return NO;
  }
  NSString *failure = nil;
  if (terminated || stopping) failure = @"Chromium was shut down; restart Cairn to use it again.";
  else if (![NSApp isKindOfClass:CCApplication.class])
    failure = @"Call ChromiumEngineModule.prepareApplication() before NSApplication.shared.";
  else if (![NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"app"])
    failure = @"Chromium requires a Cairn.app bundle. Run engine/bundle.py after building.";
  if (failure) { if (error) *error = Failure(failure); return NO; }
  rootPath = [root copy];
  if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
  library = std::make_unique<CefScopedLibraryLoader>();
  if (!library->LoadInMain()) {
    library.reset();
    if (error) *error = Failure(@"CEF framework could not be loaded. Verify bundle layout, architecture and signatures.");
    return NO;
  }
  CefSettings settings;
  settings.external_message_pump = true;
  settings.command_line_args_disabled = true;
  settings.no_sandbox = false;
  CefString(&settings.root_cache_path) = root.UTF8String;
  // No global cache path: each Space receives its own request context below.
  CefString(&settings.log_file) = [[root stringByAppendingPathComponent:@"cef.log"] UTF8String];
  CefString(&settings.browser_subprocess_path) =
      [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
        @"Contents/Frameworks/Cairn Helper.app/Contents/MacOS/Cairn Helper"] UTF8String];
  running = CefInitialize(CefMainArgs(*_NSGetArgc(), *_NSGetArgv()), settings, new Application(), nullptr);
  if (!running) {
    library.reset();
    terminated = true;
    if (error) *error = Failure(@"CEF initialization failed (including singleton/profile lock). See cef.log.");
    return NO;
  }
  // CEF's external pump needs a bounded idle fallback as well as explicit work
  // requests; otherwise renderer IPC can stall. Common modes keep it alive while
  // AppKit tracks menus/resizes. Pump guards nested event-loop reentrancy.
  pumpTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *) { Pump(); }];
  [NSRunLoop.mainRunLoop addTimer:pumpTimer forMode:NSRunLoopCommonModes];
  Pump();
  return YES;
}
+ (NSString *)versionDescription {
  return [NSString stringWithFormat:@"Chromium %d.%d.%d.%d (CEF %s)",
          CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH, CEF_VERSION];
}
+ (void)shutdown {
  if (!running || stopping) return;
  stopping = true;
  auto snapshot = clients;
  for (const auto& pair : snapshot) {
    auto client = pair.second;
    client->owner.closing = YES;
    if (client->browser) client->browser->GetHost()->CloseBrowser(true);
  }
  if (clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
}
+ (void)shutdownWithCompletion:(void (^)(void))completion {
  NSAssert(NSThread.isMainThread, @"CEF must shut down on the main thread");
  if (!running) {
    dispatch_async(dispatch_get_main_queue(), completion);
    return;
  }
  if (!shutdownCompletions) shutdownCompletions = [NSMutableArray array];
  [shutdownCompletions addObject:[completion copy]];
  [self shutdown];
}
+ (void)clearProfile:(NSString *)profile cookies:(BOOL)cookies cache:(BOOL)cache
         completion:(void (^)(void))completion {
  if (!running || stopping) { completion(); return; }
  auto context = Context(profile, false);
  dispatch_group_t group = dispatch_group_create();
  if (cookies) {
    dispatch_group_enter(group);
    CefRefPtr<CookiesDone> done = new CookiesDone(^{ dispatch_group_leave(group); });
    if (!context->GetCookieManager(nullptr)->DeleteCookies("", "", done)) done->OnComplete(0);
  }
  if (cache) {
    dispatch_group_enter(group);
    context->ClearHttpCache(new Done(^{ dispatch_group_leave(group); }));
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), completion);
}
@end

@implementation CCChromiumTab {
  CefRefPtr<Client> _client;
  int _nextMessage;
  double _zoom;
}
- (instancetype)initWithProfile:(NSString *)profile ephemeral:(BOOL)ephemeral {
  if ((self = [super init])) {
    _profile = [profile copy]; _ephemeral = ephemeral; _zoom = 1;
    _state = [@{@"title": @"", @"progress": @0, @"isLoading": @NO, @"isSecure": @NO} mutableCopy];
    _configuredScripts = @[]; _scriptIDs = [NSMutableArray array]; _replies = [NSMutableDictionary dictionary];
    CCContainerView *container = [[CCContainerView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    container.owner = self;
    _view = container;
  }
  return self;
}
- (void)dealloc {
  if (_client && _client->browser && running) _client->browser->GetHost()->CloseBrowser(true);
}
- (void)ensureBrowser {
  if (_client || self.closing || !running || stopping || !self.view.window) return;
  if (!ready) {
    __weak CCChromiumTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(),
                   ^{ [weakSelf ensureBrowser]; });
    return;
  }
  _client = new Client(self);
  CefWindowInfo window;
  window.SetAsChild((__bridge void *)self.view,
                    CefRect(0, 0, self.view.bounds.size.width, self.view.bounds.size.height));
  window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  // New request contexts initialize asynchronously. CreateBrowserSync can reject
  // them before their browser context is ready; CreateBrowser waits correctly.
  pendingBrowsers++;
  bool accepted = CefBrowserHost::CreateBrowser(window, _client, "about:blank", settings, nullptr,
                                                Context(self.profile, self.ephemeral));
  if (!accepted) {
    pendingBrowsers--;
    _client = nullptr; self.state[@"error"] = @"CEF failed to create an embedded browser."; [self publish]; return;
  }
}
- (void)browserCreated {
  auto browser = _client->browser;
  NSView *native = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  native.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  native.frame = self.view.bounds;
  browser->GetHost()->SetZoomLevel(std::log(_zoom) / std::log(1.2));
  self.scriptOperations = 1;
  __weak CCChromiumTab *weakSelf = self;
  [self call:@"Page.enable" params:@{} reply:^(NSDictionary *, NSError *error) {
    auto tab = weakSelf;
    if (error) { tab.state[@"error"] = error.localizedDescription; [tab publish]; return; }
    tab.pageEnabled = YES;
    tab.scriptOperations--;
    [tab setScripts:tab.configuredScripts];
  }];
}
- (void)publish { [self.delegate chromiumTab:self changed:[self.state copy]]; }
- (void)loadURL:(NSString *)url { self.pendingURL = url; [self ensureBrowser]; [self drainNavigation]; }
- (void)drainNavigation {
  if (self.pendingURL && !self.scriptOperations && _client && _client->browser && !self.closing) {
    auto url = self.pendingURL; self.pendingURL = nil;
    _client->browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
}
- (void)goBack { if (_client && _client->browser) _client->browser->GoBack(); }
- (void)goForward { if (_client && _client->browser) _client->browser->GoForward(); }
- (void)reloadIgnoringCache:(BOOL)ignoringCache {
  if (!_client || !_client->browser) return;
  if (ignoringCache) _client->browser->ReloadIgnoreCache(); else _client->browser->Reload();
}
- (void)stop { self.pendingURL = nil; if (_client && _client->browser) _client->browser->StopLoad(); }
- (double)zoom { return _zoom; }
- (void)setZoom:(double)value {
  _zoom = std::isfinite(value) ? std::clamp(value, 0.25, 5.0) : 1.0;
  if (_client && _client->browser) _client->browser->GetHost()->SetZoomLevel(std::log(_zoom) / std::log(1.2));
}
- (void)find:(NSString *)query forward:(BOOL)forward completion:(void (^)(BOOL))completion {
  if (self.findReply) { auto old = self.findReply; self.findReply = nil; old(NO); }
  if (!_client || !_client->browser || !query.length) { completion(NO); return; }
  self.findReply = completion;
  _client->browser->GetHost()->Find(query.UTF8String, forward, false, [self.lastFind isEqualToString:query]);
  self.lastFind = query;
  __weak CCChromiumTab *weakSelf = self;
  auto callback = self.findReply;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    auto tab = weakSelf;
    if (tab.findReply == callback) { tab.findReply = nil; callback(NO); }
  });
}
- (void)clearFind {
  if (self.findReply) { auto callback = self.findReply; self.findReply = nil; callback(NO); }
  self.lastFind = nil;
  if (_client && _client->browser) _client->browser->GetHost()->StopFinding(true);
}
- (void)call:(NSString *)method params:(NSDictionary *)params reply:(DevToolsReply)reply {
  if (!_client || !_client->browser || self.closing) { reply(nil, Failure(@"Tab is not ready")); return; }
  NSData *json = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
  auto value = CefParseJSON(json.bytes, json.length, JSON_PARSER_RFC);
  int identifier = ++_nextMessage;
  self.replies[@(identifier)] = reply;
  int accepted = _client->browser->GetHost()->ExecuteDevToolsMethod(identifier, method.UTF8String, value->GetDictionary());
  if (!accepted) {
    [self.replies removeObjectForKey:@(identifier)]; reply(nil, Failure(@"CEF rejected the operation")); return;
  }
  __weak CCChromiumTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    auto tab = weakSelf;
    DevToolsReply pending = tab.replies[@(identifier)];
    if (pending) {
      [tab.replies removeObjectForKey:@(identifier)];
      pending(nil, Failure(@"Chromium operation timed out"));
    }
  });
}
- (void)received:(int)identifier success:(BOOL)success data:(NSData *)data {
  DevToolsReply reply = self.replies[@(identifier)];
  if (!reply) return;
  [self.replies removeObjectForKey:@(identifier)];
  NSDictionary *result = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
  if (![result isKindOfClass:NSDictionary.class]) { reply(nil, Failure(@"Malformed Chromium reply")); return; }
  reply(success ? result : nil, success ? nil : Failure(result[@"message"] ?: @"Chromium operation failed"));
}
- (void)cancelReplies:(NSString *)reason {
  NSDictionary *pending = [self.replies copy]; [self.replies removeAllObjects];
  for (DevToolsReply reply in pending.allValues) reply(nil, Failure(reason));
  [self clearFind];
}
- (void)evaluate:(NSString *)source completion:(void (^)(id, NSError *))completion {
  [self call:@"Runtime.evaluate" params:@{@"expression": source, @"returnByValue": @YES, @"awaitPromise": @YES}
       reply:^(NSDictionary *result, NSError *error) {
    if (error) { completion(nil, error); return; }
    if (result[@"exceptionDetails"]) {
      completion(nil, Failure([result[@"exceptionDetails"] description])); return;
    }
    NSDictionary *remote = result[@"result"];
    if (remote[@"unserializableValue"] || ([remote[@"type"] isEqual:@"object"] && !remote[@"value"]
                                          && ![remote[@"subtype"] isEqual:@"null"])) {
      completion(nil, Failure(@"JavaScript result is not JSON-serializable")); return;
    }
    completion(remote[@"value"] == NSNull.null ? nil : remote[@"value"], nil);
  }];
}
- (void)setScripts:(NSArray<NSDictionary<NSString *,NSString *> *> *)scripts {
  self.configuredScripts = [scripts copy];
  if (!_client || !_client->browser || !self.pageEnabled || self.closing) return;
  NSUInteger generation = ++self.scriptGeneration;
  NSArray *oldIDs = [self.scriptIDs copy]; [self.scriptIDs removeAllObjects];
  self.scriptOperations += oldIDs.count + scripts.count;
  __weak CCChromiumTab *weakSelf = self;
  void (^finish)(NSError *) = ^(NSError *error) {
    auto tab = weakSelf;
    if (!tab) return;
    if (error && generation == tab.scriptGeneration) { tab.state[@"error"] = error.localizedDescription; [tab publish]; }
    if (tab.scriptOperations) tab.scriptOperations--;
    [tab drainNavigation];
  };
  for (NSString *identifier in oldIDs) {
    [self call:@"Page.removeScriptToEvaluateOnNewDocument" params:@{@"identifier": identifier}
         reply:^(NSDictionary *, NSError *error) { finish(error); }];
  }
  for (NSDictionary *script in scripts) {
    NSString *source = script[@"source"] ?: @"";
    if ([script[@"injection"] isEqual:@"documentEnd"]) {
      source = [NSString stringWithFormat:
        @"document.addEventListener('DOMContentLoaded',()=>{\n%@\n},{once:true});", source];
    }
    [self call:@"Page.addScriptToEvaluateOnNewDocument" params:@{@"source": source}
         reply:^(NSDictionary *result, NSError *error) {
      auto tab = weakSelf;
      if (result[@"identifier"]) {
        if (generation == tab.scriptGeneration) [tab.scriptIDs addObject:result[@"identifier"]];
        else {
          tab.scriptOperations++;
          [tab call:@"Page.removeScriptToEvaluateOnNewDocument" params:@{@"identifier": result[@"identifier"]}
               reply:^(NSDictionary *, NSError *error) { finish(error); }];
        }
      }
      finish(error);
    }];
  }
  [self drainNavigation];
}
- (void)snapshot:(void (^)(NSImage *))completion {
  [self call:@"Page.captureScreenshot" params:@{@"format": @"png", @"captureBeyondViewport": @NO}
       reply:^(NSDictionary *result, NSError *error) {
    if (error || ![result[@"data"] isKindOfClass:NSString.class]) { completion(nil); return; }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:result[@"data"] options:0];
    completion(data ? [[NSImage alloc] initWithData:data] : nil);
  }];
}
- (void)close {
  if (self.closing) return;
  self.closing = YES; self.pendingURL = nil;
  [self cancelReplies:@"Tab closed"];
  if (_client && _client->browser) _client->browser->GetHost()->CloseBrowser(true);
}
@end

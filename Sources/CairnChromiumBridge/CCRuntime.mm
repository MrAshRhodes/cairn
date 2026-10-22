// CCRuntime.mm — CEF process lifecycle: library loading, initialization, the external message pump,
// request contexts (one per Space profile), profile clearing and shutdown.
#import "CCInternal.h"
#import <crt_externs.h>
#include <algorithm>
#include <memory>
#include "include/cef_application_mac.h"
#include "include/cef_cookie.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

using namespace cc;

namespace {
bool terminated = false;
bool useMockKeychain = false;
typedef void (^ShutdownCompletion)(void);
NSMutableArray<ShutdownCompletion> *shutdownCompletions;
bool pumping = false;
NSTimer *pumpTimer;
NSString *rootPath;
std::unique_ptr<CefScopedLibraryLoader> library;

void Pump() {
  if (!running || pumping) return;
  pumping = true;
  CefDoMessageLoopWork();
  pumping = false;
}

class Application final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    // Without this, an unattended run blocks forever on a Keychain authorization prompt
    // for the "Chromium Safe Storage" item and no page ever commits.
    if (useMockKeychain && process_type.empty()) command_line->AppendSwitch("use-mock-keychain");
  }
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

namespace cc {
bool running = false;
bool ready = false;
bool stopping = false;
int pendingBrowsers = 0;
std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
std::map<int, CefRefPtr<Client>> clients;

NSString *String(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @"";
}

NSError *Failure(NSString *message) {
  return [NSError errorWithDomain:@"org.cairn.Chromium" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

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

@implementation CCChromiumRuntime
+ (BOOL)prepareApplicationWithMockKeychain:(BOOL)mockKeychain {
  if (NSApp && ![NSApp isKindOfClass:CCApplication.class]) return NO;
  useMockKeychain = mockKeychain;
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

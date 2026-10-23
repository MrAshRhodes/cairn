// CCRuntime.mm — CEF process lifecycle: library loading, initialization, the external message pump,
// request contexts (one per Space profile), profile clearing and shutdown.
#import "CCInternal.h"
#import "Handlers/CCPending.h"
#import <crt_externs.h>
#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <memory>
#include <unistd.h>
#include "include/cef_application_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

using namespace cc;

namespace {
bool terminated = false;
// Read by the watchdog on a background queue; set once the shutdown completions have run.
std::atomic<bool> shutdownCompleted{false};
std::atomic<bool> shuttingDownCEF{false};
constexpr int64_t kCloseWarningSeconds = 4;
constexpr int64_t kHardExitSeconds = 10;
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
    // Chromium's built-in blocker makes window.open() return null without telling the browser. Turning it
    // off routes every attempt to OnBeforePopup (CCLifeSpanHandler.mm), where Cairn's popup policy blocks
    // or adopts it and the user can see what was blocked.
    if (process_type.empty()) command_line->AppendSwitch("disable-popup-blocking");
    if (useMockKeychain && process_type.empty()) command_line->AppendSwitch("use-mock-keychain");
    // Lets CefRequestHandler::GetAuthCredentials see HTTP authentication instead of Chromium's own prompt.
    if (process_type.empty()) command_line->AppendSwitch("disable-chrome-login-prompt");
  }
  void OnContextInitialized() override { ready = true; }
  bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine>, const CefString&) override {
    // A second launch on this profile: surface the running instance instead of letting CEF open an untracked window.
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp activateIgnoringOtherApps:YES];
      for (NSWindow *window in NSApp.windows) {
        if (window.canBecomeMainWindow) { [window makeKeyAndOrderFront:nil]; break; }
      }
    });
    return true;
  }
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

}

namespace cc {
bool running = false;
bool ready = false;
bool stopping = false;
int pendingBrowsers = 0;
std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
std::map<int, CefRefPtr<Client>> clients;
std::map<std::string, int> creating;

NSString *ProfileRoot() { return rootPath; }

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
    // Most login cookies have no expiry; Cairn restores tabs, so they must survive a relaunch.
    settings.persist_session_cookies = true;
    LoadTrackedOrigins(profile);
  }
  auto context = CefRequestContext::CreateContext(settings, nullptr);
  contexts[key] = context;
  return context;
}

void FinishShutdown() {
  if (!running || !stopping) return;
  if (!clients.empty() || pendingBrowsers) return;
  // A nested run loop can drain this block from inside CefDoMessageLoopWork; CefShutdown must not run there.
  if (pumping) { dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); }); return; }
  running = false;
  ready = false;
  [pumpTimer invalidate];
  pumpTimer = nil;
  contexts.clear();
  ReleaseDownloads();
  shuttingDownCEF = true;
  CefShutdown();
  library.reset();
  terminated = true; // CEF may only be initialized once per process.
  NSArray<ShutdownCompletion> *completions = [shutdownCompletions copy];
  shutdownCompletions = nil;
  for (ShutdownCompletion completion in completions) completion();
  shutdownCompleted = true;
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
    char existing[PATH_MAX];
    const char *requested = realpath(root.fileSystemRepresentation, existing) ? existing : root.fileSystemRepresentation;
    if ([rootPath isEqualToString:[NSString stringWithUTF8String:requested]]) return YES;
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
  if (![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
  // CEF requires every per-Space cache path to sit under the symlink-resolved root; otherwise it silently falls back to
  // an in-memory profile. Resolve once here and derive every path from the result.
  char resolved[PATH_MAX];
  if (!realpath(root.fileSystemRepresentation, resolved)) {
    if (error) *error = Failure(@"The Chromium data folder cannot be resolved.");
    return NO;
  }
  root = [NSString stringWithUTF8String:resolved];
  rootPath = [root copy];
  library = std::make_unique<CefScopedLibraryLoader>();
  if (!library->LoadInMain()) {
    library.reset();
    if (error) *error = Failure(@"CEF framework could not be loaded. Verify bundle layout, architecture and signatures.");
    return NO;
  }
  ApplyPendingProfileWork(root);
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
    int code = CefGetExitCode();
    NSString *message = [NSString stringWithFormat:@"CEF initialization failed (exit code %d, including singleton/profile lock). See cef.log.", code];
    if (error) *error = [NSError errorWithDomain:@"org.cairn.Chromium.Startup" code:code
                                        userInfo:@{NSLocalizedDescriptionKey: message}];
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
  NSAssert(NSThread.isMainThread, @"CEF must shut down on the main thread");
  if (!running || stopping) return;
  for (const auto& pair : clients) {
    if (!pair.second->closeApproved &&
        !pair.second->browser->GetHost()->IsReadyToBeClosed()) {
      NSLog(@"Cairn: refusing Chromium shutdown before every page has approved close.");
      return;
    }
  }
  stopping = true;
  // Arm before any CEF calls: CloseBrowser/callback cancellation can also stop making progress.
  // Never call CefShutdown with live browsers or unresolved creations. A failed quit must not
  // masquerade as a clean exit or invoke completion handlers that claim Chromium flushed its data.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kHardExitSeconds * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    if (shutdownCompleted) return;
    const char *phase = shuttingDownCEF ? "CEF teardown/completion" : "browser close/creation";
    NSLog(@"Cairn: Chromium shutdown FAILED after %lld s (%s); terminating with failure. "
           "Chromium data may not have been flushed.", kHardExitSeconds, phase);
    static const char diagnostic[] =
        "Cairn: Chromium shutdown timed out; unclean termination (exit 1). Data may not be flushed.\n";
    (void)write(STDERR_FILENO, diagnostic, sizeof(diagnostic) - 1);
    _exit(EXIT_FAILURE);
  });
  ReleaseDownloads();
  auto snapshot = clients;
  for (const auto& pair : snapshot) {
    auto client = pair.second;
    client->owner.closing = YES;
    CancelPending(client->owner);
    if (client->browser) client->browser->GetHost()->CloseBrowser(true);
  }
  if (clients.empty()) dispatch_async(dispatch_get_main_queue(), ^{ FinishShutdown(); });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kCloseWarningSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!running || !stopping) return;
    NSLog(@"Cairn: still waiting for Chromium shutdown: %zu open and %d pending browsers. "
           "Refusing unsafe CEF teardown.", clients.size(), pendingBrowsers);
    auto remaining = clients;
    for (const auto& pair : remaining) {
      if (pair.second->browser) pair.second->browser->GetHost()->CloseBrowser(true);
    }
    FinishShutdown();
  });
}
+ (void)shutdownWithCompletion:(void (^)(void))completion {
  NSAssert(NSThread.isMainThread, @"CEF must shut down on the main thread");
  if (terminated || (!running && !stopping)) {
    dispatch_async(dispatch_get_main_queue(), completion);
    return;
  }
  if (!shutdownCompletions) shutdownCompletions = [NSMutableArray array];
  [shutdownCompletions addObject:[completion copy]];
  [self shutdown];
}
@end

// CCTab.mm — CCChromiumTab: the browser view, navigation, DevTools calls with replies and timeouts,
// user scripts, find-in-page and snapshots. Feature-specific tab commands belong in CCTab+<Feature>.mm.
#import "CCInternal.h"
#include <algorithm>
#include <cmath>
#include "include/cef_parser.h"

using namespace cc;

namespace {
// The 30 s default can be shortened (never below 1 s) so the smoke test can exercise the watchdog quickly.
NSTimeInterval NavigationWatchdogSeconds() {
  const char *override = getenv("CAIRN_NAVIGATION_WATCHDOG_SECONDS");
  double seconds = override ? atof(override) : 0;
  return seconds >= 1 ? seconds : 30;
}
}

@interface CCContainerView : NSView
@property(nonatomic, weak) CCChromiumTab *owner;
@end

@implementation CCContainerView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) { [self.owner ensureBrowser]; [self.owner restoreContentFocus]; }
}
@end

@implementation CCChromiumTab {
  CefRefPtr<Client> _client;
  int _nextMessage;
  double _zoom;
  NSUInteger _navigationToken;
  BOOL _navigationStalled;
  NSUInteger _unresponsiveToken;
  CefRefPtr<CefUnresponsiveProcessCallback> _unresponsiveCallback;
}
- (instancetype)initWithProfile:(NSString *)profile ephemeral:(BOOL)ephemeral {
  if ((self = [super init])) {
    _profile = [profile copy]; _ephemeral = ephemeral; _zoom = 1; _bootstrapDocument = YES;
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
- (CefRefPtr<CefBrowser>)cefBrowser { return _client ? _client->browser : nullptr; }
- (void)adoptClient { if (!_client) _client = new Client(self); }
- (CefRefPtr<Client>)adoptedClient { return _client; }
- (void)ensureBrowser {
  if (_client || self.closing || !running || stopping || !self.view.window) return;
  if (!ready) {
    __weak CCChromiumTab *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(),
                   ^{ [weakSelf ensureBrowser]; });
    return;
  }
  auto context = Context(self.profile, self.ephemeral);
  if (!self.ephemeral && context->GetCachePath().empty()) {
    // CEF rejected the profile directory and would silently use an in-memory profile.
    contexts.erase(std::string("persistent:") + self.profile.UTF8String);
    self.state[@"error"] = @"Storage for this Space is unavailable, so Cairn will not load it. Check the Chromium data folder.";
    [self publish];
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
  _client->creationPending = true;
  pendingBrowsers++;
  creating[_client->contextKey]++;
  bool accepted = CefBrowserHost::CreateBrowser(window, _client, "about:blank", settings, nullptr, context);
  if (!accepted) {
    _client->creationPending = false;
    pendingBrowsers--;
    creating[_client->contextKey]--;
    _client = nullptr; self.state[@"error"] = @"CEF failed to create an embedded browser."; [self publish]; return;
  }
  // A creation that never reaches OnAfterCreated must not leak the counter that gates shutdown.
  CefRefPtr<Client> pending = _client;
  __weak CCChromiumTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!pending->creationPending) return;
    pending->creationPending = false;
    pending->abandoned = true;
    pendingBrowsers--;
    creating[pending->contextKey]--;
    NSLog(@"Cairn: Chromium did not finish creating a browser within 20 s; abandoning it.");
    CCChromiumTab *tab = weakSelf;
    if (!tab) return;
    if (tab->_client == pending) tab->_client = nullptr;
    tab.state[@"error"] = @"Chromium did not finish starting this page. Reload to try again.";
    tab.state[@"isLoading"] = @NO;
    [tab publish];
  });
}
- (void)browserCreated {
  auto browser = _client->browser;
  NSView *native = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  native.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  native.frame = self.view.bounds;
  browser->GetHost()->SetZoomLevel(std::log(_zoom) / std::log(1.2));
  [self enableSpellChecking];
  [self applyAudioMuted];
  [self beginBoot];
}
// Boot = Page.enable + user scripts. Every attempt chain settles `scriptOperations` exactly once (success,
// final failure or supersession), so a failed boot can never leave the tab unable to navigate.
- (void)beginBoot {
  self.bootFailed = NO;
  self.pageEnabled = NO;
  NSUInteger token = ++self.bootToken;
  self.scriptOperations++;
  [self enablePage:0 token:token];
}
- (void)settleBoot {
  if (self.scriptOperations) self.scriptOperations--;
}
- (void)enablePage:(int)attempt token:(NSUInteger)token {
  __weak CCChromiumTab *weakSelf = self;
  [self call:@"Page.enable" params:@{} reply:^(NSDictionary *, NSError *error) {
    auto tab = weakSelf;
    if (!tab) return;
    if (tab.bootToken != token || tab.closing) { [tab settleBoot]; [tab drainNavigation]; return; }
    if (!error) {
      tab.pageEnabled = YES;
      [tab applyEmulation];
      [tab settleBoot];
      [tab setScripts:tab.configuredScripts];
      return;
    }
    if (attempt < 2) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        auto again = weakSelf;
        if (!again) return;
        if (again.bootToken != token || again.closing) { [again settleBoot]; [again drainNavigation]; return; }
        [again enablePage:attempt + 1 token:token];
      });
      return;
    }
    // Page automation is an enhancement: navigate anyway and say that Boosts are unavailable.
    tab.bootFailed = YES;
    [tab settleBoot];
    [tab publishHealth:@"automationUnavailable" detail:error.localizedDescription code:0];
    [tab drainNavigation];
  }];
}
- (void)publish { [self.delegate chromiumTab:self changed:[self.state copy]]; }
- (void)publishHealth:(NSString *)kind detail:(NSString *)detail code:(NSInteger)code {
  id<CCChromiumTabDelegate> delegate = self.delegate;
  if ([delegate conformsToProtocol:@protocol(CCChromiumTabHealthDelegate)]) {
    [(id<CCChromiumTabHealthDelegate>)delegate chromiumTab:self health:kind detail:detail ?: @"" code:code];
  } else if ([kind isEqual:@"crashed"]) {
    self.state[@"error"] = [NSString stringWithFormat:@"The page %@.", detail]; [self publish];
  }
}
- (void)loadURL:(NSString *)url {
  self.pendingURL = url;
  // The address bar shows the requested URL until the navigation commits.
  self.state[@"url"] = url;
  self.state[@"isLoading"] = @(self.view.window != nil);
  self.state[@"progress"] = @0;
  if ([url isEqualToString:@"about:blank"]) self.bootstrapDocument = NO;
  // A renderer crash needs no boot: the DevTools session (Page.enable, user scripts) survives it, and Page.enable
  // cannot be re-sent until a navigation has revived the renderer.
  if (self.bootFailed && _client && _client->browser && !self.closing) [self beginBoot];
  [self ensureBrowser];
  [self drainNavigation];
}
- (void)drainNavigation {
  if (self.pendingURL && !self.scriptOperations && _client && _client->browser && !self.closing) {
    auto url = self.pendingURL; self.pendingURL = nil;
    [self armNavigationWatchdog];
    _client->browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
}
- (void)armNavigationWatchdog {
  NSUInteger token = ++_navigationToken;
  __weak CCChromiumTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NavigationWatchdogSeconds() * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    CCChromiumTab *tab = weakSelf;
    if (!tab || tab->_navigationToken != token || tab.closing) return;
    tab->_navigationStalled = YES;
    [tab publishHealth:@"navigationStalled"
                detail:@"This page has not started loading yet. If macOS asks whether Cairn may use "
                       @"\"Chromium Safe Storage\" in your Keychain, choose Always Allow, then retry. Otherwise "
                       @"check your network connection."
                  code:0];
  });
}
- (void)disarmNavigationWatchdog {
  ++_navigationToken;
  if (!_navigationStalled) return;
  _navigationStalled = NO;
  [self publishHealth:@"healthy" detail:@"" code:0];
}
- (void)renderProcessTerminated:(NSString *)reason code:(NSInteger)code {
  self.awaitingRecovery = YES;
  ++_unresponsiveToken; _unresponsiveCallback = nullptr;
  ++_navigationToken; _navigationStalled = NO;
  self.state[@"isLoading"] = @NO;
  [self cancelReplies:@"Renderer stopped"];
  [self publishHealth:@"crashed" detail:reason code:code];
  [self publish];
}
- (void)renderProcessUnresponsive:(CefRefPtr<CefUnresponsiveProcessCallback>)callback {
  _unresponsiveCallback = callback;
  NSUInteger token = ++_unresponsiveToken;
  [self publishHealth:@"unresponsive" detail:@"" code:0];
  __weak CCChromiumTab *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    CCChromiumTab *tab = weakSelf;
    if (!tab || tab->_unresponsiveToken != token || !tab->_unresponsiveCallback) return;
    auto pending = tab->_unresponsiveCallback;
    tab->_unresponsiveCallback = nullptr;
    pending->Terminate();
  });
}
- (void)renderProcessResponsive {
  ++_unresponsiveToken; _unresponsiveCallback = nullptr;
  [self publishHealth:@"healthy" detail:@"" code:0];
}
- (void)goBack { if (_client && _client->browser) _client->browser->GoBack(); }
- (void)goForward { if (_client && _client->browser) _client->browser->GoForward(); }
- (void)reloadIgnoringCache:(BOOL)ignoringCache {
  if (!_client) { [self ensureBrowser]; return; }
  if (!_client->browser) return;
  NSString *url = self.state[@"url"];
  [self armNavigationWatchdog];
  if (ignoringCache) _client->browser->ReloadIgnoreCache(); else _client->browser->Reload();
}
- (void)stop { self.pendingURL = nil; [self disarmNavigationWatchdog]; if (_client && _client->browser) _client->browser->StopLoad(); }
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
  self.closing = YES; self.pendingURL = nil; ++_navigationToken;
  [self exitFullscreen];
  [self cancelReplies:@"Tab closed"];
  if (_client && _client->browser) _client->browser->GetHost()->CloseBrowser(true);
}
@end

// CCTab.mm — CCChromiumTab: the browser view, navigation, DevTools calls with replies and timeouts,
// user scripts, find-in-page and snapshots. Feature-specific tab commands belong in CCTab+<Feature>.mm.
#import "CCInternal.h"
#include <algorithm>
#include <cmath>
#include "include/cef_parser.h"

using namespace cc;

@interface CCContainerView : NSView
@property(nonatomic, weak) CCChromiumTab *owner;
@end

@implementation CCContainerView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) [self.owner ensureBrowser];
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
- (CefRefPtr<CefBrowser>)cefBrowser { return _client ? _client->browser : nullptr; }
- (void)adoptClient { if (!_client) _client = new Client(self); }
- (CefRefPtr<CefClient>)adoptedClient { return _client; }
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

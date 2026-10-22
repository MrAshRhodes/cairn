// CCTab+PageTools.mm — DevTools window and per-tab Accept-Language / User-Agent emulation.
//
// DevTools opens in CEF's own window and is not a Cairn tab. It gets a fresh minimal client: the inspected
// tab's Client holds a single `browser`. `remote_debugging_port` stays unset on purpose; it would expose every
// Space's cookies on a local socket.
#import "CCInternal.h"

namespace {
class DevToolsClient final : public CefClient {
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};
}

@implementation CCChromiumTab (DevTools)
- (BOOL)hasDevTools {
  auto browser = self.cefBrowser;
  return browser && browser->GetHost()->HasDevTools();
}
- (void)showDevTools { [self showDevToolsInspectingPoint:NSMakePoint(NSNotFound, NSNotFound)]; }
- (void)showDevToolsInspectingPoint:(NSPoint)point {
  auto browser = self.cefBrowser;
  if (!browser || self.closing) return;
  CefWindowInfo window;
  window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  CefPoint inspect = point.x == NSNotFound ? CefPoint() : CefPoint((int)point.x, (int)point.y);
  browser->GetHost()->ShowDevTools(window, new DevToolsClient(), settings, inspect);
}
- (void)closeDevTools {
  auto browser = self.cefBrowser;
  if (browser) browser->GetHost()->CloseDevTools();
}
@end

@implementation CCChromiumTab (Emulation)
- (void)setAcceptLanguage:(NSString *)acceptLanguage userAgent:(NSString *)userAgent {
  self.emulationLanguage = acceptLanguage;
  self.emulationUserAgent = userAgent;
  if (self.pageEnabled) [self applyEmulation];
}
- (void)applyEmulation {
  if (!self.emulationLanguage.length && !self.emulationUserAgent.length) return;
  NSMutableDictionary *params = [NSMutableDictionary dictionary];
  params[@"userAgent"] = self.emulationUserAgent ?: @"";
  if (self.emulationLanguage.length) params[@"acceptLanguage"] = self.emulationLanguage;
  self.scriptOperations++;
  __weak CCChromiumTab *weakSelf = self;
  [self call:@"Emulation.setUserAgentOverride" params:params reply:^(NSDictionary *, NSError *error) {
    auto tab = weakSelf;
    if (!tab) return;
    if (error && !tab.closing) { tab.state[@"error"] = error.localizedDescription; [tab publish]; }
    if (tab.scriptOperations) tab.scriptOperations--;
    [tab drainNavigation];
  }];
}
@end

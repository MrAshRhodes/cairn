// CCTab+PageTools.mm — DevTools window and per-tab Accept-Language / User-Agent emulation.
//
// DevTools: CEF 154 opens it as its own Chrome-style window (a DevToolsWindow), not a Cairn tab, and ignores the
// client argument there. Passing runtime_style ALLOY or a SetAsChild parent is rejected ("Alloy style is not
// supported for this browser"), so the window info stays empty. `remote_debugging_port` stays unset on purpose;
// it would expose every Space's cookies on a local socket. CloseDevTools is asynchronous: reopening before the
// window has finished closing only focuses it.
#import "CCInternal.h"

@implementation CCChromiumTab (DevTools)
- (BOOL)hasDevTools {
  auto browser = self.cefBrowser;
  return browser && browser->GetHost()->HasDevTools();
}
- (void)showDevTools { [self showDevToolsInspectingPoint:NSMakePoint(NSNotFound, NSNotFound)]; }
- (void)showDevToolsInspectingPoint:(NSPoint)point {
  auto browser = self.cefBrowser;
  if (!browser || self.closing) return;
  CefPoint inspect = point.x == NSNotFound ? CefPoint() : CefPoint((int)point.x, (int)point.y);
  browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), inspect);
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

#import "CCInternal.h"
#import "Handlers/CCPending.h"

@implementation CCChromiumTab (Closing)
- (void)requestCloseWithCompletion:(void (^)(BOOL))completion {
  if (self.closing) { completion(YES); return; }
  if (self.closeDecision) {
    void (^previous)(BOOL) = self.closeDecision;
    self.closeDecision = ^(BOOL approved) { previous(approved); completion(approved); };
    return;
  }
  // A prior alert/authentication prompt must not obscure beforeunload. This is not close approval.
  cc::CancelPending(self);
  ++self.closeGeneration;
  self.closeDecision = completion;
  auto browser = self.cefBrowser;
  if (!browser) {
    // An uncreated/creating browser has no page to veto; OnAfterCreated will finish its teardown.
    [self approveClose];
    return;
  }
  if (!self.awaitingBeforeUnloadAck && !self.closeAckLost) {
    browser->GetHost()->CloseBrowser(false); return;
  }
  // Let the renderer finish acknowledging Stay before asking CEF to close again.
  self.awaitingBeforeUnloadAck = NO;
  NSUInteger generation = self.closeGeneration;
  __weak CCChromiumTab *weakSelf = self;
  [self call:@"Runtime.evaluate" params:@{@"expression": @"0"} reply:^(NSDictionary *, NSError *error) {
    CCChromiumTab *tab = weakSelf;
    if (!tab || tab.closing || !tab.closeDecision || tab.closeGeneration != generation) return;
    if (error) {
      NSLog(@"Cairn: could not acknowledge the previous close decision: %@", error.localizedDescription);
      [tab cancelCloseRequest];
      return;
    }
    if (tab.closeAckLost) {
      // A crash can leave Alloy's close state pending forever. Page.close dispatches beforeunload
      // on the recovered frame without that stale state gate; it still requires the page's decision.
      [tab call:@"Page.close" params:@{} reply:^(NSDictionary *, NSError *closeError) {
        CCChromiumTab *current = weakSelf;
        if (!current || current.closing || !current.closeDecision || current.closeGeneration != generation) return;
        if (closeError) {
          NSLog(@"Cairn: could not request close after renderer recovery: %@", closeError.localizedDescription);
          [current cancelCloseRequest];
        } else {
          current.closeAckLost = NO;
        }
      }];
      return;
    }
    if (auto current = tab.cefBrowser) current->GetHost()->CloseBrowser(false);
  }];
}
- (void)cancelCloseRequest {
  if (self.closing || !self.closeDecision) return;
  void (^completion)(BOOL) = self.closeDecision;
  self.closeDecision = nil;
  self.awaitingBeforeUnloadAck = YES;
  ++self.closeGeneration;
  completion(NO);
}
- (void)approveClose {
  if (self.closing) return;
  self.closing = YES;
  auto client = self.adoptedClient;
  if (client) client->closeApproved = true;
  if (auto browser = self.cefBrowser) cc::InvalidateDownloadRetries(browser->GetIdentifier());
  void (^completion)(BOOL) = self.closeDecision;
  self.closeDecision = nil;
  ++self.closeGeneration;
  cc::CancelPending(self);
  [self prepareApprovedClose];
  if (completion) completion(YES);
}
- (void)forceClose {
  [self approveClose];
  auto browser = self.cefBrowser;
  if (browser) {
    browser->GetHost()->CloseDevTools();
    browser->GetHost()->CloseBrowser(true);
  }
}
@end

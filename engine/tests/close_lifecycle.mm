// Executes the production close coordinator and JS dialog handler against inert CEF C handles.
// No framework, renderer, native browser window or Keychain is loaded.
#define WRAPPING_CEF_SHARED
#import "../../Sources/CairnChromiumBridge/CCTab+Closing.mm"
#import "../../Sources/CairnChromiumBridge/Handlers/CCJSDialogHandler.mm"
#include "libcef_dll/ctocpp/browser_ctocpp.h"
#include <cassert>
#include <vector>

static CefRefPtr<CefBrowser> fixtureBrowser;
static std::vector<bool> closeCalls;
static int prepared = 0;
static int devToolsClosed = 0;
static int retriesInvalidated = 0;
static cef_browser_host_t hostHandle{};
static NSString *devToolsMethod;
static DevToolsReply pendingDevToolsReply;

static void Reply(NSError *error = nil) {
  assert(pendingDevToolsReply);
  DevToolsReply reply = pendingDevToolsReply;
  pendingDevToolsReply = nil;
  reply(error ? nil : @{}, error);
}

namespace cc {
bool stopping = false;
NSString *String(const CefString&) { return @""; }
Client::Client(CCChromiumTab *tab) : owner(tab), ephemeral(false) {}
void InvalidateDownloadRetries(int) { ++retriesInvalidated; }
}

@implementation CCChromiumTab
@synthesize delegate, closing, closeDecision, closeGeneration;
@synthesize awaitingBeforeUnloadAck, closeAckLost;
- (CefRefPtr<CefBrowser>)cefBrowser { return fixtureBrowser; }
- (CefRefPtr<cc::Client>)adoptedClient { return nullptr; }
- (void)prepareApprovedClose { ++prepared; }
- (void)call:(NSString *)method params:(NSDictionary *)params reply:(DevToolsReply)reply {
  assert(!pendingDevToolsReply);
  devToolsMethod = method;
  pendingDevToolsReply = reply;
}
@end

@interface CloseDelegate : NSObject <CCChromiumTabJSDialogDelegate>
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic) int dismissed;
@end
@implementation CloseDelegate
- (void)chromiumTab:(CCChromiumTab *)tab requestsJSDialog:(NSString *)requestID type:(NSString *)type
           message:(NSString *)message defaultText:(NSString *)defaultText origin:(NSString *)origin
          isReload:(BOOL)isReload {
  assert([type isEqualToString:@"beforeUnload"]);
  self.requestID = requestID;
}
- (void)chromiumTab:(CCChromiumTab *)tab dismissesJSDialog:(NSString *)requestID { ++self.dismissed; }
@end

class Callback final : public CefJSDialogCallback {
 public:
  std::vector<bool> answers;
  void Continue(bool accepted, const CefString&) override { answers.push_back(accepted); }
  IMPLEMENT_REFCOUNTING(Callback);
};

void InitBase(cef_base_ref_counted_t& base, size_t size) {
  base.size = size;
  base.add_ref = [](cef_base_ref_counted_t *) {};
  base.release = [](cef_base_ref_counted_t *) { return 0; };
  base.has_one_ref = [](cef_base_ref_counted_t *) { return 1; };
  base.has_at_least_one_ref = [](cef_base_ref_counted_t *) { return 1; };
}

int main() {
  @autoreleasepool {
    InitBase(hostHandle.base, sizeof(hostHandle));
    hostHandle.close_browser = [](cef_browser_host_t *, int force) { closeCalls.push_back(force); };
    hostHandle.close_dev_tools = [](cef_browser_host_t *) { ++devToolsClosed; };
    cef_browser_t browserHandle{};
    InitBase(browserHandle.base, sizeof(browserHandle));
    browserHandle.get_host = [](cef_browser_t *) { return &hostHandle; };
    browserHandle.is_same = [](cef_browser_t *self, cef_browser_t *other) { return self == other ? 1 : 0; };
    fixtureBrowser = CefBrowserCToCpp_Wrap(&browserHandle);

    CCChromiumTab *tab = [CCChromiumTab new];
    CloseDelegate *delegate = [CloseDelegate new];
    tab.delegate = (id)delegate;
    CefRefPtr<cc::Client> client = new cc::Client(tab);
    auto handler = cc::MakeJSDialogHandler(*client);
    __block int allowed = 0, denied = 0;
    void (^decide)(BOOL) = ^(BOOL answer) { if (answer) ++allowed; else ++denied; };
    [tab requestCloseWithCompletion:decide];
    [tab requestCloseWithCompletion:decide];
    assert(closeCalls == std::vector<bool>({false}));
    assert(!tab.closing && tab.closeDecision && prepared == 0);
    assert(retriesInvalidated == 0);
    CefRefPtr<Callback> stay = new Callback();
    assert(handler->OnBeforeUnloadDialog(fixtureBrowser, CefString(), false, stay));
    NSString *stale = delegate.requestID;
    [tab resolveJSDialog:stale accept:NO text:nil suppressFurther:NO];
    assert(stay->answers == std::vector<bool>({false}));
    assert(denied == 2 && allowed == 0 && !tab.closing && !tab.closeDecision);
    [tab resolveJSDialog:stale accept:YES text:nil suppressFurther:NO];
    assert(stay->answers.size() == 1);

    [tab requestCloseWithCompletion:decide];
    assert(closeCalls == std::vector<bool>({false}));
    assert([devToolsMethod isEqualToString:@"Runtime.evaluate"]);
    Reply();
    assert(closeCalls == std::vector<bool>({false, false}));
    CefRefPtr<Callback> invalidated = new Callback();
    handler->OnBeforeUnloadDialog(fixtureBrowser, CefString(), false, invalidated);
    [tab resolveJSDialog:stale accept:YES text:nil suppressFurther:NO];
    assert(invalidated->answers.empty() && tab.closeDecision);
    cc::CancelPending(tab);  // Production navigation / renderer-loss path.
    assert(invalidated->answers == std::vector<bool>({false}));
    assert(denied == 3 && !tab.closing && !tab.closeDecision && delegate.dismissed == 1);

    [tab requestCloseWithCompletion:decide];
    assert([devToolsMethod isEqualToString:@"Runtime.evaluate"]);
    Reply();
    CefRefPtr<Callback> leave = new Callback();
    handler->OnBeforeUnloadDialog(fixtureBrowser, CefString(), false, leave);
    [tab resolveJSDialog:delegate.requestID accept:YES text:nil suppressFurther:NO];
    assert(leave->answers == std::vector<bool>({true}));
    assert(!tab.closing && allowed == 0);  // Wait for CEF's irreversible DoClose.
    [tab approveClose];
    [tab approveClose];
    assert(tab.closing && allowed == 1 && prepared == 1);
    assert(retriesInvalidated == 1);

    tab = [CCChromiumTab new];
    tab.delegate = (id)delegate;
    client = new cc::Client(tab);
    handler = cc::MakeJSDialogHandler(*client);
    [tab requestCloseWithCompletion:decide];
    CefRefPtr<Callback> forced = new Callback();
    handler->OnBeforeUnloadDialog(fixtureBrowser, CefString(), false, forced);
    [tab forceClose];
    assert(tab.closing && allowed == 2 && denied == 3);
    assert(forced->answers == std::vector<bool>({false}));
    assert(closeCalls == std::vector<bool>({false, false, false, false, true}));
    assert(devToolsClosed == 1);
    assert(retriesInvalidated == 2);

    tab = [CCChromiumTab new];
    tab.delegate = (id)delegate;
    client = new cc::Client(tab);
    handler = cc::MakeJSDialogHandler(*client);
    tab.closeAckLost = YES;
    tab.awaitingBeforeUnloadAck = YES;
    __block int recoveryAllowed = 0, recoveryDenied = 0;
    void (^recover)(BOOL) = ^(BOOL answer) { if (answer) ++recoveryAllowed; else ++recoveryDenied; };
    NSError *unavailable = [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil];
    [tab requestCloseWithCompletion:recover];
    Reply(unavailable);
    assert(recoveryDenied == 1 && recoveryAllowed == 0 && tab.closeAckLost && !tab.closing);
    assert(!tab.closeDecision && !pendingDevToolsReply && closeCalls.size() == 5);

    [tab requestCloseWithCompletion:recover];
    Reply();
    assert([devToolsMethod isEqualToString:@"Page.close"]);
    Reply(unavailable);
    assert(recoveryDenied == 2 && recoveryAllowed == 0 && tab.closeAckLost && !tab.closing);
    assert(!tab.closeDecision && !pendingDevToolsReply && closeCalls.size() == 5);

    [tab requestCloseWithCompletion:recover];
    DevToolsReply staleBarrier = pendingDevToolsReply;
    pendingDevToolsReply = nil;
    [tab cancelCloseRequest];
    [tab requestCloseWithCompletion:recover];
    staleBarrier(@{}, nil);
    assert([devToolsMethod isEqualToString:@"Runtime.evaluate"] && pendingDevToolsReply);
    Reply();
    assert([devToolsMethod isEqualToString:@"Page.close"]);
    Reply();
    assert(!tab.closeAckLost && recoveryDenied == 3 && recoveryAllowed == 0 && !tab.closing);
    assert(tab.closeDecision && closeCalls.size() == 5);
    CefRefPtr<Callback> recoveredStay = new Callback();
    handler->OnBeforeUnloadDialog(fixtureBrowser, CefString(), false, recoveredStay);
    [tab resolveJSDialog:delegate.requestID accept:NO text:nil suppressFurther:NO];
    assert(recoveredStay->answers == std::vector<bool>({false}));
    assert(recoveryDenied == 4 && recoveryAllowed == 0 && !tab.closing);
    assert(!tab.closeDecision && tab.awaitingBeforeUnloadAck);

    fixtureBrowser = nullptr;
    tab = [CCChromiumTab new];
    [tab requestCloseWithCompletion:decide];
    assert(tab.closing && allowed == 3);  // A lazy/uncreated tab is safe to discard.
    assert(retriesInvalidated == 2);
  }
}

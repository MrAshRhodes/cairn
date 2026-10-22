// CCRequestHandler.mm — renderer health, link opening, HTTP authentication and certificate errors.
// Certificate errors are reported to Swift and always refused: OnCertificateError returns false, which
// cancels the request, and nothing here ever calls the callback to continue.
// CEF may call GetResourceRequestHandler off the main thread, so this handler keeps the resource
// handler itself and never touches its Client.
#import "../CCInternal.h"
#import "CCPending.h"

namespace cc {
namespace {
class RequestHandler final : public TabHandler, public CefRequestHandler {
 public:
  RequestHandler(Client& client, CefRefPtr<CefResourceRequestHandler> resource)
      : TabHandler(client), resource_(resource) {}
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool,
      const CefString&, bool&) override {
    return resource_;
  }
  // Middle- and Cmd-click reach here (not OnBeforePopup); without this CEF navigates the source tab.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& url,
                        WindowOpenDisposition disposition, bool gesture) override {
    bool background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    if (!background && disposition != CEF_WOD_NEW_FOREGROUND_TAB && disposition != CEF_WOD_NEW_WINDOW) return false;
    auto tab = owner;
    if (gesture) [tab.delegate chromiumTab:tab popup:String(url) activate:!background];
    return true;
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString& originURL, bool isProxy, const CefString& host,
                          int port, const CefString& realm, const CefString& scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    auto tab = owner;
    if (!tab || ![tab.delegate conformsToProtocol:@protocol(CCChromiumTabRequestDelegate)]) return false;
    NSString *requestID = [NSString stringWithFormat:@"a%llu", ++counter_];
    Pending(tab)[requestID] = [^(NSDictionary *answer) {
      NSString *user = answer[@"username"];
      if (user) callback->Continue(CefString(user.UTF8String), CefString(((NSString *)answer[@"password"] ?: @"").UTF8String));
      else callback->Cancel();
    } copy];
    [(id<CCChromiumTabRequestDelegate>)tab.delegate chromiumTab:tab requestsAuthentication:requestID
        url:String(originURL) host:String(host) port:port realm:String(realm) scheme:String(scheme) isProxy:isProxy];
    return true;
  }
  bool OnCertificateError(CefRefPtr<CefBrowser>, cef_errorcode_t error, const CefString& url,
                          CefRefPtr<CefSSLInfo> info, CefRefPtr<CefCallback>) override {
    auto tab = owner;
    if (tab && [tab.delegate conformsToProtocol:@protocol(CCChromiumTabRequestDelegate)]) {
      NSString *subject = @"", *issuer = @"";
      double from = 0, until = 0;
      if (auto certificate = info ? info->GetX509Certificate() : nullptr) {
        if (auto principal = certificate->GetSubject()) subject = String(principal->GetDisplayName());
        if (auto principal = certificate->GetIssuer()) issuer = String(principal->GetDisplayName());
        // CefBaseTime counts microseconds since 1601-01-01.
        auto unix = [](CefBaseTime time) { return time.val ? time.val / 1e6 - 11644473600.0 : 0.0; };
        from = unix(certificate->GetValidStart());
        until = unix(certificate->GetValidExpiry());
      }
      [(id<CCChromiumTabRequestDelegate>)tab.delegate chromiumTab:tab blockedCertificate:String(url)
          code:error subject:subject issuer:issuer validFrom:from validUntil:until];
    }
    return false;
  }
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser>,
                                   CefRefPtr<CefUnresponsiveProcessCallback> callback) override {
    auto tab = owner;
    if (!tab) return false;
    [tab renderProcessUnresponsive:callback];
    return true; // The tab ends the hang with Terminate() if the page does not recover.
  }
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser>) override { [owner renderProcessResponsive]; }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int code,
                                 const CefString& error) override {
    NSString *reason;
    switch (status) {
      case TS_PROCESS_WAS_KILLED: reason = @"was stopped by the system"; break;
      case TS_PROCESS_OOM: reason = @"ran out of memory"; break;
      case TS_LAUNCH_FAILED: reason = @"could not be started"; break;
      case TS_INTEGRITY_FAILURE: reason = @"failed an integrity check"; break;
      default: reason = @"crashed"; break;
    }
    NSLog(@"Cairn: renderer terminated (status %d, code %d): %@", (int)status, code, String(error));
    [owner renderProcessTerminated:reason code:code];
  }
 private:
  CefRefPtr<CefResourceRequestHandler> resource_;
  uint64_t counter_ = 0;
  IMPLEMENT_REFCOUNTING(RequestHandler);
};
}

CefRefPtr<CefRequestHandler> MakeRequestHandler(Client& client) {
  return new RequestHandler(client, MakeResourceRequestHandler(client));
}

}  // namespace cc

@implementation CCChromiumTab (Request)
- (void)resolveAuthentication:(NSString *)requestID username:(NSString *)username password:(NSString *)password {
  NSMutableDictionary *answer = [NSMutableDictionary dictionary];
  if (username) { answer[@"username"] = username; answer[@"password"] = password ?: @""; }
  cc::Answer(self, requestID, answer);
}
@end

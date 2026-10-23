// CCJSDialogHandler.mm — CefJSDialogHandler: alert, confirm, prompt and beforeunload.
//
// Dialogs are forwarded to Swift, which shows them in a sheet on the tab that raised them, and the CEF
// callback is completed from -resolveJSDialog:... . "Prevent more dialogs" is kept here per tab and lapses when
// the main frame navigates (OnResetDialogState also fires after every dialog, so it cannot mark navigation).
// It uses CEF's suppress_message path, which lets Chromium treat the page as dialog-spamming.
#import "../CCInternal.h"
#import "CCPending.h"

namespace cc {
namespace {

// Identifies the page a suppression applies to: the main frame and its URL.
NSString *SuppressKey(CefRefPtr<CefBrowser> browser) {
  CefRefPtr<CefFrame> main = browser ? browser->GetMainFrame() : nullptr;
  if (!main) return @"suppress:";
  return [NSString stringWithFormat:@"suppress:%@:%@", String(main->GetIdentifier()), String(main->GetURL())];
}

class JSDialogHandler final : public TabHandler, public CefJSDialogHandler {
 public:
  explicit JSDialogHandler(Client& client) : TabHandler(client) {}

  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin, JSDialogType type, const CefString& message,
                  const CefString& defaultText, CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress) override {
    auto tab = owner;
    if (!tab || tab.closing || stopping || !SameBrowser(tab.cefBrowser, browser)) { suppress = true; return false; }
    NSString *suppressKey = SuppressKey(browser);
    auto pending = Pending(tab);
    for (NSString *key in [pending.allKeys copy]) {
      if ([key hasPrefix:@"suppress:"] && ![key isEqualToString:suppressKey]) [pending removeObjectForKey:key];
    }
    if (pending[suppressKey]) { suppress = true; return false; }
    NSString *name = type == JSDIALOGTYPE_CONFIRM ? @"confirm" : type == JSDIALOGTYPE_PROMPT ? @"prompt" : @"alert";
    return Forward(tab, name, String(message), String(defaultText), String(origin), false, callback);
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString& message, bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    auto tab = owner;
    if (tab && SameBrowser(tab.cefBrowser, browser) && tab.closing) {
      callback->Continue(true, CefString()); return true;
    }
    if (!tab || stopping || !SameBrowser(tab.cefBrowser, browser)) {
      callback->Continue(false, CefString()); return true;
    }
    return Forward(tab, @"beforeUnload", String(message), @"", @"", isReload, callback);
  }

  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    auto tab = owner;
    if (!tab || !SameBrowser(tab.cefBrowser, browser)) return;
    auto pending = Pending(tab);
    for (NSString *key in [pending.allKeys copy]) {
      if (![key hasPrefix:@"js"]) continue;
      Answer(tab, key, nil);
      if ([tab.delegate conformsToProtocol:@protocol(CCChromiumTabJSDialogDelegate)])
        [(id<CCChromiumTabJSDialogDelegate>)tab.delegate chromiumTab:tab dismissesJSDialog:key];
    }
  }

 private:
  bool Forward(CCChromiumTab *tab, NSString *type, NSString *message, NSString *defaultText, NSString *origin,
               bool isReload, CefRefPtr<CefJSDialogCallback> callback) {
    // Without a UI the dialog is cancelled; never fall back to an app-modal CEF dialog.
    if (![tab.delegate conformsToProtocol:@protocol(CCChromiumTabJSDialogDelegate)]) {
      callback->Continue(false, CefString());
      if ([type isEqualToString:@"beforeUnload"]) [tab cancelCloseRequest];
      return true;
    }
    NSString *requestID = [@"js" stringByAppendingString:NSUUID.UUID.UUIDString];
    BOOL closeRequest = [type isEqualToString:@"beforeUnload"] && tab.closeDecision != nil;
    NSUInteger generation = tab.closeGeneration;
    __weak CCChromiumTab *weakTab = tab;
    Pending(tab)[requestID] = [^(NSDictionary *answer) {
      NSString *text = answer[@"text"];
      BOOL accept = [answer[@"accept"] boolValue];
      callback->Continue(accept, text ? CefString(text.UTF8String) : CefString());
      CCChromiumTab *current = weakTab;
      if (!accept && closeRequest && current.closeGeneration == generation) [current cancelCloseRequest];
    } copy];
    [(id<CCChromiumTabJSDialogDelegate>)tab.delegate chromiumTab:tab requestsJSDialog:requestID type:type
        message:message defaultText:defaultText origin:origin isReload:isReload];
    return true;
  }

  IMPLEMENT_REFCOUNTING(JSDialogHandler);
};
}

CefRefPtr<CefJSDialogHandler> MakeJSDialogHandler(Client& client) { return new JSDialogHandler(client); }

}  // namespace cc

@implementation CCChromiumTab (JSDialog)
- (void)resolveJSDialog:(NSString *)requestID accept:(BOOL)accept text:(NSString *)text
        suppressFurther:(BOOL)suppressFurther {
  // A delayed answer from a dismissed card must not silence the newly navigated page.
  if (!cc::Pending(self)[requestID]) return;
  if (suppressFurther) cc::Pending(self)[cc::SuppressKey(self.cefBrowser)] = ^(NSDictionary *) {};
  NSMutableDictionary *answer = [@{@"accept": @(accept)} mutableCopy];
  if (text) answer[@"text"] = text;
  cc::Answer(self, requestID, answer);
}
@end

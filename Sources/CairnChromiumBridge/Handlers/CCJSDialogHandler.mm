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
    if (!tab) return false;
    NSString *suppressKey = SuppressKey(browser);
    auto pending = Pending(tab);
    for (NSString *key in [pending.allKeys copy]) {
      if ([key hasPrefix:@"suppress:"] && ![key isEqualToString:suppressKey]) [pending removeObjectForKey:key];
    }
    if (pending[suppressKey]) { suppress = true; return false; }
    NSString *name = type == JSDIALOGTYPE_CONFIRM ? @"confirm" : type == JSDIALOGTYPE_PROMPT ? @"prompt" : @"alert";
    return Forward(tab, name, String(message), String(defaultText), String(origin), false, callback);
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString& message, bool isReload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    auto tab = owner;
    if (!tab) return false;
    return Forward(tab, @"beforeUnload", String(message), @"", @"", isReload, callback);
  }

  void OnResetDialogState(CefRefPtr<CefBrowser>) override {
    auto tab = owner;
    if (!tab) return;
    auto pending = Pending(tab);
    for (NSString *key in [pending.allKeys copy]) {
      if (![key hasPrefix:@"js"]) continue;
      [pending removeObjectForKey:key];
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
      return true;
    }
    NSString *requestID = [NSString stringWithFormat:@"js%llu", ++counter_];
    Pending(tab)[requestID] = [^(NSDictionary *answer) {
      NSString *text = answer[@"text"];
      callback->Continue([answer[@"accept"] boolValue], text ? CefString(text.UTF8String) : CefString());
    } copy];
    [(id<CCChromiumTabJSDialogDelegate>)tab.delegate chromiumTab:tab requestsJSDialog:requestID type:type
        message:message defaultText:defaultText origin:origin isReload:isReload];
    return true;
  }

  uint64_t counter_ = 0;
  IMPLEMENT_REFCOUNTING(JSDialogHandler);
};
}

CefRefPtr<CefJSDialogHandler> MakeJSDialogHandler(Client& client) { return new JSDialogHandler(client); }

}  // namespace cc

@implementation CCChromiumTab (JSDialog)
- (void)resolveJSDialog:(NSString *)requestID accept:(BOOL)accept text:(NSString *)text
        suppressFurther:(BOOL)suppressFurther {
  if (suppressFurther) cc::Pending(self)[cc::SuppressKey(self.cefBrowser)] = ^(NSDictionary *) {};
  NSMutableDictionary *answer = [@{@"accept": @(accept)} mutableCopy];
  if (text) answer[@"text"] = text;
  cc::Answer(self, requestID, answer);
}
@end

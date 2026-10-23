// CCTab+Focus.mm — keyboard focus into the page, and the spell-check preference.
#import "CCInternal.h"

@implementation CCChromiumTab (Focus)
- (void)focusContent {
  auto browser = [self cefBrowser];
  if (!browser || self.closing || !self.view.window) return;
  NSView *native = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  [self.view.window makeFirstResponder:native];
  browser->GetHost()->SetFocus(true);
}
- (void)restoreContentFocus {
  // Focusing right away (direct selection) keeps AppKit from later choosing the page's first focusable element as the
  // initial responder of a window the live view was just moved into, which would reset the scroll position.
  [self focusContentUnlessShellOwnsFocus];
  __weak CCChromiumTab *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf focusContentUnlessShellOwnsFocus]; });
}
// Switching tabs or panes returns focus to the page, but never steals it from a shell text field.
- (void)focusContentUnlessShellOwnsFocus {
  NSWindow *window = self.view.window;
  if (!window || ![self cefBrowser]) return;
  NSResponder *current = window.firstResponder;
  NSView *view = [current isKindOfClass:NSView.class] ? (NSView *)current : nil;
  if (current == window || !current || [view isDescendantOf:self.view]) [self focusContent];
}
- (void)enableSpellChecking {
  auto browser = [self cefBrowser];
  if (!browser) return;
  auto context = browser->GetHost()->GetRequestContext();
  auto value = CefValue::Create();
  value->SetBool(true);
  CefString error;
  if (context) context->SetPreference("browser.enable_spellchecking", value, error);
}
@end

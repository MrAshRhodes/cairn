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
  __weak CCChromiumTab *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    CCChromiumTab *tab = weakSelf;
    NSWindow *window = tab.view.window;
    if (!window || ![tab cefBrowser]) return;
    NSResponder *current = window.firstResponder;
    NSView *view = [current isKindOfClass:NSView.class] ? (NSView *)current : nil;
    // Switching tabs or panes returns focus to the page, but never steals it from a shell text field.
    if (current == window || !current || [view isDescendantOf:tab.view]) [tab focusContent];
  });
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

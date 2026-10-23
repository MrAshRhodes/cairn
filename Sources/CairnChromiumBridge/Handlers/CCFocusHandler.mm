// CCFocusHandler.mm — CefFocusHandler: keyboard focus moving between the page and Cairn's chrome.
#import "../CCInternal.h"

namespace cc {
namespace {
class FocusHandler final : public TabHandler, public CefFocusHandler {
 public:
  explicit FocusHandler(Client& client) : TabHandler(client) {}
  // Tab past the last (or before the first) focusable page element: continue in the shell.
  void OnTakeFocus(CefRefPtr<CefBrowser>, bool next) override {
    NSWindow *window = owner.view.window;
    if (next) [window selectNextKeyView:nil]; else [window selectPreviousKeyView:nil];
  }
  // Chromium asks for focus on navigation and load completion; a text field in the shell
  // (command bar, address, find) that is being edited must keep it.
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource source) override {
    if (source != FOCUS_SOURCE_NAVIGATION) return false;
    NSTextView *editor = (NSTextView *)owner.view.window.firstResponder;
    return [editor isKindOfClass:NSTextView.class] && editor.fieldEditor;
  }
 private:
  IMPLEMENT_REFCOUNTING(FocusHandler);
};
}

CefRefPtr<CefFocusHandler> MakeFocusHandler(Client& client) { return new FocusHandler(client); }

}  // namespace cc

// CCKeyboardHandler.mm — CefKeyboardHandler: browser-reserved shortcuts and Esc out of HTML fullscreen.
//
// Keys the page does not consume already reach the app's main menu (CEF forwards them to
// [NSApp.mainMenu performKeyEquivalent:]), so ⌘C/⌘V/⌘L and friends need nothing here. A page that calls
// preventDefault() would swallow them, so the keys Chrome reserves for the browser are offered to the menu
// BEFORE the page and, when the menu takes them, consumed so nothing handles them twice.
// Fires for every key: keep it O(1) and allocation-free on the common path.
#import "../CCInternal.h"

namespace cc {
namespace {
constexpr int kEscape = 0x1B;
constexpr int kTab = 0x09;

bool IsReserved(const CefKeyEvent& event) {
  const bool command = event.modifiers & EVENTFLAG_COMMAND_DOWN;
  const bool control = event.modifiers & EVENTFLAG_CONTROL_DOWN;
  const bool option = event.modifiers & EVENTFLAG_ALT_DOWN;
  if (command && !control && !option) {
    switch (event.windows_key_code) { case 'T': case 'N': case 'W': case 'Q': return true; default: return false; }
  }
  return control && !command && !option && event.windows_key_code == kTab;
}

class KeyboardHandler final : public TabHandler, public CefKeyboardHandler {
 public:
  explicit KeyboardHandler(Client& client) : TabHandler(client) {}
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event,
                     bool*) override {
    if (event.type != KEYEVENT_RAWKEYDOWN) return false;
    if (event.windows_key_code == kEscape && !event.modifiers && browser->GetHost()->IsFullscreen()) {
      browser->GetHost()->ExitFullscreen(false);
      return true;
    }
    if (!os_event || !IsReserved(event)) return false;
    return [NSApp.mainMenu performKeyEquivalent:(__bridge NSEvent *)os_event];
  }
 private:
  IMPLEMENT_REFCOUNTING(KeyboardHandler);
};
}

CefRefPtr<CefKeyboardHandler> MakeKeyboardHandler(Client& client) { return new KeyboardHandler(client); }

}  // namespace cc

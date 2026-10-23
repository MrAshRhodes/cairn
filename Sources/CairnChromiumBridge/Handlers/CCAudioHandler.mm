// CCAudioHandler.mm — CefAudioHandler: the tab's "playing audio" state.
//
// Alloy starts the audio capturer when the tab becomes audible and stops it after Chromium's
// recently-audible timeout, so Started/Stopped are the audible/not-audible edges. The capture is a
// loopback copy: packets are ignored and playback is not diverted. Started and Stopped can arrive off
// the main thread, so they hop to it before touching tab state.
#import "../CCInternal.h"

namespace cc {
namespace {
class AudioHandler final : public TabHandler, public CefAudioHandler {
 public:
  explicit AudioHandler(Client& client) : TabHandler(client) {}
  bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters&) override { return true; }
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters&, int) override { Report(true); }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float**, int, int64_t) override {}
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override { Report(false); }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString&) override {}
 private:
  void Report(bool playing) {
    __weak CCChromiumTab *weakTab = owner;
    dispatch_async(dispatch_get_main_queue(), ^{
      CCChromiumTab *tab = weakTab;
      if (!tab) return;
      if (playing) [tab applyAudioMuted];
      id<CCChromiumTabAudioDelegate> delegate = (id)tab.delegate;
      if ([delegate conformsToProtocol:@protocol(CCChromiumTabAudioDelegate)]) {
        [delegate chromiumTab:tab audioPlayingChanged:playing];
      }
    });
  }
  IMPLEMENT_REFCOUNTING(AudioHandler);
};
}

CefRefPtr<CefAudioHandler> MakeAudioHandler(Client& client) { return new AudioHandler(client); }

}  // namespace cc

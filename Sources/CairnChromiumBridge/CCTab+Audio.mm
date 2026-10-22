// CCTab+Audio.mm — per-tab mute. The wanted state lives on the tab because the browser may not exist yet
// and Chromium may drop it on a cross-site navigation; the audio handler re-applies it.
#import "CCInternal.h"
#import <objc/runtime.h>

static const void *kMutedKey = &kMutedKey;

@implementation CCChromiumTab (Audio)
- (BOOL)audioMuted { return [objc_getAssociatedObject(self, kMutedKey) boolValue]; }
- (void)setAudioMuted:(BOOL)muted {
  objc_setAssociatedObject(self, kMutedKey, @(muted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self applyAudioMuted];
}
- (void)applyAudioMuted {
  auto browser = [self cefBrowser];
  if (browser && browser->GetHost()->IsAudioMuted() != (bool)self.audioMuted) {
    browser->GetHost()->SetAudioMuted(self.audioMuted);
  }
}
@end

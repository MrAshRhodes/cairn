// CCTab+Fullscreen.mm — HTML fullscreen: the page view moves into a borderless window covering the screen
// (menu bar and Dock hidden) and returns to where it was on every exit path: Esc (CCKeyboardHandler), the
// page leaving fullscreen itself, and the tab closing. Idempotent: every path may call leave twice.
#import "CCInternal.h"
#import <objc/runtime.h>

@interface CCFullscreenWindow : NSWindow
@end
@implementation CCFullscreenWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface CCFullscreenState : NSObject
@property(nonatomic, strong) CCFullscreenWindow *window;
@property(nonatomic, weak) NSView *superview;
@property(nonatomic, weak) NSWindow *host;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSAutoresizingMaskOptions mask;
@property(nonatomic) NSApplicationPresentationOptions options;
@end
@implementation CCFullscreenState
@end

static const void *kFullscreenKey = &kFullscreenKey;

@implementation CCChromiumTab (Fullscreen)
- (CCFullscreenState *)fullscreenState { return objc_getAssociatedObject(self, kFullscreenKey); }
- (BOOL)isFullscreen { return [self fullscreenState] != nil; }

- (void)pageFullscreenChanged:(BOOL)fullscreen {
  if (fullscreen) [self enterFullscreen]; else [self leaveFullscreen];
}

- (void)enterFullscreen {
  auto browser = [self cefBrowser];
  NSWindow *host = self.view.window;
  if ([self fullscreenState]) return;
  if (!host || self.closing) { if (browser) browser->GetHost()->ExitFullscreen(false); return; }
  NSScreen *screen = host.screen ?: NSScreen.mainScreen;
  CCFullscreenState *state = [CCFullscreenState new];
  state.superview = self.view.superview; state.host = host;
  state.frame = self.view.frame; state.mask = self.view.autoresizingMask;
  state.options = NSApp.presentationOptions;
  CCFullscreenWindow *window = [[CCFullscreenWindow alloc] initWithContentRect:screen.frame
                                                                     styleMask:NSWindowStyleMaskBorderless
                                                                       backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed = NO;
  window.backgroundColor = NSColor.blackColor;
  window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
  state.window = window;
  objc_setAssociatedObject(self, kFullscreenKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window.contentView addSubview:self.view];
  self.view.frame = window.contentView.bounds;
  self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSApp.presentationOptions = state.options | NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
  [window makeKeyAndOrderFront:nil];
  [self focusContent];
}

- (void)leaveFullscreen {
  CCFullscreenState *state = [self fullscreenState];
  if (!state) return;
  objc_setAssociatedObject(self, kFullscreenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSApp.presentationOptions = state.options;
  // SwiftUI may already have re-mounted the view elsewhere (tab switched while fullscreen).
  if (self.view.superview == state.window.contentView) {
    [self.view removeFromSuperview];
    if (state.superview) {
      self.view.frame = state.frame;
      self.view.autoresizingMask = state.mask;
      [state.superview addSubview:self.view];
    }
  }
  [state.window orderOut:nil];
  [state.window close];
  [state.host makeKeyAndOrderFront:nil];
  [self focusContent];
}

- (void)exitFullscreen {
  if (![self fullscreenState]) return;
  auto browser = [self cefBrowser];
  if (browser && !self.closing && browser->GetHost()->IsFullscreen()) browser->GetHost()->ExitFullscreen(false);
  [self leaveFullscreen];
}
@end

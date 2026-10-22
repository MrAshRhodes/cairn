#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CCChromiumTab;
@protocol CCChromiumTabDelegate <NSObject>
- (void)chromiumTab:(CCChromiumTab *)tab changed:(NSDictionary<NSString *, id> *)state;
- (void)chromiumTab:(CCChromiumTab *)tab popup:(NSString *)url activate:(BOOL)activate;
- (void)chromiumTab:(CCChromiumTab *)tab download:(NSString *)url filename:(NSString *)filename;
- (void)chromiumTabRequestsClose:(CCChromiumTab *)tab;
@end

@interface CCChromiumRuntime : NSObject
// Test harnesses only: `mockKeychain` swaps Chromium's Keychain-backed cookie-encryption key for a fixed mock key.
+ (BOOL)prepareApplicationWithMockKeychain:(BOOL)mockKeychain;
+ (BOOL)startWithRoot:(NSString *)root error:(NSError *_Nullable *_Nullable)error;
+ (NSString *)versionDescription;
+ (void)shutdown;
+ (void)shutdownWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(shutdown(completion:));
@end

@interface CCChromiumTab : NSObject
@property(nonatomic, weak, nullable) id<CCChromiumTabDelegate> delegate;
@property(nonatomic, readonly) NSView *view;
@property(nonatomic) double zoom;
- (instancetype)initWithProfile:(NSString *)profile ephemeral:(BOOL)ephemeral;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reloadIgnoringCache:(BOOL)ignoringCache;
- (void)stop;
- (void)find:(NSString *)query forward:(BOOL)forward completion:(void (^)(BOOL))completion;
- (void)clearFind;
- (void)evaluate:(NSString *)source completion:(void (^)(id _Nullable, NSError *_Nullable))completion;
- (void)setScripts:(NSArray<NSDictionary<NSString *, NSString *> *> *)scripts;
- (void)snapshot:(void (^)(NSImage *_Nullable))completion;
- (void)close;
@end

// FEATURE SLOTS. Additive only: do not edit the declarations above. Each feature adds its public API
// under its own marker, so features written in parallel do not touch the same lines. Keep the blank
// line between slots. A slot holds what the feature needs:
//   - events: a protocol such as CCChromiumTab<Feature>Delegate. The Swift ChromiumTab adopts it in
//     ChromiumTab+<Feature>.swift and the handler reaches it with
//     `[tab.delegate conformsToProtocol:@protocol(CCChromiumTab<Feature>Delegate)]`;
//   - commands: a category, `@interface CCChromiumTab (<Feature>)`, implemented in CCTab+<Feature>.mm.
// A feature with no marker adds `// [Name]` directly above NS_ASSUME_NONNULL_END.

// [Audio]
@protocol CCChromiumTabAudioDelegate <NSObject>
// `playing` follows Chromium's own audible state (with its short recently-audible debounce).
- (void)chromiumTab:(CCChromiumTab *)tab audioPlayingChanged:(BOOL)playing;
@end

@interface CCChromiumTab (Audio)
// The wanted mute state; it survives browser creation and navigation.
@property(nonatomic) BOOL audioMuted;
@end

// [ContextMenu]
@protocol CCChromiumTabContextMenuDelegate <NSObject>
- (void)chromiumTab:(CCChromiumTab *)tab searchFor:(NSString *)query activate:(BOOL)activate;
// A page navigated to a non-web scheme (mailto:, tel:, custom). The bridge never launches it itself.
- (void)chromiumTab:(CCChromiumTab *)tab openExternalURL:(NSString *)url;
@end

// [Dialog]

// [Display]
@interface CCChromiumTab (Fullscreen)
@property(nonatomic, readonly, getter=isFullscreen) BOOL fullscreen;
- (void)exitFullscreen;
// Called by the Display handler when the page enters or leaves HTML fullscreen.
- (void)pageFullscreenChanged:(BOOL)fullscreen;
@end

@protocol CCChromiumTabFaviconDelegate <NSObject>
// PNG bytes of the page's icon, or nil when the page has none or none could be fetched.
- (void)chromiumTab:(CCChromiumTab *)tab faviconPNG:(NSData *_Nullable)png iconURL:(NSString *_Nullable)iconURL;
@end

// [Download]

// [Drag]

// [Find]

// [Focus]
@interface CCChromiumTab (Focus)
// Gives the page keyboard focus (tab switch, pane focus, after the command bar closes).
- (void)focusContent;
// Focus the page after the tab joins a window, unless something in the shell is being edited.
- (void)restoreContentFocus;
- (void)enableSpellChecking;
@end

// [JSDialog]

// [Keyboard]

// [LifeSpan]

// [Load]

// [Permission]

// [Print]

// [Request]

// [ResourceRequest]
// Content blocking: immutable rule snapshot swapped under a lock; lookups run on Chromium's IO thread.
@interface CCChromiumRuntime (ContentBlocking)
+ (void)setContentBlockingEnabled:(BOOL)enabled blockedHosts:(NSArray<NSString *> *)blockedHosts
                      exemptSites:(NSArray<NSString *> *)exemptSites;
+ (NSUInteger)blockedRequestCount;
@end

// [SiteData]
// `profile` is the hashed profile directory name. `site` is a host name or nil for the whole profile.
@interface CCChromiumRuntime (SiteData)
+ (void)clearSiteDataForProfile:(NSString *)profile site:(nullable NSString *)site cookies:(BOOL)cookies
                          cache:(BOOL)cache storage:(BOOL)storage
                     completion:(void (^)(NSArray<NSString *> *failures))completion;
+ (void)deleteProfile:(NSString *)profile completion:(void (^)(void))completion;
+ (NSArray<NSString *> *)removeOrphanProfilesKeeping:(NSArray<NSString *> *)directories;
@end

NS_ASSUME_NONNULL_END

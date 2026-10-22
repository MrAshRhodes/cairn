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
+ (void)clearProfile:(NSString *)profile cookies:(BOOL)cookies cache:(BOOL)cache
         completion:(void (^)(void))completion;
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

// [ContextMenu]

// [Dialog]

// [Display]

// [Download]

// [Drag]

// [Find]

// [Focus]

// [JSDialog]

// [Keyboard]

// [LifeSpan]

// [Load]

// [Permission]

// [Print]
// Page tools: printing, DevTools window, and per-tab language/user-agent emulation.
@interface CCChromiumTab (Print)
/// Presents the system print panel for the page.
- (void)printPage;
/// Writes the page as a PDF. `error` is nil on success.
- (void)printToPDFAtPath:(NSString *)path completion:(void (^)(NSError *_Nullable error))completion;
@end

@interface CCChromiumTab (DevTools)
@property(nonatomic, readonly) BOOL hasDevTools;
/// Opens (or focuses) the DevTools window; a point inspects the element there, in view coordinates.
- (void)showDevTools;
- (void)showDevToolsInspectingPoint:(NSPoint)point;
- (void)closeDevTools;
@end

@interface CCChromiumTab (Emulation)
/// Empty strings keep Chromium's defaults. Applies to following navigations; before the first load when set early.
- (void)setAcceptLanguage:(NSString *)acceptLanguage userAgent:(NSString *)userAgent;
@end

// [Request]

// [ResourceRequest]

NS_ASSUME_NONNULL_END

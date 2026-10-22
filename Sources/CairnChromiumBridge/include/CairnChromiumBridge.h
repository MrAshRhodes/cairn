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
// `type` is alert, confirm, prompt or beforeUnload. A dismissal also covers navigation resetting the dialog.
@protocol CCChromiumTabJSDialogDelegate <NSObject>
- (void)chromiumTab:(CCChromiumTab *)tab requestsJSDialog:(NSString *)requestID type:(NSString *)type
            message:(NSString *)message defaultText:(NSString *)defaultText origin:(NSString *)origin
           isReload:(BOOL)isReload;
- (void)chromiumTab:(CCChromiumTab *)tab dismissesJSDialog:(NSString *)requestID;
@end
@interface CCChromiumTab (JSDialog)
- (void)resolveJSDialog:(NSString *)requestID accept:(BOOL)accept text:(nullable NSString *)text
        suppressFurther:(BOOL)suppressFurther;
@end

// [Keyboard]

// [LifeSpan]

// [Load]

// [Permission]
// `kinds` are SitePermissionKind raw values; requests for anything else are denied inside the bridge.
@protocol CCChromiumTabPermissionDelegate <NSObject>
- (void)chromiumTab:(CCChromiumTab *)tab requestsPermission:(NSString *)requestID origin:(NSString *)origin
           topLevel:(NSString *)topLevel kinds:(NSArray<NSString *> *)kinds;
- (void)chromiumTab:(CCChromiumTab *)tab dismissesPermission:(NSString *)requestID;
@end
@interface CCChromiumTab (Permission)
- (void)resolvePermission:(NSString *)requestID allow:(BOOL)allow;
@end

// [Print]

// [Request]
// Authentication and blocked-certificate reports. There is deliberately no way to continue past a TLS error.
@protocol CCChromiumTabRequestDelegate <NSObject>
- (void)chromiumTab:(CCChromiumTab *)tab requestsAuthentication:(NSString *)requestID url:(NSString *)url
               host:(NSString *)host port:(NSInteger)port realm:(NSString *)realm scheme:(NSString *)scheme
            isProxy:(BOOL)isProxy;
// validFrom/validUntil are seconds since 1970, or 0 when unknown.
- (void)chromiumTab:(CCChromiumTab *)tab blockedCertificate:(NSString *)url code:(NSInteger)code
            subject:(NSString *)subject issuer:(NSString *)issuer validFrom:(double)validFrom
         validUntil:(double)validUntil;
@end
@interface CCChromiumTab (Request)
// A nil username cancels the request.
- (void)resolveAuthentication:(NSString *)requestID username:(nullable NSString *)username
                     password:(nullable NSString *)password;
@end

// [ResourceRequest]

NS_ASSUME_NONNULL_END

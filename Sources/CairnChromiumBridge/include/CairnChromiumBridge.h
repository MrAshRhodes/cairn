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

NS_ASSUME_NONNULL_END

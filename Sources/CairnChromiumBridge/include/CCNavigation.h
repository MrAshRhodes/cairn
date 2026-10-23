#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@class CCChromiumTab;
@protocol CCChromiumTabNavigationDelegate <NSObject>
// Called only for an ordinary user-activated top-level GET link, never a redirect or form.
- (BOOL)chromiumTab:(CCChromiumTab *)tab interceptUserNavigation:(NSString *)url;
@end
NS_ASSUME_NONNULL_END

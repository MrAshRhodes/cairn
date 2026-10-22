// Exercises the real pending-answer registry without loading or starting CEF.
#import "../../Sources/CairnChromiumBridge/Handlers/CCPending.h"
#include <cassert>

// Only the weak delegate is needed by CCPending; no browser/window is created.
@implementation CCChromiumTab
@synthesize delegate;
@end

@interface PromptDelegate : NSObject <CCChromiumTabJSDialogDelegate, CCChromiumTabPermissionDelegate,
                                      CCChromiumTabRequestDelegate>
@property(nonatomic, strong) NSMutableSet<NSString *> *dismissed;
@end

@implementation PromptDelegate
- (instancetype)init {
  if ((self = [super init])) _dismissed = [NSMutableSet set];
  return self;
}
- (void)chromiumTab:(CCChromiumTab *)tab dismissesJSDialog:(NSString *)identifier {
  [self.dismissed addObject:identifier];
}
- (void)chromiumTab:(CCChromiumTab *)tab dismissesPermission:(NSString *)identifier {
  [self.dismissed addObject:identifier];
}
- (void)chromiumTab:(CCChromiumTab *)tab dismissesAuthentication:(NSString *)identifier {
  [self.dismissed addObject:identifier];
}
@end

int main() {
  @autoreleasepool {
    auto tab = [CCChromiumTab new];
    auto delegate = [PromptDelegate new];
    tab.delegate = (id)delegate;
    NSArray<NSString *> *identifiers = @[@"a-auth", @"js-dialog", @"m-media", @"p-permission"];
    __block int cancelled = 0;
    for (NSString *identifier in identifiers) {
      __weak CCChromiumTab *weakTab = tab;
      cc::Pending(tab)[identifier] = ^(NSDictionary *answer) {
        assert(answer == nil);
        assert(cc::Pending(weakTab).count == 0);
        assert(!cc::Answer(weakTab, identifier, @{@"allow": @YES}));
        ++cancelled;
      };
    }
    cc::Pending(tab)[@"suppress:old-document"] = ^(NSDictionary *) { assert(false); };
    cc::CancelPending(tab);
    assert(cancelled == 4);
    assert(cc::Pending(tab).count == 0);
    assert([delegate.dismissed isEqualToSet:[NSSet setWithArray:identifiers]]);
    cc::CancelPending(tab);
    cc::CancelPending(nil);
    assert(cancelled == 4);

    __block int answered = 0;
    cc::Pending(tab)[@"js-new"] = ^(NSDictionary *answer) {
      assert([answer[@"accept"] boolValue]);
      ++answered;
    };
    assert(!cc::Answer(tab, @"js-dialog", @{@"accept": @YES}));
    assert(cc::Answer(tab, @"js-new", @{@"accept": @YES}));
    assert(!cc::Answer(tab, @"js-new", @{@"accept": @YES}));
    assert(answered == 1);
    cc::CancelPending(tab);
    assert(answered == 1);

    __weak NSObject *weakOwned;
    @autoreleasepool {
      NSObject *owned = [NSObject new];
      weakOwned = owned;
      cc::Pending(tab)[@"a-lifetime"] = ^(NSDictionary *) { (void)[owned hash]; };
    }
    assert(weakOwned != nil);
    cc::CancelPending(tab);
    assert(weakOwned == nil);
  }
}

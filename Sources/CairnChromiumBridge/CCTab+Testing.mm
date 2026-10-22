// CCTab+Testing.mm — fault injection for the bundled smoke test only (see engine/smoke/main.swift).
#import "CCInternal.h"

@implementation CCChromiumTab (Testing)
- (void)crashRendererForTesting {
  [self call:@"Page.crash" params:@{} reply:^(NSDictionary *, NSError *) {}];
}
@end

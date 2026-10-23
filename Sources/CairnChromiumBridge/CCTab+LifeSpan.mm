// CCTab+LifeSpan.mm — popup adoption. The popup's browser is created by CEF (in the opener's request
// context, with window.opener intact); this tab only supplies the view and Client it is created with.
#import "CCInternal.h"

@implementation CCChromiumTab (LifeSpan)
- (instancetype)initAdoptingPopupFromTab:(CCChromiumTab *)opener {
  if ((self = [self initWithProfile:opener.profile ephemeral:opener.ephemeral])) {
    // An opener may intentionally create and populate about:blank; it is not our startup placeholder.
    self.bootstrapDocument = NO;
    [self adoptClient];
  }
  return self;
}
@end

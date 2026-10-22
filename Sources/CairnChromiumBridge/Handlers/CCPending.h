// CCPending.h — answers that CEF callbacks are waiting for, kept per tab.
//
// A block stored here owns the CEF callback it will complete. Navigation, close and shutdown
// explicitly cancel it and dismiss the corresponding UI. Main thread only.
#pragma once
#import "../CCInternal.h"
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

namespace cc {

typedef void (^PendingAnswer)(NSDictionary *_Nullable answer);

inline NSMutableDictionary<NSString *, PendingAnswer> *Pending(CCChromiumTab *tab) {
  static const char key = 0;
  auto pending = (NSMutableDictionary<NSString *, PendingAnswer> *)objc_getAssociatedObject(tab, &key);
  if (!pending) {
    pending = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(tab, &key, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return pending;
}

// Completes and removes the answer registered under `requestID`; false when it is gone.
inline bool Answer(CCChromiumTab *tab, NSString *requestID, NSDictionary *answer) {
  auto pending = Pending(tab);
  PendingAnswer block = pending[requestID];
  if (!block) return false;
  [pending removeObjectForKey:requestID];
  block(answer);
  return true;
}

inline void CancelPending(CCChromiumTab *tab) {
  if (!tab) return;
  auto pending = Pending(tab);
  NSDictionary<NSString *, PendingAnswer> *snapshot = [pending copy];
  // Clear before completing: CEF callbacks and Swift dismissal can synchronously re-enter.
  [pending removeAllObjects];
  for (NSString *key in snapshot) {
    if ([key hasPrefix:@"suppress:"]) continue;
    snapshot[key](nil);
    if ([key hasPrefix:@"js"] && [tab.delegate conformsToProtocol:@protocol(CCChromiumTabJSDialogDelegate)])
      [(id<CCChromiumTabJSDialogDelegate>)tab.delegate chromiumTab:tab dismissesJSDialog:key];
    else if ([key hasPrefix:@"a"] && [tab.delegate respondsToSelector:@selector(chromiumTab:dismissesAuthentication:)])
      [(id<CCChromiumTabRequestDelegate>)tab.delegate chromiumTab:tab dismissesAuthentication:key];
    else if (([key hasPrefix:@"m"] || [key hasPrefix:@"p"]) &&
             [tab.delegate conformsToProtocol:@protocol(CCChromiumTabPermissionDelegate)])
      [(id<CCChromiumTabPermissionDelegate>)tab.delegate chromiumTab:tab dismissesPermission:key];
  }
}

}  // namespace cc

#pragma clang diagnostic pop

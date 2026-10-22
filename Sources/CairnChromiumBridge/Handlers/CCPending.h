// CCPending.h — answers that CEF callbacks are waiting for, kept per tab.
//
// A block stored here owns the CEF callback it will complete, so closing the tab (and with it this
// dictionary) releases anything the page was still waiting on. Main thread only.
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

}  // namespace cc

#pragma clang diagnostic pop

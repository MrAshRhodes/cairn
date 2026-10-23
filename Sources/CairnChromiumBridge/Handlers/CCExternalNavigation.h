#pragma once
#import <Foundation/Foundation.h>

namespace cc {

inline bool IsExternalNavigationURL(NSString *url) {
  NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
  if (!scheme.length) return false;
  // Keep browser-owned schemes in Chromium, including their genuine load errors.
  return ![@[@"http", @"https", @"file", @"ftp", @"about", @"data", @"blob", @"filesystem",
             @"javascript", @"chrome", @"chrome-untrusted", @"chrome-error", @"chrome-extension",
             @"chrome-search", @"devtools", @"view-source", @"ws", @"wss"] containsObject:scheme];
}

}  // namespace cc

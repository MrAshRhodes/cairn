// CCTab+Print.mm — SKELETON: printing and print-to-PDF as tab commands.
//
// Unlike the other skeletons there is no CEF handler to register: CefPrintHandler is Linux-only, so on
// macOS printing is driven from the tab through CefBrowserHost (Print, PrintToPDF), reached via
// `self.cefBrowser`. This file shows the pattern for any feature that is a tab *command* rather than
// a handler callback; it adds no behavior today.
//
// To implement, change only this file (plus your slot in the public header and a Swift extension):
//   1. declare the command as a category of CCChromiumTab in your slot of include/CairnChromiumBridge.h
//      (`@interface CCChromiumTab (Print) ... @end`; additive, so existing API is untouched);
//   2. implement it below with `auto browser = self.cefBrowser; if (!browser) return;` and, for page
//      content, `[self call:@"Page.printToPDF" params:... reply:...]`, which handles replies and timeouts;
//   3. call it from a ChromiumTab+Print.swift extension on the Swift side.
// Categories keep each feature's tab commands out of CCTab.mm, so parallel features do not collide there.
#import "CCInternal.h"

@interface CCChromiumTab (PrintSkeleton)
@end

@implementation CCChromiumTab (PrintSkeleton)
@end

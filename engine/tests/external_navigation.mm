#import "../../Sources/CairnChromiumBridge/Handlers/CCExternalNavigation.h"
#include <cassert>

int main() {
  @autoreleasepool {
    for (NSString *url in @[@"mailto:smoke@example.com", @"MAILTO:smoke@example.com", @"tel:+123",
                           @"cairn-smoke-unknown://resource", @"ssh://example.test"]) {
      assert(cc::IsExternalNavigationURL(url));
    }
    for (NSString *url in @[@"https://example.test", @"http://127.0.0.1:1", @"file:///missing",
                           @"ftp://example.test/file", @"about:blank", @"data:text/plain,hello",
                           @"blob:https://example.test/id", @"filesystem:https://example.test/temporary/a",
                           @"javascript:void(0)", @"chrome://crash", @"chrome-error://chromewebdata/",
                           @"chrome-untrusted://test", @"chrome-extension://test",
                           @"chrome-search://local-ntp", @"devtools://devtools",
                           @"view-source:https://example.test", @"ws://example.test",
                           @"wss://example.test", @"", @"/relative"]) {
      assert(!cc::IsExternalNavigationURL(url));
    }
  }
}

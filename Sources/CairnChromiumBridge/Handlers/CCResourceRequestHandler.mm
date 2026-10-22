// CCResourceRequestHandler.mm — CefResourceRequestHandler: content blocking and origin tracking.
//
// Content blocking uses a user-supplied host list (Swift parses it; nothing is fetched remotely). A request is
// refused only when it is a subresource or sub-frame load, third-party to the top-level page, its host (or a parent
// domain) is on the list, and the page's site is not exempt. Main-frame navigations are never cancelled.
// Callbacks run on Chromium's IO thread: the rule snapshot is immutable and swapped under a lock, and nothing here
// touches the tab. Every http(s) origin a persistent profile navigates to is also recorded for site-data clearing.
#import "../CCInternal.h"
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>
#include "include/cef_parser.h"

namespace cc {
namespace {
struct Rules {
  bool enabled = false;
  std::unordered_set<std::string> blocked;
  std::vector<std::string> exempt;
};
std::mutex rulesMutex;
std::shared_ptr<const Rules> rules = std::make_shared<const Rules>();
std::atomic<size_t> blockedCount{0};

std::shared_ptr<const Rules> CurrentRules() {
  std::lock_guard<std::mutex> lock(rulesMutex);
  return rules;
}

std::string HostOf(const CefString& url) {
  CefURLParts parts;
  if (!url.empty() && CefParseURL(url, parts)) {
    std::string scheme = CefString(&parts.scheme).ToString();
    if (scheme == "http" || scheme == "https") {
      std::string host = CefString(&parts.host).ToString();
      for (auto& c : host) c = (char)tolower(c);
      return host;
    }
  }
  return "";
}

bool IsSameOrSubdomain(const std::string& host, const std::string& site) {
  return host == site || (host.size() > site.size() && host.compare(host.size() - site.size(), site.size(), site) == 0 &&
                          host[host.size() - site.size() - 1] == '.');
}

bool IsListed(const Rules& set, const std::string& host) {
  if (set.blocked.count(host)) return true;
  for (auto dot = host.find('.'); dot != std::string::npos; dot = host.find('.', dot + 1)) {
    std::string parent = host.substr(dot + 1);
    if (parent.find('.') == std::string::npos) break; // Never match a bare top-level domain.
    if (set.blocked.count(parent)) return true;
  }
  return false;
}

class ResourceRequestHandler final : public CefResourceRequestHandler {
 public:
  explicit ResourceRequestHandler(std::string contextKey) : contextKey_(std::move(contextKey)) {}
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback>) override {
    auto type = request->GetResourceType();
    if (type == RT_MAIN_FRAME || type == RT_SUB_FRAME) TrackOrigin(contextKey_, request->GetURL());
    if (type == RT_MAIN_FRAME) return RV_CONTINUE;
    auto current = CurrentRules();
    if (!current->enabled || current->blocked.empty()) return RV_CONTINUE;
    std::string host = HostOf(request->GetURL());
    if (host.empty() || !IsListed(*current, host)) return RV_CONTINUE;
    CefString page = browser ? browser->GetMainFrame()->GetURL() : request->GetReferrerURL();
    std::string site = HostOf(page);
    if (!site.empty()) {
      if (IsSameOrSubdomain(host, site) || IsSameOrSubdomain(site, host)) return RV_CONTINUE;
      for (const auto& exempt : current->exempt)
        if (IsSameOrSubdomain(site, exempt)) return RV_CONTINUE;
    }
    blockedCount++;
    return RV_CANCEL;
  }
  void OnResourceRedirect(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse>, CefString& newURL) override {
    auto type = request->GetResourceType();
    if (type == RT_MAIN_FRAME || type == RT_SUB_FRAME) TrackOrigin(contextKey_, newURL);
  }
 private:
  std::string contextKey_;
  IMPLEMENT_REFCOUNTING(ResourceRequestHandler);
};
}  // namespace

CefRefPtr<CefResourceRequestHandler> MakeResourceRequestHandler(Client& client) {
  return new ResourceRequestHandler(client.contextKey);
}

}  // namespace cc

@implementation CCChromiumRuntime (ContentBlocking)
+ (void)setContentBlockingEnabled:(BOOL)enabled blockedHosts:(NSArray<NSString *> *)blockedHosts
                      exemptSites:(NSArray<NSString *> *)exemptSites {
  auto next = std::make_shared<cc::Rules>();
  next->enabled = enabled;
  for (NSString *host in blockedHosts) next->blocked.insert(host.lowercaseString.UTF8String);
  for (NSString *site in exemptSites) next->exempt.push_back(site.lowercaseString.UTF8String);
  std::lock_guard<std::mutex> lock(cc::rulesMutex);
  cc::rules = next;
}
+ (NSUInteger)blockedRequestCount { return cc::blockedCount.load(); }
@end

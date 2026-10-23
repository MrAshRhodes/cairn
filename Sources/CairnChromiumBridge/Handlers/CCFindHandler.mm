// CCFindHandler.mm — CefFindHandler: find-in-page results.
// The smallest complete handler; copy it as the template for a new family.
#import "../CCInternal.h"

namespace cc {
namespace {
class FindHandler final : public TabHandler, public CefFindHandler {
 public:
  explicit FindHandler(Client& client) : TabHandler(client) {}
  void OnFindResult(CefRefPtr<CefBrowser>, int, int count, const CefRect&, int, bool final) override {
    auto tab = owner;
    if (final && tab.findReply) {
      auto callback = tab.findReply; tab.findReply = nil; callback(count > 0);
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(FindHandler);
};
}

CefRefPtr<CefFindHandler> MakeFindHandler(Client& client) { return new FindHandler(client); }

}  // namespace cc

// CCDownloadHandler.mm — CefDownloadHandler: in-engine downloads.
//
// Chromium performs the transfer, so cookies, authentication, POST bodies and blob:/data: sources
// work. Swift picks the destination (`CCChromiumDownloads.delegate`) and receives progress. A
// download outlives its tab, so state is process-wide and never refers to the originating browser.
#import "../CCInternal.h"
#include <map>
#include <set>

namespace cc {
namespace {

struct LiveDownload {
  CefRefPtr<CefDownloadItemCallback> callback;
  CFAbsoluteTime lastSent = 0;
  bool sent = false;
  bool lastPaused = false;
};
std::map<uint32_t, LiveDownload> live;
// UI destination choices must not retain a CEF callback after runtime shutdown.
std::map<uint32_t, CefRefPtr<CefBeforeDownloadCallback>> pendingChoices;
std::set<uint32_t> cancellingAtShutdown;
// Chromium re-enters OnBeforeDownload when it auto-resumes an interrupted download; reuse the user's choice.
std::map<uint32_t, std::string> chosen;

NSDictionary *Update(CefRefPtr<CefDownloadItem> item) {
  return @{
    @"id": @(item->GetId()),
    @"complete": @(item->IsComplete()),
    @"canceled": @(item->IsCanceled()),
    @"interrupted": @(item->IsInterrupted()),
    @"paused": @(item->IsPaused()),
    @"reason": @((int)item->GetInterruptReason()),
    @"received": @(item->GetReceivedBytes()),
    @"total": @(item->GetTotalBytes()),
    @"percent": @(item->GetPercentComplete()),
    @"speed": @(item->GetCurrentSpeed()),
    @"path": String(item->GetFullPath()),
  };
}

class DownloadHandler final : public TabHandler, public CefDownloadHandler {
 public:
  explicit DownloadHandler(Client& client) : TabHandler(client) {}

  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                        const CefString& suggested, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (stopping) return true;
    auto tab = owner;
    id<CCChromiumDownloadDelegate> delegate = CCChromiumDownloads.delegate;
    if (!delegate) {
      // No app is listening: surface the refusal through the legacy URL path instead of failing silently.
      [tab.delegate chromiumTab:tab download:String(item->GetURL()) filename:String(suggested)];
      return true;
    }
    auto previous = chosen.find(item->GetId());
    if (previous != chosen.end()) {
      callback->Continue(previous->second, false);
      return true;
    }
    NSDictionary *info = @{
      @"id": @(item->GetId()),
      @"url": String(item->GetURL()),
      @"suggestedName": String(suggested),
      @"mime": String(item->GetMimeType()),
      @"totalBytes": @(item->GetTotalBytes()),
      @"profile": tab.profile ?: @"",
      @"ephemeral": @(tab.ephemeral),
    };
    uint32_t identifier = item->GetId();
    pendingChoices[identifier] = callback;
    [delegate chromiumDownloadWillStart:info decide:^(NSString *path) {
      auto found = pendingChoices.find(identifier);
      if (found == pendingChoices.end()) return;
      CefRefPtr<CefBeforeDownloadCallback> pending = found->second;
      pendingChoices.erase(found);
      // Releasing the callback without Continue cancels the download.
      if (path.length && !stopping) {
        chosen[identifier] = path.UTF8String;
        pending->Continue(CefString(path.UTF8String), false);
      }
    }];
    return true; // Swift must always decide: an unanswered callback leaves the download pending.
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!item->IsValid()) return;
    uint32_t identifier = item->GetId();
    if (stopping) {
      if (!item->IsComplete() && !item->IsCanceled() && !item->IsInterrupted() &&
          cancellingAtShutdown.insert(identifier).second) callback->Cancel();
      return;
    }
    if (item->IsComplete() || item->IsCanceled() || item->IsInterrupted()) {
      live.erase(identifier);
      chosen.erase(identifier);
      pendingChoices.erase(identifier);
    } else {
      LiveDownload& entry = live[identifier];
      entry.callback = callback;
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      bool paused = item->IsPaused();
      if (entry.sent && paused == entry.lastPaused && now - entry.lastSent < 0.1) return;
      entry.sent = true;
      entry.lastSent = now;
      entry.lastPaused = paused;
    }
    [CCChromiumDownloads.delegate chromiumDownloadUpdated:Update(item)];
  }

 private:
  IMPLEMENT_REFCOUNTING(DownloadHandler);
};
}

void ReleaseDownloads() {
  // Move first because Cancel can re-enter OnDownloadUpdated.
  auto active = std::move(live);
  live.clear();
  pendingChoices.clear();
  chosen.clear();
  for (const auto& pair : active) {
    if (cancellingAtShutdown.insert(pair.first).second) pair.second.callback->Cancel();
  }
}

CefRefPtr<CefDownloadHandler> MakeDownloadHandler(Client& client) { return new DownloadHandler(client); }

}  // namespace cc

static __weak id<CCChromiumDownloadDelegate> downloadDelegate;

@implementation CCChromiumDownloads
+ (id<CCChromiumDownloadDelegate>)delegate { return downloadDelegate; }
+ (void)setDelegate:(id<CCChromiumDownloadDelegate>)delegate { downloadDelegate = delegate; }
+ (void)cancel:(uint32_t)identifier {
  cc::pendingChoices.erase(identifier);
  auto found = cc::live.find(identifier);
  if (found != cc::live.end()) found->second.callback->Cancel();
}
+ (void)pause:(uint32_t)identifier {
  auto found = cc::live.find(identifier);
  if (found != cc::live.end()) found->second.callback->Pause();
}
+ (void)resume:(uint32_t)identifier {
  auto found = cc::live.find(identifier);
  if (found != cc::live.end()) found->second.callback->Resume();
}
@end

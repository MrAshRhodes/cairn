// CCDownloadHandler.mm — CefDownloadHandler: in-engine downloads.
//
// Chromium performs the transfer, so cookies, authentication, POST bodies and blob:/data: sources
// work. Swift picks the destination (`CCChromiumDownloads.delegate`) and receives progress.
// Original transfers can outlive tabs. Retrying requires the original live tab and Chromium item.
#import "../CCInternal.h"
#include <map>
#include <set>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace cc {
namespace {

struct LiveDownload {
  CefRefPtr<CefDownloadItemCallback> callback;
  __weak CCChromiumTab *origin = nil;
  int browserID = -1;
  std::string profile;
  std::string destination;
  std::string parent;
  std::string method;
  struct stat folder = {};
  struct stat partial = {};
  bool hasFolder = false;
  bool hasPartial = false;
  bool capturedPartial = false;
  bool safeURL = false;
  bool failed = false;
  bool retrying = false;
  bool cancelling = false;
  uint32_t attempt = 0;
  int reason = 0;
  NSString *unavailable = nil;
  NSDictionary *lastUpdate = nil;
  CFAbsoluteTime lastSent = 0;
  bool sent = false;
  bool lastPaused = false;
};
std::map<uint32_t, LiveDownload> live;
// UI destination choices must not retain a CEF callback after runtime shutdown.
std::map<uint32_t, CefRefPtr<CefBeforeDownloadCallback>> pendingChoices;
std::set<uint32_t> cancellingAtShutdown;
std::set<uint32_t> discarded;
// Chromium re-enters OnBeforeDownload when it auto-resumes an interrupted download; reuse the user's choice.
std::map<uint32_t, std::string> chosen;
uint32_t nextIdentifier = 0;

bool SameFile(const struct stat& a, const struct stat& b) {
  return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
      a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}

bool PlainParents(NSString *path) {
  NSString *current = [path stringByDeletingLastPathComponent];
  while (current.length > 1) {
    struct stat info = {};
    if (lstat(current.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode)) return false;
    current = [current stringByDeletingLastPathComponent];
  }
  return true;
}

NSString *RetryRefusal(const LiveDownload& entry) {
  if (entry.unavailable) return entry.unavailable;
  auto origin = entry.origin;
  if (stopping || !origin || origin.closing || !origin.cefBrowser ||
      origin.cefBrowser->GetIdentifier() != entry.browserID ||
      entry.profile != (origin.profile ?: @"").UTF8String)
    return @"The original tab or Space is no longer available. Start the download again from its page.";
  if (entry.method != "GET" || !entry.safeURL)
    return @"This request cannot be safely repeated (POST, one-use URL, redirect, or unknown method). Start the download again from its page.";
  // Only transport interruptions: security blocks, server refusals and file errors need page/user action.
  if (entry.reason != 20 && entry.reason != 21 && entry.reason != 22 &&
      entry.reason != 23 && entry.reason != 30 && entry.reason != 38)
    return @"Chromium cannot safely retry this interruption. Start the download again from its page.";
  if (!entry.callback || !entry.hasFolder || entry.destination.empty())
    return @"The original transfer or destination is unavailable. Start the download again from its page.";
  return nil;
}

NSString *DestinationRefusal(const LiveDownload& entry) {
  struct stat folder = {}, partial = {};
  NSString *path = [NSString stringWithUTF8String:entry.destination.c_str()];
  if (!PlainParents(path) || lstat(entry.parent.c_str(), &folder) || !S_ISDIR(folder.st_mode) ||
      folder.st_dev != entry.folder.st_dev || folder.st_ino != entry.folder.st_ino ||
      access(entry.parent.c_str(), W_OK | X_OK))
    return @"The destination folder changed or is not writable. Start the download again from its page.";
  bool exists = lstat(entry.destination.c_str(), &partial) == 0;
  if ((!exists && errno != ENOENT) || exists != entry.hasPartial ||
      (exists && (!S_ISREG(partial.st_mode) || !SameFile(partial, entry.partial) ||
                  access(entry.destination.c_str(), W_OK))))
    return @"The partial file changed. Retry will not overwrite it. Start the download again from its page and choose another filename.";
  return nil;
}

NSString *InitialDestinationRefusal(NSString *path) {
  NSString *parent = path.stringByDeletingLastPathComponent;
  struct stat folder = {}, target = {};
  if (!path.isAbsolutePath || stat(parent.fileSystemRepresentation, &folder) ||
      !S_ISDIR(folder.st_mode) || access(parent.fileSystemRepresentation, W_OK | X_OK))
    return @"The chosen destination folder is unavailable or is not writable. Start the download again and choose another folder.";
  if (lstat(path.fileSystemRepresentation, &target) == 0) {
    if (!S_ISREG(target.st_mode) || access(path.fileSystemRepresentation, W_OK))
      return @"The chosen destination is not a writable regular file. Start the download again and choose another filename.";
  } else if (errno != ENOENT) {
    return @"The chosen destination could not be accessed. Start the download again and choose another filename.";
  }
  return nil;
}

void Send(uint32_t identifier, NSDictionary *value) {
  NSMutableDictionary *update = [value mutableCopy];
  auto found = live.find(identifier);
  if (found != live.end()) {
    auto& entry = found->second;
    NSString *refusal = RetryRefusal(entry);
    update[@"attempt"] = @(entry.attempt);
    update[@"retryable"] = @(entry.failed && !refusal);
    if (refusal) update[@"retryReason"] = refusal;
    entry.lastUpdate = update;
  }
  [CCChromiumDownloads.delegate chromiumDownloadUpdated:update];
}

void Refuse(uint32_t identifier, uint32_t attempt, NSString *message, int reason = 20) {
  [CCChromiumDownloads.delegate chromiumDownloadUpdated:@{
    @"id": @(identifier), @"attempt": @(attempt), @"interrupted": @YES, @"reason": @(reason),
    @"retryable": @NO, @"retryReason": message,
  }];
}

NSDictionary *Update(CefRefPtr<CefDownloadItem> item, uint32_t identifier) {
  return @{
    @"id": @(identifier),
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

  bool CanDownload(CefRefPtr<CefBrowser>, const CefString& url, const CefString& method) override {
    auto tab = owner;
    if (stopping || !tab || tab.closing) return false;
    // CEF supplies the method but no request ID here. Ambiguous concurrent requests fail closed.
    if (methods_.size() >= 256) { methods_.clear(); provenanceOverflow_ = true; }
    if (!provenanceOverflow_) {
      auto [entry, inserted] = methods_.emplace(url.ToString(), method.ToString());
      if (!inserted) entry->second = "";
    }
    return true;
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                        const CefString& suggested, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (stopping) return true;
    uint32_t identifier = Identifier(item->GetId());
    if (!identifier || discarded.count(identifier)) return true;
    auto tab = owner;
    if (!tab || tab.closing) return true;
    id<CCChromiumDownloadDelegate> delegate = CCChromiumDownloads.delegate;
    if (!delegate) {
      // No app is listening: surface the refusal through the legacy URL path instead of failing silently.
      [tab.delegate chromiumTab:tab download:String(item->GetURL()) filename:String(suggested)];
      return true;
    }
    auto previous = chosen.find(identifier);
    if (previous != chosen.end()) {
      auto found = live.find(identifier);
      if (found == live.end() || found->second.unavailable || found->second.cancelling ||
          (found->second.failed && !found->second.retrying)) return true;
      if (found->second.attempt && DestinationRefusal(found->second)) return true;
      callback->Continue(previous->second, false);
      return true;
    }
    auto& entry = live[identifier];
    entry.origin = tab;
    entry.browserID = browser ? browser->GetIdentifier() : -1;
    entry.profile = (tab.profile ?: @"").UTF8String;
    auto method = methods_.find(item->GetURL().ToString());
    if (method != methods_.end()) {
      entry.method = method->second;
      methods_.erase(method);
    }
    NSURL *source = [NSURL URLWithString:String(item->GetURL())];
    entry.safeURL = ([source.scheme isEqualToString:@"https"] || [source.scheme isEqualToString:@"http"]) &&
        source.host.length && !source.user && !source.password &&
        !source.query && !source.fragment &&
        item->GetOriginalUrl() == item->GetURL();
    NSDictionary *info = @{
      @"id": @(identifier),
      @"url": String(item->GetURL()),
      @"suggestedName": String(suggested),
      @"mime": String(item->GetMimeType()),
      @"totalBytes": @(item->GetTotalBytes()),
      @"profile": tab.profile ?: @"",
      @"ephemeral": @(tab.ephemeral),
    };
    pendingChoices[identifier] = callback;
    [delegate chromiumDownloadWillStart:info decide:^(NSString *path) {
      auto found = pendingChoices.find(identifier);
      if (found == pendingChoices.end()) {
        if (!stopping && discarded.count(identifier))
          [CCChromiumDownloads.delegate chromiumDownloadUpdated:@{@"id": @(identifier), @"canceled": @YES}];
        return;
      }
      CefRefPtr<CefBeforeDownloadCallback> pending = found->second;
      pendingChoices.erase(found);
      // Releasing the callback without Continue cancels the download.
      auto entry = live.find(identifier);
      if (path.length && !stopping && !discarded.count(identifier) && entry != live.end()) {
        if (NSString *refusal = InitialDestinationRefusal(path)) {
          auto control = entry->second.callback;
          uint32_t attempt = entry->second.attempt;
          discarded.insert(identifier);
          live.erase(entry);
          Refuse(identifier, attempt, refusal, CEF_DOWNLOAD_INTERRUPT_REASON_FILE_FAILED);
          if (control) control->Cancel();
          return;
        }
        chosen[identifier] = path.UTF8String;
        entry->second.destination = path.fileSystemRepresentation;
        entry->second.parent = path.stringByDeletingLastPathComponent.fileSystemRepresentation;
        entry->second.hasFolder = !lstat(entry->second.parent.c_str(), &entry->second.folder) &&
            S_ISDIR(entry->second.folder.st_mode);
        pending->Continue(CefString(path.UTF8String), false);
      }
    }];
    return true; // Swift must always decide: an unanswered callback leaves the download pending.
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!item->IsValid()) return;
    uint32_t identifier = Identifier(item->GetId());
    if (!identifier) { callback->Cancel(); return; }
    if (discarded.count(identifier)) {
      if (item->IsInProgress()) callback->Cancel();
      return;
    }
    if (stopping) {
      if (!item->IsComplete() && !item->IsCanceled() && !item->IsInterrupted() &&
          cancellingAtShutdown.insert(identifier).second) callback->Cancel();
      return;
    }
    auto& entry = live[identifier];
    if (entry.cancelling && !item->IsComplete() && !item->IsCanceled()) {
      if (item->IsInProgress()) callback->Cancel();
      return;
    }
    if (entry.failed && !entry.retrying && !item->IsInterrupted() && !item->IsCanceled()) {
      callback->Cancel();
      return; // A late/automatic update must not resurrect an explicitly failed item.
    }
    entry.callback = callback;
    entry.reason = (int)item->GetInterruptReason();
    if (item->IsComplete() || item->IsCanceled()) {
      Send(identifier, Update(item, identifier));
      live.erase(identifier);
      chosen.erase(identifier);
      pendingChoices.erase(identifier);
      discarded.insert(identifier);
      return;
    } else if (item->IsInterrupted()) {
      entry.failed = true;
      entry.retrying = false;
      if (!entry.capturedPartial) {
        // Chromium clears GetFullPath before asynchronously deleting a non-resumable partial.
        // Such a retry may start only once the destination is absent, never over a replacement.
        entry.hasPartial = !item->GetFullPath().empty();
        if (entry.hasPartial &&
            (item->GetFullPath().ToString() != entry.destination ||
             lstat(entry.destination.c_str(), &entry.partial))) {
          entry.unavailable = @"The original partial file is unavailable. Start the download again from its page.";
        }
        entry.capturedPartial = true;
      }
    } else {
      entry.failed = false;
      entry.retrying = false;
      entry.capturedPartial = false;
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      bool paused = item->IsPaused();
      if (entry.sent && paused == entry.lastPaused && now - entry.lastSent < 0.1) return;
      entry.sent = true;
      entry.lastSent = now;
      entry.lastPaused = paused;
    }
    Send(identifier, Update(item, identifier));
  }

 private:
  uint32_t Identifier(uint32_t nativeID) {
    auto found = identifiers_.find(nativeID);
    if (found != identifiers_.end()) return found->second;
    if (nextIdentifier == UINT32_MAX) {
      NSLog(@"Cairn refused a download because the process-wide identifier range was exhausted.");
      return 0;
    }
    uint32_t identifier = ++nextIdentifier;
    identifiers_.emplace(nativeID, identifier);
    return identifier;
  }

  // Chromium IDs are profile-local. Each originating browser has one handler; keep its mapping
  // through terminal/late callbacks, including updates that precede the destination request.
  std::map<uint32_t, uint32_t> identifiers_;
  std::map<std::string, std::string> methods_;
  bool provenanceOverflow_ = false;
  IMPLEMENT_REFCOUNTING(DownloadHandler);
};
}

void InvalidateDownloadRetries(int browserID) {
  std::vector<uint32_t> identifiers;
  for (const auto& [identifier, entry] : live) {
    if (entry.browserID == browserID) identifiers.push_back(identifier);
  }
  for (uint32_t identifier : identifiers) {
    auto found = live.find(identifier);
    if (found == live.end()) continue;
    auto& entry = found->second;
    entry.unavailable = @"The original tab or Space was closed. Start the download again from its page.";
    if (pendingChoices.count(identifier) || entry.retrying || (entry.attempt && !entry.failed)) {
      discarded.insert(identifier);
      entry.retrying = false;
      pendingChoices.erase(identifier);
      if (entry.callback) entry.callback->Cancel();
      Refuse(identifier, entry.attempt, entry.unavailable);
    } else if (entry.failed && entry.lastUpdate) {
      Send(identifier, entry.lastUpdate);
    }
  }
}

void ReleaseDownloads() {
  // Move first because Cancel can re-enter OnDownloadUpdated.
  auto active = std::move(live);
  live.clear();
  pendingChoices.clear();
  chosen.clear();
  for (const auto& pair : active) {
    if (pair.second.callback && cancellingAtShutdown.insert(pair.first).second) pair.second.callback->Cancel();
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
  cc::chosen.erase(identifier);
  auto found = cc::live.find(identifier);
  if (found != cc::live.end()) {
    auto callback = found->second.callback;
    if (callback) {
      if (found->second.cancelling) return;
      found->second.cancelling = true;
      found->second.retrying = false;
      // Cancel is asynchronous. Publish the terminal state only when Chromium acknowledges it.
      callback->Cancel();
      return;
    }
    uint32_t attempt = found->second.attempt;
    cc::live.erase(found);
    cc::discarded.insert(identifier);
    [self.delegate chromiumDownloadUpdated:@{@"id": @(identifier), @"canceled": @YES, @"attempt": @(attempt)}];
  }
}
+ (void)pause:(uint32_t)identifier {
  auto found = cc::live.find(identifier);
  if (found != cc::live.end() && !found->second.failed && !found->second.cancelling && found->second.callback)
    found->second.callback->Pause();
}
+ (void)resume:(uint32_t)identifier {
  auto found = cc::live.find(identifier);
  if (found != cc::live.end() && !found->second.failed && !found->second.cancelling && found->second.callback)
    found->second.callback->Resume();
}
+ (void)retry:(uint32_t)identifier attempt:(uint32_t)attempt {
  auto found = cc::live.find(identifier);
  if (found == cc::live.end() || cc::discarded.count(identifier)) {
    cc::Refuse(identifier, attempt, @"The original transfer is unavailable. Start the download again from its page.");
    return;
  }
  auto& entry = found->second;
  if (!entry.failed || entry.retrying || entry.cancelling || attempt != entry.attempt + 1) return;
  entry.attempt = attempt;
  NSString *refusal = cc::RetryRefusal(entry) ?: cc::DestinationRefusal(entry);
  if (refusal) {
    entry.unavailable = refusal;
    cc::Refuse(identifier, attempt, refusal);
    return;
  }
  entry.retrying = true;
  entry.sent = false;
  // CEF 154 checks the retained DownloadItem's CanResume() and calls Resume(true), preserving its
  // request context and partial-file handling. It exposes neither CanResume nor an acknowledgement.
  entry.callback->Resume();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    auto pending = cc::live.find(identifier);
    if (cc::stopping || pending == cc::live.end() || pending->second.attempt != attempt ||
        !pending->second.retrying) return;
    auto& entry = pending->second;
    entry.retrying = false;
    entry.unavailable = @"Chromium could not resume this transfer. Start the download again from its page.";
    cc::discarded.insert(identifier);
    if (entry.callback) entry.callback->Cancel();
    cc::Refuse(identifier, attempt, entry.unavailable);
  });
}
@end

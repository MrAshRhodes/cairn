// Runs the production download handler against inert CEF objects, without loading the framework.
#define WRAPPING_CEF_SHARED
#import "cef_fixture_strings.h"
#import "../../Sources/CairnChromiumBridge/Handlers/CCDownloadHandler.mm"
#include "libcef_dll/ctocpp/browser_ctocpp.h"
#include <cassert>

static CefRefPtr<CefBrowser> fixtureBrowser;
static CefRefPtr<CefBrowser> fixtureSecondBrowser;
namespace cc {
bool stopping = false;
NSString *String(const CefString& text) { return [NSString stringWithUTF8String:text.ToString().c_str()]; }
Client::Client(CCChromiumTab *tab) : owner(tab), ephemeral(false) {}
}
@implementation CCChromiumTab
@synthesize delegate, closing, profile, ephemeral;
- (CefRefPtr<CefBrowser>)cefBrowser { return self.ephemeral ? fixtureSecondBrowser : fixtureBrowser; }
@end

class Item final : public CefDownloadItem {
 public:
  uint32_t identifier;
  uint32_t appIdentifier = 0;
  std::string url = "https://files.test/file", original = url, path;
  bool interrupted = false, complete = false, canceled = false, paused = false;
  int64_t received = 5;
  explicit Item(uint32_t value) : identifier(value) {}
  bool IsValid() override { return true; }
  bool IsInProgress() override { return !interrupted && !complete && !canceled; }
  bool IsComplete() override { return complete; }
  bool IsCanceled() override { return canceled; }
  bool IsInterrupted() override { return interrupted; }
  bool IsPaused() override { return paused; }
  cef_download_interrupt_reason_t GetInterruptReason() override {
    return interrupted ? CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_DISCONNECTED : CEF_DOWNLOAD_INTERRUPT_REASON_NONE;
  }
  int64_t GetCurrentSpeed() override { return 0; }
  int GetPercentComplete() override { return 5; }
  int64_t GetTotalBytes() override { return 100; }
  int64_t GetReceivedBytes() override { return received; }
  CefBaseTime GetStartTime() override { return {}; }
  CefBaseTime GetEndTime() override { return {}; }
  CefString GetFullPath() override { return path; }
  uint32_t GetId() override { return identifier; }
  CefString GetURL() override { return url; }
  CefString GetOriginalUrl() override { return original; }
  CefString GetSuggestedFileName() override { return "file.bin"; }
  CefString GetContentDisposition() override { return "attachment"; }
  CefString GetMimeType() override { return "application/octet-stream"; }
  IMPLEMENT_REFCOUNTING(Item);
};
class Callback final : public CefDownloadItemCallback {
 public:
  int resumes = 0, cancels = 0, pauses = 0;
  void Cancel() override { ++cancels; }
  void Resume() override { ++resumes; }
  void Pause() override { ++pauses; }
  IMPLEMENT_REFCOUNTING(Callback);
};
class Choice final : public CefBeforeDownloadCallback {
 public:
  int continued = 0;
  void Continue(const CefString&, bool) override { ++continued; }
  IMPLEMENT_REFCOUNTING(Choice);
};

@interface DownloadDelegate : NSObject <CCChromiumDownloadDelegate>
@property(nonatomic, copy) NSString *destination;
@property(nonatomic, strong) NSDictionary *last;
@property(nonatomic, strong) NSDictionary *started;
@property(nonatomic) BOOL hold;
@property(nonatomic, copy) void (^decision)(NSString *);
@end
@implementation DownloadDelegate
- (void)chromiumDownloadWillStart:(NSDictionary *)info decide:(void (^)(NSString *))decide {
  self.started = info;
  if (self.hold) self.decision = decide;
  else decide(self.destination);
}
- (void)chromiumDownloadUpdated:(NSDictionary *)update { self.last = update; }
@end

void InitBase(cef_base_ref_counted_t& base, size_t size) {
  base.size = size;
  base.add_ref = [](cef_base_ref_counted_t *) {};
  base.release = [](cef_base_ref_counted_t *) { return 0; };
  base.has_one_ref = [](cef_base_ref_counted_t *) { return 1; };
  base.has_at_least_one_ref = [](cef_base_ref_counted_t *) { return 1; };
}

int main() {
  @autoreleasepool {
    cef_browser_t browser{};
    InitBase(browser.base, sizeof(browser));
    browser.get_identifier = [](cef_browser_t *) { return 17; };
    fixtureBrowser = CefBrowserCToCpp_Wrap(&browser);
    CCChromiumTab *tab = [CCChromiumTab new];
    tab.profile = @"profile-a";
    CefRefPtr<cc::Client> client = new cc::Client(tab);
    auto handler = cc::MakeDownloadHandler(*client);
    DownloadDelegate *delegate = [DownloadDelegate new];
    CCChromiumDownloads.delegate = delegate;
    NSString *directory = NSProcessInfo.processInfo.environment[@"TMPDIR"];
    assert([directory containsString:@".build/"]);
    delegate.destination = [directory stringByAppendingPathComponent:@"partial.bin"];
    auto write = [&] {
      assert([@"partial" writeToFile:delegate.destination atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    };
    uint32_t next = 0;
    auto start = [&](const char *method, const char *url = "https://files.test/file", bool ambiguous = false,
                     const char *originalURL = nullptr, bool discardPartial = false) {
      CefRefPtr<Item> item = new Item(++next);
      item->url = item->original = url;
      if (originalURL) item->original = originalURL;
      item->path = delegate.destination.UTF8String;
      if (method) assert(handler->CanDownload(fixtureBrowser, url, method));
      if (ambiguous) assert(handler->CanDownload(fixtureBrowser, url, "POST"));
      CefRefPtr<Choice> choice = new Choice();
      handler->OnBeforeDownload(fixtureBrowser, item, "file.bin", choice);
      assert(choice->continued == 1);
      item->appIdentifier = [delegate.started[@"id"] unsignedIntValue];
      CefRefPtr<Callback> callback = new Callback();
      handler->OnDownloadUpdated(fixtureBrowser, item, callback);
      write();
      item->interrupted = true;
      if (discardPartial) item->path.clear();
      handler->OnDownloadUpdated(fixtureBrowser, item, callback);
      return std::make_pair(item, callback);
    };

    NSString *validDestination = delegate.destination;
    auto rejectDestination = [&](NSString *path) {
      delegate.destination = path;
      CefRefPtr<Item> invalid = new Item(++next);
      CefRefPtr<Callback> control = new Callback();
      handler->OnDownloadUpdated(fixtureBrowser, invalid, control);
      CefRefPtr<Choice> choice = new Choice();
      handler->OnBeforeDownload(fixtureBrowser, invalid, "file.bin", choice);
      invalid->appIdentifier = [delegate.started[@"id"] unsignedIntValue];
      assert(choice->continued == 0 && control->cancels == 1);
      assert([delegate.last[@"interrupted"] boolValue] && ![delegate.last[@"retryable"] boolValue]);
      assert([delegate.last[@"reason"] intValue] == CEF_DOWNLOAD_INTERRUPT_REASON_FILE_FAILED);
      assert([delegate.last[@"retryReason"] containsString:@"chosen destination"]);
      NSDictionary *failure = delegate.last;
      invalid->canceled = true;
      handler->OnDownloadUpdated(fixtureBrowser, invalid, control);
      invalid->canceled = false;
      invalid->complete = true;
      handler->OnDownloadUpdated(fixtureBrowser, invalid, control);
      assert(delegate.last == failure);
      handler->OnBeforeDownload(fixtureBrowser, invalid, "file.bin", choice);
      [CCChromiumDownloads retry:invalid->appIdentifier attempt:1];
      assert(choice->continued == 0 && control->resumes == 0);
    };
    assert([@"unchanged" writeToFile:validDestination atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    rejectDestination([validDestination stringByAppendingPathComponent:@"file.bin"]);
    rejectDestination([directory stringByAppendingPathComponent:@"missing/file.bin"]);
    rejectDestination(directory);
    rejectDestination(@"relative.bin");
    NSString *readOnlyFolder = [directory stringByAppendingPathComponent:@"read-only"];
    assert(!mkdir(readOnlyFolder.fileSystemRepresentation, 0500));
    rejectDestination([readOnlyFolder stringByAppendingPathComponent:@"file.bin"]);
    assert(!chmod(readOnlyFolder.fileSystemRepresentation, 0700));
    NSString *linkedDestination = [directory stringByAppendingPathComponent:@"linked.bin"];
    assert(!symlink(validDestination.fileSystemRepresentation, linkedDestination.fileSystemRepresentation));
    rejectDestination(linkedDestination);
    assert([[NSString stringWithContentsOfFile:validDestination encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"unchanged"]);
    delegate.destination = validDestination;

    auto [item, callback] = start("GET");
    assert([delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:item->appIdentifier attempt:1];
    [CCChromiumDownloads retry:item->appIdentifier attempt:1];
    assert(callback->resumes == 1);
    item->interrupted = false;
    handler->OnDownloadUpdated(fixtureBrowser, item, callback);
    assert([delegate.last[@"attempt"] unsignedIntValue] == 1);
    [CCChromiumDownloads pause:item->appIdentifier];
    [CCChromiumDownloads resume:item->appIdentifier];
    assert(callback->pauses == 1 && callback->resumes == 2);
    item->complete = true;
    handler->OnDownloadUpdated(fixtureBrowser, item, callback);
    assert([delegate.last[@"complete"] boolValue]);
    [CCChromiumDownloads retry:item->appIdentifier attempt:2];
    assert(callback->resumes == 2 && ![delegate.last[@"retryable"] boolValue]);

    cef_browser_t secondBrowser{};
    InitBase(secondBrowser.base, sizeof(secondBrowser));
    secondBrowser.get_identifier = [](cef_browser_t *) { return 18; };
    fixtureSecondBrowser = CefBrowserCToCpp_Wrap(&secondBrowser);
    CCChromiumTab *secondTab = [CCChromiumTab new];
    secondTab.profile = @"profile-b";
    secondTab.ephemeral = YES;
    CefRefPtr<cc::Client> secondClient = new cc::Client(secondTab);
    auto secondHandler = cc::MakeDownloadHandler(*secondClient);
    CefRefPtr<Item> collision = new Item(item->identifier);
    collision->path = delegate.destination.UTF8String;
    CefRefPtr<Callback> collisionControl = new Callback();
    assert(secondHandler->CanDownload(fixtureSecondBrowser, collision->url, "GET"));
    secondHandler->OnDownloadUpdated(fixtureSecondBrowser, collision, collisionControl);
    collision->appIdentifier = [delegate.last[@"id"] unsignedIntValue];
    assert(collisionControl->cancels == 0 && collision->appIdentifier != item->appIdentifier);
    CefRefPtr<Choice> collisionChoice = new Choice();
    secondHandler->OnBeforeDownload(fixtureSecondBrowser, collision, "file.bin", collisionChoice);
    assert(collisionChoice->continued == 1);
    assert([delegate.started[@"id"] unsignedIntValue] == collision->appIdentifier);
    write();
    collision->interrupted = true;
    secondHandler->OnDownloadUpdated(fixtureSecondBrowser, collision, collisionControl);
    assert([delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:item->appIdentifier attempt:3];
    [CCChromiumDownloads cancel:item->appIdentifier];
    assert(collisionControl->resumes == 0 && collisionControl->cancels == 0);
    [CCChromiumDownloads retry:collision->appIdentifier attempt:1];
    assert(collisionControl->resumes == 1 && callback->resumes == 2);
    collision->interrupted = false;
    collision->complete = true;
    secondHandler->OnDownloadUpdated(fixtureSecondBrowser, collision, collisionControl);
    assert([delegate.last[@"complete"] boolValue]);
    assert([delegate.last[@"id"] unsignedIntValue] == collision->appIdentifier);

    auto [discardedPartial, discardedControl] = start("GET", "https://files.test/file", false, nullptr, true);
    assert(!unlink(delegate.destination.fileSystemRepresentation));
    [CCChromiumDownloads retry:discardedPartial->appIdentifier attempt:1];
    assert(discardedControl->resumes == 1);

    auto [pendingCleanup, pendingControl] = start("GET", "https://files.test/file", false, nullptr, true);
    [CCChromiumDownloads retry:pendingCleanup->appIdentifier attempt:1];
    assert(pendingControl->resumes == 0);
    assert([[NSString stringWithContentsOfFile:delegate.destination encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"partial"]);

    auto [replacedDiscard, replacedControl] = start("GET", "https://files.test/file", false, nullptr, true);
    assert(!unlink(delegate.destination.fileSystemRepresentation));
    assert([@"replacement" writeToFile:delegate.destination atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    [CCChromiumDownloads retry:replacedDiscard->appIdentifier attempt:1];
    assert(replacedControl->resumes == 0);
    assert([[NSString stringWithContentsOfFile:delegate.destination encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"replacement"]);

    for (const char *method : {"POST", "PUT", ""}) {
      auto [unsafe, control] = start(method);
      assert(![delegate.last[@"retryable"] boolValue]);
      [CCChromiumDownloads retry:unsafe->appIdentifier attempt:1];
      assert(control->resumes == 0);
    }
    for (const char *url : {"blob:https://files.test/expired", "data:text/plain,one-use",
                            "https://files.test/file?token=expired", "https://user:secret@files.test/file"}) {
      auto [unsafe, control] = start("GET", url);
      assert(![delegate.last[@"retryable"] boolValue]);
      [CCChromiumDownloads retry:unsafe->appIdentifier attempt:1];
      assert(control->resumes == 0);
    }
    auto [ambiguous, ambiguousControl] = start("GET", "https://files.test/file", true);
    assert(![delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:ambiguous->appIdentifier attempt:1];
    assert(ambiguousControl->resumes == 0);
    auto [redirected, redirectedControl] = start("GET", "https://files.test/file", false, "https://files.test/post-redirect");
    assert(![delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:redirected->appIdentifier attempt:1];
    assert(redirectedControl->resumes == 0);
    auto [unknown, unknownControl] = start(nullptr);
    assert(![delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:unknown->appIdentifier attempt:1];
    assert(unknownControl->resumes == 0);

    auto [changed, changedControl] = start("GET");
    assert([@"unrelated" writeToFile:delegate.destination atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    [CCChromiumDownloads retry:changed->appIdentifier attempt:1];
    assert(changedControl->resumes == 0);
    assert([delegate.last[@"retryReason"] containsString:@"partial file changed"]);
    assert([[NSString stringWithContentsOfFile:delegate.destination encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"unrelated"]);
    auto [missing, missingControl] = start("GET");
    assert(!unlink(delegate.destination.fileSystemRepresentation));
    [CCChromiumDownloads retry:missing->appIdentifier attempt:1];
    assert(missingControl->resumes == 0);

    auto [readOnly, readOnlyControl] = start("GET");
    assert(!chmod(delegate.destination.fileSystemRepresentation, 0400));
    [CCChromiumDownloads retry:readOnly->appIdentifier attempt:1];
    assert(readOnlyControl->resumes == 0);
    assert(!chmod(delegate.destination.fileSystemRepresentation, 0600));

    NSString *originalDestination = delegate.destination;
    NSString *folder = [directory stringByAppendingPathComponent:@"folder"];
    NSString *moved = [directory stringByAppendingPathComponent:@"moved-folder"];
    assert(!mkdir(folder.fileSystemRepresentation, 0700));
    delegate.destination = [folder stringByAppendingPathComponent:@"partial.bin"];
    auto [movedItem, movedControl] = start("GET");
    assert(!rename(folder.fileSystemRepresentation, moved.fileSystemRepresentation));
    assert(!mkdir(folder.fileSystemRepresentation, 0700));
    [CCChromiumDownloads retry:movedItem->appIdentifier attempt:1];
    assert(movedControl->resumes == 0 && [delegate.last[@"retryReason"] containsString:@"folder changed"]);
    delegate.destination = originalDestination;

    auto [profile, profileControl] = start("GET");
    tab.profile = @"profile-b";
    [CCChromiumDownloads retry:profile->appIdentifier attempt:1];
    assert(profileControl->resumes == 0);
    tab.profile = @"profile-a";

    auto [closed, closedControl] = start("GET");
    cc::InvalidateDownloadRetries(17);
    assert(![delegate.last[@"retryable"] boolValue]);
    [CCChromiumDownloads retry:closed->appIdentifier attempt:1];
    assert(closedControl->resumes == 0);
    auto [closingRetry, closingControl] = start("GET");
    [CCChromiumDownloads retry:closingRetry->appIdentifier attempt:1];
    cc::InvalidateDownloadRetries(17);  // Close before Chromium acknowledges its queued Resume.
    assert(closingControl->resumes == 1 && closingControl->cancels == 1);
    closingRetry->interrupted = false;
    handler->OnDownloadUpdated(fixtureBrowser, closingRetry, closingControl);
    assert(![delegate.last[@"retryable"] boolValue]);
    assert(closingControl->cancels == 2);

    auto [cancelled, cancelledControl] = start("GET");
    [CCChromiumDownloads retry:cancelled->appIdentifier attempt:1];
    [CCChromiumDownloads cancel:cancelled->appIdentifier];
    assert(![delegate.last[@"canceled"] boolValue]);
    [CCChromiumDownloads retry:cancelled->appIdentifier attempt:2];
    assert(cancelledControl->resumes == 1);
    cancelled->interrupted = false;
    handler->OnDownloadUpdated(fixtureBrowser, cancelled, cancelledControl);
    assert(![delegate.last[@"canceled"] boolValue]);
    cancelled->canceled = true;
    handler->OnDownloadUpdated(fixtureBrowser, cancelled, cancelledControl);
    assert([delegate.last[@"canceled"] boolValue]);
    [CCChromiumDownloads retry:cancelled->appIdentifier attempt:2];
    assert(cancelledControl->resumes == 1 && cancelledControl->cancels >= 1);

    delegate.hold = YES;
    CefRefPtr<Item> pending = new Item(++next);
    CefRefPtr<Choice> choice = new Choice();
    handler->OnBeforeDownload(fixtureBrowser, pending, "file.bin", choice);
    cc::InvalidateDownloadRetries(17);
    delegate.decision(delegate.destination);
    assert(choice->continued == 0 && [delegate.last[@"canceled"] boolValue]);
    pending = new Item(++next);
    choice = new Choice();
    handler->OnBeforeDownload(fixtureBrowser, pending, "file.bin", choice);
    cc::stopping = true;
    cc::ReleaseDownloads();
    delegate.decision(delegate.destination);
    assert(choice->continued == 0 && cc::live.empty() && cc::pendingChoices.empty());
    assert(callback->resumes == 2);
    delegate.decision = nil;
    CCChromiumDownloads.delegate = nil;
    fixtureBrowser = nullptr;
    fixtureSecondBrowser = nullptr;
  }
}

// CCRuntime+SiteData.mm — runtime clearing of Space data, deleting a Space's profile directory and
// orphan-profile garbage collection.
//
// CEF has no "clear browsing data" call, so clearing is layered (see docs/UPDATING_CHROMIUM.md):
//   1. CEF APIs: cookie manager, HTTP cache, HTTP-auth cache.
//   2. DevTools `Storage.clearDataForOrigin` for localStorage, IndexedDB, Cache Storage, service workers,
//      File System and WebSQL. DevTools cannot enumerate origins, so every http(s) origin a persistent
//      profile navigated to is recorded in `<profile>/cairn-origins.json` (see TrackOrigin).
//   3. Directory deletion: authoritative for Space removal. A `<hash>.delete` marker is written first and
//      honoured at the next launch (before CefInitialize) if the files are still locked or Cairn quits.
// A profile that predates origin tracking is marked `legacy`; clearing its storage wholesale also
// schedules a one-time deletion of its storage directories for the next launch.
#import "CCInternal.h"
#include <memory>
#include <mutex>
#include <set>
#include "include/cef_cookie.h"
#include "include/cef_parser.h"

using namespace cc;

namespace {
constexpr NSUInteger kMaxOrigins = 5000;
NSString *const kOriginsFile = @"cairn-origins.json";
NSString *const kDeleteMarker = @"delete";
NSString *const kWipeMarker = @"wipe-storage";
// Chromium's per-profile storage directories (relative to the profile directory).
NSArray<NSString *> *StorageDirectories() {
  return @[@"Local Storage", @"IndexedDB", @"Service Worker", @"File System", @"Session Storage",
           @"databases", @"blob_storage", @"WebStorage", @"Storage", @"shared_proto_db"];
}

std::mutex originsMutex;
std::map<std::string, std::set<std::string>> originsByProfile;
std::set<std::string> loadedProfiles, dirtyProfiles, legacyProfiles;
bool saveScheduled = false;

bool IsProfileDirectoryName(NSString *name) {
  if (name.length != 64) return false;
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
  return [name rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

NSString *OriginsPath(NSString *profile) {
  return [[ProfileRoot() stringByAppendingPathComponent:profile] stringByAppendingPathComponent:kOriginsFile];
}

void SaveOrigins() {
  std::map<std::string, std::set<std::string>> snapshot;
  std::set<std::string> legacy;
  {
    std::lock_guard<std::mutex> lock(originsMutex);
    saveScheduled = false;
    for (const auto& name : dirtyProfiles) snapshot[name] = originsByProfile[name];
    dirtyProfiles.clear();
    legacy = legacyProfiles;
  }
  for (const auto& entry : snapshot) {
    NSMutableArray *list = [NSMutableArray array];
    for (const auto& origin : entry.second) [list addObject:@(origin.c_str())];
    NSString *profile = @(entry.first.c_str());
    NSDictionary *document = @{@"origins": list, @"legacy": @(legacy.count(entry.first) > 0)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:0 error:nil];
    NSString *path = OriginsPath(profile);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
  }
}

void ScheduleSave() {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SaveOrigins(); });
}

std::string OriginOf(const CefString& url) {
  CefURLParts parts;
  if (!CefParseURL(url, parts)) return "";
  std::string scheme = CefString(&parts.scheme).ToString(), host = CefString(&parts.host).ToString(),
              port = CefString(&parts.port).ToString();
  if (scheme != "http" && scheme != "https") return "";
  if (host.empty()) return "";
  return scheme + "://" + host + (port.empty() ? "" : ":" + port);
}

std::string HostOf(const std::string& origin) {
  auto start = origin.find("://") + 3, end = origin.find(':', start);
  return origin.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

bool HostMatchesSite(const std::string& host, const std::string& site) {
  return host == site || (host.size() > site.size() && host.compare(host.size() - site.size(), site.size(), site) == 0
                          && host[host.size() - site.size() - 1] == '.');
}

NSString *ProfileDirectory(NSString *profile) { return [ProfileRoot() stringByAppendingPathComponent:profile]; }
NSString *MarkerPath(NSString *profile, NSString *kind) {
  return [ProfileRoot() stringByAppendingPathComponent:[profile stringByAppendingPathExtension:kind]];
}
void WriteMarker(NSString *profile, NSString *kind) {
  [NSFileManager.defaultManager createDirectoryAtPath:ProfileRoot() withIntermediateDirectories:YES attributes:nil error:nil];
  [@"" writeToFile:MarkerPath(profile, kind) atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Tracks one clear: every started step must finish (or time out) before the completion runs once.
struct Job {
  NSMutableArray<NSString *> *failures = [NSMutableArray array];
  int pending = 0;
  bool finished = false;
  void (^completion)(NSArray<NSString *> *);
  void Enter() { pending++; }
  void Fail(NSString *message) { if (![failures containsObject:message]) [failures addObject:message]; }
  void Leave() { if (--pending <= 0) Finish(); }
  void Finish() {
    if (finished) return;
    finished = true;
    completion([failures copy]);
  }
};

class Done final : public CefCompletionCallback {
 public:
  explicit Done(void (^block)(void)) : block_([block copy]) {}
  void OnComplete() override { dispatch_async(dispatch_get_main_queue(), block_); }
 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(Done);
};
class CookiesDone final : public CefDeleteCookiesCallback {
 public:
  explicit CookiesDone(void (^block)(void)) : block_([block copy]) {}
  void OnComplete(int) override { dispatch_async(dispatch_get_main_queue(), block_); }
 private:
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(CookiesDone);
};

// Deletes the matching cookies. CEF releases the visitor after the last cookie (or at once when there
// are none), which is when the step completes.
class CookieSweeper final : public CefCookieVisitor {
 public:
  CookieSweeper(std::string site, void (^block)(void)) : site_(std::move(site)), block_([block copy]) {}
  ~CookieSweeper() override { dispatch_async(dispatch_get_main_queue(), block_); }
  bool Visit(const CefCookie& cookie, int, int, bool& deleteCookie) override {
    std::string domain = CefString(&cookie.domain).ToString();
    while (!domain.empty() && domain.front() == '.') domain.erase(0, 1);
    for (auto& c : domain) c = (char)tolower(c);
    deleteCookie = HostMatchesSite(domain, site_) || HostMatchesSite(site_, domain);
    return true;
  }
 private:
  std::string site_;
  void (^block_)(void);
  IMPLEMENT_REFCOUNTING(CookieSweeper);
};

// Cookie access fails until the context finishes initializing; retry briefly.
void Retry(int attempts, BOOL (^attempt)(void), void (^gaveUp)(void)) {
  if (attempt()) return;
  if (attempts <= 0) { gaveUp(); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    Retry(attempts - 1, attempt, gaveUp);
  });
}

CCChromiumTab *LiveTab(const std::string& key) {
  for (const auto& item : clients) {
    CCChromiumTab *tab = item.second->owner;
    if (item.second->contextKey == key && item.second->browser && tab && !tab.closing) return tab;
  }
  return nil;
}

NSString *const kStorageTypes = @"local_storage,indexeddb,file_systems,websql,service_workers,cache_storage,shared_storage,storage_buckets";
NSString *const kBasicStorageTypes = @"local_storage,indexeddb,file_systems,websql,service_workers,cache_storage";

void ClearOrigins(CCChromiumTab *tab, NSArray<NSString *> *origins, std::shared_ptr<Job> job, void (^finished)(void)) {
  if (!origins.count) { finished(); return; }
  __block NSUInteger remaining = origins.count;
  for (NSString *origin in origins) {
    void (^done)(NSDictionary *, NSError *) = ^(NSDictionary *, NSError *error) {
      if (error) job->Fail([NSString stringWithFormat:@"Site storage could not be cleared for %@: %@", origin, error.localizedDescription]);
      if (--remaining == 0) finished();
    };
    [tab call:@"Storage.clearDataForOrigin" params:@{@"origin": origin, @"storageTypes": kStorageTypes}
        reply:^(NSDictionary *result, NSError *error) {
      if (!error) { done(result, nil); return; }
      // An older protocol may reject a newer storage type; retry with the long-standing ones.
      [tab call:@"Storage.clearDataForOrigin" params:@{@"origin": origin, @"storageTypes": kBasicStorageTypes} reply:done];
    }];
  }
}

void ClearStorage(NSString *profile, const std::string& key, NSArray<NSString *> *origins, std::shared_ptr<Job> job) {
  if (!origins.count) return;
  job->Enter();
  if (CCChromiumTab *live = LiveTab(key)) {
    ClearOrigins(live, origins, job, ^{ job->Leave(); });
    return;
  }
  // No open tab: borrow a hidden one so DevTools can reach the profile's storage.
  CCChromiumTab *hidden = [[CCChromiumTab alloc] initWithProfile:profile ephemeral:NO];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 240) styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:YES];
  window.releasedWhenClosed = NO;
  [window.contentView addSubview:hidden.view];
  __block int attempts = 200;
  __block void (^wait)(void) = ^{
    if ([hidden cefBrowser]) {
      ClearOrigins(hidden, origins, job, ^{
        [hidden close];
        [hidden.view removeFromSuperview];
        [window close];
        job->Leave();
      });
    } else if (--attempts <= 0 || !running || stopping) {
      job->Fail(@"Site storage could not be reached: Chromium did not open a browser for this Space.");
      [hidden close]; [window close]; job->Leave();
    } else {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), wait);
    }
  };
  wait();
}

NSArray<NSString *> *TrackedOrigins(NSString *profile, NSString *site) {
  std::vector<std::string> found;
  {
    std::lock_guard<std::mutex> lock(originsMutex);
    for (const auto& origin : originsByProfile[profile.UTF8String])
      if (!site || HostMatchesSite(HostOf(origin), site.UTF8String)) found.push_back(origin);
  }
  NSMutableOrderedSet *result = [NSMutableOrderedSet orderedSet];
  for (const auto& origin : found) [result addObject:@(origin.c_str())];
  if (site) {
    [result addObject:[@"https://" stringByAppendingString:site]];
    [result addObject:[@"http://" stringByAppendingString:site]];
  }
  return result.array;
}

void RemoveDirectory(NSString *path) { [NSFileManager.defaultManager removeItemAtPath:path error:nil]; }
}  // namespace

namespace cc {

void LoadTrackedOrigins(NSString *profile) {
  std::string name = profile.UTF8String;
  {
    std::lock_guard<std::mutex> lock(originsMutex);
    if (!loadedProfiles.insert(name).second) return;
  }
  NSData *data = [NSData dataWithContentsOfFile:OriginsPath(profile)];
  NSDictionary *document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  BOOL existing = [NSFileManager.defaultManager fileExistsAtPath:ProfileDirectory(profile)];
  std::lock_guard<std::mutex> lock(originsMutex);
  auto& set = originsByProfile[name];
  if ([document isKindOfClass:NSDictionary.class]) {
    for (id origin in document[@"origins"])
      if ([origin isKindOfClass:NSString.class] && set.size() < kMaxOrigins) set.insert([origin UTF8String]);
    if ([document[@"legacy"] boolValue]) legacyProfiles.insert(name);
  } else if (existing) {
    legacyProfiles.insert(name); // Data from before origin tracking: origins are unknown.
  }
  dirtyProfiles.insert(name);
  if (!saveScheduled) { saveScheduled = true; ScheduleSave(); }
}

void TrackOrigin(const std::string& contextKey, const CefString& url) {
  static const std::string prefix = "persistent:";
  if (contextKey.compare(0, prefix.size(), prefix) != 0) return;
  std::string origin = OriginOf(url);
  if (origin.empty()) return;
  std::string profile = contextKey.substr(prefix.size());
  std::lock_guard<std::mutex> lock(originsMutex);
  auto& set = originsByProfile[profile];
  if (set.size() >= kMaxOrigins || !set.insert(origin).second) return;
  dirtyProfiles.insert(profile);
  if (!saveScheduled) {
    saveScheduled = true;
    dispatch_async(dispatch_get_main_queue(), ^{ ScheduleSave(); });
  }
}

void ApplyPendingProfileWork(NSString *root) {
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *entry in [files contentsOfDirectoryAtPath:root error:nil]) {
    NSString *name = entry.stringByDeletingPathExtension, *kind = entry.pathExtension;
    if (!IsProfileDirectoryName(name)) continue;
    NSString *directory = [root stringByAppendingPathComponent:name];
    if ([kind isEqualToString:kDeleteMarker]) RemoveDirectory(directory);
    else if ([kind isEqualToString:kWipeMarker])
      for (NSString *sub in StorageDirectories()) RemoveDirectory([directory stringByAppendingPathComponent:sub]);
    else continue;
    RemoveDirectory([root stringByAppendingPathComponent:entry]);
  }
}

}  // namespace cc

@implementation CCChromiumRuntime (SiteData)

+ (void)clearSiteDataForProfile:(NSString *)profile site:(NSString *)site cookies:(BOOL)cookies cache:(BOOL)cache
                        storage:(BOOL)storage completion:(void (^)(NSArray<NSString *> *))completion {
  NSAssert(NSThread.isMainThread, @"site data is cleared on the main thread");
  site = site.length ? site.lowercaseString : nil;
  std::string key = "persistent:" + std::string(profile.UTF8String);
  bool open = contexts.count(key) > 0;
  if (!running || stopping || (!open && ![NSFileManager.defaultManager fileExistsAtPath:ProfileDirectory(profile)])) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
    return;
  }
  auto context = Context(profile, false);
  auto job = std::make_shared<Job>();
  job->completion = [completion copy];
  job->Enter(); // Held until every step has been started.
  if (cookies) {
    job->Enter();
    void (^leave)(void) = ^{ job->Leave(); };
    void (^gaveUp)(void) = ^{ job->Fail(@"Cookies could not be reached: Chromium's cookie store was not ready."); job->Leave(); };
    if (site) {
      Retry(50, ^BOOL{
        auto manager = context->GetCookieManager(nullptr);
        return manager && manager->VisitAllCookies(new CookieSweeper(site.UTF8String, leave));
      }, gaveUp);
    } else {
      Retry(50, ^BOOL{
        auto manager = context->GetCookieManager(nullptr);
        return manager && manager->DeleteCookies("", "", new CookiesDone(leave));
      }, gaveUp);
      job->Enter();
      context->ClearHttpAuthCredentials(new Done(^{ job->Leave(); }));
    }
  }
  if (cache) {
    job->Enter();
    context->ClearHttpCache(new Done(^{ job->Leave(); }));
  }
  if (storage) {
    ClearStorage(profile, key, TrackedOrigins(profile, site), job);
    BOOL legacy;
    {
      std::lock_guard<std::mutex> lock(originsMutex);
      legacy = !site && legacyProfiles.erase(profile.UTF8String) > 0;
      if (legacy) dirtyProfiles.insert(profile.UTF8String);
    }
    if (legacy) {
      WriteMarker(profile, kWipeMarker);
      SaveOrigins();
      job->Fail(@"Site storage saved before this version of Cairn is removed the next time Cairn starts.");
    }
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!job->finished) { job->Fail(@"Clearing website data timed out."); job->Finish(); }
  });
  job->Leave();
}

+ (void)deleteProfile:(NSString *)profile completion:(void (^)(void))completion {
  NSAssert(NSThread.isMainThread, @"profiles are deleted on the main thread");
  if (!IsProfileDirectoryName(profile)) { dispatch_async(dispatch_get_main_queue(), completion); return; }
  std::string key = "persistent:" + std::string(profile.UTF8String);
  WriteMarker(profile, kDeleteMarker);
  {
    std::lock_guard<std::mutex> lock(originsMutex);
    originsByProfile.erase(profile.UTF8String);
    dirtyProfiles.erase(profile.UTF8String);
    legacyProfiles.erase(profile.UTF8String);
    loadedProfiles.erase(profile.UTF8String);
  }
  auto snapshot = clients;
  for (const auto& item : snapshot) {
    if (item.second->contextKey != key) continue;
    CCChromiumTab *tab = item.second->owner;
    if (tab) [tab close]; else if (item.second->browser) item.second->browser->GetHost()->CloseBrowser(true);
  }
  void (^finish)(void) = ^{
    RemoveDirectory(ProfileDirectory(profile));
    if (![NSFileManager.defaultManager fileExistsAtPath:ProfileDirectory(profile)])
      RemoveDirectory(MarkerPath(profile, kDeleteMarker));
    completion();
  };
  if (!running) { finish(); return; }
  __block int attempts = 50;
  __block void (^poll)(void) = ^{
    BOOL busy = creating[key] > 0 ||
      std::any_of(clients.begin(), clients.end(), [&](const auto& item) { return item.second->contextKey == key; });
    if (busy && --attempts > 0 && running && !stopping) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), poll);
      return;
    }
    contexts.erase(key);
    // Chromium's storage service shuts down asynchronously; give it a moment, else the marker finishes at launch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), finish);
  };
  poll();
}

+ (NSArray<NSString *> *)removeOrphanProfilesKeeping:(NSArray<NSString *> *)directories {
  if (!ProfileRoot()) return @[];
  NSSet *keep = [NSSet setWithArray:directories];
  NSMutableArray *removed = [NSMutableArray array];
  NSFileManager *files = NSFileManager.defaultManager;
  for (NSString *entry in [files contentsOfDirectoryAtPath:ProfileRoot() error:nil]) {
    BOOL isDirectory = NO;
    if (!IsProfileDirectoryName(entry) || [keep containsObject:entry]) continue;
    if (![files fileExistsAtPath:ProfileDirectory(entry) isDirectory:&isDirectory] || !isDirectory) continue;
    if (contexts.count("persistent:" + std::string(entry.UTF8String))) continue;
    RemoveDirectory(ProfileDirectory(entry));
    [removed addObject:entry];
  }
  return removed;
}

@end

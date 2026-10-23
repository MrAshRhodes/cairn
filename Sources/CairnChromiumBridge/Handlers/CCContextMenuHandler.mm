// CCContextMenuHandler.mm — CefContextMenuHandler: the page context menu, shown as a native NSMenu.
//
// CEF still builds the model (navigation, editing, spelling suggestions, print). OnBeforeContextMenu adds
// Cairn's items around it, RunContextMenu renders the result natively and hands the chosen command id back
// to CEF, and OnContextMenuCommand runs Cairn's own commands. Everything that opens a tab or a search goes
// to the tab's delegate, so the app owns where it lands.
#import "../CCInternal.h"
#include <vector>
#include "include/cef_context_menu_handler.h"

@interface CCMenuSession : NSObject
@property(nonatomic) int chosen;
- (void)pick:(NSMenuItem *)item;
@end

@implementation CCMenuSession
- (instancetype)init { if ((self = [super init])) _chosen = -1; return self; }
- (void)pick:(NSMenuItem *)item { self.chosen = (int)item.tag; }
@end

namespace cc {
namespace {

enum Command {
  kOpenLinkTab = MENU_ID_USER_FIRST,
  kOpenLinkBackground,
  kCopyLink,
  kDownloadLink,
  kOpenImageTab,
  kSaveImage,
  kCopyImage,
  kCopyImageAddress,
  kSearchSelection,
  kReloadPage,
  kInspect,
};

constexpr NSUInteger kMaxSelectionLength = 512;
constexpr unsigned long long kMaxImageBytes = 64ull * 1024 * 1024;

NSString *Trimmed(NSString *text) {
  return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSString *Label(const CefString& raw) {
  return [String(raw) stringByReplacingOccurrencesOfString:@"&" withString:@""];
}

void Fill(NSMenu *menu, CefRefPtr<CefMenuModel> model, CCMenuSession *session) {
  menu.autoenablesItems = NO;
  for (size_t i = 0; i < model->GetCount(); i++) {
    auto type = model->GetTypeAt(i);
    if (!model->IsVisibleAt(i)) continue;
    if (type == MENUITEMTYPE_SEPARATOR) {
      if (menu.numberOfItems && !menu.itemArray.lastObject.separatorItem) [menu addItem:NSMenuItem.separatorItem];
      continue;
    }
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:Label(model->GetLabelAt(i)) action:nil keyEquivalent:@""];
    item.enabled = model->IsEnabledAt(i);
    if (type == MENUITEMTYPE_SUBMENU) {
      NSMenu *submenu = [[NSMenu alloc] initWithTitle:item.title];
      Fill(submenu, model->GetSubMenuAt(i), session);
      item.submenu = submenu;
    } else {
      item.tag = model->GetCommandIdAt(i);
      item.target = session;
      item.action = @selector(pick:);
      if (type == MENUITEMTYPE_CHECK || type == MENUITEMTYPE_RADIO)
        item.state = model->IsCheckedAt(i) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:item];
  }
  while (menu.numberOfItems && menu.itemArray.lastObject.separatorItem)
    [menu removeItemAtIndex:menu.numberOfItems - 1];
}

NSString *Shortened(NSString *text) {
  text = Trimmed(text);
  return text.length > 30 ? [[text substringToIndex:30] stringByAppendingString:@"…"] : text;
}

void CopyText(NSString *text) {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

void CopyImage(NSString *address) {
  NSURL *url = [NSURL URLWithString:address];
  NSString *scheme = url.scheme.lowercaseString;
  auto write = ^(NSData *data) {
    NSImage *image = data.length ? [[NSImage alloc] initWithData:data] : nil;
    if (!image) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[image]];
  };
  if ([scheme isEqualToString:@"data"]) {
    NSRange comma = [address rangeOfString:@","];
    if (comma.location == NSNotFound) return;
    NSString *payload = [address substringFromIndex:NSMaxRange(comma)];
    bool base64 = [[address substringToIndex:comma.location] hasSuffix:@";base64"];
    write(base64 ? [[NSData alloc] initWithBase64EncodedString:payload options:NSDataBase64DecodingIgnoreUnknownCharacters]
                 : [payload.stringByRemovingPercentEncoding dataUsingEncoding:NSUTF8StringEncoding]);
    return;
  }
  if (![@[@"http", @"https"] containsObject:scheme]) return;
  // The page's own session is not reachable from here, so this is a cookie-less, cache-less fetch.
  NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    if (!error && response.expectedContentLength <= (long long)kMaxImageBytes && data.length <= kMaxImageBytes)
      dispatch_async(dispatch_get_main_queue(), ^{ write(data); });
    [session finishTasksAndInvalidate];
  }] resume];
}

class ContextMenuHandler final : public TabHandler, public CefContextMenuHandler {
 public:
  explicit ContextMenuHandler(Client& client) : TabHandler(client) {}

  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    std::vector<std::pair<int, std::string>> leading;
    auto flags = params->GetTypeFlags();
    bool link = (flags & CM_TYPEFLAG_LINK) && !params->GetLinkUrl().empty();
    bool image = params->HasImageContents() && !params->GetSourceUrl().empty();
    NSString *selection = (flags & CM_TYPEFLAG_SELECTION) ? Trimmed(String(params->GetSelectionText())) : @"";
    if (link) {
      leading.push_back({kOpenLinkTab, "Open Link in New Tab"});
      leading.push_back({kOpenLinkBackground, "Open Link in Background Tab"});
      leading.push_back({kCopyLink, "Copy Link Address"});
      leading.push_back({kDownloadLink, "Download Linked File"});
    }
    if (image) {
      if (link) leading.push_back({-1, ""});
      leading.push_back({kOpenImageTab, "Open Image in New Tab"});
      leading.push_back({kSaveImage, "Save Image As…"});
      leading.push_back({kCopyImage, "Copy Image"});
      leading.push_back({kCopyImageAddress, "Copy Image Address"});
    }
    if (selection.length) {
      if (link || image) leading.push_back({-1, ""});
      leading.push_back({kSearchSelection, std::string("Search for “") + Shortened(selection).UTF8String + "”"});
    }
    size_t index = 0;
    for (auto& entry : leading) {
      if (entry.first < 0) model->InsertSeparatorAt(index++);
      else model->InsertItemAt(index++, entry.first, entry.second);
    }
    if (index) model->InsertSeparatorAt(index);
    if (model->GetIndexOf(MENU_ID_RELOAD) < 0) model->AddItem(kReloadPage, "Reload");
    model->AddSeparator();
    model->AddItem(kInspect, "Inspect");
  }

  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
    auto tab = owner;
    if (!tab || tab.closing) { callback->Cancel(); return true; }
    NSPoint point = NSMakePoint(params->GetXCoord(), tab.view.bounds.size.height - params->GetYCoord());
    __weak CCChromiumTab *weakTab = tab;
    dispatch_async(dispatch_get_main_queue(), ^{
      CCChromiumTab *live = weakTab;
      if (!live || live.closing || !live.view.window) { callback->Cancel(); return; }
      CCMenuSession *session = [CCMenuSession new];
      NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
      Fill(menu, model, session);
      if (!menu.numberOfItems) { callback->Cancel(); return; }
      [menu popUpMenuPositioningItem:nil atLocation:point inView:live.view];
      if (session.chosen >= 0 && !live.closing) callback->Continue(session.chosen, EVENTFLAG_NONE);
      else callback->Cancel();
    });
    return true;
  }

  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params,
                            int command, EventFlags) override {
    auto tab = owner;
    if (!tab) return false;
    NSString *link = String(params->GetLinkUrl());
    NSString *source = String(params->GetSourceUrl());
    switch (command) {
      case kOpenLinkTab: [tab.delegate chromiumTab:tab popup:link activate:YES]; return true;
      case kOpenLinkBackground: [tab.delegate chromiumTab:tab popup:link activate:NO]; return true;
      case kCopyLink: CopyText(link); return true;
      // Save through this browser's authenticated CEF context and the native download controller,
      // never the separate URL-only downloader used for manually pasted addresses.
      case kDownloadLink: browser->GetHost()->StartDownload(params->GetLinkUrl()); return true;
      case kOpenImageTab: [tab.delegate chromiumTab:tab popup:source activate:YES]; return true;
      case kSaveImage: browser->GetHost()->StartDownload(params->GetSourceUrl()); return true;
      case kCopyImage: CopyImage(source); return true;
      case kCopyImageAddress: CopyText(source); return true;
      case kReloadPage: browser->Reload(); return true;
      case kSearchSelection: {
        NSString *query = Trimmed(String(params->GetSelectionText()));
        if (query.length > kMaxSelectionLength) query = [query substringToIndex:kMaxSelectionLength];
        if (query.length && [tab.delegate conformsToProtocol:@protocol(CCChromiumTabContextMenuDelegate)])
          [(id<CCChromiumTabContextMenuDelegate>)tab.delegate chromiumTab:tab searchFor:query activate:YES];
        return true;
      }
      case kInspect: {
        CefWindowInfo window;
        CefBrowserSettings settings;
        browser->GetHost()->ShowDevTools(window, nullptr, settings,
                                         CefPoint(params->GetXCoord(), params->GetYCoord()));
        return true;
      }
      default: return false;
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(ContextMenuHandler);
};
}  // namespace

CefRefPtr<CefContextMenuHandler> MakeContextMenuHandler(Client& client) { return new ContextMenuHandler(client); }

}  // namespace cc

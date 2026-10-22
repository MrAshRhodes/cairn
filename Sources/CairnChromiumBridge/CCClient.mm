// CCClient.mm — the registration list. Client's constructor creates one handler object per CEF
// handler family and CCInternal.h exposes them through the matching CefClient getters.
//
// Every family has a fixed line here and a file under Handlers/ that defines its factory, so
// implementing a family never edits this list. Skeleton families return nullptr until a feature
// fills them in, which is exactly CEF's default behavior. A family that CefClient has a getter
// for, but this list lacks, needs its member and getter in CCInternal.h and one line here.
//
// ResourceRequest is the one family without a line: CEF reaches it through CefRequestHandler, so
// MakeRequestHandler (CCRequestHandler.mm) creates it.
#import "CCInternal.h"

namespace cc {

Client::Client(CCChromiumTab *tab) : owner(tab), container(tab.view),
    contextKey(std::string(tab.ephemeral ? "private:" : "persistent:") + tab.profile.UTF8String),
    ephemeral(tab.ephemeral) {
  lifeSpan_ = MakeLifeSpanHandler(*this);
  load_ = MakeLoadHandler(*this);
  display_ = MakeDisplayHandler(*this);
  find_ = MakeFindHandler(*this);
  download_ = MakeDownloadHandler(*this);
  request_ = MakeRequestHandler(*this);
  devTools_ = MakeDevToolsObserver(*this);

  jsDialog_ = MakeJSDialogHandler(*this);
  permission_ = MakePermissionHandler(*this);
  contextMenu_ = MakeContextMenuHandler(*this);
  keyboard_ = MakeKeyboardHandler(*this);
  focus_ = MakeFocusHandler(*this);
  audio_ = MakeAudioHandler(*this);
  drag_ = MakeDragHandler(*this);
  dialog_ = MakeDialogHandler(*this);
}

}  // namespace cc

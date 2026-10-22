// CCTab+Print.mm — printing and print-to-PDF as tab commands.
//
// CefPrintHandler is Linux-only, so on macOS printing is driven through CefBrowserHost: Print() shows the
// system NSPrintPanel (Alloy has no Chrome print preview, and "Save as PDF" is the panel's own PDF menu);
// PrintToPDF renders a file without any UI.
#import "CCInternal.h"

namespace {
class PDFDone final : public CefPdfPrintCallback {
 public:
  explicit PDFDone(void (^block)(NSError *)) : block_([block copy]) {}
  void OnPdfPrintFinished(const CefString& path, bool ok) override {
    auto callback = block_;
    NSString *target = cc::String(path);
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(ok ? nil : cc::Failure([NSString stringWithFormat:@"Chromium could not write the PDF to %@", target]));
    });
  }
 private:
  void (^block_)(NSError *);
  IMPLEMENT_REFCOUNTING(PDFDone);
};
}

@implementation CCChromiumTab (Print)
- (void)printPage {
  auto browser = self.cefBrowser;
  if (browser && !self.closing) browser->GetHost()->Print();
}
- (void)printToPDFAtPath:(NSString *)path completion:(void (^)(NSError *))completion {
  auto browser = self.cefBrowser;
  if (!browser || self.closing) { completion(cc::Failure(@"The page is not ready to print")); return; }
  CefPdfPrintSettings settings;
  settings.print_background = true;
  settings.generate_tagged_pdf = true;
  settings.prefer_css_page_size = true;
  settings.paper_width = 8.5;
  settings.paper_height = 11;
  browser->GetHost()->PrintToPDF(path.UTF8String, settings, new PDFDone(completion));
}
@end

// CCTab+Testing.mm — fault injection for the bundled smoke test only (see engine/smoke/main.swift).
#import "CCInternal.h"
#include "include/cef_task_manager.h"

@implementation CCChromiumTab (Testing)
- (BOOL)crashRendererForTesting {
  auto browser = self.cefBrowser;
  auto manager = CefTaskManager::GetTaskManager();
  if (!browser || !manager || self.closing) return NO;
  auto task = manager->GetTaskIdForBrowserId(browser->GetIdentifier());
  CefTaskInfo info;
  // Page.crash runs in the renderer and cannot interrupt a pending beforeunload dialog.
  if (task < 0 || !manager->GetTaskInfo(task, info) ||
      info.type != CEF_TASK_TYPE_RENDERER || !info.is_killable) return NO;
  return manager->KillTask(task);
}
@end

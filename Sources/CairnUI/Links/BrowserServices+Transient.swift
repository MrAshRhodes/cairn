import AppKit
import CairnCore
import CairnEngineKit

extension BrowserServices {
    var activeQuickWindowID: UUID? {
        quickWindows.first { $0.value.window === NSApp.keyWindow }?.key
    }

    var activeTransientID: UUID? { activeQuickWindowID ?? model.peek.tabID }

    func newQuickWindow() {
        model.resumeWorkspace()
        _ = model.openQuickPage(in: model.selectedSpace.id)
    }

    func showQuickWindow(_ id: UUID, activate: Bool) {
        if let presentQuickWindow { presentQuickWindow(id, activate); return }
        let controller = QuickWindowController(services: self, tabID: id)
        quickWindows[id] = controller
        controller.show(activate: activate)
    }

    /// Do not run main-workspace actions against an unrelated tab while a transient page has focus.
    func performTransientAction(_ action: String) -> Bool {
        guard let id = activeTransientID, let tab = model.liveTabs[id] else { return false }
        switch action {
        case "ui.close-tab", "ui.close-window": model.dismissTransient(id)
        case "ui.address", "ui.command-bar":
            quickWindows[id]?.focusAddress()
        case "ui.reload": tab.reload(ignoringCache: false)
        case "ui.hard-reload": tab.reload(ignoringCache: true)
        case "ui.stop": tab.stopLoading()
        case "ui.back": tab.goBack()
        case "ui.forward": tab.goForward()
        case "ui.zoom-in": tab.zoom = min(tab.zoom + 0.1, 5)
        case "ui.zoom-out": tab.zoom = max(tab.zoom - 0.1, 0.25)
        case "ui.zoom-reset": tab.zoom = 1
        case "ui.copy-url":
            if let url = tab.state.url { copyToPasteboard(url.absoluteString) }
        case "ui.quick-window": return false
        default:
            // Other actions belong to the main browser; show it deliberately rather than
            // letting e.g. Pin Tab silently mutate a page behind this window.
            if activeQuickWindowID != nil { return true }
            return false
        }
        return true
    }
}

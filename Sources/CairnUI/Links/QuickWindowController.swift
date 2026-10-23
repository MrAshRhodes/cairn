import AppKit
import SwiftUI
import CairnCore

@MainActor
final class QuickWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private weak var services: BrowserServices?
    private let tabID: UUID
    private var approvedClose = false
    private var keyMonitor: Any?
    private let focus = TransientFocus()

    init(services: BrowserServices, tabID: UUID) {
        self.services = services
        self.tabID = tabID
        // Only app-chosen, screen-constrained geometry. Never honor window.open feature strings.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(820, visible.width),
                                              height: min(640, max(400, visible.height - 40))),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Quick Window — Cairn"
        window.minSize = NSSize(width: min(520, visible.width), height: min(360, visible.height))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TransientPageView(services: services, tabID: tabID, focus: focus))
        window.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53,
                  self.services?.model.prompts.front(self.tabID) == nil else { return event }
            self.services?.model.dismissTransient(self.tabID)
            return nil
        }
    }

    func show(activate: Bool) {
        if activate { window.makeKeyAndOrderFront(nil) }
        else { window.orderFront(nil) }
    }

    func focusAddress() { focus.addressRequest += 1 }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        services?.model.dismissTransient(tabID)
        return false
    }

    func finishClose() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        approvedClose = true
        window.close()
        window.contentView = nil
    }
}

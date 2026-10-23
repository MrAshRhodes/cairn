import AppKit
import SwiftUI
import CairnCore

@MainActor
public enum CairnApp {
    private static var delegate: CairnApplicationDelegate?

    public static func run(prepareForTermination: TerminationPreparation? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = CairnApplicationDelegate(prepareForTermination: prepareForTermination)
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class CairnApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var services: BrowserServices?
    private var window: NSWindow?
    private var pendingURLs: [URL] = []
    private let termination: ApplicationTerminationCoordinator
    private var windowClosePending = false
    private var allowWindowClose = false
    private var forcePageClose = false

    init(prepareForTermination: CairnApp.TerminationPreparation? = nil) {
        termination = ApplicationTerminationCoordinator(prepare: prepareForTermination)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let services = try BrowserServices.bootstrap()
            self.services = services
            services.onShortcutsChanged = { [weak self] in self?.buildMenus() }
            buildMenus()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Cairn"
            window.identifier = NSUserInterfaceItemIdentifier("CairnMainWindow")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 780, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("CairnMainWindow")
            window.contentView = NSHostingView(rootView: BrowserView(services: services))
            if !window.setFrameUsingName("CairnMainWindow") { window.center() }
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pendingURLs.forEach { services.openExternalLink($0) }
            pendingURLs = []
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cairn could not start"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let services {
            services.model.resumeWorkspace()
            urls.forEach { services.openExternalLink($0) }
            if services.activeQuickWindowID == nil { showWindow() }
        } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A window-close decision must not race a quit into tearing down a vetoed workspace.
        guard !windowClosePending else { return .terminateCancel }
        window?.makeKeyAndOrderFront(nil)
        let force = forcePageClose
        return termination.request(approval: { self.approveUnsavedBoosts() }, pageApproval: { decide in
            guard let services = self.services else { decide(true); return }
            services.requestPageCloseApproval(force: force, completion: decide)
        }, commitApproval: {
            self.approvePersistence()
        }, failed: {
            self.services?.report("Cairn could not finish quitting",
                                  detail: "Chromium did not finish approved teardown. The quit was not reported as successful.")
        }) { [weak self, weak sender] approved in
            self?.forcePageClose = false
            if !approved { self?.services?.model.resumeWorkspace() }
            sender?.reply(toApplicationShouldTerminate: approved)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowWindowClose { return true }
        guard !windowClosePending, !termination.isInProgress, services?.model.isClosingWorkspace != true else { return false }
        guard approveUnsavedBoosts() else { return false }
        windowClosePending = true
        services?.requestPageCloseApproval { [weak self, weak sender] approved in
            guard let self else { return }
            self.windowClosePending = false
            guard approved, self.approvePersistence() else {
                self.services?.model.resumeWorkspace()
                return
            }
            self.allowWindowClose = true
            sender?.close()
            self.allowWindowClose = false
        }
        if services == nil { windowClosePending = false; return true }
        return false
    }

    private func approveUnsavedBoosts() -> Bool {
        if services?.hasUnsavedBoostChanges == true {
            let alert = NSAlert()
            alert.messageText = "A Boost has unsaved changes"
            alert.informativeText = "Keep Cairn open to save your changes, or discard them and close."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard & Close")
            if alert.runModal() == .alertFirstButtonReturn { return false }
            services?.hasUnsavedBoostChanges = false
        }
        return true
    }

    private func approvePersistence() -> Bool {
        do { try services?.flush() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Your latest changes could not be saved"
            alert.informativeText = "\(error.localizedDescription)\nYou can keep Cairn open and try again."
            alert.addButton(withTitle: "Keep Cairn Open")
            alert.addButton(withTitle: "Quit Without Saving")
            if alert.runModal() == .alertFirstButtonReturn { return false }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { services?.shutdown() }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let result = NSMenu(title: title)
            item.submenu = result
            main.addItem(item)
            return result
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target ?? self
            menu.addItem(item)
        }
        let app = menu("Cairn")
        item(app, "About Cairn", #selector(about))
        item(app, "Check for Updates…", #selector(checkUpdates))
        app.addItem(.separator())
        if let settings = shortcutMap.action("ui.settings") {
            app.addItem(MenuBuilder.item(settings, map: shortcutMap, target: self, action: #selector(performShortcutAction(_:))))
        }
        app.addItem(.separator())
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let serviceMenu = NSMenu(title: "Services")
        serviceItem.submenu = serviceMenu; app.addItem(serviceItem); NSApp.servicesMenu = serviceMenu
        app.addItem(.separator())
        item(app, "Hide Cairn", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Quit Cairn", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        item(app, "Force Close Pages and Quit…", #selector(forceQuitPages))
        func adopt(_ kind: ShortcutMenu, into main: NSMenu, before: NSMenu? = nil) -> NSMenu {
            let built = MenuBuilder.menu(kind, map: shortcutMap, target: self, action: #selector(performShortcutAction(_:)))
            let holder = NSMenuItem(title: kind.rawValue, action: nil, keyEquivalent: "")
            holder.submenu = built
            main.addItem(holder)
            return built
        }
        _ = adopt(.file, into: main)
        let edit = adopt(.edit, into: main)
        let system: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command), ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command), ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command), ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (offset, entry) in system.enumerated() {
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: entry.2)
            item.keyEquivalentModifierMask = entry.3
            item.target = nil
            edit.insertItem(item, at: offset)
        }
        edit.insertItem(.separator(), at: system.count)
        for kind in [ShortcutMenu.view, .history, .tabs, .spaces, .split, .tools] { _ = adopt(kind, into: main) }
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: self.window)
        window.items.last?.target = nil
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.items.last?.target = nil
        item(window, "Show Browser", #selector(showWindow))
        item(window, "Force Close Tab…", #selector(forceCloseCurrentTab))
        NSApp.windowsMenu = window
        let help = menu("Help")
        item(help, "Cairn Keyboard Shortcuts", #selector(showShortcuts))
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private var shortcutMap: ShortcutMap { services?.shortcuts ?? ShortcutMap() }

    @objc private func performShortcutAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let services else { return }
        if services.activeQuickWindowID != nil { services.perform(action: id); return }
        if id == "ui.close-window" { window?.performClose(nil); return }
        if id != "ui.close-tab" && id != "ui.quick-window" { showWindow() }
        services.perform(action: id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let services else { return false }
        if let id = menuItem.representedObject as? String {
            if window?.attachedSheet != nil || services.model.closingTabID != nil { return false }
            return id == "ui.close-window" || services.isEnabled(action: id)
        }
        return true
    }

    @objc private func checkUpdates() { showWindow(); services?.checkForUpdates() }
    @objc private func showWindow() {
        services?.model.resumeWorkspace()
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func forceCloseCurrentTab() {
        guard let model = services?.model, let id = model.closingTabID ?? services?.activeTransientID ?? model.selectedTabID,
              !model.isClosingWorkspace else { return }
        guard confirmForcedClose(quitting: false) else { return }
        model.forceCloseTab(id)
    }
    @objc private func forceQuitPages() {
        guard confirmForcedClose(quitting: true) else { return }
        forcePageClose = true
        if services?.model.isClosingWorkspace == true {
            services?.model.requestCloseAll(force: true) { _ in }
        } else {
            NSApp.terminate(nil)
            // A synchronous Boost/persistence veto must not authorize a future ordinary quit.
            if services?.model.isClosingWorkspace != true { forcePageClose = false }
        }
    }
    private func confirmForcedClose(quitting: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = quitting ? "Force close all pages and quit?" : "Force close this page?"
        alert.informativeText = "Unsaved changes on these pages will be lost. Use this only when a page will not let you close normally."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: quitting ? "Force Close Pages and Quit" : "Force Close Tab")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cairn",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: NSAttributedString(string: "A quieter place for the web.\nIndependent, local-first browsing.\n\n\(services?.model.engine.versionDescription ?? "")"),
        ])
    }
    @objc private func showShortcuts() { showWindow(); services?.sheet = .shortcuts }
}

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

    init(prepareForTermination: CairnApp.TerminationPreparation? = nil) {
        termination = ApplicationTerminationCoordinator(prepare: prepareForTermination)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let services = try BrowserServices.bootstrap()
            self.services = services
            buildMenus()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Cairn"
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
            urls.forEach { services.openExternalLink($0) }
            window?.makeKeyAndOrderFront(nil)
        } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(approval: { self.approveTermination() }) { [weak sender] approved in
            sender?.reply(toApplicationShouldTerminate: approved)
        }
    }

    private func approveTermination() -> Bool {
        if services?.hasUnsavedBoostChanges == true {
            let alert = NSAlert()
            alert.messageText = "A Boost has unsaved changes"
            alert.informativeText = "Keep Cairn open to save your changes, or discard them and quit."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard & Quit")
            if alert.runModal() == .alertFirstButtonReturn { return false }
        }
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
        item(app, "Settings…", #selector(preferences), ",")
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
        let file = menu("File")
        item(file, "New Tab", #selector(newTab), "t")
        item(file, "Open Location…", #selector(address), "l")
        item(file, "Command Bar…", #selector(commandBar), "k")
        file.addItem(.separator())
        item(file, "Close Tab", #selector(closeTab), "w")
        item(file, "Close Window", #selector(closeWindow), "w", [.command, .shift])
        let edit = menu("Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = nil; edit.addItem(entry)
        }
        edit.addItem(.separator())
        item(edit, "Find in Page…", #selector(find), "f")
        item(edit, "Find Next", #selector(findNext), "g")
        item(edit, "Find Previous", #selector(findPrevious), "g", [.command, .shift])
        let view = menu("View")
        item(view, "Toggle Sidebar", #selector(sidebar), "s", [.command, .shift])
        item(view, "Toggle Split View", #selector(split), "d", [.command, .shift])
        view.addItem(.separator())
        item(view, "Reload Page", #selector(reload), "r")
        item(view, "Reload Without Cache", #selector(hardReload), "r", [.command, .shift])
        item(view, "Stop Loading", #selector(stop), ".")
        view.addItem(.separator())
        item(view, "Zoom In", #selector(zoomIn), "+")
        item(view, "Zoom Out", #selector(zoomOut), "-")
        item(view, "Actual Size", #selector(actualSize), "0")
        let history = menu("History")
        item(history, "Back", #selector(back), "[")
        item(history, "Forward", #selector(forward), "]")
        history.addItem(.separator())
        item(history, "Show History", #selector(showHistory), "y")
        item(history, "Archived Tabs", #selector(archive))
        let tools = menu("Tools")
        item(tools, "Downloads", #selector(downloads), "j")
        item(tools, "Boosts", #selector(boosts))
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: self.window)
        window.items.last?.target = nil
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.items.last?.target = nil
        item(window, "Show Browser", #selector(showWindow))
        NSApp.windowsMenu = window
        let help = menu("Help")
        item(help, "Cairn Keyboard Shortcuts", #selector(shortcuts))
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let services else { return false }
        if window?.attachedSheet != nil {
            let browserActions: [Selector] = [
                #selector(newTab), #selector(address), #selector(commandBar), #selector(closeTab),
                #selector(closeWindow), #selector(preferences), #selector(split), #selector(find),
                #selector(back), #selector(forward), #selector(reload), #selector(hardReload),
                #selector(downloads), #selector(boosts), #selector(archive), #selector(showHistory),
            ]
            if let action = menuItem.action, browserActions.contains(action) { return false }
        }
        switch menuItem.action {
        case #selector(back): return services.activeEngineTab?.state.canGoBack == true
        case #selector(forward): return services.activeEngineTab?.state.canGoForward == true
        case #selector(closeTab), #selector(reload), #selector(find): return services.model.selectedTabID != nil
        default: return true
        }
    }

    @objc private func newTab() { showWindow(); services?.newTab() }
    @objc private func closeTab() { services?.closeTab() }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func address() { showWindow(); services?.focusAddress() }
    @objc private func commandBar() { showWindow(); services?.commandBarPresented = true }
    @objc private func preferences() { showWindow(); services?.sheet = .preferences }
    @objc private func sidebar() { services?.sidebarVisible.toggle() }
    @objc private func split() { services?.toggleSplit() }
    @objc private func reload() { services?.activeEngineTab?.reload(ignoringCache: false) }
    @objc private func hardReload() { services?.activeEngineTab?.reload(ignoringCache: true) }
    @objc private func stop() { services?.activeEngineTab?.stopLoading() }
    @objc private func back() { services?.activeEngineTab?.goBack() }
    @objc private func forward() { services?.activeEngineTab?.goForward() }
    @objc private func find() { services?.findPresented = true }
    @objc private func findNext() { services?.find() }
    @objc private func findPrevious() { services?.find(forward: false) }
    @objc private func zoomIn() { if let services { services.setZoom((services.activeEngineTab?.zoom ?? 1) + 0.1) } }
    @objc private func zoomOut() { if let services { services.setZoom((services.activeEngineTab?.zoom ?? 1) - 0.1) } }
    @objc private func actualSize() { services?.setZoom(1) }
    @objc private func downloads() { showWindow(); services?.sheet = .downloads }
    @objc private func boosts() { showWindow(); services?.sheet = .boosts }
    @objc private func archive() { showWindow(); services?.sheet = .archive }
    @objc private func showHistory() { showWindow(); services?.sheet = .history }
    @objc private func checkUpdates() { showWindow(); services?.checkForUpdates() }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cairn",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: NSAttributedString(string: "A quieter place for the web.\nIndependent, local-first browsing.\n\n\(services?.model.engine.versionDescription ?? "")"),
        ])
    }
    @objc private func shortcuts() {
        let alert = NSAlert()
        alert.messageText = "Make yourself at home"
        alert.informativeText = "⌘T  New tab\n⌘L  Edit current address\n⌘K  Search tabs and commands\n⌘W  Close tab\n⇧⌘D  Split view\n⇧⌘S  Sidebar\n⌘F  Find in page\n⌘J  Downloads\n⌘,  Settings\n\nDrag tabs to reorder them or move them between Spaces. Right-click tabs for pins, favorites, archive, and split actions."
        alert.runModal()
    }
}

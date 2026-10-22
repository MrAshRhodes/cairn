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
            services.onShortcutsChanged = { [weak self] in self?.buildMenus() }
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
            pendingURLs.forEach { services.model.newTab(url: $0) }
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
            urls.forEach { services.model.newTab(url: $0) }
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
        NSApp.windowsMenu = window
        let help = menu("Help")
        item(help, "Cairn Keyboard Shortcuts", #selector(showShortcuts))
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private var shortcutMap: ShortcutMap { services?.shortcuts ?? ShortcutMap() }

    @objc private func performShortcutAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let services else { return }
        if id == "ui.close-window" { window?.performClose(nil); return }
        if id != "ui.close-tab" { showWindow() }
        services.perform(action: id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let services else { return false }
        if let id = menuItem.representedObject as? String {
            if window?.attachedSheet != nil { return false }
            return id == "ui.close-window" || services.isEnabled(action: id)
        }
        return true
    }

    @objc private func checkUpdates() { showWindow(); services?.checkForUpdates() }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cairn",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: NSAttributedString(string: "A quieter place for the web.\nIndependent, local-first browsing.\n\n\(services?.model.engine.versionDescription ?? "")"),
        ])
    }
    @objc private func showShortcuts() { showWindow(); services?.sheet = .shortcuts }
}

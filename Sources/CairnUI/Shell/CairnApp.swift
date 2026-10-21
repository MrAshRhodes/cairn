import AppKit
import CairnCore

// STUB — replaced by the UI-SHELL agent (window controller, content host, split view, menus, app delegate wiring).
@MainActor
public enum CairnApp {
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        print("Cairn stub: UI shell not implemented yet")
    }
}

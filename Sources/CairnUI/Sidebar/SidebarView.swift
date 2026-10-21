import SwiftUI
import CairnCore
import CairnModules

// STUB — replaced by the UI-SIDEBAR agent. The init signature is FROZEN: the shell constructs this view.
public struct SidebarView: View {
    let model: BrowserModel
    let showCommandBar: () -> Void
    public init(model: BrowserModel, showCommandBar: @escaping () -> Void) {
        self.model = model
        self.showCommandBar = showCommandBar
    }
    public var body: some View { Text("Sidebar") }
}

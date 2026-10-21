import SwiftUI
import CairnCore
import CairnModules

// STUB — replaced by the UI-COMMANDBAR agent. The init signature is FROZEN: the shell constructs this view.
// `commands` is evaluated each time the bar opens (modules may contribute dynamic commands).
public struct CommandBarView: View {
    let model: BrowserModel
    let commands: () -> [Command]
    let dismiss: () -> Void
    public init(model: BrowserModel, commands: @escaping () -> [Command], dismiss: @escaping () -> Void) {
        self.model = model
        self.commands = commands
        self.dismiss = dismiss
    }
    public var body: some View { Text("Command bar") }
}

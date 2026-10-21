import SwiftUI
import CairnCore
import CairnUpdater

// STUB — replaced by the UI-PREFS agent. The init signature is FROZEN: the shell constructs this view.
public struct PreferencesView: View {
    let model: BrowserModel
    public init(model: BrowserModel) { self.model = model }
    public var body: some View { Text("Preferences") }
}

import SwiftUI
import CairnCore
import CairnEngineKit

/// Visible recovery affordance for a tab whose page process crashed, hung or never started loading.
struct TabHealthBanner: View {
    let model: BrowserModel
    let tabID: UUID

    var body: some View {
        if let health = model.tabHealth[tabID], let copy = Self.copy(for: health) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(copy.message).font(.callout).textSelection(.enabled)
                Spacer()
                Button(copy.action) { model.recoverTab(tabID) }
                if copy.dismissible { Button("Dismiss") { model.dismissHealthNotice(tabID) } }
            }
            .padding(12)
            .background(Color.red.opacity(0.12))
            .accessibilityElement(children: .contain)
        }
    }

    struct Copy: Equatable { var message: String; var action: String; var dismissible: Bool }

    static func copy(for health: EngineTabHealth) -> Copy? {
        switch health {
        case .healthy: nil
        case .crashed(let reason, _): Copy(message: "This page \(reason).", action: "Reload", dismissible: false)
        case .unresponsive: Copy(message: "This page is not responding. Cairn will stop it if it does not recover.",
                                 action: "Reload", dismissible: false)
        case .navigationStalled(let hint): Copy(message: hint, action: "Retry", dismissible: true)
        case .automationUnavailable:
            Copy(message: "Page tools such as Boosts could not start on this page.", action: "Reload", dismissible: true)
        }
    }
}

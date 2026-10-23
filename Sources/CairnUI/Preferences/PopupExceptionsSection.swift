import SwiftUI
import CairnCore

@MainActor
struct PopupExceptionsSection: View {
    let model: BrowserModel

    var body: some View {
        Section("Popup exceptions") {
            Text("Allow popups from a blocked-popup banner. Each exception applies only to the exact scheme, host and port in that Space. Embedded frames are not included. The 3-popups-per-10-seconds limit and safe-address checks always apply.")
                .font(.callout)
            if model.popupExceptions.entries.isEmpty {
                Text("No sites can open popups without a click.").foregroundStyle(.secondary)
            }
            ForEach(model.workspace.spaces) { space in
                ForEach(model.popupExceptions.entries(spaceID: space.id, profileID: space.profileID)) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle").frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.origin).font(.callout).textSelection(.enabled)
                            Text(space.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { model.popupExceptions.revoke(entry.id) }
                            .accessibilityLabel("Revoke popups for \(entry.origin) in \(space.name)")
                    }
                }
            }
            if let error = model.popupExceptions.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}

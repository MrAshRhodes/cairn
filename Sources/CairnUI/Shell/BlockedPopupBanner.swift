import SwiftUI
import CairnCore
import CairnEngineKit

@MainActor
struct BlockedPopupBanner: View {
    let model: BrowserModel
    let tabID: UUID
    @ViewState<Bool> private var confirmAllow = false
    @ViewState<PopupGrantRequest?> private var request = nil

    var body: some View {
        if let count = model.blockedPopups[tabID], count > 0 {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.slash")
                VStack(alignment: .leading, spacing: 3) {
                    Text(count == 1 ? "A popup was blocked" : "\(count) popups were blocked").font(.callout).monospacedDigit()
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                    if let error = model.popupExceptions.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if model.blockedPopupOrigin(for: tabID) != nil {
                    Button("Allow for This Site…") {
                        request = model.popupGrantRequest(for: tabID)
                        confirmAllow = request != nil
                    }
                        .disabled(!model.popupExceptions.isWritable)
                }
                Button("Dismiss") { model.dismissBlockedPopups(tabID) }
            }
            .padding(12).background(Color.yellow.opacity(0.12))
            .alert("Allow popups for this origin?", isPresented: $confirmAllow) {
                Button("Cancel", role: .cancel) {}
                Button("Allow in This Space") {
                    if let request { model.allowBlockedPopups(request) }
                }
            } message: {
                Text("\(request?.origin ?? "This page") will be allowed to open popups without a click, only in “\(request?.spaceName ?? "")”. Other ports, subdomains and embedded frames are not included. The limit of 3 popups per 10 seconds still applies. Retry the website's action after allowing. Revoke this in Settings → Permissions.")
            }
        }
    }

    private var explanation: String {
        switch model.blockedPopupReasons[tabID] {
        case .rateLimited: return "The popup limit was reached. Wait a few seconds before trying again."
        case .unsupportedScheme: return "This popup used an unsupported address. Site exceptions cannot allow it."
        default: return "Sites need a click to open popups unless you allow this exact origin in this Space."
        }
    }
}

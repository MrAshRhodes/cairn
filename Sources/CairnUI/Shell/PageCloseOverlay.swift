import SwiftUI
import CairnCore

/// Background-tab decisions are visible without changing the user's selected tab or Space.
@MainActor
struct PageCloseOverlay: View {
    let model: BrowserModel
    let tabID: UUID

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.tabStates[tabID]?.url?.host ?? model.item(tabID)?.url?.host ?? model.item(tabID)?.title ?? "Page")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 20)
                if case .jsDialog(let request)? = model.prompts.front(tabID) {
                    JSDialogCard(model: model, tabID: tabID, request: request, offersSuppression: false)
                        .id(request.id)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for this page to close…").font(.headline)
                        }
                        Text("If the page does not respond, use Window → Force Close Tab, or Cairn → Force Close Pages and Quit. Forcing a close discards unsaved page changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(20)
                }
            }
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(radius: 18, y: 6)
            .accessibilityAddTraits(.isModal)
        }
    }
}

import SwiftUI
import CairnCore
import CairnEngineKit

/// Preferences → Permissions: every remembered site decision, per Space, with the ability to revoke it.
@MainActor
struct SitePermissionsView: View {
    let services: BrowserServices
    @ViewState<Bool> private var confirmReset = false

    private var store: SitePermissionStore { services.model.sitePermissions }

    var body: some View {
        Form {
            PopupExceptionsSection(model: services.model)
            Section("Site permissions") {
                Text("Websites ask before using your camera, microphone, location and more. Choices are remembered per site, separately for each Space. Nothing is allowed unless you say so.")
                    .font(.callout)
                if store.entries.isEmpty {
                    Text("No remembered choices yet.").foregroundStyle(.secondary)
                }
            }
            ForEach(services.model.workspace.spaces) { space in
                let entries = store.entries(profileID: space.profileID).sorted { ($0.origin, $0.kind.rawValue) < ($1.origin, $1.kind.rawValue) }
                if !entries.isEmpty {
                    Section(space.name) {
                        ForEach(entries) { entry in
                            HStack {
                                Image(systemName: entry.kind.symbol).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.origin).font(.callout)
                                    Text(entry.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("Decision", selection: binding(for: entry)) {
                                    Text("Allow").tag(SitePermissionDecision.allow)
                                    Text("Block").tag(SitePermissionDecision.block)
                                }.labelsHidden().frame(width: 100)
                                Button("Reset") { store.remove(entry.id) }
                                    .accessibilityLabel("Reset \(entry.kind.title) for \(entry.origin)")
                            }
                        }
                    }
                }
            }
            if !store.isWritable {
                Label("Permissions are read-only because their saved file could not be read.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Section {
                Button("Reset All Permissions…", role: .destructive) { confirmReset = true }.disabled(store.entries.isEmpty)
            }
        }
        .formStyle(.grouped)
        .alert("Reset all site permissions?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All", role: .destructive) { store.removeAll() }
        } message: { Text("Websites will ask again the next time they need a permission.") }
    }

    private func binding(for entry: SitePermissionEntry) -> Binding<SitePermissionDecision> {
        Binding(get: { entry.decision },
                set: { store.set($0, profileID: entry.profileID, origin: entry.origin, kind: entry.kind) })
    }
}

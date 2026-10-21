import SwiftUI

@MainActor
struct ScriptTrustReview: View {
    let title: String
    let source: String
    let scope: String
    var confirmTitle = "Allow for This Session"
    let onAllow: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var acknowledged = false
    @ViewState<String?> private var error = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review JavaScript", systemImage: "exclamationmark.shield")
                .font(.title2.weight(.semibold))
            Text(title).font(.headline)
            Text(scope).font(.callout).foregroundStyle(.secondary)
            Text("This code runs unsandboxed in the website's page context. It can read site data, change pages, and perform authenticated actions as you. Only allow code you understand and trust.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView([.horizontal, .vertical]) {
                Text(source).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Complete JavaScript source")
            Toggle("I reviewed this code and trust its source.", isOn: $acknowledged)
            Text("Permission expires when Cairn quits. Editing a Boost's code or host scope also revokes its permission.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle) {
                    do { try onAllow(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!acknowledged)
            }
        }.padding(24).frame(width: 660, height: 570)
    }
}

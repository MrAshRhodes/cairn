import SwiftUI
import CairnCore

/// Preferences ▸ Links: where external and eligible in-app new-tab links open.
@MainActor
struct LinksPane: View {
    let services: BrowserServices
    @ViewState<[LinkRule]> private var rules = []
    @ViewState<LinkDestination> private var fallback = .mostRecent
    @ViewState<Bool> private var peek = true
    @ViewState<String?> private var error = nil

    private var spaces: [Space] { services.model.workspace.spaces }

    var body: some View {
        Form {
            Section("Link destinations") {
                destinationPicker("Default destination", selection: $fallback)
                Text("External links and in-app Open Link in New Tab, Cmd-click and middle-click use these rules. Only http and https links are routed; the first match wins. Same-tab navigation and opener-dependent popups stay in their Space.").font(.caption).foregroundStyle(.secondary)
                Text("Quick windows use the most recent Space's cookies and storage, not private browsing. They are not restored; Open In Space keeps a page as a Today tab.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Rules") {
                ForEach($rules) { $rule in
                    HStack {
                        Picker("", selection: $rule.match) {
                            ForEach(LinkRule.Match.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 100)
                        TextField("text", text: $rule.text).accessibilityLabel("Rule text")
                        destinationPicker("", selection: $rule.destination).labelsHidden().frame(width: 160)
                        Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove rule")
                    }
                }
                Button("Add Rule") { rules.append(LinkRule(text: "", destination: .mostRecent)) }
            }
            Section("Peek") {
                Toggle("Preview cross-site links from pinned tabs and favorites", isOn: $peek)
                Text("Ordinary cross-site links open a live preview in the originating Space's profile. Expand keeps the same page as a Today tab. Forms, sign-in, payments and pop-ups keep their normal navigation and opener context.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Save", action: save).disabled(!services.linkRules.isWritable)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            rules = services.linkRules.rules; fallback = services.linkRules.defaultDestination; peek = services.linkRules.peekEnabled
        }
    }

    private func destinationPicker(_ title: String, selection: Binding<LinkDestination>) -> some View {
        Picker(title, selection: selection) {
            Text("Most recent Space").tag(LinkDestination.mostRecent)
            ForEach(spaces) { Text($0.name).tag(LinkDestination.space($0.id)) }
            Text("Quick window").tag(LinkDestination.quickWindow)
        }
    }

    private func save() {
        do {
            let cleaned = rules.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            try services.linkRules.update(rules: cleaned, defaultDestination: fallback, peekEnabled: peek)
            rules = cleaned; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

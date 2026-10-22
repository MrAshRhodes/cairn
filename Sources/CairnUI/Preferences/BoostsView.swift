import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CairnBoosts

@MainActor
struct BoostsView: View {
    let services: BrowserServices
    @ViewState<UUID?> private var selection = nil
    @ViewState<Boost> private var draft = Boost(name: "", hostPatterns: [])
    @ViewState<String> private var hosts = ""
    @ViewState<Bool> private var editingNew = false
    @ViewState<String?> private var error = nil
    @ViewState<Bool> private var deleting = false
    @ViewState<Bool> private var savedMessage = false
    @ViewState<UUID?> private var pendingSelection = nil
    @ViewState<Bool> private var discardConfirmation = false
    @ViewState<Bool> private var newAfterDiscard = false
    @ViewState<Bool> private var closeAfterDiscard = false
    @ViewState<Bool> private var reviewingJavaScript = false
    @ViewState<Bool> private var zapping = false
    @ViewState<String?> private var notice = nil
    @Environment(\.dismiss) private var dismiss

    private var selected: Boost? { services.boosts.boosts.first { $0.id == selection } }
    private var dirty: Bool {
        guard editingNew || selection != nil else { return false }
        if editingNew { return !draft.name.isEmpty || !draft.css.isEmpty || !draft.js.isEmpty }
        return currentDraft != selected
    }
    private var currentDraft: Boost {
        var value = draft
        value.hostPatterns = hosts.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "A web that feels like you.", subtitle: "Boosts · small, per-site CSS and JavaScript customizations",
                        onDone: {
                            if dirty { closeAfterDiscard = true; discardConfirmation = true }
                            else { dismiss() }
                        })
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(services.boosts.boosts) { boost in
                                Button {
                                    if dirty { pendingSelection = boost.id; newAfterDiscard = false; closeAfterDiscard = false; discardConfirmation = true }
                                    else { choose(boost.id) }
                                } label: {
                                    HStack {
                                        Image(systemName: boost.isEnabled ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                                        Text(boost.name).lineLimit(1)
                                        Spacer()
                                    }.padding(11).contentShape(Rectangle())
                                        .background(selection == boost.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(8)
                    }
                    Button {
                        if dirty { newAfterDiscard = true; closeAfterDiscard = false; discardConfirmation = true }
                        else { create() }
                    } label: { Label("New Boost", systemImage: "plus").frame(maxWidth: .infinity) }
                        .padding(.horizontal, 12).padding(.top, 12).disabled(!services.boostsWritable)
                    HStack {
                        Button("Import…", action: importBoosts).disabled(!services.boostsWritable)
                        Button("Export…", action: exportBoosts).disabled(services.boosts.boosts.isEmpty)
                    }.padding(12)
                }.frame(width: 190)
                Divider()
                editor
            }
        }
        .frame(width: 850, height: 650)
        .onAppear {
            if let first = services.boosts.boosts.first { choose(first.id) }
            else if services.boostsWritable { create() }
        }
        .alert("Delete this Boost?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let selection else { return }
                do {
                    try services.boosts.remove(selection)
                    self.selection = nil; editingNew = false
                    services.refreshBoosts()
                    if let next = services.boosts.boosts.first { choose(next.id) }
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text("The Boost will be removed and open pages will reload to remove its effects.") }
        .alert("Discard unsaved changes?", isPresented: $discardConfirmation) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) {
                if closeAfterDiscard { dismiss() }
                else if newAfterDiscard { create() } else if let pendingSelection { choose(pendingSelection) }
            }
        }
        .interactiveDismissDisabled(dirty)
        .onChange(of: dirty) { _, value in services.hasUnsavedBoostChanges = value }
        .onDisappear { services.hasUnsavedBoostChanges = false }
        .sheet(isPresented: $reviewingJavaScript) {
            if let selected {
                ScriptTrustReview(title: selected.name, source: selected.js,
                                  scope: "Runs on \(selected.hostPatterns.joined(separator: ", ")). Open pages will reload.",
                                  onAllow: {
                                      try services.boosts.setJavaScriptTrusted(true, for: selected.id)
                                      services.refreshBoosts()
                                  })
            }
        }
    }

    @ViewBuilder private var editor: some View {
        if editingNew || selection != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Boost name", text: $draft.name).font(.title3).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Boost name")
                    Toggle("Enabled", isOn: $draft.isEnabled).toggleStyle(.switch)
                }
                TextField("Hosts, separated by commas", text: $hosts).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Boost host patterns")
                Text("example.com includes its subdomains. Use * for every website.")
                    .font(.caption2).foregroundStyle(.secondary)
                BoostStyleEditor(boost: $draft, onZap: zap, zapping: zapping)
                codeEditor("CSS", text: $draft.css)
                codeEditor("JavaScript", text: $draft.js)
                if !draft.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack {
                        let trusted = selection.map { services.boosts.trustedJavaScriptIDs.contains($0) } ?? false
                        Label(trusted ? "JavaScript allowed this session" : "JavaScript is blocked until you allow it",
                              systemImage: trusted ? "checkmark.shield" : "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if trusted {
                            Button("Revoke") {
                                guard let selection else { return }
                                do {
                                    try services.boosts.setJavaScriptTrusted(false, for: selection)
                                    services.refreshBoosts()
                                } catch { self.error = error.localizedDescription }
                            }
                        } else {
                            Button("Review & Allow…") { reviewingJavaScript = true }
                                .disabled(editingNew || dirty)
                                .help("Save changes first, then review the exact saved JavaScript.")
                        }
                    }
                }
                Label("Only run scripts you trust. They can access data on matching websites.",
                      systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.secondary)
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if savedMessage { Text("Saved. Open pages reloaded with your changes.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if !editingNew {
                        Button("Delete…", role: .destructive) { deleting = true }
                    }
                    Spacer()
                    Button("Revert") {
                        if let selection { choose(selection) } else { create() }
                    }.disabled(!dirty)
                    Button("Save & Reload Pages", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!services.boostsWritable || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  currentDraft.hostPatterns.isEmpty)
                }
            }.padding(20).disabled(!services.boostsWritable)
        } else {
            ContentUnavailableView("Small changes, your way.", systemImage: "paintbrush",
                description: Text(services.boostsWritable ? "Create a Boost to customize a website." : "Editing is disabled because saved Boosts could not be loaded."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func codeEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
                .padding(5)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
                .accessibilityLabel("\(title) source code")
        }.frame(maxHeight: .infinity)
    }

    private func choose(_ id: UUID) {
        guard let boost = services.boosts.boosts.first(where: { $0.id == id }) else { return }
        selection = id; draft = boost; hosts = boost.hostPatterns.joined(separator: ", ")
        editingNew = false; error = nil; savedMessage = false
    }
    private func create() {
        selection = nil
        draft = Boost(name: "", hostPatterns: [])
        hosts = services.model.selectedTab?.url?.host ?? ""
        editingNew = true; error = nil; savedMessage = false
    }
    private func save() {
        do {
            var boost = currentDraft
            boost.name = boost.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if editingNew { try services.boosts.add(boost) } else { try services.boosts.update(boost) }
            choose(boost.id)
            savedMessage = true
            services.refreshBoosts()
        } catch { self.error = error.localizedDescription }
    }

    private func exportBoosts() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cairnboost") ?? .json]
        panel.nameFieldStringValue = "Boosts.cairnboost"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let chosen = services.boosts.boosts.filter { selection == nil || $0.id == selection }
            try BoostExchange.export(chosen).write(to: url, options: .atomic)
            notice = "Exported \(chosen.count) Boost\(chosen.count == 1 ? "" : "s")."
        } catch { self.error = error.localizedDescription }
    }

    private func importBoosts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cairnboost") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try BoostExchange.importBoosts(from: Data(contentsOf: url))
            for boost in result.boosts { try services.boosts.add(boost) }
            services.refreshBoosts()
            error = nil
            notice = "Imported \(result.boosts.count) Boost\(result.boosts.count == 1 ? "" : "s")."
                + (result.needsReview.isEmpty ? "" : " \(result.needsReview.count) with scripts or remote resources are disabled until you review them.")
            if let first = result.boosts.first { choose(first.id) }
        } catch { self.error = error.localizedDescription }
    }

    private func zap() {
        guard let tab = services.activeEngineTab else { error = "Open a page to zap an element."; return }
        zapping = true; error = nil
        tab.evaluateJavaScript(ZapPickerScript.pickerSource, completion: nil)
        Task { @MainActor in
            defer { zapping = false }
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                let value: String? = await withCheckedContinuation { continuation in
                    tab.evaluateJavaScript(ZapPickerScript.pollSource) { result in
                        if case .success(let any) = result { continuation.resume(returning: any as? String) }
                        else { continuation.resume(returning: nil) }
                    }
                }
                guard let value else { continue }
                if value.isEmpty { return }
                guard ZapSelector.isSafe(value) else { error = "That element can't be hidden safely."; return }
                var list = draft.zapped ?? []
                if !list.contains(value), list.count < ZapSelector.maximumPerBoost { list.append(value) }
                draft.zapped = list
                return
            }
        }
    }
}

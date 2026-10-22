import AppKit
import SwiftUI

/// Keyboard shortcuts: preset picker, per-action chords with a recorder, and the Arc rows Cairn does not implement.
@MainActor
struct ShortcutsPane: View {
    let services: BrowserServices
    @ViewState<String?> private var recording = nil
    @ViewState<String?> private var message = nil
    @ViewState<Any?> private var monitor = nil

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Keyboard shortcuts.", subtitle: "Click a shortcut, then press the new keys. Esc cancels.",
                        onDone: { stopRecording(); services.sheet = nil })
            content
        }.frame(width: 640, height: 600)
        .onDisappear { stopRecording() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Keymap", selection: Binding(get: { services.shortcuts.preset }, set: { preset in
                    attempt { try services.setKeymapPreset(preset) }
                })) {
                    ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 320).accessibilityLabel("Keymap preset")
                Spacer()
                Text("Changing the keymap resets your custom shortcuts.").font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .accessibilityLabel("Shortcut problem: \(message)")
            }
            if !services.shortcutsWritable {
                Label("Shortcuts are read-only this session because the saved file could not be set aside.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(ShortcutMenu.allCases, id: \.self) { menu in
                    let rows = services.shortcuts.actions.filter { $0.menu == menu && $0.remappable }
                    if !rows.isEmpty {
                        Section(menu.rawValue) { ForEach(rows) { row($0) } }
                    }
                }
                Section("Not available in Cairn") {
                    ForEach(ShortcutCatalog.unmappedArcRows, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }

    private func row(_ action: ShortcutAction) -> some View {
        let chord = services.shortcuts.chord(for: action.id)
        return HStack {
            Text(action.title)
            Spacer()
            Button(recording == action.id ? "Press keys…" : (chord?.display ?? "None")) { startRecording(action.id) }
                .buttonStyle(.bordered).monospacedDigit()
                .accessibilityLabel("\(action.title) shortcut, \(chord?.display ?? "none")")
                .accessibilityHint("Activate, then press the new keys")
            Button("Clear") { attempt { try services.assignShortcut(nil, to: action.id) } }
                .disabled(chord == nil).buttonStyle(.borderless)
            Button("Reset") { attempt { try services.resetShortcut(action.id) } }.buttonStyle(.borderless)
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); message = nil } catch { message = error.localizedDescription }
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recording = id
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { stopRecording(); return }
                guard let chord = KeyChord(event: event) else { return }
                attempt { try services.assignShortcut(chord, to: id) }
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

/// Site-search keywords: type the keyword and Tab in the command bar to search that site.
@MainActor
struct SiteSearchPane: View {
    let services: BrowserServices
    @ViewState<String> private var keyword = ""
    @ViewState<String> private var name = ""
    @ViewState<String> private var template = ""
    @ViewState<String?> private var message = nil

    var body: some View {
        let store = services.siteSearch
        Form {
            Section("Site search") {
                Text("Type a keyword and press Tab in the command bar to search a site directly. Use %s where the query goes.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.engines) { engine in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(engine.name) · \(engine.keyword)")
                            Text(engine.template).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if store.defaultKeyword == engine.keyword {
                            Button("Default ✓") { attempt { try store.setDefault(keyword: nil); services.applySettings() } }
                        } else {
                            Button("Make Default") { attempt { try store.setDefault(keyword: engine.keyword); services.applySettings() } }
                        }
                        Button("Remove", role: .destructive) { attempt { try store.remove(keyword: engine.keyword); services.applySettings() } }
                    }
                }
                HStack {
                    TextField("Keyword", text: $keyword).frame(width: 90)
                    TextField("Name", text: $name).frame(width: 110)
                    TextField("https://example.com/?q=%s", text: $template)
                    Button("Add") {
                        attempt {
                            try store.add(SiteSearchEngine(keyword: keyword, name: name.isEmpty ? keyword : name, template: template))
                            keyword = ""; name = ""; template = ""
                        }
                    }.disabled(keyword.isEmpty || template.isEmpty || !store.isWritable)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); message = nil } catch { message = error.localizedDescription }
    }
}

import SwiftUI
import AppKit
import CairnCore
import CairnImport

/// A five-step import: source → what → preview (dry run) → import → result. Nothing is read before the user
/// confirms a source and its data kinds; nothing leaves this Mac.
@MainActor
struct ImportWizardView: View {
    enum Step { case source, what, preview, importing, result }

    let services: BrowserServices
    @Environment(\.dismiss) private var dismiss
    @ViewState<Step> private var step = .source
    @ViewState<[ImportSource]> private var sources: [ImportSource] = []
    @ViewState<ImportSource?> private var source = nil
    @ViewState<Bool> private var includeBookmarks = true
    @ViewState<Bool> private var includeHistory = false
    @ViewState<ImportPreview?> private var preview = nil
    @ViewState<ImportResult?> private var result = nil
    @ViewState<String?> private var failure = nil
    @ViewState<Bool> private var busy = false
    @ViewState<Task<Void, Never>?> private var scanTask = nil

    private let privacyNote = "Read locally. Nothing leaves this Mac. Passwords, cookies and extensions are never imported."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import").font(.system(size: 24, design: .serif))
            Label(privacyNote, systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
            Divider()
            content
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(28).frame(width: 540, height: 470)
        .onAppear { sources = ImportSourceDiscovery.discover() }
        .onDisappear { scanTask?.cancel(); services.sweepImportStaging() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .source: sourceStep
        case .what: whatStep
        case .preview: previewStep
        case .importing: HStack { ProgressView(); Text("Importing…") }
        case .result: resultStep
        }
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose where to import from").font(.headline)
            Text("Cairn only checks that these folders exist. Nothing is opened until you confirm the next step.")
                .font(.caption).foregroundStyle(.secondary)
            if sources.isEmpty { Text("No supported browsers were found.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sources) { candidate in
                        Button { choose(candidate) } label: {
                            Label(candidate.name, systemImage: "globe").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 160)
            Button("Choose File or Folder…") { chooseFile() }
            Text("Supports bookmark .html exports (Safari, Firefox, Chrome…), a cairn-import-v1 .json file, or a Chromium profile folder.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source?.name ?? "").font(.headline)
            Toggle("Bookmarks (as Pinned tabs, folders kept)", isOn: $includeBookmarks)
            Toggle("History", isOn: $includeHistory).disabled(source?.supportsHistory != true)
            if source?.supportsHistory != true {
                Text("This kind of file has no history.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Imported items go into a new Space with its own cookies and storage. Nothing existing is changed or deleted.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var previewStep: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview — nothing has been added yet").font(.headline)
                Text("\(preview.bookmarkCount) bookmarks in \(preview.folderCount) folders")
                Text("\(preview.historyCount) history entries")
                ForEach(SkipReason.allCases.filter { (preview.skipped[$0] ?? 0) > 0 }, id: \.self) { reason in
                    Text("Skipped \(preview.skipped[reason] ?? 0): \(reason.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(preview.spaces.indices, id: \.self) { index in
                    let space = preview.spaces[index]
                    Label("\(space.isExisting ? "Added to" : "New Space") “\(space.name)”", systemImage: "square.grid.2x2").font(.callout)
                }
                if preview.isEmpty { Text("There is nothing new to import.").foregroundStyle(.secondary) }
            }
        } else { HStack { ProgressView(); Text("Reading…") } }
    }

    @ViewBuilder private var resultStep: some View {
        if let result {
            VStack(alignment: .leading, spacing: 8) {
                Label("Import complete", systemImage: "checkmark.circle").font(.headline)
                Text("\(result.bookmarksAdded) bookmarks, \(result.foldersAdded) folders, \(result.historyAdded) history entries added.")
                ForEach(SkipReason.allCases.filter { (result.skipped[$0] ?? 0) > 0 }, id: \.self) { reason in
                    Text("Skipped \(result.skipped[reason] ?? 0): \(reason.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(step == .result ? "Done" : "Cancel") { scanTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            switch step {
            case .source: EmptyView()
            case .what:
                Button("Back") { step = .source }
                Button("Read & Preview") { startScan() }.keyboardShortcut(.defaultAction)
                    .disabled(!includeBookmarks && !includeHistory)
            case .preview:
                Button("Back") { scanTask?.cancel(); preview = nil; step = .what }
                Button("Import") { runImport() }.keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || preview?.isEmpty == true)
            case .importing, .result: EmptyView()
            }
        }
    }

    private func choose(_ candidate: ImportSource) {
        source = candidate
        failure = nil
        includeHistory = false
        step = .what
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks export, a cairn-import-v1 file, or a browser profile folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { choose(try ImportSourceDiscovery.chosen(url)) }
        catch { failure = error.localizedDescription }
    }

    private func startScan() {
        guard let source else { return }
        failure = nil
        preview = nil
        step = .preview
        let consent = ImportConsent(source: source, options: ImportOptions(bookmarks: includeBookmarks, history: includeHistory))
        let scanner = ImportScanner(staging: services.importStaging)
        let sink = services.makeImportSink()
        scanTask = Task {
            do {
                let plan = try await scanner.scan(consent)
                preview = try ImportApplier.preview(plan, sink: sink)
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
                step = .what
            }
        }
    }

    private func runImport() {
        guard let preview else { return }
        step = .importing
        do {
            result = try ImportApplier.apply(preview, to: services.makeImportSink())
            step = .result
        } catch is CancellationError {
            step = .preview
        } catch {
            failure = error.localizedDescription
            step = .preview
        }
    }
}

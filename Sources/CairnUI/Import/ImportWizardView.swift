import SwiftUI
import AppKit
import CairnCore
import CairnImport

/// Nothing is read before the user confirms a source and its data kinds; nothing leaves this Mac.
@MainActor
struct ImportWizardView: View {
    enum Step { case source, what, mapping, preview, importing, result }

    let services: BrowserServices
    @Environment(\.dismiss) private var dismiss
    @ViewState<Step> private var step = .source
    @ViewState<[ImportSource]> private var sources: [ImportSource] = []
    @ViewState<ImportSource?> private var source = nil
    @ViewState<Bool> private var includeBookmarks = true
    @ViewState<Bool> private var includeHistory = false
    @ViewState<Bool> private var mapWorkspace = false
    @ViewState<ImportPlan?> private var scannedPlan = nil
    @ViewState<[MigrationMapping]> private var mappings = []
    @ViewState<ImportPreview?> private var preview = nil
    @ViewState<ImportResult?> private var result = nil
    @ViewState<String?> private var failure = nil
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
        .padding(28).frame(width: 620, height: 650)
        .onAppear { sources = ImportSourceDiscovery.discover() }
        .onDisappear { scanTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .source: sourceStep
        case .what: whatStep
        case .mapping:
            if let scannedPlan {
                ImportMappingView(plan: scannedPlan, mappings: $mappings,
                                  existingSpaceNames: services.model.workspace.spaces.map(\.name))
            }
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
            HStack {
                Button("Safari Bookmarks HTML…") { chooseSafariExport() }
                Button("Safari Local Data…") { chooseSafariData() }
            }
            Button("Map an Export into Spaces…") { chooseFile(guided: true) }
            Text("Supports Firefox, Safari or Chromium local data, bookmark .html exports, and cairn-import-v1 .json files. For an export folder, select its supported HTML or JSON file; archives and private Arc data are not read.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source?.name ?? "").font(.headline)
            Text(source?.location.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Toggle("Bookmarks (as Pinned tabs, folders kept)", isOn: $includeBookmarks)
            Toggle("History", isOn: $includeHistory).disabled(source?.supportsHistory != true)
            Toggle("Guide me through mapping folders into Spaces", isOn: $mapWorkspace).disabled(!includeBookmarks)
            if source?.supportsHistory != true {
                Text("This kind of file has no history.").font(.caption).foregroundStyle(.secondary)
            }
            Text("New Spaces have their own cookies and storage. Named portable Spaces may match existing Spaces; review the destination before importing. Existing items are never replaced or deleted.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if source?.isSafari == true {
                Text(SafariBookmarks.accessGuidance).font(.caption).foregroundStyle(.secondary)
                Button("Use Safari HTML Export Instead…") { chooseSafariExport() }
            }
            Text("Read & Preview is your consent to read only this source and the selected kinds of data.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var previewStep: some View {
        if let preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview — nothing has been added yet").font(.headline)
                    Text(scannedPlan?.sourceName ?? source?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    Text("\(preview.bookmarkCount) bookmarks in \(preview.folderCount) new folders").monospacedDigit()
                    Text("\(preview.historyCount) history entries").monospacedDigit()
                    ForEach(SkipReason.allCases.filter { (preview.skipped[$0] ?? 0) > 0 }, id: \.self) { reason in
                        Text("Skipped \(preview.skipped[reason] ?? 0): \(reason.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(preview.spaces.indices, id: \.self) { index in
                        let space = preview.spaces[index]
                        Label("\(space.isExisting ? "Added to" : "New Space") “\(space.name)”", systemImage: "square.grid.2x2").font(.callout)
                    }
                    if preview.isEmpty { Text("There is nothing new to import.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
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
                Button("Back") { failure = nil; step = .source }
                Button("Read & Preview") { startScan() }.keyboardShortcut(.defaultAction)
                    .disabled(!includeBookmarks && !includeHistory)
            case .mapping:
                Button("Back") { failure = nil; scannedPlan = nil; step = .what }
                Button("Preview Destinations") { previewMapping() }.keyboardShortcut(.defaultAction)
            case .preview:
                Button("Back") {
                    scanTask?.cancel(); preview = nil; failure = nil
                    step = mapWorkspace && includeBookmarks && scannedPlan != nil ? .mapping : .what
                }
                Button("Import") { runImport() }.keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || preview?.isEmpty == true)
            case .importing, .result: EmptyView()
            }
        }
    }

    private func choose(_ candidate: ImportSource, guided: Bool = false) {
        if candidate.format == .firefoxProfiles {
            chooseFirefoxProfile(at: candidate.location)
            return
        }
        source = candidate
        failure = nil
        includeBookmarks = true
        includeHistory = false
        mapWorkspace = guided
        scannedPlan = nil
        mappings = []
        step = .what
    }

    private func chooseFirefoxProfile(at root: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.message = "Choose a Firefox profile folder (for example, xxxxxxxx.default-release). Its contents are not read until Read & Preview."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try ImportSourceDiscovery.chosen(url)
            guard candidate.format == .firefoxProfile else {
                throw ImportError.unsupportedSource("Choose an individual Firefox profile folder containing places.sqlite.")
            }
            choose(candidate)
        } catch { failure = error.localizedDescription }
    }

    private func chooseFile(guided: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks HTML export, a cairn-import-v1 JSON file, or supported browser data. For an export folder, choose its HTML/JSON file; do not select private Arc databases."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { choose(try ImportSourceDiscovery.chosen(url), guided: guided) }
        catch { failure = error.localizedDescription }
    }

    private func chooseSafariExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Export bookmarks from Safari, then choose the HTML file. History is not included. Nothing is read until Read & Preview."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var candidate = try ImportSourceDiscovery.chosen(url)
            guard candidate.format == .netscapeHTML else {
                throw ImportError.unsupportedSource("Choose Safari's exported bookmarks HTML file, not a ZIP archive or passwords file.")
            }
            candidate.browser = "Safari"
            candidate.name = "Safari — \(url.lastPathComponent)"
            choose(candidate)
        } catch { failure = error.localizedDescription }
    }

    private func chooseSafariData() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a Safari data folder containing Bookmarks.plist and optionally History.db. macOS may deny access; Cairn will not change permissions. Use a bookmarks HTML export instead if denied."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(ImportSourceDiscovery.safariFolder(url))
    }

    private func startScan() {
        guard let source else { return }
        failure = nil
        preview = nil
        scannedPlan = nil
        step = .preview
        let consent = ImportConsent(source: source, options: ImportOptions(bookmarks: includeBookmarks, history: includeHistory))
        let scanner = ImportScanner(staging: services.importStaging)
        let sink = services.makeImportSink()
        scanTask = Task {
            do {
                let plan = try await scanner.scan(consent)
                try Task.checkCancellation()
                scannedPlan = plan
                if mapWorkspace && includeBookmarks {
                    mappings = ImportMigration.groups(in: plan).map { MigrationMapping(group: $0, preserveSourceSpace: source.format == .cairnJSON) }
                    step = .mapping
                } else {
                    preview = try ImportApplier.preview(plan, sink: sink)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                step = .what
            }
        }
    }

    private func previewMapping() {
        guard let scannedPlan else { return }
        do {
            let plan = try ImportMigration.plan(from: scannedPlan, mappings: mappings,
                                                existingSpaceNames: services.model.workspace.spaces.map(\.name))
            preview = try ImportApplier.preview(plan, sink: services.makeImportSink())
            failure = nil
            step = .preview
        } catch {
            failure = error.localizedDescription
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

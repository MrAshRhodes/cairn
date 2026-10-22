import SwiftUI
import CairnCore

struct SheetHeader: View {
    let title: String
    let subtitle: String
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 26, design: .serif))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { if let onDone { onDone() } else { dismiss() } }.keyboardShortcut(.cancelAction)
        }.padding(24)
    }
}

@MainActor
struct ArchiveView: View {
    let model: BrowserModel
    @ViewState<String> private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var tabs: [TabItem] {
        model.selectedSpace.archive.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) ||
            $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.url?.absoluteString.localizedCaseInsensitiveContains(search) ?? false) }
    }
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "A place to come back to.", subtitle: "Archived tabs in \(model.selectedSpace.name)")
            TextField("Search archive", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 24)
            List(tabs) { tab in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.displayTitle).lineLimit(1)
                        Text(tab.url?.absoluteString ?? "Empty tab").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Restore") { model.moveTab(tab.id, to: .today); model.select(tab.id); dismiss() }
                    Button(role: .destructive) { model.removeTab(tab.id) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete archived tab \(tab.displayTitle)")
                }.padding(.vertical, 5)
            }.overlay { if tabs.isEmpty { ContentUnavailableView("Nothing archived", systemImage: "archivebox", description: Text("Inactive tabs will appear here, ready whenever you need them.")) } }
        }.frame(width: 620, height: 480)
    }
}

@MainActor
struct HistoryView: View {
    let services: BrowserServices
    @ViewState<String> private var query = ""
    @ViewState<[HistoryEntry]> private var entries = []
    @ViewState<String?> private var failure = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Your trail.", subtitle: "Browsing history stays on this Mac.")
            TextField("Search history", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 24)
            if let failure { Text(failure).foregroundStyle(.red).font(.caption).padding() }
            List(entries) { entry in
                Button {
                    services.model.newTab(url: entry.url)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.title).lineLimit(1)
                            Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.visitedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain)
            }.overlay {
                if entries.isEmpty && failure == nil {
                    ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Pages you visit will appear here."))
                }
            }
        }.frame(width: 650, height: 480).onAppear(perform: refresh)
            .onChange(of: query) { _, _ in refresh() }
    }
    private func refresh() {
        guard let history = services.history else { failure = "History is unavailable. See the startup notice for details."; return }
        do {
            entries = try query.isEmpty ? history.recent(limit: 100) : history.search(query, limit: 100)
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

@MainActor
struct DownloadsView: View {
    let services: BrowserServices
    @ViewState<String> private var link = ""
    @ViewState<String?> private var inputError = nil
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Downloads", subtitle: "Direct-link downloads · you choose where each file is saved.")
            HStack {
                TextField("Paste an HTTP(S) download link", text: $link)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Download link")
                    .onSubmit(download)
                Button("Download Link…", action: download).disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 24).padding(.bottom, 10)
            if let inputError { Text(inputError).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
            List(services.downloads.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.status == .completed ? "doc" : "arrow.down.circle")
                        .font(.title2).foregroundStyle(.secondary).frame(width: 32)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.filename).font(.callout.weight(.medium)).lineLimit(1)
                        if item.status == .downloading {
                            ProgressView(value: item.progress).accessibilityLabel("Download progress")
                            Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            Text(item.errorMessage ?? item.status.rawValue.capitalized)
                                .font(.caption).foregroundStyle(item.status == .failed ? Color.red : .secondary)
                                .textSelection(.enabled)
                        }
                        Text(item.url.host ?? "").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if item.status == .downloading {
                        Button("Cancel") { services.downloads.cancel(item.id) }
                    } else if item.status == .completed {
                        Button("Show in Finder") { services.downloads.reveal(item.id) }
                    } else if item.status == .failed || item.status == .cancelled {
                        Button("Retry") { services.downloads.start(url: item.url, suggestedFilename: item.filename) }
                    }
                }.padding(.vertical, 8)
            }.overlay {
                if services.downloads.items.isEmpty {
                    ContentUnavailableView("No direct-link downloads", systemImage: "arrow.down.circle",
                        description: Text("Paste a public download link above. Downloads started from a page also appear here."))
                }
            }
            HStack {
                Text("Downloads are requested again from their URL without your website sign-ins, so files that need you to be signed in may fail.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { services.downloads.clearFinished() }
                    .disabled(!services.downloads.items.contains { $0.status != .downloading })
            }.padding(16)
        }.frame(width: 650, height: 480)
    }
    private func download() {
        let input = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), URLResolver.isWebURL(url) else {
            inputError = "Enter a complete HTTP(S) URL, without embedded credentials."
            return
        }
        inputError = nil
        services.downloads.start(url: url)
    }
}

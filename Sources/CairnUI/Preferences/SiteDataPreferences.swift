import SwiftUI
import UniformTypeIdentifiers
import CairnCore
import CairnEngineKit

/// Privacy → website data clearing (per Space, per site, per kind) and local content blocking.
@MainActor
struct SiteDataPreferences: View {
    let services: BrowserServices
    @ViewState<UUID?> private var spaceID = nil
    @ViewState<Bool> private var cookies = true
    @ViewState<Bool> private var cache = true
    @ViewState<Bool> private var storage = true
    @ViewState<String> private var site = ""
    @ViewState<Bool> private var confirmation = false

    private var kinds: SiteDataKinds {
        var kinds: SiteDataKinds = []
        if cookies { kinds.insert(.cookies) }
        if cache { kinds.insert(.cache) }
        if storage { kinds.insert(.storage) }
        return kinds
    }
    private var trimmedSite: String? {
        let value = site.trimmingCharacters(in: .whitespaces).lowercased()
        return value.isEmpty ? nil : value
    }
    private var scopeDescription: String {
        let space = spaceID.flatMap { id in services.model.workspace.spaces.first { $0.id == id }?.name } ?? "every Space"
        return trimmedSite.map { "\($0) in \(space)" } ?? space
    }
    private var activeHost: String? { services.activeEngineTab?.state.url?.host()?.lowercased() }

    var body: some View {
        Group {
            websiteData
            contentBlocking
        }
        .alert("Clear website data for \(scopeDescription)?", isPresented: $confirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                let ids = spaceID.map { Set([$0]) }
                Task { await services.clearSiteData(kinds: kinds, site: trimmedSite, spaceIDs: ids) }
            }
        } message: {
            Text("Websites may sign you out. This cannot be undone.")
        }
    }

    private var websiteData: some View {
        Section("Website data") {
            Picker("Space", selection: $spaceID) {
                Text("All Spaces").tag(UUID?.none)
                ForEach(services.model.workspace.spaces) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            HStack {
                TextField("Only this site (optional)", text: $site, prompt: Text("example.com"))
                if let host = activeHost, host != trimmedSite {
                    Button("Use \(host)") { site = host }.buttonStyle(.link)
                }
            }
            Toggle("Cookies and saved logins", isOn: $cookies)
            Toggle("Cache", isOn: $cache)
            Toggle("Site storage (localStorage, IndexedDB, service workers, Cache Storage)", isOn: $storage)
            HStack {
                Text("Open pages can create new site data after clearing.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if services.privacyBusy { ProgressView().controlSize(.small) }
                Button("Clear Website Data…") { confirmation = true }
                    .disabled(services.privacyBusy || kinds.isEmpty)
            }
            if trimmedSite != nil && cache {
                Text("Chromium cannot clear its cache per site, so the cache is cleared for the whole Space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = services.siteDataNotice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("Removing a Space deletes its cookies, storage and cache for good.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contentBlocking: some View {
        let store = services.contentBlocking
        return Section("Content blocking") {
            Toggle("Block third-party requests to listed hosts", isOn: Binding(
                get: { store.isEnabled }, set: { store.setEnabled($0) }))
                .disabled(store.blockedHosts.isEmpty || !services.contentBlockingWritable)
            LabeledContent("Blocklist") {
                Text(store.listName.map { "\($0) · \(store.blockedHosts.count) hosts" } ?? "None imported")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Import List…") { chooseList() }.disabled(!services.contentBlockingWritable)
                Button("Remove List") { store.removeList() }.disabled(store.blockedHosts.isEmpty)
                Spacer()
                Text("\(services.blockedRequestCount) blocked this session").font(.caption).foregroundStyle(.secondary)
            }
            if let host = activeHost, store.isEnabled {
                Toggle("Block on \(host)", isOn: Binding(
                    get: { store.isBlocking(on: host) }, set: { store.setBlocking($0, on: host) }))
            }
            ForEach(store.exemptSites, id: \.self) { exempt in
                HStack {
                    Text("Not blocking on \(exempt)")
                    Spacer()
                    Button("Block Again") { store.setBlocking(true, on: exempt) }
                }
            }
            Text("Your own list, one host per line, a hosts file, or `||host^` rules. Nothing is downloaded. Only third-party subresources are blocked; pages themselves always load.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a blocklist file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        services.importBlocklist(from: url)
    }
}

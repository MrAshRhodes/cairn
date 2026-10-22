import AppKit
import Observation
import CairnCore
import CairnEngineKit
import CairnBoosts
import CairnModules
import CairnUpdater

public struct BrowserIssue: Identifiable {
    public let id = UUID()
    public let title: String
    public let detail: String
}

public enum BrowserSheet: String, Identifiable {
    case preferences, downloads, boosts, archive, history, moduleTrust, shortcuts, importer
    public var id: String { rawValue }
}

@MainActor
struct ModuleScriptReview: Identifiable {
    let id: String
    let title: String
    let source: String
    let runsAfterGrant: Bool
    let allow: () throws -> Void
}

/// Owns application lifetime services. A failed read never authorizes replacing the source file.
@MainActor @Observable
public final class BrowserServices {
    public let model: BrowserModel
    public let settings: Settings
    public let downloads: DownloadsManager
    public let boosts: BoostStore
    public let linkRules: LinkRuleStore
    public let modules: ModuleRegistry
    public let updater: UpdateController
    public let directory: URL
    public private(set) var history: HistoryStore?
    public private(set) var issues: [BrowserIssue] = []
    public private(set) var workspaceWritable = true
    public private(set) var settingsWritable = true
    public private(set) var boostsWritable = true
    public var sheet: BrowserSheet?
    public var commandBarPresented = false
    public var commandBarMode: CommandBarMode = .search
    public internal(set) var shortcuts = ShortcutMap()
    public internal(set) var shortcutsWritable = true
    public private(set) var splitsWritable = true
    public let siteSearch: SiteSearchStore
    public let tabSwitcher = TabSwitcher()
    @ObservationIgnored let splitStore: SplitStore
    @ObservationIgnored let shortcutStore: ShortcutStore
    @ObservationIgnored public var onShortcutsChanged: (() -> Void)?
    public var sidebarVisible = true
    public var addressFocusRequest = 0
    public var findPresented = false
    public var findQuery = ""
    public var findResult: Bool?
    public var zoom: Double = 1
    public var privacyBusy = false
    /// Why the last website-data clear could not remove everything; shown in Preferences.
    public internal(set) var siteDataNotice: String?
    public internal(set) var contentBlocking = ContentBlockingStore()
    public internal(set) var contentBlockingWritable = true
    public var hasUnsavedBoostChanges = false
    public private(set) var moduleTrustRevision = 0
    var moduleReview: ModuleScriptReview?
    @ObservationIgnored private let workspaceStore: WorkspaceStore
    @ObservationIgnored private var archiveTimer: Timer?
    @ObservationIgnored private var mediaKeys: MediaKeyController?

    public init(model: BrowserModel, settings: Settings? = nil,
                directory: URL = WorkspaceStore.defaultDirectory,
                registry: ModuleRegistry? = nil) {
        self.model = model
        self.settings = settings ?? Settings()
        self.directory = directory
        modules = registry ?? ModuleRegistry()
        workspaceStore = WorkspaceStore(directory: directory)
        splitStore = SplitStore(directory: directory)
        shortcutStore = ShortcutStore(directory: directory)
        siteSearch = SiteSearchStore(directory: directory)
        boosts = BoostStore(directory: directory.appendingPathComponent("Boosts", isDirectory: true))
        linkRules = LinkRuleStore(url: directory.appendingPathComponent("link-rules.json"))
        downloads = DownloadsManager()
        updater = UpdateController()
    }

    public static func bootstrap(registry suppliedRegistry: EngineRegistry? = nil,
                                 directory: URL = WorkspaceStore.defaultDirectory) throws -> BrowserServices {
        let registry = suppliedRegistry ?? .shared
        var initialIssues: [BrowserIssue] = []
        var directoryWritable = true
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            directoryWritable = false
            initialIssues.append(.init(title: "Application data is unavailable", detail: error.localizedDescription))
        }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let settings: Settings
        var settingsWritable = directoryWritable
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do { settings = try Settings.load(from: settingsURL) }
            catch {
                settings = Settings()
                settingsWritable = false
                initialIssues.append(.init(title: "Settings could not be read",
                    detail: "\(error.localizedDescription)\nThe original file is preserved. Settings will not be saved this session."))
            }
        } else { settings = Settings() }
        guard let engine = registry.make(.chromium) else {
            throw NSError(domain: "Cairn", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Chromium, the browser engine Cairn runs on, is not available in this installation. Reinstall Cairn from a complete release."
            ])
        }
        let initialWorkspace = Workspace(spaces: [Space(name: "Home", icon: "house", colorHex: "#527B72", profileID: "default")])
        let service = BrowserServices(model: BrowserModel(engine: engine, workspace: initialWorkspace), settings: settings,
                                      directory: directory)
        service.issues = initialIssues
        service.settingsWritable = settingsWritable
        service.workspaceWritable = directoryWritable
        service.boostsWritable = directoryWritable
        service.load()
        return service
    }

    private func load() {
        model.onError = { [weak self] error in self?.report("Browser action could not finish", error: error) }
        downloads.onError = { [weak self] error in self?.report("Download could not finish", error: error) }
        do {
            // Read even when restore is off: a corrupt session must not be replaced by a fresh one.
            if var saved = try workspaceStore.load() {
                if !settings.restoreSessionOnLaunch {
                    for index in saved.spaces.indices {
                        saved.spaces[index].tabs = []
                        saved.spaces[index].selectedTabID = nil
                    }
                }
                model.workspace = saved
            }
        } catch {
            workspaceWritable = false
            report("Session recovery required", detail: "\(error.localizedDescription)\nYour saved session is preserved. This session will not overwrite it. Reveal the data folder in Settings to recover the file.")
        }
        let splits = splitStore.load()
        model.restoreSplits(splits.groups)
        if let error = splits.error {
            splitsWritable = splits.quarantinedTo != nil
            report("Split view layout could not be read", detail: "\(error.localizedDescription)\n"
                + (splits.quarantinedTo.map { "The file was moved to \($0.lastPathComponent)." } ?? "The original file is preserved. Layouts will not be saved this session."))
        }
        splitStore.onError = { [weak self] error in self?.report("Split view layout could not be saved", error: error) }
        model.onSplitsChange = { [weak self] in
            guard let self, self.splitsWritable else { return }
            self.splitStore.scheduleSave(self.model.splitGroups)
        }
        siteSearch.onError = { [weak self] title, detail in self?.report(title, detail: detail) }
        siteSearch.load()
        do { history = try HistoryStore(url: directory.appendingPathComponent("history.sqlite")) }
        catch { report("History is unavailable", error: error) }
        model.sitePermissions.onError = { [weak self] error in self?.report("Site permissions could not be saved", error: error) }
        do { try model.sitePermissions.load(from: directory.appendingPathComponent("permissions.json")) }
        catch { report("Site permissions could not be loaded", detail: "\(error.localizedDescription)\nThe original file is preserved. Choices will not be remembered this session.") }
        do { try boosts.load() }
        catch {
            boostsWritable = false
            report("Boosts could not be loaded", detail: "\(error.localizedDescription)\nEditing is disabled to preserve your saved Boosts.")
        }
        model.faviconStore = FaviconStore(directory: directory.appendingPathComponent("Favicons", isDirectory: true))
        mediaKeys = MediaKeyController(model: model)
        loadLinkRules()
        model.userScriptProvider = { [weak self] url in self?.boosts.scripts(for: url) ?? [] }
        modules.onError = { [weak self] error in self?.report("Module error", error: error) }
        BuiltinModules.all().forEach { modules.register($0) }
        do { try modules.loadUserModules(from: directory.appendingPathComponent("Modules", isDirectory: true)) }
        catch { report("Some modules could not be loaded", error: error) }
        modules.activate(model: model)
        loadShortcuts()
        sweepImportStaging()
        model.onChange = { [weak self] in
            guard let self, self.workspaceWritable else { return }
            self.workspaceStore.scheduleSave(self.model.workspace)
        }
        workspaceStore.onError = { [weak self] error in self?.report("Session could not be saved", error: error) }
        model.onNavigationCommitted = { [weak self] url, title in
            guard let self, let history = self.history else { return }
            do { try history.record(url: url, title: title) }
            catch { self.report("History could not be saved", error: error) }
        }
        model.downloadHandler = { [weak self] url, filename in
            self?.downloads.start(url: url, suggestedFilename: filename)
            self?.sheet = .downloads
        }
        loadContentBlocking()
        removeOrphanProfiles()
        applySettings()
        autoArchive()
        if let selected = model.selectedTabID { model.select(selected) }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoArchive() }
        }
    }

    public func applySettings() {
        model.searchTemplate = siteSearch.defaultEngine?.template ?? settings.searchTemplate
        autoArchive()
    }

    public func saveSettings() {
        applySettings()
        guard settingsWritable else { return }
        do { try settings.save(to: directory.appendingPathComponent("settings.json")) }
        catch { report("Settings could not be saved", error: error) }
    }

    public func flush() throws {
        if workspaceWritable { try workspaceStore.saveNow(model.workspace) }
        if splitsWritable { try splitStore.saveNow(model.splitGroups) }
        if settingsWritable { try settings.save(to: directory.appendingPathComponent("settings.json")) }
    }

    public func shutdown() {
        archiveTimer?.invalidate()
        archiveTimer = nil
        model.onChange = nil
        model.onNavigationCommitted = nil
        model.downloadHandler = nil
        model.onError = nil
        downloads.onError = nil
        modules.deactivate()
        Array(model.liveTabs.keys).forEach { model.unloadTab($0) }
        model.engine.shutdown()
    }

    public func report(_ title: String, error: Error) { report(title, detail: error.localizedDescription) }
    public func report(_ title: String, detail: String) {
        guard !issues.contains(where: { $0.title == title && $0.detail == detail }) else { return }
        issues.append(.init(title: title, detail: detail))
    }
    public func dismissIssue(_ id: UUID) { issues.removeAll { $0.id == id } }

    public var activeEngineTab: EngineTab? {
        model.selectedTabID.flatMap { model.liveTab(for: $0) }
    }

    public func focusAddress() {
        commandBarPresented = false
        addressFocusRequest += 1
    }

    public func newTab() {
        model.newTab()
        focusAddress()
    }

    public func closeTab() {
        if commandBarPresented { commandBarPresented = false; return }
        guard let id = model.selectedTabID else { return }
        model.closeTab(id)
    }

    public func toggleSplit() {
        if !model.splitTabIDs.isEmpty { model.closeSplit(); return }
        guard let current = model.selectedTabID else { newTab(); return }
        let candidate = model.selectedSpace.tabs.first { $0.id != current }
            ?? model.selectedSpace.pinned.first { $0.id != current }
        let other = candidate?.id ?? model.newTab(activate: false)
        model.splitSelected(with: other)
    }

    public func setZoom(_ value: Double) {
        zoom = min(max(value, 0.25), 5)
        activeEngineTab?.zoom = zoom
    }

    public func selectTab(_ id: UUID) {
        model.select(id)
        zoom = activeEngineTab?.zoom ?? 1
        findResult = nil
    }

    public func find(forward: Bool = true) {
        guard !findQuery.isEmpty else { activeEngineTab?.clearFind(); findResult = nil; return }
        let query = findQuery
        let id = model.selectedTabID
        activeEngineTab?.find(query, forward: forward) { [weak self] found in
            guard let self, self.findQuery == query, self.model.selectedTabID == id else { return }
            self.findResult = found
        }
    }

    public func closeFind() {
        activeEngineTab?.clearFind()
        findPresented = false
        findResult = nil
    }

    public func autoArchive() {
        guard settings.autoArchiveAfterHours.isFinite, settings.autoArchiveAfterHours > 0 else { return }
        model.archiveStaleTabs(olderThan: settings.autoArchiveAfterHours * 3_600)
    }

    public func refreshBoosts() {
        model.refreshUserScripts()
        for tab in Array(model.liveTabs.values) { tab.reload(ignoringCache: false) }
    }

    public func clearHistory() {
        guard let history else { report("History is unavailable", detail: "History could not be opened during startup."); return }
        do { try history.clear() }
        catch { report("History could not be cleared", error: error) }
    }

    public func checkForUpdates() {
        if let error = updater.configurationError {
            report("Updates are not configured", detail: error)
        } else { updater.checkForUpdates() }
    }

    func moduleScriptReview(for command: Command, runAfterGrant: Bool) -> ModuleScriptReview? {
        guard let source = modules.javaScriptSource(for: command.id) else { return nil }
        return ModuleScriptReview(id: command.id, title: command.title, source: source, runsAfterGrant: runAfterGrant) { [weak self] in
            guard let self else { return }
            try self.setModuleJavaScriptTrusted(true, for: command.id)
            if runAfterGrant { command.perform(self.model) }
        }
    }

    func setModuleJavaScriptTrusted(_ trusted: Bool, for commandID: String) throws {
        try modules.setJavaScriptTrusted(trusted, for: commandID)
        moduleTrustRevision += 1
    }

    public func commands() -> [Command] {
        let localBase: [Command] = [
            .init(id: "ui.new-tab", title: "New Tab", symbol: "plus", perform: { [weak self] _ in self?.showCommandBar(mode: .newTab) }),
            .init(id: "ui.new-blank-tab", title: "New Blank Tab", symbol: "plus.square", perform: { [weak self] _ in self?.newTab() }),
            .init(id: "ui.address", title: "Edit Address", symbol: "link", perform: { [weak self] _ in self?.editAddress() }),
            .init(id: "ui.split", title: "Toggle Split View", symbol: "rectangle.split.2x1", perform: { [weak self] _ in self?.toggleSplit() }),
            .init(id: "ui.split-add-right", title: "Split: Add Pane on the Right", symbol: "rectangle.righthalf.inset.filled", perform: { [weak self] _ in self?.addSplit(edge: .right) }),
            .init(id: "ui.split-add-left", title: "Split: Add Pane on the Left", symbol: "rectangle.lefthalf.inset.filled", perform: { [weak self] _ in self?.addSplit(edge: .left) }),
            .init(id: "ui.split-add-top", title: "Split: Add Pane on Top", symbol: "rectangle.tophalf.inset.filled", perform: { [weak self] _ in self?.addSplit(edge: .top) }),
            .init(id: "ui.split-add-bottom", title: "Split: Add Pane on the Bottom", symbol: "rectangle.bottomhalf.inset.filled", perform: { [weak self] _ in self?.addSplit(edge: .bottom) }),
            .init(id: "ui.split-remove-pane", title: "Split: Remove Focused Pane", symbol: "rectangle.badge.minus", perform: { [weak self] _ in self?.perform(action: "ui.split-remove-pane") }),
            .init(id: "ui.split-separate", title: "Split: Separate All Panes", symbol: "rectangle.split.1x2", perform: { [weak self] _ in self?.model.closeSplit() }),
            .init(id: "ui.reopen-closed-tab", title: "Reopen Closed Tab", symbol: "arrow.uturn.backward", perform: { [weak self] _ in self?.perform(action: "ui.reopen-closed-tab") }),
            .init(id: "ui.clear-today", title: "Clear Today's Tabs", symbol: "trash", perform: { [weak self] _ in self?.perform(action: "ui.clear-today") }),
            .init(id: "ui.copy-url", title: "Copy Current URL", symbol: "doc.on.doc", perform: { [weak self] _ in self?.copyCurrentURL() }),
            .init(id: "ui.copy-markdown-link", title: "Copy Page Link as Markdown", symbol: "text.quote", perform: { [weak self] _ in self?.copyMarkdownLink() }),
            .init(id: "ui.sidebar", title: "Toggle Sidebar", symbol: "sidebar.left", perform: { [weak self] _ in self?.sidebarVisible.toggle() }),
            .init(id: "ui.next-space", title: "Select Next Space", symbol: "chevron.right.square", perform: { [weak self] _ in self?.stepSpace(1) }),
            .init(id: "ui.previous-space", title: "Select Previous Space", symbol: "chevron.left.square", perform: { [weak self] _ in self?.stepSpace(-1) }),
            .init(id: "ui.shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", perform: { [weak self] _ in self?.sheet = .shortcuts }),
            .init(id: "ui.settings", title: "Settings", symbol: "gearshape", perform: { [weak self] _ in self?.sheet = .preferences }),
            .init(id: "ui.boosts", title: "Edit Boosts", symbol: "paintbrush", perform: { [weak self] _ in self?.sheet = .boosts }),
            .init(id: "ui.downloads", title: "Downloads", symbol: "arrow.down.circle", perform: { [weak self] _ in self?.sheet = .downloads }),
            .init(id: "ui.archive", title: "Archived Tabs", symbol: "archivebox", perform: { [weak self] _ in self?.sheet = .archive }),
            .init(id: "ui.history", title: "History", symbol: "clock", perform: { [weak self] _ in self?.sheet = .history }),
            .init(id: "ui.import", title: "Import from Another Browser…", symbol: "square.and.arrow.down", perform: { [weak self] _ in self?.presentImporter() }),
            .init(id: "ui.find", title: "Find in Page", symbol: "magnifyingglass", perform: { [weak self] _ in self?.findPresented = true }),
        ]
        let local = localBase.map { command -> Command in
            var shown = command
            shown.shortcut = shortcuts.chord(for: command.id)?.display
            return shown
        }
        let localTitles = Set(local.map { $0.title.lowercased() })
        let moduleCommands = modules.allCommands(for: model).filter { !localTitles.contains($0.title.lowercased()) }
        return local + moduleCommands.map { command in
            var wrapped = command
            wrapped.perform = { [weak self] model in
                guard let self else { return }
                if self.modules.requiresJavaScriptTrust(for: command.id),
                   !self.modules.isJavaScriptTrusted(for: command.id) {
                    self.moduleReview = self.moduleScriptReview(for: command, runAfterGrant: true)
                    if self.moduleReview != nil { self.sheet = .moduleTrust }
                    else { self.report("Script source unavailable", detail: "The module command could not be reviewed, so it was not run.") }
                } else { command.perform(model) }
            }
            return wrapped
        }
    }
}

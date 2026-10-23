import AppKit
import SwiftUI
import Testing
import CairnCore
import CairnEngineKit
import CairnModules
import CairnBoosts
@testable import CairnUI

@MainActor
private final class TestEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Test engine"
    let versionDescription = "Test 1"
    var tabs: [TestTab] = []
    var clearedProfiles: [String] = []
    var stopped = false
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = TestTab()
        tab.state.url = initialURL
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async { clearedProfiles.append(profileID) }
    func shutdown() { stopped = true }
}

@MainActor
private final class SiteDataTestEngine: BrowserEngine, EngineSiteDataManaging {
    let kind = EngineKind.chromium
    let displayName = "Site data engine"
    let versionDescription = "Test 1"
    var cleared: [(profile: String, site: String?, kinds: SiteDataKinds)] = []
    var failures: [String] = []
    var blocking: ContentBlockingConfiguration?
    var orphanCalls: [Set<String>] = []
    let blockedRequestCount = 7
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { TestTab() }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
    func clearSiteData(profileID: String, site: String?, kinds: SiteDataKinds) async -> SiteDataClearResult {
        cleared.append((profileID, site, kinds))
        return SiteDataClearResult(failures: failures)
    }
    func deleteProfileData(profileID: String) async {}
    func removeOrphanProfiles(keeping profileIDs: Set<String>) -> [String] { orphanCalls.append(profileIDs); return [] }
    func configureContentBlocking(_ configuration: ContentBlockingConfiguration) { blocking = configuration }
}

@MainActor
private final class TestTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    var closed = false
    var reloadCount = 0
    var scripts: [EngineUserScript] = []
    var lastFind: String?
    var evaluations: [String] = []
    func load(_ url: URL) { state.url = url }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) { reloadCount += 1 }
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { lastFind = query; completion(query == "found") }
    func clearFind() { lastFind = nil }
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        evaluations.append(source)
        completion?(.success(nil))
    }
    func setUserScripts(_ scripts: [EngineUserScript]) { self.scripts = scripts }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { closed = true }
}

@Suite(.serialized) @MainActor
struct BrowserServicesTests {
    @Test(arguments: [
        #""engineKind":"webkit","engineKindIsExplicit":true"#,
        #""engineKind":"webkit","engineKindIsExplicit":false"#,
        #""engineKind":"webkit""#,
    ])
    func legacyEngineSettingsBootstrapChromiumAndKeepOtherSettings(engineFields: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let legacy = """
        {"schemaVersion":1,"searchTemplate":"https://duckduckgo.com/?q=%s",\(engineFields),
        "autoArchiveAfterHours":24,"restoreSessionOnLaunch":false,"sidebarWidth":300}
        """
        try Data(legacy.utf8).write(to: file)
        let registry = EngineRegistry()
        registry.register(.chromium) { TestEngine() }
        let services = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { services.shutdown() }
        #expect(services.model.engine.kind == .chromium)
        #expect(services.settingsWritable)
        #expect(services.issues.isEmpty)
        #expect(services.settings.searchTemplate == "https://duckduckgo.com/?q=%s")
        #expect(services.settings.autoArchiveAfterHours == 24)
        #expect(!services.settings.restoreSessionOnLaunch)
        #expect(services.settings.sidebarWidth == 300)

        services.settings.sidebarWidth = 320
        try services.flush()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["engineKind"] as? String == "chromium")
        #expect(saved["engineKindIsExplicit"] == nil)
        let reloaded = try Settings.load(from: file)
        #expect(reloaded.sidebarWidth == 320)
        #expect(reloaded.autoArchiveAfterHours == 24)
        #expect(!reloaded.restoreSessionOnLaunch)
    }

    @Test func freshInstallBootstrapsChromium() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(.chromium) { TestEngine() }
        let services = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { services.shutdown() }
        #expect(services.model.engine.kind == .chromium)
        #expect(services.issues.isEmpty)
    }

    @Test func bootstrapFailsClearlyWithoutChromiumAndLeavesSavedSettingsUntouched() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let saved = Data(#"{"schemaVersion":1,"searchTemplate":"https://duckduckgo.com/?q=%s","engineKind":"webkit","autoArchiveAfterHours":24,"restoreSessionOnLaunch":false,"sidebarWidth":300}"#.utf8)
        try saved.write(to: file)
        do {
            _ = try BrowserServices.bootstrap(registry: EngineRegistry(), directory: directory)
            Issue.record("Bootstrap must fail when Chromium is not registered.")
        } catch {
            #expect(error.localizedDescription.contains("Chromium"))
            #expect(!error.localizedDescription.localizedCaseInsensitiveContains("webkit"))
        }
        #expect(try Data(contentsOf: file) == saved)
    }

    @Test func newTabAndEditAddressAreDistinct() {
        let model = BrowserModel(engine: TestEngine())
        let services = BrowserServices(model: model)
        services.newTab()
        let first = model.selectedTabID
        #expect(model.selectedSpace.tabs.count == 1)
        services.focusAddress()
        #expect(model.selectedSpace.tabs.count == 1)
        #expect(model.selectedTabID == first)
        #expect(services.addressFocusRequest == 2)
        services.newTab()
        #expect(model.selectedSpace.tabs.count == 2)
        #expect(model.selectedTabID != first)
    }

    @Test(arguments: [false, true])
    func mostRecentSpaceConsidersOrdinaryAndPinnedTabs(pinned: Bool) {
        let tabs = [10.0, 30.0, 20.0].map { TabItem(lastActiveAt: Date(timeIntervalSince1970: $0)) }
        let recent = Space(name: "Recent", pinned: pinned ? tabs : [], tabs: pinned ? [] : tabs)
        let olderTab = TabItem(lastActiveAt: Date(timeIntervalSince1970: 25))
        let older = Space(name: "Older", pinned: pinned ? [] : [olderTab], tabs: pinned ? [olderTab] : [])
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [Space(name: "Empty first"), older, recent, Space(name: "Empty last")],
            selectedSpaceID: older.id))
        let services = BrowserServices(model: model)

        #expect(services.mostRecentSpaceID == recent.id)
        #expect(model.selectedSpace.id == older.id)
    }

    @Test func mostRecentSpaceIgnoresArchivedTabs() {
        let active = Space(name: "Active", tabs: [TabItem(lastActiveAt: Date(timeIntervalSince1970: 20))])
        let archived = Space(name: "Archived", archive: [TabItem(lastActiveAt: Date(timeIntervalSince1970: 30))])
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [archived, active], selectedSpaceID: archived.id))
        let services = BrowserServices(model: model)

        #expect(services.mostRecentSpaceID == active.id)
    }

    @Test func mostRecentSpaceKeepsFirstSpaceWhenActivityTies() {
        let date = Date(timeIntervalSince1970: 20)
        let first = Space(name: "First", tabs: [TabItem(lastActiveAt: date)])
        let second = Space(name: "Second", pinned: [TabItem(lastActiveAt: date)])
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [first, second], selectedSpaceID: second.id))
        let services = BrowserServices(model: model)

        #expect(services.mostRecentSpaceID == first.id)
    }

    @Test func mostRecentSpaceKeepsFirstSpaceWhenAllSpacesAreEmpty() {
        let first = Space(name: "First")
        let second = Space(name: "Second")
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [first, second], selectedSpaceID: second.id))
        let services = BrowserServices(model: model)

        #expect(services.mostRecentSpaceID == first.id)
    }

    @Test(arguments: [LinkDestination.mostRecent, .quickWindow, .space(UUID())])
    func externalLinksUseMostRecentSpaceForFallbackDestinations(destination: LinkDestination) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Space(name: "Older", tabs: [TabItem(lastActiveAt: Date(timeIntervalSince1970: 10))])
        let recent = Space(name: "Recent", pinned: [TabItem(lastActiveAt: Date(timeIntervalSince1970: 20))])
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [older, recent], selectedSpaceID: older.id))
        let services = BrowserServices(model: model, directory: directory)
        try services.linkRules.update(rules: [], defaultDestination: destination, peekEnabled: true)
        let url = try #require(URL(string: "https://example.com/external"))

        services.openExternalLink(url)

        #expect(model.selectedSpace.id == recent.id)
        #expect(model.selectedTab?.url == url)
        #expect(model.workspace.spaces[0].tabs.count == 1)
        #expect(model.workspace.spaces[1].tabs.count == 1)
    }

    @Test func externalLinksHonorExplicitSpaceInsteadOfMostRecent() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = Space(name: "Destination")
        let recent = Space(name: "Recent", tabs: [TabItem(lastActiveAt: Date(timeIntervalSince1970: 20))])
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(
            spaces: [destination, recent], selectedSpaceID: recent.id))
        let services = BrowserServices(model: model, directory: directory)
        let rule = LinkRule(text: "example.com", destination: .space(destination.id))
        try services.linkRules.update(rules: [rule], defaultDestination: .mostRecent, peekEnabled: true)
        let url = try #require(URL(string: "https://example.com/external"))

        services.openExternalLink(url)

        #expect(model.selectedSpace.id == destination.id)
        #expect(model.selectedTab?.url == url)
        #expect(model.workspace.spaces[0].tabs.count == 1)
        #expect(model.workspace.spaces[1].tabs.count == 1)
    }

    @Test func splitUsesAnotherTabOrCreatesOneAndTogglesOff() {
        let model = BrowserModel(engine: TestEngine())
        let services = BrowserServices(model: model)
        let original = model.newTab()
        services.toggleSplit()
        #expect(model.splitTabIDs.count == 2)
        #expect(model.splitTabIDs.first == original)
        #expect(model.selectedTabID == original)
        #expect(model.selectedSpace.tabs.count == 2)
        services.toggleSplit()
        #expect(model.splitTabIDs.isEmpty)
        #expect(model.selectedSpace.tabs.count == 2)
    }

    @Test func closeCommandBarDoesNotClosePage() {
        let model = BrowserModel(engine: TestEngine())
        let services = BrowserServices(model: model)
        model.newTab()
        services.commandBarPresented = true
        services.closeTab()
        #expect(!services.commandBarPresented)
        #expect(model.selectedSpace.tabs.count == 1)
        services.closeTab()
        #expect(model.selectedSpace.tabs.isEmpty)
    }

    @Test func liveSettingsPropagateAndNeverDisablesAutoArchive() {
        let old = TabItem(title: "Old", lastActiveAt: Date(timeIntervalSince1970: 0))
        let active = TabItem(title: "Active")
        let model = BrowserModel(engine: TestEngine(), workspace: Workspace(spaces: [
            Space(name: "Home", tabs: [old, active], selectedTabID: active.id),
        ]))
        let settings = Settings()
        let services = BrowserServices(model: model, settings: settings)
        settings.autoArchiveAfterHours = 0
        settings.searchTemplate = "https://example.com/?q=%s"
        services.applySettings()
        #expect(model.selectedSpace.archive.isEmpty)
        #expect(model.searchTemplate == settings.searchTemplate)
        settings.autoArchiveAfterHours = 12
        services.applySettings()
        #expect(model.selectedSpace.archive.map(\.id) == [old.id])
        #expect(model.selectedSpace.tabs.map(\.id) == [active.id])
    }

    @Test func zoomFindAndScriptRefreshReachEngine() {
        let engine = TestEngine()
        let model = BrowserModel(engine: engine)
        let services = BrowserServices(model: model)
        model.newTab()
        services.setZoom(100)
        #expect(engine.tabs[0].zoom == 5)
        services.setZoom(-1)
        #expect(engine.tabs[0].zoom == 0.25)
        services.findQuery = "found"; services.find()
        #expect(services.findResult == true)
        services.closeFind()
        #expect(engine.tabs[0].lastFind == nil)
        model.userScriptProvider = { _ in [.init(id: "test", source: "void 0")] }
        services.refreshBoosts()
        #expect(engine.tabs[0].scripts.count == 1)
        #expect(engine.tabs[0].reloadCount == 1)
    }

    @Test func clearingSiteDataCoversEachUniqueProfile() async {
        let engine = TestEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [
            Space(name: "Work", profileID: "work"), Space(name: "Home", profileID: "home"),
        ]))
        let services = BrowserServices(model: model)
        await services.clearSiteData()
        #expect(Set(engine.clearedProfiles) == ["work", "home"])
        #expect(!services.privacyBusy)
        services.shutdown()
        #expect(engine.stopped)
    }

    @Test func clearingASpaceAndSiteUsesTheFineGrainedEngineAPI() async {
        let engine = SiteDataTestEngine()
        let work = Space(name: "Work", profileID: "work")
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [work, Space(name: "Home", profileID: "home")]))
        let services = BrowserServices(model: model)
        await services.clearSiteData(kinds: [.cookies, .storage], site: "example.com", spaceIDs: [work.id])
        #expect(engine.cleared.count == 1)
        #expect(engine.cleared[0].profile == "work" && engine.cleared[0].site == "example.com")
        #expect(engine.cleared[0].kinds == [.cookies, .storage])
        #expect(services.siteDataNotice == nil && !services.privacyBusy)

        engine.failures = ["partial"]
        await services.clearSiteData()
        #expect(Set(engine.cleared.dropFirst().map(\.profile)) == ["work", "home"])
        #expect(services.siteDataNotice == "partial")
        #expect(services.issues.isEmpty)
    }

    @Test func orphanCollectionKeepsEverySpaceProfileAndNeedsAReadableWorkspace() {
        let engine = SiteDataTestEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [
            Space(name: "Work", profileID: "work"), Space(name: "Home", profileID: "home")]))
        let services = BrowserServices(model: model)
        services.removeOrphanProfiles()
        #expect(engine.orphanCalls == [["work", "home"]])
    }

    @Test func contentBlockingConfigurationReachesTheEngine() throws {
        let engine = SiteDataTestEngine()
        let services = BrowserServices(model: BrowserModel(engine: engine))
        services.contentBlocking.onChange = { services.contentBlockingDidChange() }
        try services.contentBlocking.importList("ads.example.com", name: "list.txt")
        services.contentBlocking.setEnabled(true)
        services.contentBlocking.setBlocking(false, on: "news.example.com")
        #expect(engine.blocking == ContentBlockingConfiguration(
            isEnabled: true, blockedHosts: ["ads.example.com"], exemptSites: ["news.example.com"]))
        #expect(services.blockedRequestCount == 7)
    }

    @Test func errorsAreVisibleAndDeduplicated() {
        let services = BrowserServices(model: BrowserModel(engine: TestEngine()))
        services.report("Disk full", detail: "Not saved")
        services.report("Disk full", detail: "Not saved")
        #expect(services.issues.count == 1)
        services.dismissIssue(services.issues[0].id)
        #expect(services.issues.isEmpty)
    }

    @Test func nativeViewInitializersRemainAvailable() throws {
        let model = BrowserModel(engine: TestEngine())
        _ = SidebarView(model: model, showCommandBar: {})
        _ = CommandBarView(model: model, commands: { [] }, dismiss: {})
        _ = PreferencesView(model: model)
        let host = NSHostingView(rootView: BrowserView(services: BrowserServices(model: model)))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width == 1000)
        if ProcessInfo.processInfo.environment["CAIRN_UI_SNAPSHOT"] == "1" {
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/cairn-ui-preview.png")
            try data.write(to: output)
        }
    }

    @Test func corruptSavedFilesCannotBeOverwrittenByAutosaveOrExit() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/ui-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = Data("{not valid json; preserve me".utf8)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let workspaceURL = directory.appendingPathComponent("workspace.json")
        try corrupt.write(to: settingsURL)
        try corrupt.write(to: workspaceURL)
        let registry = EngineRegistry()
        registry.register(.chromium) { TestEngine() }
        let services = try BrowserServices.bootstrap(registry: registry, directory: directory)
        #expect(!services.workspaceWritable)
        #expect(!services.settingsWritable)
        #expect(services.issues.contains { $0.title == "Session recovery required" })
        services.newTab()
        services.settings.sidebarWidth = 300
        services.saveSettings()
        try services.flush()
        services.shutdown()
        #expect(try Data(contentsOf: settingsURL) == corrupt)
        #expect(try Data(contentsOf: workspaceURL) == corrupt)
    }

    @Test func moduleJavaScriptRequiresSourceReviewBeforeExecution() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-module-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {"schemaVersion":1,"id":"local.review","name":"Review","version":"1","commands":[
        {"id":"run","title":"Reviewed Command","action":{"type":"javaScript","source":"document.title = 'Reviewed';"}}
        ]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("review.json"))
        let registry = ModuleRegistry()
        try registry.loadUserModules(from: directory)
        let engine = TestEngine()
        let model = BrowserModel(engine: engine)
        model.newTab(url: URL(string: "https://example.com"))
        let services = BrowserServices(model: model, directory: directory, registry: registry)
        let command = try #require(services.commands().first { $0.id == "local.review.run" })
        command.perform(model)
        #expect(services.sheet == .moduleTrust)
        #expect(engine.tabs[0].evaluations.isEmpty)
        #expect(!registry.isJavaScriptTrusted(for: command.id))
        let review = try #require(services.moduleReview)
        #expect(review.source == "document.title = 'Reviewed';")
        try review.allow()
        #expect(registry.isJavaScriptTrusted(for: command.id))
        #expect(!engine.tabs[0].evaluations.isEmpty)
        services.shutdown()
        #expect(!registry.isJavaScriptTrusted(for: command.id))
    }

    @Test func boostPermissionChangesRefreshAndReloadExistingPages() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-boost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = TestEngine()
        let model = BrowserModel(engine: engine)
        let services = BrowserServices(model: model, directory: directory)
        let boost = Boost(name: "Local style", hostPatterns: ["example.com"], css: "body { color: teal; }", js: "window.reviewed = true;")
        try services.boosts.add(boost)
        model.userScriptProvider = { services.boosts.scripts(for: $0) }
        model.newTab(url: URL(string: "https://example.com"))
        #expect(!engine.tabs[0].scripts[0].source.contains("window.reviewed = true"))
        try services.boosts.setJavaScriptTrusted(true, for: boost.id)
        services.refreshBoosts()
        #expect(engine.tabs[0].scripts[0].source.contains("window.reviewed = true"))
        #expect(engine.tabs[0].reloadCount == 1)
        try services.boosts.setJavaScriptTrusted(false, for: boost.id)
        services.refreshBoosts()
        #expect(!engine.tabs[0].scripts[0].source.contains("window.reviewed = true"))
        #expect(engine.tabs[0].reloadCount == 2)
        model.userScriptProvider = nil
    }

    @Test func draggingBeforeLaterTabAdjustsForRemovedSource() throws {
        let model = BrowserModel(engine: TestEngine())
        let first = model.newTab()
        model.newTab()
        let last = model.newTab()
        let index = TabDrop.insertionIndex(source: model.locate(first), target: model.locate(last))
        #expect(index == 1)
        model.moveTab(first, to: .today, at: index)
        #expect(model.selectedSpace.tabs[1].id == first)
        #expect(model.selectedSpace.tabs[2].id == last)
        #expect(TabDrop.insertionIndex(source: model.locate(last), target: nil) == nil)
    }

    @Test func bootstrapWiresHistoryAutosaveSettingsAndScripts() async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = TestEngine()
        let registry = EngineRegistry()
        registry.register(.chromium) { engine }
        let services = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { services.shutdown() }
        #expect(services.issues.isEmpty)
        #expect(services.model.selectedSpace.colorHex == "#527B72")
        let url = try #require(URL(string: "https://example.com/docs"))
        let id = services.model.newTab(url: url)
        let tab = try #require(services.model.liveTab(for: id))
        services.model.engineTab(tab, didChange: .init(url: url, title: "Local docs", isLoading: true))
        services.model.engineTab(tab, didChange: .init(url: url, title: "Local docs", isLoading: false))
        #expect(try services.history?.recent().first?.title == "Local docs")
        try await Task.sleep(for: .milliseconds(450))
        let saved = try #require(try WorkspaceStore(directory: directory).load())
        #expect(saved.spaces[0].tabs.first?.id == id)
        services.settings.searchTemplate = "https://www.bing.com/search?q=%s"
        services.settings.sidebarWidth = 320
        services.settings.autoArchiveAfterHours = 0
        services.saveSettings()
        #expect(services.model.searchTemplate == services.settings.searchTemplate)
        let settings = try Settings.load(from: directory.appendingPathComponent("settings.json"))
        #expect(settings.sidebarWidth == 320)
        #expect(settings.autoArchiveAfterHours == 0)
        let boost = Boost(name: "Readable", hostPatterns: ["example.com"], css: "body { line-height: 1.8; }")
        try services.boosts.add(boost)
        services.refreshBoosts()
        #expect(engine.tabs[0].scripts.contains { $0.source.contains("line-height: 1.8") })
        services.model.downloadHandler?(URL(fileURLWithPath: "/not-a-web-download"), nil)
        #expect(services.sheet == .downloads)
        #expect(services.downloads.items.last?.status == .failed)
        #expect(services.issues.contains { $0.title == "Download could not finish" })
        try services.flush()
        let reloaded = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { reloaded.shutdown() }
        #expect(reloaded.model.selectedTabID == id)
        #expect(reloaded.model.selectedTab?.url == url)
    }

    @Test func disablingOrdinaryTabRestoreKeepsPermanentWorkspace() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pin = TabItem(url: URL(string: "https://example.com"), title: "Pin")
        let ordinary = TabItem(title: "Ordinary")
        let favorite = TabItem(title: "Favorite")
        let archived = TabItem(title: "Archive")
        let space = Space(name: "Writing", pinned: [pin], tabs: [ordinary], archive: [archived], selectedTabID: ordinary.id)
        try WorkspaceStore(directory: directory).saveNow(Workspace(spaces: [space], favorites: [favorite]))
        let settings = Settings()
        settings.restoreSessionOnLaunch = false
        try settings.save(to: directory.appendingPathComponent("settings.json"))
        let registry = EngineRegistry()
        registry.register(.chromium) { TestEngine() }
        let services = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { services.shutdown() }
        #expect(services.model.selectedSpace.id == space.id)
        #expect(services.model.selectedSpace.pinned == [pin])
        #expect(services.model.selectedSpace.archive == [archived])
        #expect(services.model.workspace.favorites == [favorite])
        #expect(services.model.selectedSpace.tabs.isEmpty)
        #expect(services.model.selectedTabID == nil)
    }
}

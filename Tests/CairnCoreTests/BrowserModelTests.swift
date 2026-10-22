import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class FakeEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [FakeTab] = []
    var configurations: [EngineConfiguration] = []
    var initialURLs: [URL?] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        configurations.append(configuration)
        initialURLs.append(initialURL)
        let tab = FakeTab()
        tabs.append(tab)
        if let initialURL { tab.load(initialURL) }
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class FakeTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    var scripts: [EngineUserScript] = []
    var scriptsRegistered = false
    var readyAtLoad = false
    var closed = false
    func load(_ url: URL) {
        readyAtLoad = delegate != nil && scriptsRegistered
        emit(EngineTabState(url: url, isLoading: true, progress: 0))
    }
    func emit(_ state: EngineTabState) { self.state = state; delegate?.engineTab(self, didChange: state) }
    func goBack() {}
    func goForward() {}
    var reloads = 0
    func reload(ignoringCache: Bool) { reloads += 1 }
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) { self.scripts = scripts; scriptsRegistered = true }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { closed = true }
}

@Suite @MainActor struct BrowserModelTests {
    @Test(arguments: ["a", "👩🏽‍💻"])
    func oversizedEngineTitlesRemainSaveable(glyph: String) throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url, debounce: .seconds(60))
        let model = BrowserModel(engine: FakeEngine())
        let url = URL(string: "https://example.com")!
        let id = model.newTab(url: url)
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        try store.saveNow(model.workspace)
        model.onChange = { [weak model] in
            if let model { store.scheduleSave(model.workspace) }
        }

        tab.emit(EngineTabState(url: url, title: String(repeating: glyph, count: 32_769), progress: 1))

        #expect(model.item(id)?.title.count == 32_768)
        #expect(model.tabStates[id]?.title.count == 32_768)
        try store.flush()
        #expect(try store.load()?.spaces[0].tabs[0].title.count == 32_768)
        model.moveTab(id, to: .archive)
        try store.flush()
        #expect(try store.load()?.spaces[0].archive[0].title.count == 32_768)
    }

    @Test func customTitleSurvivesPageUpdatesArchiveAndSessionRestore() throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url)
        let model = BrowserModel(engine: FakeEngine())
        let url = URL(string: "https://example.com")!
        let id = model.newTab(url: url)
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        tab.emit(EngineTabState(url: url, title: "Original page", progress: 1))
        model.renameTab(id, title: "  My reference  ")
        var committedTitle: String?
        model.onNavigationCommitted = { _, title in committedTitle = title }

        tab.load(url)
        tab.emit(EngineTabState(url: url, title: "Updated page", progress: 1))
        #expect(model.item(id)?.customTitle == "My reference")
        #expect(model.item(id)?.displayTitle == "My reference")
        #expect(model.item(id)?.title == "Updated page")
        #expect(committedTitle == "Updated page")

        model.moveTab(id, to: .archive)
        try store.saveNow(model.workspace)
        let restored = BrowserModel(engine: FakeEngine(), workspace: try #require(try store.load()))
        #expect(restored.item(id)?.displayTitle == "My reference")
        restored.select(id)
        let restoredTab = try #require(restored.liveTabs[id] as? FakeTab)
        restoredTab.emit(EngineTabState(url: url, title: "Restored page", progress: 1))
        #expect(restored.item(id)?.customTitle == "My reference")
        #expect(restored.item(id)?.displayTitle == "My reference")
        #expect(restored.item(id)?.title == "Restored page")
        try store.saveNow(restored.workspace)
        #expect(try store.load()?.spaces[0].tabs[0].customTitle == "My reference")

        restored.renameTab(id, title: nil)
        #expect(restored.item(id)?.customTitle == nil)
        #expect(restored.item(id)?.displayTitle == "Restored page")
        try store.saveNow(restored.workspace)
        #expect(try store.load()?.spaces[0].tabs[0].customTitle == nil)
    }

    @Test(arguments: [TabList.favorites, .pinned, .today, .archive])
    func renameUpdatesEveryListAndFiresPersistenceHook(list: TabList) throws {
        let model = BrowserModel(engine: FakeEngine())
        let id = model.newTab(url: URL(string: "https://example.com")!)
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        tab.emit(EngineTabState(url: tab.state.url, title: "Page title", progress: 1))
        model.moveTab(id, to: list)
        var changes = 0
        model.onChange = { changes += 1 }

        model.renameTab(id, title: "Saved name")
        #expect(model.item(id)?.displayTitle == "Saved name")
        #expect(model.item(id)?.title == "Page title")
        #expect(changes == 1)
        model.renameTab(id, title: " \n ")
        #expect(model.item(id)?.customTitle == nil)
        #expect(model.item(id)?.displayTitle == "Page title")
        #expect(changes == 2)
        model.renameTab(UUID(), title: "Missing tab")
        model.renameTab(id, title: nil)
        #expect(changes == 2)
        try model.workspace.validate()
    }

    @Test func oversizedCustomNamesAreBoundedBeforePersistence() throws {
        let directory = try TestDirectory()
        let model = BrowserModel(engine: FakeEngine())
        let id = model.newTab()
        model.renameTab(id, title: String(repeating: "n", count: TabItem.maximumTitleLength + 1))
        #expect(model.item(id)?.customTitle?.count == TabItem.maximumTitleLength)
        try WorkspaceStore(directory: directory.url).saveNow(model.workspace)
    }

    @Test func delegateScriptsAndReverseMappingPrecedeFirstLoad() throws {
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine)
        let script = EngineUserScript(id: "test", source: "void 0")
        model.userScriptProvider = { _ in [script] }
        let id = model.newTab(url: URL(string: "https://example.com")!)
        let tab = try #require(engine.tabs.first)
        #expect(engine.initialURLs.allSatisfy { $0 == nil })
        #expect(tab.readyAtLoad)
        #expect(tab.scripts == [script])
        #expect(model.tabStates[id]?.isLoading == true)
    }

    @Test func favoritesNeverReuseAnotherSpacesCookieSession() throws {
        let favorite = TabItem(url: URL(string: "https://example.com")!)
        let first = Space(name: "One", profileID: "one", selectedTabID: favorite.id)
        let second = Space(name: "Two", profileID: "two", selectedTabID: favorite.id)
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [first, second], favorites: [favorite]))
        model.select(favorite.id)
        let original = try #require(engine.tabs.last)
        model.selectSpace(second.id)
        let replacement = try #require(engine.tabs.last)
        #expect(original !== replacement)
        #expect(original.closed)
        #expect(original.delegate == nil)
        #expect(engine.configurations.map(\.profileID) == ["one", "two"])
        #expect(model.liveTabs.count == 1)
        model.selectSpace(first.id)
        #expect(replacement.closed)
        #expect(engine.configurations.last?.profileID == "one")
    }

    @Test func globalFavoriteRemovalRepairsEverySpaceSelection() throws {
        let favorite = TabItem(url: URL(string: "https://example.com")!)
        let a = TabItem()
        let b = TabItem()
        let first = Space(name: "One", tabs: [a], selectedTabID: favorite.id)
        let second = Space(name: "Two", tabs: [b], selectedTabID: favorite.id)
        let model = BrowserModel(engine: FakeEngine(), workspace: Workspace(spaces: [first, second], favorites: [favorite]))
        model.removeTab(favorite.id)
        #expect(model.workspace.spaces[0].selectedTabID == a.id)
        #expect(model.workspace.spaces[1].selectedTabID == b.id)
        try model.workspace.validate()
    }

    @Test func movingSelectedAndSplitTabsRepairsSourceReferences() throws {
        let a = TabItem()
        let b = TabItem()
        let first = Space(name: "One", tabs: [a, b], selectedTabID: a.id)
        let second = Space(name: "Two")
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [first, second]))
        model.select(a.id)
        model.splitSelected(with: b.id)
        #expect(model.splitTabIDs.count == 2)
        let movedLive = try #require(model.liveTabs[b.id] as? FakeTab)
        model.moveTab(b.id, to: .today, in: second.id)
        #expect(model.splitTabIDs.isEmpty)
        #expect(movedLive.closed)
        model.moveTab(a.id, to: .today, in: second.id)
        #expect(model.workspace.spaces[0].selectedTabID == nil)
        #expect(model.selectedSpace.id == first.id)
        try model.workspace.validate()
    }

    @Test func selectingArchiveRestoresAndLoadsIt() throws {
        let archived = TabItem(url: URL(string: "https://example.com")!)
        let space = Space(name: "One", archive: [archived])
        let model = BrowserModel(engine: FakeEngine(), workspace: Workspace(spaces: [space]))
        #expect(model.liveTab(for: archived.id) == nil)
        model.select(archived.id)
        #expect(model.locate(archived.id)?.list == .today)
        #expect(model.selectedTabID == archived.id)
        #expect(model.liveTabs[archived.id] != nil)
        try model.workspace.validate()
    }

    @Test func closingPinnedAndFavoriteTabsRetainsMetadataWithoutReopening() throws {
        let pinned = TabItem(url: URL(string: "https://example.com")!)
        let favorite = TabItem(url: URL(string: "https://favorite.example")!)
        let space = Space(name: "One", pinned: [pinned], selectedTabID: pinned.id)
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [space], favorites: [favorite]))
        model.select(pinned.id)
        let original = try #require(model.liveTabs[pinned.id] as? FakeTab)
        var changes = 0
        model.onChange = { changes += 1 }
        model.closeTab(pinned.id)
        #expect(model.locate(pinned.id)?.list == .pinned)
        #expect(model.selectedTabID == favorite.id)
        #expect(model.liveTabs[pinned.id] == nil)
        #expect(original.closed)
        #expect(changes == 1)
        model.removeTab(pinned.id)
        model.select(favorite.id)
        model.closeTab(favorite.id)
        #expect(model.locate(favorite.id)?.list == .favorites)
        #expect(model.selectedTabID == nil)
        #expect(model.liveTabs[favorite.id] == nil)
        try model.workspace.validate()
    }

    @Test func splitCannotCrossSpacesAndRemovalClosesSplit() throws {
        let a = TabItem()
        let b = TabItem()
        let c = TabItem()
        let first = Space(name: "One", tabs: [a, b], selectedTabID: a.id)
        let second = Space(name: "Two", tabs: [c], selectedTabID: c.id)
        let model = BrowserModel(engine: FakeEngine(), workspace: Workspace(spaces: [first, second]))
        model.splitSelected(with: c.id)
        #expect(model.splitTabIDs.isEmpty)
        model.splitSelected(with: b.id)
        model.removeTab(b.id)
        #expect(model.splitTabIDs.isEmpty)
        model.selectSpace(second.id)
        model.removeSpace(second.id)
        #expect(model.selectedSpace.id == first.id)
        #expect(model.splitTabIDs.isEmpty)
        #expect(model.liveTabs[c.id] == nil)
        try model.workspace.validate()
    }

    @Test func popupUsesOriginatingSpaceEvenWhenInactive() throws {
        let a = TabItem()
        let first = Space(name: "One", profileID: "first", tabs: [a], selectedTabID: a.id)
        let second = Space(name: "Two", profileID: "second")
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [first, second]))
        let origin = try #require(model.liveTab(for: a.id))
        model.selectSpace(second.id)
        model.engineTab(origin, requestsNewTab: URL(string: "https://example.com/popup")!, activate: false)
        #expect(model.workspace.spaces[0].tabs.count == 2)
        #expect(model.workspace.spaces[1].tabs.isEmpty)
        #expect(model.selectedSpace.id == second.id)
        #expect(engine.configurations.last?.profileID == "first")
        model.engineTab(origin, requestsNewTab: URL(string: "https://example.com/active")!, activate: true)
        #expect(model.selectedSpace.id == first.id)
        #expect(engine.configurations.last?.profileID == "first")
    }

    @Test func failedLoadsAreNotRecordedAndErrorsAreSurfaced() throws {
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine)
        var commits: [URL] = []
        var errors = 0
        model.onNavigationCommitted = { url, _ in commits.append(url) }
        model.onError = { _ in errors += 1 }
        let url = URL(string: "https://example.com")!
        let id = model.newTab(url: url)
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        tab.emit(EngineTabState(url: url, isLoading: false, errorMessage: "Offline"))
        #expect(commits.isEmpty)
        #expect(errors == 1)
        tab.load(url)
        tab.emit(EngineTabState(url: url, title: "Success", isLoading: false, progress: 1))
        tab.emit(tab.state)
        #expect(commits == [url])
        model.load(URL(string: "javascript:alert(1)")!, in: id)
        #expect(tab.state.url == url)
        #expect(errors == 2)
    }

    @Test func activeSplitTabsAreNotAutoArchived() throws {
        let old = Date(timeIntervalSince1970: 0)
        let a = TabItem(lastActiveAt: old)
        let b = TabItem(lastActiveAt: old)
        let c = TabItem(lastActiveAt: old)
        let space = Space(name: "One", tabs: [a, b, c], selectedTabID: a.id)
        let model = BrowserModel(engine: FakeEngine(), workspace: Workspace(spaces: [space]))
        model.splitSelected(with: b.id)
        model.archiveStaleTabs(olderThan: 10)
        #expect(model.locate(a.id)?.list == .today)
        #expect(model.locate(b.id)?.list == .today)
        #expect(model.locate(c.id)?.list == .archive)
        try model.workspace.validate()
    }

    @Test func scriptsRefreshOnExplicitNavigationAndProfileEditsDiscardLiveTabs() throws {
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine)
        model.userScriptProvider = { url in [EngineUserScript(id: url?.host ?? "blank", source: "void 0")] }
        let id = model.newTab(url: URL(string: "https://one.example")!)
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        model.load(URL(string: "https://two.example")!, in: id)
        #expect(tab.scripts.first?.id == "two.example")
        model.updateSpace(model.selectedSpace.id) { $0.profileID = "replacement" }
        #expect(tab.closed)
        #expect(model.liveTabs[id] == nil)
        _ = model.liveTab(for: id)
        #expect(engine.configurations.last?.profileID == "replacement")
    }
}

@Suite @MainActor struct BrowserModelRecoveryTests {
    private static let crash = EngineTabHealth.crashed(reason: "crashed", code: 5)

    private func makeModel() throws -> (BrowserModel, FakeEngine, UUID, UUID) {
        let a = TabItem(url: URL(string: "https://example.com/a")), b = TabItem(url: URL(string: "https://example.com/b"))
        let model = BrowserModel(engine: FakeEngine(),
                                 workspace: Workspace(spaces: [Space(name: "S", tabs: [a, b], selectedTabID: a.id)]))
        _ = model.liveTab(for: a.id)
        return (model, model.engine as! FakeEngine, a.id, b.id)
    }

    @Test func firstCrashReloadsTheVisibleTabSecondShowsBannerThirdStopsReloading() throws {
        let (model, _, id, _) = try makeModel()
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        var now = Date(timeIntervalSince1970: 1_000)
        model.recoveryClock = { now }

        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(tab.reloads == 1)
        #expect(model.tabHealth[id] == nil)

        now += 5
        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(tab.reloads == 1)
        #expect(model.tabHealth[id] == Self.crash)

        now += 5
        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(tab.reloads == 1)
        #expect(model.tabHealth[id] == Self.crash)

        now += RecoveryPolicy.window + 1
        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(tab.reloads == 2)
    }

    @Test func manualRecoveryReloadsAndResetsTheCrashLoopGuard() throws {
        let (model, _, id, _) = try makeModel()
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        model.engineTab(tab, healthDidChange: Self.crash)
        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(model.tabHealth[id] != nil)
        model.recoverTab(id)
        #expect(tab.reloads == 2)
        #expect(model.tabHealth[id] == nil)
        model.engineTab(tab, healthDidChange: Self.crash)
        #expect(tab.reloads == 3)
    }

    @Test func backgroundCrashDefersTheReloadUntilSelected() throws {
        let (model, engine, _, other) = try makeModel()
        model.select(other)
        let background = try #require(engine.tabs.first)
        model.engineTab(background, healthDidChange: Self.crash)
        #expect(background.reloads == 0)
        #expect(model.tabHealth[model.workspace.spaces[0].tabs[0].id] == Self.crash)
        model.select(model.workspace.spaces[0].tabs[0].id)
        #expect(background.reloads == 1)
        #expect(model.tabHealth.isEmpty)
    }

    @Test func stalledNavigationAndRecoveryNoticesClear() throws {
        let (model, _, id, _) = try makeModel()
        let tab = try #require(model.liveTabs[id] as? FakeTab)
        model.engineTab(tab, healthDidChange: .navigationStalled(hint: "Waiting"))
        #expect(model.tabHealth[id] == .navigationStalled(hint: "Waiting"))
        model.engineTab(tab, healthDidChange: .healthy)
        #expect(model.tabHealth[id] == nil)
        model.engineTab(tab, healthDidChange: .unresponsive)
        model.dismissHealthNotice(id)
        #expect(model.tabHealth[id] == nil)
    }

    @Test func bootstrapBlankNeverReplacesTheSavedURLAndTitle() throws {
        let url = URL(string: "https://example.com/saved")!
        let item = TabItem(url: url, title: "Saved")
        let model = BrowserModel(engine: FakeEngine(),
                                 workspace: Workspace(spaces: [Space(name: "S", tabs: [item], selectedTabID: item.id)]))
        let tab = try #require(model.liveTab(for: item.id) as? FakeTab)
        var saves = 0
        model.onChange = { saves += 1 }
        tab.emit(EngineTabState(url: URL(string: "about:blank"), title: "about:blank"))
        tab.emit(EngineTabState(title: "about:blank"))
        #expect(model.item(item.id)?.url == url)
        #expect(model.item(item.id)?.title == "Saved")
        #expect(saves == 0)
        let real = URL(string: "https://example.com/real")!
        tab.emit(EngineTabState(url: real, title: "Real"))
        #expect(model.item(item.id)?.url == real)
        #expect(model.item(item.id)?.title == "Real")
    }

    @Test func backgroundTabsStayLazyUntilSelected() throws {
        let engine = FakeEngine()
        let model = BrowserModel(engine: engine)
        let id = model.newTab(url: URL(string: "https://example.com/bg"), activate: false)
        #expect(engine.tabs.isEmpty)
        #expect(model.tabStates[id] == nil)
        model.select(id)
        #expect(engine.tabs.count == 1)
        #expect(engine.tabs[0].state.url?.absoluteString == "https://example.com/bg")
    }
}

@Suite struct EngineStartupTests {
    @Test(arguments: [(21, true), (24, true), (0, false), (1, false), (7, false)])
    func onlyProfileSingletonExitsAreQuiet(code: Int, quiet: Bool) {
        let outcome = EngineStartupOutcome(exitCode: code)
        if quiet { #expect(outcome == .alreadyRunning(code: Int32(code))) } else { #expect(outcome == .failed(code: code)) }
    }

    @Test func storageRootResolvesSymlinksAndIsStable() throws {
        let directory = try TestDirectory()
        let real = directory.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.file("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = try EngineStorageRoot.resolve(link.appendingPathComponent("Chromium"))
        let direct = try EngineStorageRoot.resolve(real.appendingPathComponent("Chromium"))
        #expect(resolved == direct)
        #expect(!resolved.path.contains("/link/"))
        #expect(try EngineStorageRoot.resolve(resolved) == resolved)
        var info = stat()
        #expect(stat(resolved.path, &info) == 0 && (info.st_mode & 0o777) == 0o700)
    }
}

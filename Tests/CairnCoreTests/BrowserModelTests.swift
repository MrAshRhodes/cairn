import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class FakeEngine: BrowserEngine {
    let kind = EngineKind.webkit
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
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) { self.scripts = scripts; scriptsRegistered = true }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { closed = true }
}

@Suite @MainActor struct BrowserModelTests {
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

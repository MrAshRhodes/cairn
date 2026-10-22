import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class StubEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Stub"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { StubTab() }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class StubTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() {}
}

@Suite @MainActor struct BrowserModelFolderTests {
    private func model() -> BrowserModel { BrowserModel(engine: StubEngine()) }
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func legacyWorkspaceFixtureDecodesAndRoundTrips() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/workspace-legacy-v1.json"))
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        try workspace.validate()
        #expect(workspace.spaces[0].folders == nil && workspace.spaces[0].theme == nil)
        #expect(workspace.spaces[0].pinned[0].folderID == nil)
        let reencoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(reencoded.spaces == workspace.spaces)
        let json = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        #expect(!json.contains("folders") && !json.contains("theme") && !json.contains("folderID"))
    }

    @Test func foldersGroupPinnedTabsAndSurviveSaveAndLoad() throws {
        let directory = try TestDirectory()
        let m = model()
        let folder = try #require(m.createFolder(name: "  Work  "))
        let tab = m.newTab(url: url("https://example.com"))
        m.pin(tab, toFolder: folder)
        #expect(m.folder(folder)?.name == "Work")
        #expect(m.pinnedTabs(in: folder).map(\.id) == [tab])
        #expect(m.pinnedTabs(in: nil).isEmpty)

        let store = WorkspaceStore(directory: directory.url)
        try store.saveNow(m.workspace)
        let loaded = BrowserModel(engine: StubEngine(), workspace: try #require(try store.load()))
        #expect(loaded.folder(folder)?.name == "Work")
        #expect(loaded.item(tab)?.folderID == folder)
    }

    @Test func nestingIsLimitedAndCyclesAreRefused() throws {
        let m = model()
        let a = try #require(m.createFolder(name: "A"))
        let b = try #require(m.createFolder(name: "B", parent: a))
        let c = try #require(m.createFolder(name: "C", parent: b))
        #expect(m.createFolder(name: "D", parent: c) == nil)
        #expect(m.errorMessage != nil)
        m.moveFolder(a, toParent: c)
        #expect(m.folder(a)?.parentID == nil)
        let other = try #require(m.createFolder(name: "Other"))
        m.moveFolder(other, toParent: c)
        #expect(m.folder(other)?.parentID == nil)
        m.moveFolder(c, toParent: other)
        #expect(m.folderDepth(c) == 2)
    }

    @Test func deletingAFolderUngroupsInsteadOfClosing() throws {
        let m = model()
        let outer = try #require(m.createFolder(name: "Outer"))
        let inner = try #require(m.createFolder(name: "Inner", parent: outer))
        let tab = m.newTab(url: url("https://example.com"))
        m.pin(tab, toFolder: inner)
        m.deleteFolder(inner)
        #expect(m.item(tab)?.folderID == outer)
        m.deleteFolder(outer)
        #expect(m.item(tab)?.folderID == nil)
        #expect(m.locate(tab)?.list == .pinned)
        #expect(m.selectedSpace.folders == nil)
    }

    @Test func unpinningOrMovingSpacesLeavesTheFolder() throws {
        let m = model()
        let folder = try #require(m.createFolder(name: "F"))
        let tab = m.newTab(url: url("https://example.com"))
        m.pin(tab, toFolder: folder)
        let second = m.addSpace(name: "Second")
        m.moveTab(tab, to: .pinned, in: second)
        #expect(m.item(tab)?.folderID == nil)
        #expect(m.locate(tab)?.spaceIndex == m.spaceIndex(second))
        m.selectSpace(m.workspace.spaces[0].id)
        let other = m.newTab(url: url("https://example.org"))
        m.pin(other, toFolder: folder)
        m.unpin(other)
        #expect(m.item(other)?.folderID == nil)
        m.pin(m.newTab(url: url("https://example.net")), toFolder: UUID())
        #expect(m.errorMessage != nil)
    }

    @Test func danglingAndMisplacedFolderIDsAreRepaired() throws {
        let folder = TabFolder(name: "Real")
        var pinned = TabItem(url: url("https://example.com"))
        pinned.folderID = UUID()
        var today = TabItem(url: url("https://example.org"))
        today.folderID = folder.id
        var space = Space(name: "S", pinned: [pinned], tabs: [today])
        space.folders = [folder, TabFolder(id: folder.id, name: "Duplicate"),
                         TabFolder(name: "Orphan", parentID: UUID())]
        let m = BrowserModel(engine: StubEngine(), workspace: Workspace(spaces: [space]))
        #expect(m.selectedSpace.pinned[0].folderID == nil)
        #expect(m.selectedSpace.tabs[0].folderID == nil)
        #expect(m.selectedSpace.folders?.count == 2)
        #expect(m.selectedSpace.folders?.last?.parentID == nil)
    }

    @Test func favoritesAreCappedWithAVisibleReason() {
        let m = model()
        for i in 0..<Workspace.maximumFavorites { m.favorite(m.newTab(url: url("https://example.com/\(i)"))) }
        #expect(m.workspace.favorites.count == 12)
        let extra = m.newTab(url: url("https://example.com/extra"))
        m.favorite(extra)
        #expect(m.workspace.favorites.count == 12)
        #expect(m.locate(extra)?.list == .today)
        #expect(m.errorMessage?.contains("12") == true)
        m.unfavorite(m.workspace.favorites[0].id)
        m.favorite(extra)
        #expect(m.locate(extra)?.list == .favorites)
    }

    @Test func replacePinAndDuplicateAndCollapse() throws {
        let m = model()
        let tab = m.newTab(url: url("https://example.com"))
        m.pin(tab)
        m.load(url("https://example.com/deeper"), in: tab)
        m.replacePinWithCurrentPage(tab)
        #expect(m.item(tab)?.homeURL == url("https://example.com/deeper"))
        let copy = try #require(m.duplicateTab(tab))
        #expect(m.locate(copy)?.index == (m.locate(tab)?.index ?? 0) + 1)
        #expect(m.item(copy)?.homeURL != nil)
        m.setPinnedCollapsed(true)
        #expect(m.selectedSpace.pinnedCollapsed == true)
        m.setPinnedCollapsed(false)
        #expect(m.selectedSpace.pinnedCollapsed == nil)
    }

    @Test func themesAreValidatedAndFoldersNeverAutoArchive() throws {
        let m = model()
        let id = m.selectedSpace.id
        m.updateSpace(id) { $0.theme = SpaceTheme(primaryHex: "#112233", secondaryHex: "#445566") }
        #expect(m.selectedSpace.theme?.angle == 135)
        m.updateSpace(id) { $0.theme = SpaceTheme(primaryHex: "red", secondaryHex: "#445566") }
        #expect(m.selectedSpace.theme?.primaryHex == "#112233")
        #expect(m.errorMessage != nil)
        let tab = m.newTab(url: url("https://example.com"))
        m.pin(tab)
        m.archiveStaleTabs(olderThan: 1, now: Date().addingTimeInterval(86_400))
        #expect(m.locate(tab)?.list == .pinned)
    }

    @Test func newerSchemaWorkspaceWithFoldersIsStillPreserved() throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url)
        let data = Data(#"{"schemaVersion":2,"spaces":[],"folders":[]}"#.utf8)
        try data.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.saveNow(.makeDefault()) }
        #expect(try Data(contentsOf: store.fileURL) == data)
    }
}

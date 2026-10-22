import Foundation
import Observation
import Testing
import SQLite3
@testable import CairnCore

@Suite @MainActor struct SettingsStoreTests {
    @Test func missingSettingsUseDefaultsAndRoundTrip() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let settings = try Settings.load(from: file)
        #expect(settings.engineKind == .webkit)
        #expect(settings.restoreSessionOnLaunch)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        settings.engineKind = .chromium
        settings.sidebarWidth = 320
        settings.searchTemplate = "https://example.com/search?q=%s&safe=1"
        try settings.save(to: file)
        let loaded = try Settings.load(from: file)
        #expect(loaded.engineKind == .chromium)
        #expect(loaded.sidebarWidth == 320)
        #expect(loaded.searchTemplate == settings.searchTemplate)
    }

    @Test(arguments: ["broken", "{\"schemaVersion\":42}", "{\"schemaVersion\":1}"])
    func damagedOrUnsupportedSettingsArePreserved(contents: String) throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let data = Data(contents.utf8)
        try data.write(to: file)
        #expect(throws: (any Error).self) { try Settings.load(from: file) }
        #expect(throws: (any Error).self) { try Settings().save(to: file) }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func bundledEngineDefaultDoesNotOverrideAnExplicitPreference() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let settings = try Settings.load(from: file, defaultEngineKind: .chromium)
        #expect(settings.engineKind == .chromium)
        settings.engineKind = .webkit
        try settings.save(to: file)
        #expect(try Settings.load(from: file, defaultEngineKind: .chromium).engineKind == .webkit)
    }

    @Test func legacySettingsWithoutExplicitFlagFollowTheBundledEngine() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let legacy = """
        {"schemaVersion":1,"searchTemplate":"https://duckduckgo.com/?q=%s","engineKind":"webkit",
        "autoArchiveAfterHours":24,"restoreSessionOnLaunch":false,"sidebarWidth":300}
        """
        try Data(legacy.utf8).write(to: file)
        let settings = try Settings.load(from: file, defaultEngineKind: .chromium)
        #expect(settings.engineKind == .chromium)
        #expect(!settings.engineKindIsExplicit)
        #expect(settings.searchTemplate == "https://duckduckgo.com/?q=%s")
        #expect(settings.autoArchiveAfterHours == 24)
        #expect(!settings.restoreSessionOnLaunch)
        #expect(settings.sidebarWidth == 300)
        #expect(try Settings.load(from: file, defaultEngineKind: .webkit).engineKind == .webkit)
    }

    @Test func implicitWebKitDefaultSavedByWebKitBuildDoesNotStickInChromiumBuild() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let webKitBuild = try Settings.load(from: file, defaultEngineKind: .webkit)
        webKitBuild.sidebarWidth = 320
        try webKitBuild.save(to: file)
        let chromiumBuild = try Settings.load(from: file, defaultEngineKind: .chromium)
        #expect(chromiumBuild.engineKind == .chromium)
        #expect(!chromiumBuild.engineKindIsExplicit)
        #expect(chromiumBuild.sidebarWidth == 320)
    }

    @Test func explicitEngineChoiceSurvivesEitherBuild() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let settings = try Settings.load(from: file, defaultEngineKind: .chromium)
        #expect(!settings.engineKindIsExplicit)
        var observedChange = false
        withObservationTracking { _ = settings.engineKind } onChange: { observedChange = true }
        settings.engineKind = .webkit
        #expect(observedChange)
        #expect(settings.engineKindIsExplicit)
        try settings.save(to: file)
        let webKitBuild = try Settings.load(from: file, defaultEngineKind: .webkit)
        #expect(webKitBuild.engineKind == .webkit)
        #expect(webKitBuild.engineKindIsExplicit)
        try webKitBuild.save(to: file)
        let chromiumBuild = try Settings.load(from: file, defaultEngineKind: .chromium)
        #expect(chromiumBuild.engineKind == .webkit)
        #expect(chromiumBuild.engineKindIsExplicit)
        #expect(!Settings(engineKind: .chromium).engineKindIsExplicit)
    }

    @Test func invalidSettingsCannotReplaceGoodData() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let settings = Settings()
        try settings.save(to: file)
        let before = try Data(contentsOf: file)
        settings.sidebarWidth = .nan
        #expect(throws: (any Error).self) { try settings.save(to: file) }
        settings.sidebarWidth = 260
        settings.searchTemplate = "javascript:alert('%s')"
        #expect(throws: (any Error).self) { try settings.save(to: file) }
        #expect(try Data(contentsOf: file) == before)
    }
}

@Suite @MainActor struct WorkspaceStoreTests {
    @Test func missingWorkspaceAndAtomicRoundTrip() throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url)
        #expect(try store.load() == nil)
        let workspace = Workspace.makeDefault()
        try store.saveNow(workspace)
        #expect(try store.load()?.spaces == workspace.spaces)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["workspace.json"])
    }

    @Test(arguments: ["broken", "{\"schemaVersion\":77}", "{\"schemaVersion\":1}"])
    func corruptOrNewerWorkspaceIsNeverOverwritten(contents: String) throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url)
        let data = Data(contents.utf8)
        try data.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.saveNow(.makeDefault()) }
        #expect(try Data(contentsOf: store.fileURL) == data)
    }

    @Test func validatesIdentifiersProfilesURLsAndSelections() throws {
        var workspace = Workspace.makeDefault()
        let tab = TabItem(url: URL(string: "https://example.com")!)
        workspace.spaces[0].tabs = [tab, tab]
        #expect(throws: (any Error).self) { try workspace.validate() }
        workspace.spaces[0].tabs = [tab]
        workspace.spaces[0].selectedTabID = UUID()
        #expect(throws: (any Error).self) { try workspace.validate() }
        workspace.spaces[0].selectedTabID = tab.id
        workspace.spaces.append(Space(name: "Other", profileID: "default"))
        #expect(throws: (any Error).self) { try workspace.validate() }
        workspace.spaces[1].profileID = "../traversal"
        #expect(throws: (any Error).self) { try workspace.validate() }
        workspace.spaces.removeLast()
        workspace.spaces[0].tabs[0].url = URL(string: "javascript:alert(1)")!
        #expect(throws: (any Error).self) { try workspace.validate() }
    }

    @Test func debounceKeepsNewestSnapshotAndFlushWins() async throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url, debounce: .milliseconds(30))
        var workspace = Workspace.makeDefault()
        store.scheduleSave(workspace)
        workspace.spaces[0].name = "Newest"
        store.scheduleSave(workspace)
        try await eventually { FileManager.default.fileExists(atPath: store.fileURL.path) }
        #expect(try store.load()?.spaces[0].name == "Newest")
        workspace.spaces[0].name = "Flushed"
        store.scheduleSave(workspace)
        try store.flush()
        #expect(try store.load()?.spaces[0].name == "Flushed")
        try await Task.sleep(for: .milliseconds(60))
        #expect(try store.load()?.spaces[0].name == "Flushed")
    }

    @Test func scheduledErrorsAreSurfacedWithoutDestroyingData() async throws {
        let directory = try TestDirectory()
        let store = WorkspaceStore(directory: directory.url, debounce: .milliseconds(10))
        let before = Data("corrupt".utf8)
        try before.write(to: store.fileURL)
        var reported = false
        store.onError = { _ in reported = true }
        store.scheduleSave(.makeDefault())
        try await eventually { reported }
        #expect(store.lastError != nil)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(throws: (any Error).self) { try store.flush() }
    }
}

@Suite @MainActor struct HistoryStoreTests {
    @Test func recordsPersistAndBoundedSearchIsLiteral() throws {
        let directory = try TestDirectory()
        let file = directory.file("history.sqlite")
        let history = try HistoryStore(url: file, maximumEntries: 3)
        for index in 0..<5 {
            try history.record(url: URL(string: "https://example.com/\(index)")!,
                               title: index == 3 ? "100%_literal's" : "Visit \(index)",
                               at: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(try history.recent(limit: 100).map(\.title) == ["Visit 4", "100%_literal's", "Visit 2"])
        #expect(try history.search("%_literal").count == 1)
        #expect(try history.search("' OR 1=1 --").isEmpty)
        #expect(try history.recent(limit: -1).isEmpty)
        let reopened = try HistoryStore(url: file)
        #expect(try reopened.recent().count == 3)
        try history.clear()
        #expect(try reopened.recent().isEmpty)
    }

    @Test func invalidEntriesAreRejectedWithoutMutatingHistory() throws {
        let directory = try TestDirectory()
        let history = try HistoryStore(url: directory.file("history.sqlite"))
        #expect(throws: (any Error).self) { try history.record(url: URL(string: "file:///secret")!, title: "No") }
        #expect(throws: (any Error).self) {
            try history.record(url: URL(string: "https://example.com")!, title: "No", at: Date(timeIntervalSince1970: .nan))
        }
        #expect(try history.recent().isEmpty)
    }

    @Test func corruptHistoryIsPreserved() throws {
        let directory = try TestDirectory()
        let file = directory.file("history.sqlite")
        let before = Data("not SQLite".utf8)
        try before.write(to: file)
        #expect(throws: (any Error).self) { try HistoryStore(url: file) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func newerSchemaIsPreserved() throws {
        let directory = try TestDirectory()
        let file = directory.file("history.sqlite")
        _ = try HistoryStore(url: file)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try HistoryStore(url: file) }
        #expect(try Data(contentsOf: file) == before)
    }
}

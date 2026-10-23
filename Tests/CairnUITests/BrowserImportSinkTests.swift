import AppKit
import Foundation
import SQLite3
import Testing
import CairnCore
import CairnEngineKit
@testable import CairnImport
@testable import CairnUI

@Suite(.serialized) @MainActor
struct BrowserImportSinkTests {
    @Test func missingHistoryDoesNotPublishImportedSpaces() throws {
        let model = BrowserModel(engine: ImportTestEngine())
        let before = model.workspace
        let preview = ImportPreviewForTest.make()
        #expect(throws: ServiceError.self) {
            try ImportApplier.apply(preview, to: BrowserImportSink(model: model, history: nil))
        }
        #expect(model.workspace.spaces == before.spaces && model.workspace.selectedSpaceID == before.selectedSpaceID)
    }

    @Test func historyTransactionFailureRollsBackBeforeWorkspacePublication() throws {
        let scratch = try ImportUIDirectory()
        let historyURL = scratch.file("history.sqlite")
        let history = try HistoryStore(url: historyURL)
        var database: OpaquePointer?
        #expect(sqlite3_open(historyURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, """
            CREATE TRIGGER reject_import BEFORE INSERT ON history
            BEGIN SELECT RAISE(ABORT, 'Synthetic disk failure'); END
            """, nil, nil, nil) == SQLITE_OK)
        let model = BrowserModel(engine: ImportTestEngine())
        let before = model.workspace
        #expect(throws: ServiceError.self) {
            try ImportApplier.apply(ImportPreviewForTest.make(), to: BrowserImportSink(model: model, history: history))
        }
        #expect(model.workspace.spaces == before.spaces && model.workspace.selectedSpaceID == before.selectedSpaceID)
        #expect(try history.recent().isEmpty)
    }

    @Test func workspaceValidationFailureDoesNotStoreHistory() throws {
        let scratch = try ImportUIDirectory()
        let history = try HistoryStore(url: scratch.file("history.sqlite"))
        let model = BrowserModel(engine: ImportTestEngine())
        let before = model.workspace
        let preview = ImportPreviewForTest.make(spaceName: "   ")
        #expect(throws: (any Error).self) {
            try ImportApplier.apply(preview, to: BrowserImportSink(model: model, history: history))
        }
        #expect(model.workspace.spaces == before.spaces && model.workspace.selectedSpaceID == before.selectedSpaceID)
        #expect(try history.recent().isEmpty)
    }

    @Test func historyCapacityIsPreviewedWithoutEvictingExistingVisits() throws {
        let scratch = try ImportUIDirectory()
        let history = try HistoryStore(url: scratch.file("history.sqlite"), maximumEntries: 2)
        try history.record(url: URL(string: "https://existing.example/")!, title: "Existing", at: Date(timeIntervalSince1970: 1))
        let model = BrowserModel(engine: ImportTestEngine())
        let sink = BrowserImportSink(model: model, history: history)
        let fresh = (2...3).map { ImportedHistoryEntry(url: URL(string: "https://import.example/\($0)")!,
                                                       title: "Imported", lastVisit: Date(timeIntervalSince1970: Double($0))) }
        let selection = try sink.selectHistory(fresh)
        #expect(selection.entries == [fresh[1]] && selection.skipped[.overLimit] == 1)
        _ = try sink.commit([], history: selection.entries)
        #expect(try history.recent().map(\.title) == ["Imported", "Existing"])
    }

    @Test func historyChangedAfterPreviewFailsWithoutAddingPins() throws {
        let scratch = try ImportUIDirectory()
        let history = try HistoryStore(url: scratch.file("history.sqlite"), maximumEntries: 1)
        let model = BrowserModel(engine: ImportTestEngine())
        let before = model.workspace
        let sink = BrowserImportSink(model: model, history: history)
        let preview = ImportPreviewForTest.make()
        try history.record(url: URL(string: "https://existing.example/")!, title: "Existing")
        #expect(throws: ServiceError.self) { try ImportApplier.apply(preview, to: sink) }
        #expect(model.workspace.spaces == before.spaces && model.workspace.selectedSpaceID == before.selectedSpaceID)
        #expect(try history.recent().map(\.title) == ["Existing"])
    }

    @Test func importedWorkspaceAndHistorySurviveServicesRelaunch() async throws {
        let scratch = try ImportUIDirectory()
        let registry = EngineRegistry()
        registry.register(.chromium) { ImportTestEngine() }
        let first = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        let homeProfile = first.model.selectedSpace.profileID
        let profile = scratch.file("FirefoxProfile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var sourceDatabase: OpaquePointer?
        #expect(sqlite3_open(profile.appendingPathComponent("places.sqlite").path, &sourceDatabase) == SQLITE_OK)
        defer { sqlite3_close(sourceDatabase) }
        #expect(sqlite3_exec(sourceDatabase, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER, hidden INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, fk INTEGER, title TEXT, guid TEXT, position INTEGER);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.example/', 'Mozilla', 1700000000000000, 0);
            INSERT INTO moz_bookmarks VALUES (1, 0, 2, NULL, '', 'root________', 0),
                (2, 1, 2, NULL, '', 'toolbar_____', 0), (3, 2, 1, 1, 'Mozilla', 'bookmark___1', 0);
            """, nil, nil, nil) == SQLITE_OK)
        let source = try ImportSourceDiscovery.chosen(profile)
        let plan = try await ImportScanner(staging: first.importStaging)
            .scan(ImportConsent(source: source, options: ImportOptions(history: true)))
        let preview = try ImportApplier.preview(plan, sink: first.makeImportSink())
        let result = try ImportApplier.apply(preview, to: first.makeImportSink())
        #expect(result.bookmarksAdded == 1 && result.historyAdded == 1)
        let imported = try #require(first.model.workspace.spaces.first { $0.name == "Imported from Firefox" })
        #expect(imported.profileID != homeProfile && imported.folders?.first?.name == "Bookmarks Toolbar")
        try first.flush()
        first.shutdown()

        let second = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        defer { second.shutdown() }
        let restored = try #require(second.model.workspace.spaces.first { $0.name == "Imported from Firefox" })
        #expect(restored.profileID == imported.profileID)
        #expect(restored.pinned.map(\.url) == imported.pinned.map(\.url))
        #expect(try second.history?.recent().first?.visitedAt == preview.history[0].lastVisit)
        #expect(second.issues.isEmpty)
        let repeated = try ImportApplier.preview(plan, sink: second.makeImportSink())
        #expect(repeated.isEmpty && repeated.skipped[.duplicate] == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.importStaging.root.path).isEmpty)
    }

    @Test func guidedMultiSpaceMigrationPreservesExistingDataAndRelaunches() async throws {
        let scratch = try ImportUIDirectory()
        let registry = EngineRegistry()
        registry.register(.chromium) { ImportTestEngine() }
        let first = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        let home = first.model.selectedSpace
        try first.model.importSpaces([.init(name: "Personal", pins: [.init(title: "Keep me", url: URL(string: "https://existing.example/")!)])])
        let existing = try #require(first.model.workspace.spaces.first { $0.name == "Personal" })
        let file = scratch.file("portable.html")
        try Data("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1><DL>
              <DT><H3>Work</H3><DL><DT><H3>Team</H3><DL><DT><A HREF="https://docs.example/">Docs</A></DL></DL>
              <DT><H3>Personal</H3><DL><DT><A HREF="https://home.example/">Home</A></DL>
            </DL>
            """.utf8).write(to: file)
        let source = try ImportSourceDiscovery.chosen(file)
        let original = try await ImportScanner(staging: first.importStaging).scan(ImportConsent(source: source, options: ImportOptions()))
        var mappings = ImportMigration.groups(in: original).map { MigrationMapping(group: $0) }
        mappings[1].conflict = .append
        mappings[1].keepTopLevelFolder = true
        let plan = try ImportMigration.plan(from: original, mappings: mappings, existingSpaceNames: first.model.workspace.spaces.map(\.name))
        let preview = try ImportApplier.preview(plan, sink: first.makeImportSink())
        #expect(throws: CancellationError.self) {
            try ImportApplier.apply(preview, to: first.makeImportSink(), isCancelled: { true })
        }
        #expect(!first.model.workspace.spaces.contains { $0.name == "Work" })
        #expect(first.model.workspace.spaces.first { $0.id == existing.id } == existing)
        let result = try ImportApplier.apply(preview, to: first.makeImportSink())
        #expect(result.bookmarksAdded == 2 && result.foldersAdded == 2)
        let work = try #require(first.model.workspace.spaces.first { $0.name == "Work" })
        #expect(work.profileID != home.profileID && work.profileID != existing.profileID)
        #expect(work.folders?.map(\.name) == ["Team"])
        #expect(first.model.workspace.spaces.first { $0.id == home.id } == home)
        try first.flush()
        first.shutdown()

        let second = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        defer { second.shutdown() }
        let restored = try #require(second.model.workspace.spaces.first { $0.name == "Work" })
        let personal = try #require(second.model.workspace.spaces.first { $0.name == "Personal" })
        #expect(restored.profileID == work.profileID && restored.pinned == work.pinned && restored.folders == work.folders)
        #expect(personal.profileID == existing.profileID && personal.pinned.first == existing.pinned.first)
        #expect(personal.pinned.count == 2 && personal.folders?.map(\.name) == ["Personal"])
        #expect(second.issues.isEmpty)
        mappings[0].conflict = .append
        let repeated = try ImportMigration.plan(from: original, mappings: mappings, existingSpaceNames: second.model.workspace.spaces.map(\.name))
        #expect(try ImportApplier.preview(repeated, sink: second.makeImportSink()).isEmpty)
    }

    @Test func safariScanApplyAndHistorySurviveServicesRelaunch() async throws {
        let scratch = try ImportUIDirectory()
        let registry = EngineRegistry()
        registry.register(.chromium) { ImportTestEngine() }
        let first = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        let home = first.model.selectedSpace
        let folder = scratch.file("Safari")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Children": [["WebBookmarkType": "WebBookmarkTypeList", "Title": "Favorites", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.example/", "URIDictionary": ["title": "Safari fixture"]],
        ]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("Bookmarks.plist"))
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("History.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, title TEXT, visit_time REAL);
            INSERT INTO history_items VALUES (1, 'https://safari.example/');
            INSERT INTO history_visits VALUES (1, 1, 'Safari fixture', 721692800.5);
            """, nil, nil, nil) == SQLITE_OK)
        let plan = try await ImportScanner(staging: first.importStaging).scan(ImportConsent(
            source: ImportSourceDiscovery.safariFolder(folder), options: ImportOptions(history: true)))
        let preview = try ImportApplier.preview(plan, sink: first.makeImportSink())
        let result = try ImportApplier.apply(preview, to: first.makeImportSink())
        #expect(result.bookmarksAdded == 1 && result.historyAdded == 1)
        let imported = try #require(first.model.workspace.spaces.first { $0.name == "Imported from Safari" })
        #expect(imported.profileID != home.profileID && imported.folders?.first?.name == "Favorites")
        try first.flush()
        first.shutdown()
        let second = try BrowserServices.bootstrap(registry: registry, directory: scratch.url)
        defer { second.shutdown() }
        let restored = try #require(second.model.workspace.spaces.first { $0.name == "Imported from Safari" })
        #expect(restored.profileID == imported.profileID && restored.pinned == imported.pinned)
        #expect(try second.history?.recent().first?.visitedAt == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(try ImportApplier.preview(plan, sink: second.makeImportSink()).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.importStaging.root.path).isEmpty)
    }
}

@MainActor private enum ImportPreviewForTest {
    static func make(spaceName: String = "Imported from Firefox") -> ImportPreview {
        let url = URL(string: "https://mozilla.example/")!
        return ImportPreview(spaces: [SpaceCommit(name: spaceName, isExisting: false,
                                                  pins: [ImportedBookmark(title: "Mozilla", url: url,
                                                                          folderPath: ["Bookmarks Toolbar"])],
                                                  folderCount: 1)],
                             history: [ImportedHistoryEntry(url: url, title: "Mozilla", lastVisit: Date(timeIntervalSince1970: 1_700_000_000))],
                             skipped: [:])
    }
}

private final class ImportUIDirectory {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".import-ui-test-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

@MainActor private final class ImportTestEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Import test engine"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { ImportTestTab() }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor private final class ImportTestTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    func load(_ url: URL) { state.url = url }
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

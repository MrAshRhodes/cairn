import Foundation
import SQLite3
import Testing
import CairnCore
@testable import CairnImport

@Suite struct FirefoxImportTests {
    @Test func discoveryAndProfileChoiceReadNoContent() throws {
        let scratch = try ImportScratch()
        let file = try scratch.write("not opened", as: "Firefox/Profiles/random.default-release/places.sqlite")
        _ = try scratch.write("not opened", as: "Firefox/profiles.ini")
        let fs = RecordingFileSystem()
        let sources = ImportSourceDiscovery.discover(fileSystem: fs, applicationSupport: scratch.url)
        #expect(sources.count == 1 && sources[0].format == .firefoxProfiles)
        #expect(fs.all.allSatisfy { $0.hasPrefix("exists ") })
        let source = try ImportSourceDiscovery.chosen(file.deletingLastPathComponent(), fileSystem: fs)
        #expect(source.format == .firefoxProfile && source.supportsHistory)
        #expect(ImportOptions().bookmarks && !ImportOptions().history)
        #expect(fs.reads.isEmpty)
        #expect(!fs.all.contains { $0.hasPrefix("list ") || $0.contains("profiles.ini") })
    }

    @Test func liveWALSnapshotPreservesFoldersTitlesTimesAndLeavesSourceUntouched() async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run("""
            INSERT INTO moz_bookmarks VALUES (6, 2, 2, NULL, 'Работа 📁', 'folder______', 1);
            INSERT INTO moz_places VALUES (2, 'https://example.jp/パス', '日本語', 1700000000123456, 0);
            INSERT INTO moz_bookmarks VALUES (7, 6, 1, 2, '日本語', 'bookmark___2', 0);
            INSERT INTO moz_bookmarks VALUES (8, 2, 3, NULL, NULL, 'separator___', 2);
            INSERT INTO moz_places VALUES (3, 'https://hidden.example/', 'Hidden', 1700000000000000, 1);
            INSERT INTO moz_places VALUES (4, 'about:config', 'Internal', 1700000000000000, 0);
            INSERT INTO moz_places VALUES (5, 'https://invalid.example/', 'Invalid date', -1, 0);
            """)
        _ = try scratch.write("not opened", as: "Profile/cookies.sqlite")
        _ = try scratch.write("not opened", as: "Profile/logins.json")
        _ = try scratch.write("not opened", as: "Profile/key4.db")
        let before = try fixture.sourceBytes()
        #expect(before["-wal"]?.isEmpty == false)
        let fs = RecordingFileSystem()
        let plan = try await scanner(scratch, fs: fs).scan(fixture.consent(history: true))
        #expect(plan.spaces[0].name == "Imported from Firefox")
        #expect(plan.spaces[0].bookmarks.map(\.title) == ["Mozilla", "日本語"])
        #expect(plan.spaces[0].bookmarks[1].folderPath == ["Bookmarks Toolbar", "Работа 📁"])
        #expect(plan.history.map(\.title) == ["日本語", "Mozilla"])
        #expect(plan.history[0].lastVisit == Date(timeIntervalSince1970: 1_700_000_000.123456))
        #expect(plan.skipped[.hidden] == 1 && plan.skipped[.unsupportedScheme] == 1)
        #expect(plan.skipped[.invalidDate] == 1 && plan.skipped[.unsupportedItem] == 1)
        #expect(fs.all.filter { $0.hasPrefix("snapshot ") } == ["snapshot \(fixture.url.path)"])
        #expect(!fs.all.contains { $0.contains("cookies.sqlite") || $0.contains("logins.json") || $0.contains("key4.db") })
        #expect(try fixture.sourceBytes() == before)
        try expectClean(scratch)
    }

    @Test func defaultBookmarksNeverQueryHistoryFields() async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run("ALTER TABLE moz_places DROP COLUMN last_visit_date; ALTER TABLE moz_places DROP COLUMN hidden")
        let plan = try await scanner(scratch).scan(fixture.consent())
        #expect(plan.spaces[0].bookmarks.count == 1 && plan.history.isEmpty)
        try expectClean(scratch)
    }

    @Test func historyOnlyNeverQueriesBookmarkStructure() async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run("DROP TABLE moz_bookmarks")
        let plan = try await scanner(scratch).scan(fixture.consent(bookmarks: false, history: true))
        #expect(plan.spaces.isEmpty && plan.history.count == 1)
        try expectClean(scratch)
    }

    @Test func PRTimeUsesAbsoluteMicrosecondsNotLocalTimezone() throws {
        let formatter = ISO8601DateFormatter()
        let utc = try #require(formatter.date(from: "2024-03-31T01:30:00Z"))
        let offset = try #require(formatter.date(from: "2024-03-31T03:30:00+02:00"))
        let micros = Int64(utc.timeIntervalSince1970 * 1_000_000)
        #expect(FirefoxPlaces.date(fromMicroseconds: micros) == offset)
        #expect(FirefoxPlaces.date(fromMicroseconds: 0) == nil)
        #expect(FirefoxPlaces.date(fromMicroseconds: -1) == nil)
        #expect(FirefoxPlaces.date(fromMicroseconds: Int64.max) == nil)
    }

    @Test(arguments: [
        "UPDATE moz_bookmarks SET parent = 2 WHERE id = 2",
        "UPDATE moz_bookmarks SET parent = 999 WHERE id = 5",
        "UPDATE moz_bookmarks SET type = 99 WHERE id = 5",
        "UPDATE moz_bookmarks SET fk = 999 WHERE id = 5",
        "UPDATE moz_bookmarks SET type = 'wrong' WHERE id = 5",
        "DELETE FROM moz_bookmarks WHERE id = 1",
        "DROP TABLE moz_places",
        "ALTER TABLE moz_bookmarks RENAME TO real_bookmarks; CREATE VIEW moz_bookmarks AS SELECT * FROM real_bookmarks",
    ])
    func malformedPlacesFailAndRemoveStaging(sql: String) async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run(sql)
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(fixture.consent()) }
        try expectClean(scratch)
    }

    @Test func corruptMissingAndOversizedSourcesFailWithoutLeftovers() async throws {
        let scratch = try ImportScratch()
        let source = ImportSource(id: "firefox", name: "Firefox", browser: "Firefox", format: .firefoxProfile,
                                  location: scratch.file("Profile"))
        let consent = ImportConsent(source: source, options: ImportOptions())
        await #expect(throws: (any Error).self) { try await scanner(scratch).scan(consent) }
        try expectClean(scratch)
        let database = try scratch.write("not a sqlite database", as: "Profile/places.sqlite")
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(consent) }
        try expectClean(scratch)
        let handle = try FileHandle(forWritingTo: database)
        try handle.truncate(atOffset: UInt64(ImportLimits.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: ImportError.tooLarge("places.sqlite")) { try await scanner(scratch).scan(consent) }
        try expectClean(scratch)
    }

    @Test func historyAndBookmarkBoundsCountOmissions() throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run("""
            WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x<10)
            INSERT INTO moz_places SELECT x, 'https://example.com/' || x, 'Title', 1700000000000000+x, 0 FROM n;
            WITH RECURSIVE n(x) AS (VALUES(10) UNION ALL SELECT x+1 FROM n WHERE x<\(ImportLimits.maximumBookmarks + 10))
            INSERT INTO moz_bookmarks SELECT x, 2, 1, 1, 'Extra', 'guid' || x, x FROM n;
            """)
        let staging = ImportStaging(root: scratch.file("Staging"))
        let parsed = try staging.withSQLiteSnapshot(named: "places.sqlite", from: fixture.url.deletingLastPathComponent()) {
            try FirefoxPlaces.read(databaseAt: $0, options: ImportOptions(history: true), historyLimit: 3)
        }
        #expect(parsed.bookmarks.count == ImportLimits.maximumBookmarks)
        #expect(parsed.history.count == 3)
        #expect(parsed.skipped[.overLimit] == 9) // Two bookmarks plus seven history rows.
        try expectClean(scratch)
    }

    @Test func snapshotPermissionsAllowListAndCancellationCleanup() throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        let staging = ImportStaging(root: scratch.file("Staging"))
        #expect(throws: CancellationError.self) {
            try staging.withSQLiteSnapshot(named: "places.sqlite", from: fixture.url.deletingLastPathComponent()) { file in
                let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
                let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
                #expect(mode == 0o600 && directoryMode == 0o700)
                throw CancellationError()
            }
        }
        try expectClean(scratch)
        #expect(throws: ImportError.self) {
            try staging.withSQLiteSnapshot(named: "cookies.sqlite", from: fixture.url.deletingLastPathComponent()) { _ in }
        }
        try expectClean(scratch)
        #expect(throws: CancellationError.self) {
            try FirefoxPlaces.read(databaseAt: fixture.url, isCancelled: { true })
        }
    }

    @Test func symbolicDatabaseOrWALIsRefused() throws {
        for suffix in ["", "-wal"] {
            let scratch = try ImportScratch()
            let fixture = try FirefoxFixture(scratch: scratch)
            let link = scratch.file("Chosen/places.sqlite\(suffix)")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if suffix == "-wal" {
                try FileManager.default.copyItem(at: fixture.url, to: scratch.file("Chosen/places.sqlite"))
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: fixture.url.path + suffix))
            let staging = ImportStaging(root: scratch.file("Staging"))
            #expect(throws: ImportError.self) {
                try staging.withSQLiteSnapshot(named: "places.sqlite", from: scratch.file("Chosen")) { _ in }
            }
            try expectClean(scratch)
        }
    }

    @Test @MainActor func previewApplyReimportAndCancellationAreIdempotent() async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        try fixture.run("INSERT INTO moz_bookmarks VALUES (6, 2, 1, 1, 'Duplicate', 'duplicate___', 1)")
        let plan = try await scanner(scratch).scan(fixture.consent(history: true))
        let sink = FakeSink()
        let preview = try ImportApplier.preview(plan, sink: sink)
        #expect(preview.bookmarkCount == 1 && preview.historyCount == 1 && preview.skipped[.duplicate] == 1)
        #expect(sink.spaces.isEmpty && sink.history.isEmpty)
        #expect(throws: CancellationError.self) { try ImportApplier.apply(preview, to: sink, isCancelled: { true }) }
        #expect(sink.spaces.isEmpty && sink.history.isEmpty)
        sink.failCommit = true
        #expect(throws: ImportError.self) { try ImportApplier.apply(preview, to: sink) }
        #expect(sink.spaces.isEmpty && sink.history.isEmpty)
        sink.failCommit = false
        let result = try ImportApplier.apply(preview, to: sink)
        #expect(result.bookmarksAdded == 1 && result.historyAdded == 1 && result.foldersAdded == 1)
        let repeated = try ImportApplier.preview(plan, sink: sink)
        #expect(repeated.isEmpty && repeated.skipped[.duplicate] == 3)
        try expectClean(scratch)
    }

    @Test func cancelledScanAndNextLaunchSweepCleanPrivateData() async throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner(scratch).scan(fixture.consent(history: true))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: scratch.file("Staging").path))
        _ = try scratch.write("left by interrupted import", as: "Staging/old/places.sqlite")
        try ImportStaging(root: scratch.file("Staging")).sweep()
        try expectClean(scratch)
    }

    @Test func cleanupFailureIsVisibleAndNextLaunchCanRetry() throws {
        let scratch = try ImportScratch()
        let fixture = try FirefoxFixture(scratch: scratch)
        let fs = RecordingFileSystem()
        let staging = ImportStaging(root: scratch.file("Staging"), fileSystem: fs)
        fs.failRemoval = true
        #expect(throws: ImportError.self) {
            try staging.withSQLiteSnapshot(named: "places.sqlite", from: fixture.url.deletingLastPathComponent()) { _ in }
        }
        #expect(try !FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
        #expect(throws: ImportError.self) { try staging.sweep() }
        fs.failRemoval = false
        try staging.sweep()
        try expectClean(scratch)
    }

    private func scanner(_ scratch: ImportScratch, fs: ImportFileSystem = LocalImportFileSystem()) -> ImportScanner {
        ImportScanner(fileSystem: fs, staging: ImportStaging(root: scratch.file("Staging"), fileSystem: fs))
    }

    private func expectClean(_ scratch: ImportScratch) throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }
}

private final class FirefoxFixture {
    let url: URL
    private var db: OpaquePointer?

    init(scratch: ImportScratch) throws {
        url = scratch.file("Profile/places.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ImportError.database("Cannot create synthetic Places.") }
        try run("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_date INTEGER, hidden INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, fk INTEGER, title TEXT, guid TEXT, position INTEGER);
            INSERT INTO moz_places VALUES (1, 'https://mozilla.example/', 'Mozilla', 1700000000000000, 0);
            INSERT INTO moz_bookmarks VALUES
                (1, 0, 2, NULL, '', 'root________', 0),
                (2, 1, 2, NULL, '', 'toolbar_____', 0),
                (3, 1, 2, NULL, '', 'menu________', 1),
                (4, 1, 2, NULL, '', 'unfiled_____', 2),
                (5, 2, 1, 1, 'Mozilla', 'bookmark___1', 0);
            """)
    }

    deinit { sqlite3_close(db) }

    func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ImportError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Fixture closed.")
        }
    }

    func consent(bookmarks: Bool = true, history: Bool = false) -> ImportConsent {
        ImportConsent(source: ImportSource(id: "firefox", name: "Firefox — synthetic", browser: "Firefox",
                                          format: .firefoxProfile, location: url.deletingLastPathComponent()),
                      options: ImportOptions(bookmarks: bookmarks, history: history))
    }

    func sourceBytes() throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["", "-wal"].map { ($0, try Data(contentsOf: URL(fileURLWithPath: url.path + $0))) })
    }
}

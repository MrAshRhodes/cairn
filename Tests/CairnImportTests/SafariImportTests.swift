import Foundation
import SQLite3
import Testing
@testable import CairnImport

@Suite struct SafariImportTests {
    @Test func selectionDoesNotReadContentAndDefaultsExcludeHistory() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        let fs = RecordingFileSystem()
        let source = try ImportSourceDiscovery.chosen(fixture.folder, fileSystem: fs)
        #expect(source.format == .safariFolder && source.supportsHistory && fs.reads.isEmpty)
        #expect(ImportOptions().bookmarks && !ImportOptions().history)
        let before = try Data(contentsOf: fixture.folder.appendingPathComponent("Bookmarks.plist"))
        let plan = try await scanner(scratch, fs).scan(ImportConsent(source: source, options: ImportOptions()))
        #expect(plan.spaces[0].bookmarks[0].folderPath == ["Favorites", "研究"])
        #expect(plan.spaces[0].bookmarks[0].title == "日本語")
        #expect(plan.history.isEmpty)
        #expect(fs.reads == ["read \(fixture.folder.appendingPathComponent("Bookmarks.plist").path)"])
        #expect(try Data(contentsOf: fixture.folder.appendingPathComponent("Bookmarks.plist")) == before)
        let single = try ImportSourceDiscovery.chosen(fixture.folder.appendingPathComponent("Bookmarks.plist"), fileSystem: fs)
        #expect(single.format == .safariBookmarks && !single.supportsHistory)
    }

    @Test func liveHistorySnapshotIsBoundedReadOnlyAndCleansUp() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        try fixture.run("""
            INSERT INTO history_visits VALUES (2, 1, 721692700, 'Older');
            INSERT INTO history_items VALUES (2, 'file:///private/blocked'), (3, 'https://invalid.example/');
            INSERT INTO history_visits VALUES (3, 2, 721692800, 'Local'), (4, 3, 'invalid', 'Invalid');
            """)
        for name in ["Cookies.binarycookies", "Passwords.csv", "CloudTabs.db"] {
            _ = try scratch.write("never read", as: "Safari/\(name)")
        }
        let before = try fixture.sourceBytes()
        let fs = RecordingFileSystem()
        let plan = try await scanner(scratch, fs).scan(fixture.consent(history: true))
        #expect(plan.history.count == 1 && plan.history[0].title == "Latest")
        #expect(plan.history[0].lastVisit == Date(timeIntervalSince1970: 1_700_000_000.25))
        #expect(plan.skipped[.olderVisit] == 1 && plan.skipped[.invalidDate] == 1 && plan.skipped[.unsupportedScheme] == 1)
        #expect(try fixture.sourceBytes() == before)
        #expect(fs.reads == ["read \(fixture.folder.appendingPathComponent("Bookmarks.plist").path)",
                             "snapshot \(fixture.database.path)"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func historyOnlyDoesNotReadBookmarksAndUsesAbsoluteEpoch() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        try Data("corrupt".utf8).write(to: fixture.folder.appendingPathComponent("Bookmarks.plist"))
        let fs = RecordingFileSystem()
        let plan = try await scanner(scratch, fs).scan(fixture.consent(bookmarks: false, history: true))
        #expect(plan.spaces.isEmpty && plan.history.count == 1)
        #expect(fs.reads == ["snapshot \(fixture.database.path)"])
        #expect(SafariHistory.date(fromReferenceSeconds: 0) == ISO8601DateFormatter().date(from: "2001-01-01T00:00:00Z"))
        #expect(SafariHistory.date(fromReferenceSeconds: .infinity) == nil)
        #expect(SafariHistory.date(fromReferenceSeconds: -978_307_200) == nil)
    }

    @Test(arguments: ["Bookmarks.plist", "History.db"])
    func permissionDenialShowsHTMLFallbackAndNoPartialPlan(name: String) async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        let fs = RecordingFileSystem()
        fs.deniedNames = [name]
        do {
            _ = try await scanner(scratch, fs).scan(fixture.consent(history: true))
            Issue.record("Denied Safari data must fail rather than return empty success")
        } catch {
            #expect(error.localizedDescription.contains("Safari data was not imported"))
            #expect(error.localizedDescription.contains("HTML"))
            #expect(error.localizedDescription.contains("does not change permissions"))
        }
        if FileManager.default.fileExists(atPath: scratch.file("Staging").path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
        }
        let html = try scratch.write("<DL><DT><A HREF=\"https://fallback.example/\">Fallback</A></DL>", as: "safari.html")
        let source = try ImportSourceDiscovery.chosen(html, fileSystem: fs)
        let fallback = try await scanner(scratch, fs).scan(ImportConsent(source: source, options: ImportOptions()))
        #expect(fallback.spaces[0].bookmarks.count == 1 && fallback.history.isEmpty)
    }

    @Test(arguments: [
        "DROP TABLE history_items",
        "ALTER TABLE history_visits RENAME TO visits; CREATE VIEW history_visits AS SELECT * FROM visits",
        "UPDATE history_items SET url = X'FFFF'",
    ])
    func unsupportedHistoryFailsAndCleansSnapshot(sql: String) async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        try fixture.run(sql)
        await #expect(throws: ImportError.self) {
            try await scanner(scratch).scan(fixture.consent(history: true))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func lockedDatabaseHasVisibleFailureAndLeavesSourceAlone() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        try fixture.run("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE")
        defer { try? fixture.run("ROLLBACK") }
        let bytes = try Data(contentsOf: fixture.database)
        await #expect(throws: ImportError.self) {
            try await scanner(scratch).scan(fixture.consent(history: true))
        }
        #expect(try Data(contentsOf: fixture.database) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func corruptOversizedAndSymlinkBookmarksNeverBecomeSuccess() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        let plist = fixture.folder.appendingPathComponent("Bookmarks.plist")
        try Data("not a property list".utf8).write(to: plist)
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(fixture.consent()) }
        let handle = try FileHandle(forWritingTo: plist)
        try handle.truncate(atOffset: UInt64(ImportLimits.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(fixture.consent()) }
        try FileManager.default.removeItem(at: plist)
        let target = try scratch.write("not read", as: "target")
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: target)
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(fixture.consent()) }
    }

    @Test func missingCorruptAndOversizedHistoryReportFailureAndCleanStaging() async throws {
        let scratch = try ImportScratch()
        let source = ImportSourceDiscovery.safariFolder(scratch.file("Chosen"))
        let consent = ImportConsent(source: source, options: ImportOptions(bookmarks: false, history: true))
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(consent) }
        let file = try scratch.write("not SQLite", as: "Chosen/History.db")
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(consent) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ImportLimits.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: ImportError.self) { try await scanner(scratch).scan(consent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func cleanupFailureCannotProduceAPlanAndNextLaunchRetries() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        let fs = RecordingFileSystem()
        fs.failRemoval = true
        await #expect(throws: ImportError.self) { try await scanner(scratch, fs).scan(fixture.consent(history: true)) }
        #expect(try !FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
        fs.failRemoval = false
        try ImportStaging(root: scratch.file("Staging"), fileSystem: fs).sweep()
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func plistVariantsFiltersAndBoundsAreExplicit() throws {
        let leaf: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.test/",
                                   "URIDictionary": ["title": "Title"]]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let root: [String: Any] = ["Children": [
                leaf,
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "javascript:alert(1)"],
                ["WebBookmarkType": "WebBookmarkTypeProxy"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [leaf]],
            ]]
            let parsed = try SafariBookmarks.parse(PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0))
            #expect(parsed.bookmarks.count == 1 && parsed.skipped[.unsupportedScheme] == 1 && parsed.skipped[.unsupportedItem] == 2)
        }
        let many: [String: Any] = ["Children": Array(repeating: leaf, count: ImportLimits.maximumBookmarks + 1)]
        let parsed = try SafariBookmarks.parse(PropertyListSerialization.data(fromPropertyList: many, format: .binary, options: 0))
        #expect(parsed.bookmarks.count == ImportLimits.maximumBookmarks && parsed.skipped[.overLimit] == 1)
        var nested = leaf
        for _ in 0..<66 { nested = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Deep", "Children": [nested]] }
        let deep = try PropertyListSerialization.data(fromPropertyList: ["Children": [nested]], format: .binary, options: 0)
        #expect(throws: ImportError.self) { try SafariBookmarks.parse(deep) }
        #expect(throws: CancellationError.self) { try SafariBookmarks.parse(deep, isCancelled: { true }) }
    }

    @Test @MainActor func cancelRollbackAndDuplicateReimportReuseExistingApply() async throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        let plan = try await scanner(scratch).scan(fixture.consent(history: true))
        let sink = FakeSink()
        let preview = try ImportApplier.preview(plan, sink: sink)
        #expect(throws: CancellationError.self) { try ImportApplier.apply(preview, to: sink, isCancelled: { true }) }
        #expect(sink.committed.isEmpty && sink.history.isEmpty)
        sink.failCommit = true
        #expect(throws: ImportError.self) { try ImportApplier.apply(preview, to: sink) }
        #expect(sink.committed.isEmpty && sink.history.isEmpty)
        sink.failCommit = false
        _ = try ImportApplier.apply(preview, to: sink)
        let repeatPreview = try ImportApplier.preview(plan, sink: sink)
        #expect(repeatPreview.isEmpty && repeatPreview.skipped[.duplicate] == 2)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner(scratch).scan(fixture.consent(history: true))
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func historyRowLimitAndCancellation() throws {
        let scratch = try ImportScratch()
        let fixture = try SafariFixture(scratch)
        try fixture.run("INSERT INTO history_visits VALUES (2, 1, 721692700, 'Older'), (3, 1, 721692600, 'Oldest')")
        let staging = ImportStaging(root: scratch.file("Staging"))
        let result = try staging.withSQLiteSnapshot(named: "History.db", from: fixture.folder) {
            try SafariHistory.read(databaseAt: $0, historyLimit: 1)
        }
        #expect(result.entries.count == 1 && result.skipped[.overLimit] == 2)
        #expect(throws: CancellationError.self) { try SafariHistory.read(databaseAt: fixture.database, isCancelled: { true }) }
    }

    private func scanner(_ scratch: ImportScratch, _ fs: ImportFileSystem = LocalImportFileSystem()) -> ImportScanner {
        ImportScanner(fileSystem: fs, staging: ImportStaging(root: scratch.file("Staging"), fileSystem: fs))
    }
}

private final class SafariFixture {
    let folder: URL
    let database: URL
    private var db: OpaquePointer?
    init(_ scratch: ImportScratch) throws {
        folder = scratch.file("Safari")
        database = folder.appendingPathComponent("History.db")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root: [String: Any] = ["WebBookmarkFileVersion": 1, "Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "研究", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.example/",
                     "URIDictionary": ["title": "日本語"]],
                ]],
            ]],
        ]]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("Bookmarks.plist"))
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw ImportError.database("Fixture creation failed") }
        try run("""
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items VALUES (1, 'https://safari.example/');
            INSERT INTO history_visits VALUES (1, 1, 721692800.25, 'Latest');
            """)
    }
    deinit { sqlite3_close(db) }
    func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ImportError.database("Fixture SQL failed: \(sql)") }
    }
    func consent(bookmarks: Bool = true, history: Bool = false) -> ImportConsent {
        ImportConsent(source: ImportSourceDiscovery.safariFolder(folder), options: ImportOptions(bookmarks: bookmarks, history: history))
    }
    func sourceBytes() throws -> [Data] {
        try ["", "-wal"].map { try Data(contentsOf: URL(fileURLWithPath: database.path + $0)) }
    }
}

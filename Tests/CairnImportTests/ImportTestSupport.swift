import Foundation
import SQLite3
import Testing
@testable import CairnImport

final class ImportScratch {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func write(_ text: String, as name: String) throws -> URL {
        let target = file(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }
}

/// Records every operation so tests can prove what the importer touched.
final class RecordingFileSystem: ImportFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let inner = LocalImportFileSystem()
    var reads: [String] { lock.withLock { log.filter { $0.hasPrefix("read") || $0.hasPrefix("copy") || $0.hasPrefix("snapshot") } } }
    var all: [String] { lock.withLock { log } }
    private func record(_ entry: String) { lock.withLock { log.append(entry) } }
    var failRemoval = false
    var deniedNames: Set<String> = []

    func exists(_ url: URL) -> Bool { record("exists \(url.path)"); return inner.exists(url) }
    func isDirectory(_ url: URL) -> Bool { record("isDirectory \(url.path)"); return inner.isDirectory(url) }
    func read(_ url: URL, maximumBytes: Int) throws -> Data {
        record("read \(url.path)")
        if deniedNames.contains(url.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
        return try inner.read(url, maximumBytes: maximumBytes)
    }
    func makePrivateDirectory(_ url: URL) throws { record("mkdir \(url.path)"); try inner.makePrivateDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws { record("copy \(source.path)"); try inner.copy(source, to: destination) }
    func remove(_ url: URL) throws {
        record("remove \(url.path)")
        if failRemoval { throw ImportError.unreadable("Synthetic cleanup failure") }
        try inner.remove(url)
    }
    func childDirectories(of url: URL) throws -> [URL] { record("list \(url.path)"); return try inner.childDirectories(of: url) }
    func snapshotSQLite(_ source: URL, to destination: URL, maximumBytes: Int) throws {
        record("snapshot \(source.path)")
        if deniedNames.contains(source.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
        try inner.snapshotSQLite(source, to: destination, maximumBytes: maximumBytes)
    }
}

@MainActor
final class FakeSink: ImportSink {
    var supportsFolders = true
    var spaces: [String: Set<String>] = [:]
    var committed: [SpaceCommit] = []
    var history: [ImportedHistoryEntry] = []
    var commitCalls = 0
    var failCommit = false
    func existingPinKeys(inSpaceNamed name: String) -> Set<String>? { spaces[name] }
    func existingFolderPaths(inSpaceNamed name: String) -> Set<[String]> {
        Set(committed.filter { $0.name == name }.flatMap(\.pins).flatMap { pin in
            pin.folderPath.indices.map { Array(pin.folderPath.prefix($0 + 1)) }
        })
    }
    func commit(_ commits: [SpaceCommit], history entries: [ImportedHistoryEntry]) throws -> Int {
        commitCalls += 1
        if failCommit { throw ImportError.database("Synthetic commit failure") }
        for commit in commits {
            var keys = spaces[commit.name] ?? []
            for pin in commit.pins { keys.insert(ImportApplier.key(folderPath: pin.folderPath, url: pin.url)) }
            spaces[commit.name] = keys
            committed.append(commit)
        }
        history += entries
        return entries.count
    }
    func selectHistory(_ entries: [ImportedHistoryEntry]) throws -> HistorySelection {
        let known = Set(history.map { "\($0.url)|\($0.lastVisit.timeIntervalSince1970)" })
        let fresh = entries.filter { !known.contains("\($0.url)|\($0.lastVisit.timeIntervalSince1970)") }
        return HistorySelection(entries: fresh, skipped: fresh.count == entries.count ? [:] : [.duplicate: entries.count - fresh.count])
    }
}

/// Builds a Chromium-style History database (WAL mode) at test time. Rows live in the -wal file until the
/// returned connection is closed with a checkpoint.
func makeHistoryDatabase(at url: URL, rows: [(String, String, Int64, Int32)], keepOpen: Bool) throws -> OpaquePointer? {
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    func run(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
    run("PRAGMA journal_mode=WAL")
    run("PRAGMA wal_autocheckpoint=0")
    run("CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0, typed_count INTEGER DEFAULT 0, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0)")
    for (address, title, time, hidden) in rows {
        let escapedURL = address.replacingOccurrences(of: "'", with: "''")
        let escapedTitle = title.replacingOccurrences(of: "'", with: "''")
        run("INSERT INTO urls (url, title, last_visit_time, hidden) VALUES ('\(escapedURL)', '\(escapedTitle)', \(time), \(hidden))")
    }
    if keepOpen { return db }
    sqlite3_close(db)
    return nil
}

/// Chromium time (µs since 1601) for a Unix timestamp.
func chromiumTime(_ unix: Double) -> Int64 { Int64((unix + 11_644_473_600) * 1_000_000) }

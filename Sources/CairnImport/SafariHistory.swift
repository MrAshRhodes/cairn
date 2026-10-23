import Foundation
import SQLite3

/// Safari's History.db tables as documented by Mozilla's open-source Safari migrator.
/// Only URL, title and visit time are queried, and only from the private snapshot.
public enum SafariHistory {
    public struct Result: Sendable {
        public var entries: [ImportedHistoryEntry]
        public var skipped: SkipCounts
    }

    public static func date(fromReferenceSeconds seconds: Double) -> Date? {
        let unix = seconds + 978_307_200
        guard seconds.isFinite, unix > 0, unix < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    public static func read(databaseAt url: URL, historyLimit: Int = ImportLimits.maximumHistoryRows,
                            isCancelled: () -> Bool = { Task.isCancelled }) throws -> Result {
        guard historyLimit > 0, historyLimit <= ImportLimits.maximumHistoryRows else {
            throw ImportError.malformed("Invalid history row limit.")
        }
        if isCancelled() { throw CancellationError() }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.unreadable("History.db must be a regular file.")
        }
        guard (values.fileSize ?? 0) <= ImportLimits.maximumFileBytes else { throw ImportError.tooLarge("History.db") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw ImportError.database("Cannot open the Safari history snapshot.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY", nil, nil, nil) == SQLITE_OK else {
            throw failure(db)
        }
        return try withoutActuallyEscaping(isCancelled) { cancellation in
            let budget = Budget(cancelled: cancellation)
            sqlite3_progress_handler(db, 1_000, { context in
                guard let context else { return 1 }
                return Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue().interrupted ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            for table in ["history_items", "history_visits"] {
                let statement = try prepare("SELECT type FROM sqlite_schema WHERE name='\(table)'", db: db)
                defer { sqlite3_finalize(statement) }
                guard try step(statement, db: db, budget: budget), try text(statement, 0) == "table",
                      try !step(statement, db: db, budget: budget) else {
                    throw ImportError.unsupportedSource("Unsupported Safari history schema: \(table) must be a table.")
                }
            }
            let statement = try prepare("""
                SELECT i.url, v.title, v.visit_time
                FROM history_visits AS v JOIN history_items AS i ON i.id = v.history_item
                ORDER BY v.visit_time DESC, v.id DESC LIMIT \(historyLimit + 1)
                """, db: db)
            defer { sqlite3_finalize(statement) }
            var result = Result(entries: [], skipped: [:])
            var seen = Set<String>()
            var rows = 0
            while try step(statement, db: db, budget: budget) {
                if rows == historyLimit {
                    let count = try prepare("SELECT COUNT(*) FROM history_visits AS v JOIN history_items AS i ON i.id=v.history_item", db: db)
                    defer { sqlite3_finalize(count) }
                    guard try step(count, db: db, budget: budget) else { throw failure(db) }
                    result.skipped[.overLimit] = max(1, Int(sqlite3_column_int64(count, 0)) - historyLimit)
                    break
                }
                rows += 1
                let type = sqlite3_column_type(statement, 2)
                guard type == SQLITE_FLOAT || type == SQLITE_INTEGER,
                      let date = date(fromReferenceSeconds: sqlite3_column_double(statement, 2)) else {
                    result.skipped[.invalidDate, default: 0] += 1
                    continue
                }
                guard let address = try text(statement, 0) else { throw ImportError.malformed("Missing Safari history URL.") }
                switch Sanitizer.webURL(address) {
                case .success(let url):
                    guard seen.insert(Sanitizer.key(url)).inserted else {
                        result.skipped[.olderVisit, default: 0] += 1
                        continue
                    }
                    result.entries.append(ImportedHistoryEntry(url: url, title: Sanitizer.title(try text(statement, 1) ?? ""), lastVisit: date))
                case .failure(let reason):
                    result.skipped[reason, default: 0] += 1
                }
            }
            return result
        }
    }

    private final class Budget {
        let cancelled: () -> Bool
        let deadline = Date().addingTimeInterval(10)
        init(cancelled: @escaping () -> Bool) { self.cancelled = cancelled }
        var interrupted: Bool { cancelled() || Date() >= deadline }
        func check() throws {
            if cancelled() { throw CancellationError() }
            guard Date() < deadline else { throw ImportError.database("Reading Safari history took too long.") }
        }
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }

    private static func step(_ statement: OpaquePointer, db: OpaquePointer, budget: Budget) throws -> Bool {
        try budget.check()
        let result = sqlite3_step(statement)
        try budget.check()
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure(db) }
        return result == SQLITE_ROW
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(statement, column),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8),
              !value.contains("\0") else { throw ImportError.malformed("Invalid Safari history text.") }
        return value
    }

    private static func failure(_ db: OpaquePointer) -> ImportError { .database(String(cString: sqlite3_errmsg(db))) }
}

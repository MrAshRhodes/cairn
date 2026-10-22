import Foundation
import SQLite3

/// Reads the `urls` table of a (staged copy of a) Chromium `History` database, read-only.
public enum ChromiumHistory {
    public struct Result: Sendable {
        public var entries: [ImportedHistoryEntry]
        public var skipped: SkipCounts
    }

    /// Microseconds between 1601-01-01 and 1970-01-01.
    static let chromiumEpochOffset: Double = 11_644_473_600

    public static func date(fromChromiumMicroseconds value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let seconds = Double(value) / 1_000_000 - chromiumEpochOffset
        return seconds > 0 && seconds < 4_102_444_800 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public static func read(databaseAt url: URL, limit: Int = ImportLimits.maximumHistoryRows,
                            isCancelled: () -> Bool = { Task.isCancelled }) throws -> Result {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the history copy."
            if let handle { sqlite3_close(handle) }
            throw ImportError.database(reason)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        var statement: OpaquePointer?
        let sql = "SELECT url, title, last_visit_time, hidden FROM urls ORDER BY last_visit_time DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var entries: [ImportedHistoryEntry] = []
        var skipped = SkipCounts()
        while true {
            if isCancelled() { throw CancellationError() }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ImportError.database(String(cString: sqlite3_errmsg(db))) }
            if sqlite3_column_int(statement, 3) != 0 { skipped[.hidden, default: 0] += 1; continue }
            guard let rawURL = sqlite3_column_text(statement, 0) else { skipped[.invalidURL, default: 0] += 1; continue }
            switch Sanitizer.webURL(String(cString: rawURL)) {
            case .success(let address):
                guard let visited = date(fromChromiumMicroseconds: sqlite3_column_int64(statement, 2)) else {
                    skipped[.invalidURL, default: 0] += 1
                    continue
                }
                let title = sqlite3_column_text(statement, 1).map { Sanitizer.title(String(cString: $0)) } ?? ""
                entries.append(ImportedHistoryEntry(url: address, title: title, lastVisit: visited))
            case .failure(let reason):
                skipped[reason, default: 0] += 1
            }
        }
        return Result(entries: entries, skipped: skipped)
    }
}

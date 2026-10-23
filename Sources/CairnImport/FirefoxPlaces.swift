import Foundation
import SQLite3

/// Firefox's open-source Places schema. Only bookmark structure, URLs, titles and optional latest
/// visit times are queried; Places annotations, favicons, input history and all other profile files are ignored.
public enum FirefoxPlaces {
    public struct Result: Sendable {
        public var bookmarks: [ImportedBookmark]
        public var history: [ImportedHistoryEntry]
        public var skipped: SkipCounts
    }

    /// Firefox PRTime is microseconds since the Unix epoch, independent of the user's timezone.
    public static func date(fromMicroseconds value: Int64) -> Date? {
        guard value > 0, value < 4_102_444_800_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000)
    }

    public static func read(databaseAt url: URL, options: ImportOptions = ImportOptions(),
                            historyLimit: Int = ImportLimits.maximumHistoryRows,
                            isCancelled: () -> Bool = { Task.isCancelled }) throws -> Result {
        guard historyLimit > 0, historyLimit <= ImportLimits.maximumHistoryRows else {
            throw ImportError.malformed("Invalid history row limit.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.unreadable("Places must be a regular file.")
        }
        guard (values.fileSize ?? 0) <= ImportLimits.maximumFileBytes else { throw ImportError.tooLarge("places.sqlite") }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the Places snapshot."
            if let handle { sqlite3_close(handle) }
            throw ImportError.database(reason)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY", nil, nil, nil) == SQLITE_OK else {
            throw failure(db)
        }
        return try withoutActuallyEscaping(isCancelled) { cancellation in
            let budget = ReadBudget(isCancelled: cancellation)
            sqlite3_progress_handler(db, 1_000, { context in
                guard let context else { return 1 }
                return Unmanaged<ReadBudget>.fromOpaque(context).takeUnretainedValue().interrupted ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            try budget.check()
            var result = Result(bookmarks: [], history: [], skipped: [:])
            if options.bookmarks {
                try requireTable("moz_bookmarks", db: db)
                try requireTable("moz_places", db: db)
                let parsed = try bookmarks(db: db, check: budget.check)
                result.bookmarks = parsed.bookmarks
                result.skipped = parsed.skipped
            }
            if options.history {
                try requireTable("moz_places", db: db)
                let parsed = try history(db: db, limit: historyLimit, check: budget.check)
                result.history = parsed.entries
                result.skipped.merge(parsed.skipped, uniquingKeysWith: +)
            }
            try budget.check()
            return result
        }
    }

    private final class ReadBudget {
        let isCancelled: () -> Bool
        let deadline = Date().addingTimeInterval(10)
        init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }
        var interrupted: Bool { isCancelled() || Date() >= deadline }
        func check() throws {
            if isCancelled() { throw CancellationError() }
            guard Date() < deadline else { throw ImportError.database("Reading Places took too long.") }
        }
    }

    private struct Node {
        let id: Int64
        let parent: Int64
        let type: Int64
        let title: String
        let guid: String
        let address: String?
    }

    private static func bookmarks(db: OpaquePointer, check: () throws -> Void) throws -> ParsedBookmarks {
        let maximumNodes = ImportLimits.maximumBookmarks * 4
        let statement = try prepare("""
            SELECT b.id, b.parent, b.type, b.title, b.guid, p.url
            FROM moz_bookmarks AS b LEFT JOIN moz_places AS p ON b.fk = p.id
            ORDER BY b.parent, b.position, b.id LIMIT \(maximumNodes + 1)
            """, db: db)
        defer { sqlite3_finalize(statement) }
        var nodes: [Int64: Node] = [:]
        var ordered: [Node] = []
        while try step(statement, db: db, check: check) {
            guard ordered.count < maximumNodes else { throw ImportError.tooLarge("Firefox bookmark structure") }
            let id = try integer(statement, 0)
            let parent = try integer(statement, 1)
            let type = try integer(statement, 2)
            guard id > 0, parent >= 0, (1...3).contains(type), nodes[id] == nil else {
                throw ImportError.malformed("Invalid Firefox bookmark structure.")
            }
            let node = Node(id: id, parent: parent, type: type,
                            title: try text(statement, 3) ?? "", guid: try text(statement, 4) ?? "",
                            address: try text(statement, 5))
            nodes[id] = node
            ordered.append(node)
        }
        guard let root = ordered.first(where: { $0.guid == "root________" }), root.type == 2, root.parent == 0,
              ordered.filter({ $0.guid == "root________" }).count == 1 else {
            throw ImportError.malformed("Firefox bookmark root is missing or invalid.")
        }
        var parsed = ParsedBookmarks()
        let rootNames = ["toolbar_____": "Bookmarks Toolbar", "menu________": "Bookmarks Menu",
                         "unfiled_____": "Other Bookmarks", "mobile______": "Mobile Bookmarks"]
        for node in ordered {
            try check()
            guard node.id != root.id else { continue }
            var path: [String] = []
            var cursor = node.parent
            var seen: Set<Int64> = [node.id]
            var isTag = node.guid == "tags________"
            while cursor != root.id {
                guard seen.count <= 64, seen.insert(cursor).inserted,
                      let folder = nodes[cursor], folder.type == 2 else {
                    throw ImportError.malformed("Firefox bookmark folders are cyclic, missing or too deep.")
                }
                isTag = isTag || folder.guid == "tags________"
                path.insert(rootNames[folder.guid] ?? folder.title, at: 0)
                cursor = folder.parent
            }
            if node.type == 2 { continue }
            guard node.type == 1, !isTag else {
                parsed.skipped[.unsupportedItem, default: 0] += 1
                continue
            }
            guard let address = node.address else { throw ImportError.malformed("A Firefox bookmark has no place URL.") }
            parsed.add(title: node.title, address: address, folderPath: path)
        }
        return parsed
    }

    private static func history(db: OpaquePointer, limit: Int, check: () throws -> Void) throws -> ChromiumHistory.Result {
        let statement = try prepare("""
            SELECT url, title, last_visit_date, hidden FROM moz_places
            WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC, id DESC LIMIT \(limit + 1)
            """, db: db)
        defer { sqlite3_finalize(statement) }
        var entries: [ImportedHistoryEntry] = []
        var skipped = SkipCounts()
        var rows = 0
        while try step(statement, db: db, check: check) {
            if rows == limit {
                let count = try prepare("SELECT COUNT(*) FROM moz_places WHERE last_visit_date IS NOT NULL", db: db)
                defer { sqlite3_finalize(count) }
                guard try step(count, db: db, check: check) else { throw failure(db) }
                skipped[.overLimit] = Int(try integer(count, 0)) - limit
                break
            }
            rows += 1
            if try integer(statement, 3) != 0 { skipped[.hidden, default: 0] += 1; continue }
            guard let rawURL = try text(statement, 0) else { throw ImportError.malformed("A Firefox history URL is missing.") }
            guard let date = date(fromMicroseconds: try integer(statement, 2)) else {
                skipped[.invalidDate, default: 0] += 1
                continue
            }
            switch Sanitizer.webURL(rawURL) {
            case .success(let url):
                let title = Sanitizer.title(try text(statement, 1) ?? "")
                entries.append(ImportedHistoryEntry(url: url, title: title, lastVisit: date))
            case .failure(let reason):
                skipped[reason, default: 0] += 1
            }
        }
        return ChromiumHistory.Result(entries: entries, skipped: skipped)
    }

    private static func requireTable(_ name: String, db: OpaquePointer) throws {
        let statement = try prepare("SELECT type FROM sqlite_schema WHERE name = '\(name)'", db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, try text(statement, 0) == "table",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ImportError.unsupportedSource("Unsupported Firefox Places schema: \(name) must be a table.")
        }
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }

    private static func step(_ statement: OpaquePointer, db: OpaquePointer, check: () throws -> Void) throws -> Bool {
        try check()
        let result = sqlite3_step(statement)
        try check()
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw failure(db) }
        return result == SQLITE_ROW
    }

    private static func integer(_ statement: OpaquePointer, _ column: Int32) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw ImportError.malformed("Invalid integer field in Firefox Places.")
        }
        return sqlite3_column_int64(statement, column)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else {
            throw ImportError.malformed("Invalid text field in Firefox Places.")
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8),
              !value.contains("\0") else { throw ImportError.malformed("Invalid text encoding in Firefox Places.") }
        return value
    }

    private static func failure(_ db: OpaquePointer) -> ImportError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
}

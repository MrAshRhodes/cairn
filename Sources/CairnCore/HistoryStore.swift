import Foundation
import SQLite3

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date
    public init(id: UUID = UUID(), url: URL, title: String, visitedAt: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.visitedAt = visitedAt
    }
}

/// Local-only, bounded history. Each mutation is committed before returning; queries treat input literally.
@MainActor
public final class HistoryStore {
    private var database: OpaquePointer?
    public let maximumEntries: Int

    public convenience init(url: URL) throws { try self.init(url: url, maximumEntries: 10_000) }

    public init(url: URL, maximumEntries: Int) throws {
        guard url.isFileURL, maximumEntries > 0, maximumEntries <= 100_000 else {
            throw ServiceError.invalidData("Invalid history location or capacity.")
        }
        self.maximumEntries = maximumEntries
        let existed: Bool
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ServiceError.invalidData("History must be a regular file.")
            }
            existed = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            existed = false
        }
        if !existed {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (existed ? 0 : SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database."
            if let handle { sqlite3_close(handle) }
            throw ServiceError.database(reason)
        }
        database = handle
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
        do {
            if existed {
                let version = try scalar("PRAGMA user_version")
                guard version == "1" else { throw ServiceError.unsupportedSchema(Int(version) ?? -1) }
                guard try scalar("PRAGMA quick_check") == "ok" else { throw ServiceError.database("Integrity check failed.") }
                try validateSchema()
                // Preparing and decoding all bounded records also validates an existing table's shape and values.
                let count = Int(try scalar("SELECT COUNT(*) FROM history")) ?? Int.max
                guard count <= 100_000 else { throw ServiceError.invalidData("History exceeds its supported capacity.") }
                _ = try entries("SELECT id, url, title, visited_at FROM history", bindings: [])
            } else {
                try transaction {
                    try execute("CREATE TABLE history (id TEXT PRIMARY KEY NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, visited_at REAL NOT NULL)")
                    try execute("CREATE INDEX history_recency ON history(visited_at DESC)")
                    try execute("PRAGMA user_version = 1")
                }
            }
            _ = try scalar("PRAGMA secure_delete = ON")
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func record(url: URL, title: String, at date: Date = Date()) throws {
        guard URLResolver.isWebURL(url), url.absoluteString.utf8.count <= 65_536,
              title.utf8.count <= 65_536, !title.contains("\0"), date.timeIntervalSince1970.isFinite else {
            throw ServiceError.invalidData("Invalid history entry.")
        }
        try transaction {
            try execute("INSERT INTO history (id, url, title, visited_at) VALUES (?, ?, ?, ?)",
                        bindings: [.text(UUID().uuidString), .text(url.absoluteString), .text(title), .number(date.timeIntervalSince1970)])
            try execute("DELETE FROM history WHERE rowid IN (SELECT rowid FROM history ORDER BY visited_at DESC, rowid DESC LIMIT -1 OFFSET ?)",
                        bindings: [.integer(maximumEntries)])
        }
    }

    public func search(_ query: String, limit: Int = 20) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        guard !query.contains("\0") else { throw ServiceError.invalidData("Invalid history query.") }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try entries(
            "SELECT id, url, title, visited_at FROM history WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' ORDER BY visited_at DESC, rowid DESC LIMIT ?",
            bindings: [.text("%\(escaped)%"), .text("%\(escaped)%"), .integer(min(limit, maximumEntries))])
    }

    public func recent(limit: Int = 20) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return try entries("SELECT id, url, title, visited_at FROM history ORDER BY visited_at DESC, rowid DESC LIMIT ?",
                           bindings: [.integer(min(limit, maximumEntries))])
    }

    public func clear() throws {
        try transaction { try execute("DELETE FROM history") }
        try execute("VACUUM")
    }

    private enum Binding {
        case text(String), integer(Int), number(Double)
    }

    private func prepare(_ sql: String, bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            for (index, binding) in bindings.enumerated() {
                let position = Int32(index + 1)
                let status: Int32
                switch binding {
                case .text(let text):
                    status = text.withCString {
                        sqlite3_bind_text(statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                case .integer(let value): status = sqlite3_bind_int64(statement, position, Int64(value))
                case .number(let value): status = sqlite3_bind_double(statement, position, value)
                }
                guard status == SQLITE_OK else { throw failure() }
            }
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func scalar(_ sql: String) throws -> String {
        let statement = try prepare(sql, bindings: [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw failure() }
        return String(cString: text)
    }

    private func entries(_ sql: String, bindings: [Binding]) throws -> [HistoryEntry] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var result: [HistoryEntry] = []
        var identifiers = Set<UUID>()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            guard (0...2).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_TEXT }),
                  (0...2).allSatisfy({ sqlite3_column_bytes(statement, Int32($0)) <= 65_536 }),
                  [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, 3)) else {
                throw ServiceError.invalidData("Invalid history field types or sizes.")
            }
            guard let rawID = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: rawID)),
                  let rawURL = sqlite3_column_text(statement, 1), let url = URL(string: String(cString: rawURL)),
                  URLResolver.isWebURL(url), let rawTitle = sqlite3_column_text(statement, 2),
                  sqlite3_column_type(statement, 3) != SQLITE_NULL else {
                throw ServiceError.invalidData("Damaged history entry.")
            }
            let timestamp = sqlite3_column_double(statement, 3)
            guard timestamp.isFinite, identifiers.insert(id).inserted else {
                throw ServiceError.invalidData("Invalid history timestamp or duplicate identifier.")
            }
            result.append(HistoryEntry(id: id, url: url, title: String(cString: rawTitle), visitedAt: Date(timeIntervalSince1970: timestamp)))
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            do { try execute("ROLLBACK") }
            catch let rollbackError { throw ServiceError.database("Rollback failed: \(rollbackError.localizedDescription)") }
            throw error
        }
    }

    private func validateSchema() throws {
        let statement = try prepare("PRAGMA table_info(history)", bindings: [])
        defer { sqlite3_finalize(statement) }
        let expected = [("id", "TEXT", 1), ("url", "TEXT", 0), ("title", "TEXT", 0), ("visited_at", "REAL", 0)]
        for (name, type, primaryKey) in expected {
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let columnName = sqlite3_column_text(statement, 1), String(cString: columnName) == name,
                  let columnType = sqlite3_column_text(statement, 2), String(cString: columnType).uppercased() == type,
                  sqlite3_column_int(statement, 3) == 1, sqlite3_column_int(statement, 5) == Int32(primaryKey) else {
                throw ServiceError.invalidData("Unrecognized history table schema.")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ServiceError.invalidData("Unrecognized history table schema.") }
    }

    private func failure() -> ServiceError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed.")
    }
}

import Foundation
import SQLite3

enum SQLiteSnapshot {
    static func create(from source: URL, to destination: URL, maximumBytes: Int,
                       isCancelled: () -> Bool = { Task.isCancelled }) throws {
        guard ["places.sqlite", "History", "History.db"].contains(source.lastPathComponent) else {
            throw ImportError.unsupportedSource("This database is not an importable file.")
        }
        var totalBytes = 0
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: source.path + suffix)
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ImportError.unreadable("\(file.lastPathComponent) is not a regular file.")
                }
                let size = values.fileSize ?? 0
                guard size >= 0, size <= maximumBytes - totalBytes else { throw ImportError.tooLarge(source.lastPathComponent) }
                totalBytes += size
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile && !suffix.isEmpty {
                continue
            }
        }
        if isCancelled() { throw CancellationError() }
        var input: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let input else {
            let reason = input.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open the selected database."
            if let input { sqlite3_close(input) }
            throw ImportError.database(reason)
        }
        defer { sqlite3_close(input) }
        sqlite3_busy_timeout(input, 100)
        var output: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let output else {
            let reason = output.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot create the private snapshot."
            if let output { sqlite3_close(output) }
            throw ImportError.database(reason)
        }
        defer { sqlite3_close(output) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        guard sqlite3_exec(input, "PRAGMA query_only=ON; BEGIN; SELECT rootpage FROM sqlite_schema LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(input)))
        }
        defer { sqlite3_exec(input, "ROLLBACK", nil, nil, nil) }
        // Establish one read transaction before backup: a live writer cannot make different pages come
        // from different commits. Copying the main file and WAL separately cannot offer this guarantee.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(input, "PRAGMA page_size", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ImportError.database(String(cString: sqlite3_errmsg(input)))
        }
        let status = sqlite3_step(statement)
        let pageSize = sqlite3_column_int64(statement, 0)
        sqlite3_finalize(statement)
        guard status == SQLITE_ROW, pageSize > 0 else { throw ImportError.database("Invalid database page size.") }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw ImportError.database(String(cString: sqlite3_errmsg(output)))
        }
        do {
            let deadline = Date().addingTimeInterval(10)
            while true {
                if isCancelled() { throw CancellationError() }
                guard Date() < deadline else {
                    throw ImportError.database("The browser database is busy. Close the source browser and try again.")
                }
                let result = sqlite3_backup_step(backup, 128)
                guard Int64(sqlite3_backup_pagecount(backup)) <= Int64(maximumBytes) / pageSize else {
                    throw ImportError.tooLarge(source.lastPathComponent)
                }
                if result == SQLITE_DONE { break }
                guard result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED else {
                    throw ImportError.database(String(cString: sqlite3_errmsg(output)))
                }
                if result != SQLITE_OK { Thread.sleep(forTimeInterval: 0.01) }
            }
        } catch {
            sqlite3_backup_finish(backup)
            throw error
        }
        guard sqlite3_backup_finish(backup) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(output)))
        }
        // Backup preserves the WAL-mode header. Normalize only the private copy so a subsequent
        // strictly read-only connection needs neither a new WAL nor shared-memory file.
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(output)))
        }
    }
}

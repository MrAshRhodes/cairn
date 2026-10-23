import Foundation

/// A private scratch directory holding copies of files that cannot be read in place (a browser keeps its
/// History database locked). It is removed when the import finishes, is cancelled, or at the next launch.
public struct ImportStaging: Sendable {
    public let root: URL
    private let fileSystem: ImportFileSystem

    public static func defaultRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Cairn", isDirectory: true).appendingPathComponent("Import", isDirectory: true)
    }

    public init(root: URL, fileSystem: ImportFileSystem = LocalImportFileSystem()) {
        self.root = root; self.fileSystem = fileSystem
    }

    /// Copies exactly the allow-listed `names` that exist in `source` into a new 0700 directory.
    public func stage(_ names: [String], from source: URL) throws -> URL {
        let allowed: Set<String> = ["History", "History-wal", "History-shm"]
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileSystem.makePrivateDirectory(directory)
        do {
            for name in names {
                guard allowed.contains(name), !name.contains("/") else {
                    throw ImportError.unsupportedSource("\(name) is not an importable file.")
                }

                let file = source.appendingPathComponent(name)
                if fileSystem.exists(file) { try fileSystem.copy(file, to: directory.appendingPathComponent(name)) }
            }
        } catch {
            try? fileSystem.remove(directory)
            throw error
        }
        return directory
    }

    /// Runs a reader against one private, consistent database snapshot and removes it on every outcome.
    public func withSQLiteSnapshot<T>(named name: String, from source: URL,
                                      read: (URL) throws -> T) throws -> T {
        guard ["places.sqlite", "History", "History.db"].contains(name) else {
            throw ImportError.unsupportedSource("\(name) is not an importable database.")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileSystem.makePrivateDirectory(directory)
            let destination = directory.appendingPathComponent(name)
            try fileSystem.snapshotSQLite(source.appendingPathComponent(name), to: destination,
                                          maximumBytes: ImportLimits.maximumFileBytes)
            let result = try read(destination)
            try fileSystem.remove(directory)
            return result
        } catch {
            let original = error
            do { try fileSystem.remove(directory) }
            catch {
                throw ImportError.unreadable("Private import data could not be removed: \(error.localizedDescription). Original error: \(original.localizedDescription)")
            }
            throw original
        }
    }

    public func discard(_ directory: URL) {
        guard directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return }
        try? fileSystem.remove(directory)
    }

    /// Removes anything a crashed or killed import left behind.
    public func sweep() throws {
        guard fileSystem.exists(root) else { return }
        let leftovers = try fileSystem.childDirectories(of: root)
        for directory in leftovers { try fileSystem.remove(directory) }
    }
}

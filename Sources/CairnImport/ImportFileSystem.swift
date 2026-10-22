import Foundation

/// The only door through which the importer touches disk. Tests inject a recording fake to prove that nothing
/// is read before the user confirms.
public protocol ImportFileSystem: Sendable {
    func exists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    /// Reads a regular file (never a symlink) of at most `maximumBytes`.
    func read(_ url: URL, maximumBytes: Int) throws -> Data
    func makePrivateDirectory(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    func childDirectories(of url: URL) throws -> [URL]
}

public struct LocalImportFileSystem: ImportFileSystem {
    public init() {}

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    public func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.unreadable("\(url.lastPathComponent) is not a regular file.")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw ImportError.tooLarge(url.lastPathComponent) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ImportError.tooLarge(url.lastPathComponent) }
        return data
    }

    public func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func copy(_ source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.unreadable("\(source.lastPathComponent) is not a regular file.")
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func childDirectories(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
    }
}

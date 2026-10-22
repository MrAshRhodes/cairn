import Foundation

public enum ServiceError: LocalizedError {
    case notImplemented
    case invalidData(String)
    case unsupportedSchema(Int)
    case database(String)
    case invalidDownload(String)
    case navigation(String)
    case limit(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "This service is not implemented yet."
        case .invalidData(let reason): return "Invalid saved data: \(reason)"
        case .unsupportedSchema(let version): return "Saved data uses unsupported schema \(version). It has not been changed."
        case .database(let reason): return "History database: \(reason)"
        case .invalidDownload(let reason): return "Download failed: \(reason)"
        case .navigation(let reason), .limit(let reason): return reason
        }
    }
}

enum JSONStorage {
    private struct Header: Decodable { let schemaVersion: Int }
    // Bound allocations before decoding untrusted, potentially damaged local files.
    static let maximumBytes = 32 * 1024 * 1024

    static func read(_ url: URL) throws -> Data? {
        guard url.isFileURL else { throw ServiceError.invalidData("Expected a local file URL.") }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ServiceError.invalidData("Expected a regular file, not a directory or symbolic link.")
            }
            let size = values.fileSize ?? 0
            guard size <= maximumBytes else { throw ServiceError.invalidData("File is too large.") }
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                try handle.close()
            } catch {
                do { try handle.close() } catch let closeError { throw closeError }
                throw error
            }
            guard data.count <= maximumBytes else { throw ServiceError.invalidData("File is too large.") }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, schema: Int) throws -> T {
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard version == schema else { throw ServiceError.unsupportedSchema(version) }
        return try JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        guard url.isFileURL else { throw ServiceError.invalidData("Expected a local file URL.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw ServiceError.invalidData("File is too large.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

extension Workspace {
    /// Validate before reading or replacing a saved workspace. Unknown schemas are never migrated implicitly.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ServiceError.unsupportedSchema(schemaVersion) }
        guard !spaces.isEmpty, spaces.count <= 1_000 else { throw ServiceError.invalidData("Expected 1–1,000 Spaces.") }
        guard Set(spaces.map(\.id)).count == spaces.count else { throw ServiceError.invalidData("Duplicate Space identifiers.") }
        guard let selectedSpaceID, spaces.contains(where: { $0.id == selectedSpaceID }) else {
            throw ServiceError.invalidData("Selected Space does not exist.")
        }
        guard Set(spaces.map(\.profileID)).count == spaces.count else {
            throw ServiceError.invalidData("Spaces must have distinct storage profiles.")
        }
        var ids = Set<UUID>()
        func validateTabs(_ tabs: [TabItem]) throws {
            for tab in tabs {
                guard ids.insert(tab.id).inserted else { throw ServiceError.invalidData("Duplicate tab identifiers.") }
                guard tab.title.count <= TabItem.maximumTitleLength,
                      (tab.customTitle?.count ?? 0) <= TabItem.maximumTitleLength,
                      tab.createdAt.timeIntervalSince1970.isFinite,
                      tab.lastActiveAt.timeIntervalSince1970.isFinite else {
                    throw ServiceError.invalidData("Invalid tab metadata.")
                }
                for url in [tab.url, tab.homeURL].compactMap({ $0 }) where !URLResolver.isNavigable(url) {
                    throw ServiceError.invalidData("Unsupported tab URL: \(url.scheme ?? "missing scheme").")
                }
            }
        }
        try validateTabs(favorites)
        for space in spaces {
            guard !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  space.name.count <= 1_024, space.icon.count <= 256,
                  space.colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                  space.profileID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil else {
                throw ServiceError.invalidData("Invalid Space metadata or storage profile.")
            }
            try validateTabs(space.pinned + space.tabs + space.archive)
            let folders = space.folders ?? []
            guard folders.count <= 1_000, Set(folders.map(\.id)).count == folders.count,
                  folders.allSatisfy({ !$0.name.isEmpty && $0.name.count <= TabFolder.maximumNameLength }),
                  space.theme?.isValid ?? true else {
                throw ServiceError.invalidData("Invalid folders or Space theme.")
            }
            if let selected = space.selectedTabID,
               !(favorites + space.pinned + space.tabs).contains(where: { $0.id == selected }) {
                throw ServiceError.invalidData("A selected tab is missing, archived, or belongs to another Space.")
            }
        }
        guard ids.count <= 100_000 else { throw ServiceError.invalidData("Too many saved tabs.") }
    }
}

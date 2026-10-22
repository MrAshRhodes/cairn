import AppKit
import CryptoKit

/// Remembers each site's icon per profile so tabs show it before their page (re)loads and across launches.
/// A `nil` directory keeps everything in memory, which is what private browsing must use: nothing is written to disk.
/// The cache is a convenience, so disk failures degrade to the in-memory copy instead of interrupting browsing.
@MainActor
public final class FaviconStore {
    public let directory: URL?
    private let limit: Int
    private var memory: [String: Data] = [:]
    private var writesSincePrune = 0

    public init(directory: URL?, limit: Int = 400) {
        self.directory = directory
        self.limit = max(1, limit)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            prune()
        }
    }

    public func store(_ png: Data, profileID: String, host: String) {
        guard !png.isEmpty, !host.isEmpty else { return }
        let key = Self.key(profileID: profileID, host: host)
        memory[key] = png
        guard let directory else { return }
        try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
        writesSincePrune += 1
        if writesSincePrune >= 25 { prune() }
    }

    public func data(profileID: String, host: String) -> Data? {
        let key = Self.key(profileID: profileID, host: host)
        if let cached = memory[key] { return cached }
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".png")),
              NSImage(data: data) != nil else { return nil }
        memory[key] = data
        return data
    }

    public func image(profileID: String, host: String) -> NSImage? {
        data(profileID: profileID, host: host).flatMap { NSImage(data: $0) }
    }

    public func removeAll(profileID: String? = nil) {
        guard let profileID else {
            memory.removeAll()
            if let directory { try? FileManager.default.removeItem(at: directory); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            return
        }
        // File names are hashes, so per-profile removal only clears what this session has seen.
        let prefix = Self.hash(profileID) + "-"
        for key in memory.keys where key.hasPrefix(prefix) {
            memory[key] = nil
            if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".png")) }
        }
    }

    /// Oldest files go first once the cache exceeds its limit.
    func prune() {
        writesSincePrune = 0
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
            memory[file.deletingPathExtension().lastPathComponent] = nil
        }
    }

    // The profile prefix keeps one profile's hosts from ever resolving to another profile's file.
    private static func key(profileID: String, host: String) -> String { hash(profileID) + "-" + hash(host.lowercased()) }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

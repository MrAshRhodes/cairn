import Foundation

/// Persists split groups in `splits.json`. Unreadable or newer files are moved aside, never overwritten.
@MainActor
public final class SplitStore {
    nonisolated public static let currentSchemaVersion = 1
    public let directory: URL
    public var onError: ((Error) -> Void)?
    private var pendingSave: Task<Void, Never>?
    private var pendingGroups: [SplitGroup]?
    private let debounce: Duration
    public var fileURL: URL { directory.appendingPathComponent("splits.json") }

    private struct Document: Codable {
        var schemaVersion = SplitStore.currentSchemaVersion
        var groups: [SplitGroup]
    }

    public init(directory: URL, debounce: Duration = .milliseconds(350)) {
        self.directory = directory
        self.debounce = max(.zero, debounce)
    }

    deinit { pendingSave?.cancel() }

    public struct Loaded {
        public var groups: [SplitGroup]
        /// Set when the file could not be used and was moved to this location.
        public var quarantinedTo: URL?
        public var error: Error?
    }

    public func load() -> Loaded {
        do {
            guard let data = try JSONStorage.read(fileURL) else { return Loaded(groups: []) }
            let document = try JSONStorage.decode(Document.self, from: data, schema: Self.currentSchemaVersion)
            return Loaded(groups: document.groups)
        } catch {
            let moved = quarantine()
            return Loaded(groups: [], quarantinedTo: moved, error: error)
        }
    }

    public func scheduleSave(_ groups: [SplitGroup]) {
        pendingSave?.cancel()
        pendingGroups = groups
        let delay = debounce
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let snapshot = self.pendingGroups else { return }
            do { try self.saveNow(snapshot) } catch { self.onError?(error) }
        }
    }

    public func saveNow(_ groups: [SplitGroup]) throws {
        pendingSave?.cancel()
        pendingSave = nil
        pendingGroups = nil
        if groups.isEmpty, (try? JSONStorage.read(fileURL)) == nil { return }
        try JSONStorage.write(Document(groups: groups), to: fileURL)
    }

    public func flush() throws {
        if let groups = pendingGroups { try saveNow(groups) }
    }

    private func quarantine() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        var target = directory.appendingPathComponent("splits.json.corrupt-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("splits.json.corrupt-\(stamp)-\(counter)")
            counter += 1
        }
        do { try FileManager.default.moveItem(at: fileURL, to: target); return target }
        catch { return nil }
    }
}

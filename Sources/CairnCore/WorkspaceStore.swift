import Foundation

@MainActor
public final class WorkspaceStore {
    nonisolated public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn", isDirectory: true)
    }
    public let directory: URL
    public var onError: ((Error) -> Void)?
    public private(set) var lastError: Error?
    private var pendingSave: Task<Void, Never>?
    private var pendingWorkspace: Workspace?
    private let debounce: Duration
    public var fileURL: URL { directory.appendingPathComponent("workspace.json") }

    public convenience init(directory: URL = WorkspaceStore.defaultDirectory) {
        self.init(directory: directory, debounce: .milliseconds(350))
    }

    public init(directory: URL, debounce: Duration) {
        self.directory = directory
        self.debounce = max(.zero, debounce)
    }

    deinit { pendingSave?.cancel() }

    public func load() throws -> Workspace? {
        guard let data = try JSONStorage.read(fileURL) else { return nil }
        return try decode(data)
    }

    public func scheduleSave(_ workspace: Workspace) {
        pendingSave?.cancel()
        pendingWorkspace = workspace
        let delay = debounce
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return } // Replaced by a newer snapshot or explicitly flushed.
            guard let self, let snapshot = self.pendingWorkspace else { return }
            do { try self.saveNow(snapshot) }
            catch {
                self.lastError = error
                self.onError?(error)
            }
        }
    }

    public func saveNow(_ workspace: Workspace) throws {
        pendingSave?.cancel()
        pendingSave = nil
        try workspace.validate()
        if let data = try JSONStorage.read(fileURL) { _ = try decode(data) }
        try JSONStorage.write(workspace, to: fileURL)
        pendingWorkspace = nil
        lastError = nil
    }

    /// Call when the app terminates; a debounce must not lose the last mutation.
    public func flush() throws {
        if let workspace = pendingWorkspace { try saveNow(workspace) }
    }

    private func decode(_ data: Data) throws -> Workspace {
        let workspace = try JSONStorage.decode(Workspace.self, from: data, schema: Workspace.currentSchemaVersion)
        try workspace.validate()
        return workspace
    }
}

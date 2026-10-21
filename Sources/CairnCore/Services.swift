import AppKit
import Observation
import CairnEngineKit

// Shared contracts; the storage implementation replaces these temporary bodies.
public enum ServiceError: LocalizedError {
    case notImplemented
    public var errorDescription: String? { "This service is not implemented yet." }
}

@MainActor @Observable
public final class Settings {
    public var searchTemplate = URLResolver.defaultSearchTemplate
    public var engineKind: EngineKind = .webkit
    public var autoArchiveAfterHours: Double = 12
    public var restoreSessionOnLaunch = true
    public var sidebarWidth: Double = 260
    public init() {}
    public static func load(from url: URL) throws -> Settings { throw ServiceError.notImplemented }
    public func save(to url: URL) throws { throw ServiceError.notImplemented }
}

@MainActor
public final class WorkspaceStore {
    nonisolated public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn", isDirectory: true)
    }
    public let directory: URL
    public var onError: ((Error) -> Void)?
    public init(directory: URL = WorkspaceStore.defaultDirectory) { self.directory = directory }
    public func load() throws -> Workspace? { throw ServiceError.notImplemented }
    public func scheduleSave(_ workspace: Workspace) { onError?(ServiceError.notImplemented) }
    public func saveNow(_ workspace: Workspace) throws { throw ServiceError.notImplemented }
}

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var visitedAt: Date
    public init(id: UUID = UUID(), url: URL, title: String, visitedAt: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.visitedAt = visitedAt
    }
}

@MainActor
public final class HistoryStore {
    public init(url: URL) throws { throw ServiceError.notImplemented }
    public func record(url: URL, title: String, at date: Date = Date()) throws { throw ServiceError.notImplemented }
    public func search(_ query: String, limit: Int = 20) throws -> [HistoryEntry] { throw ServiceError.notImplemented }
    public func recent(limit: Int = 20) throws -> [HistoryEntry] { throw ServiceError.notImplemented }
    public func clear() throws { throw ServiceError.notImplemented }
}

public struct DownloadItem: Identifiable, Sendable {
    public enum Status: String, Sendable { case downloading, completed, cancelled, failed }
    public var id: UUID
    public var url: URL
    public var filename: String
    public var progress: Double
    public var status: Status
    public var destination: URL?
    public var errorMessage: String?
    public init(id: UUID = UUID(), url: URL, filename: String, progress: Double = 0,
                status: Status = .downloading, destination: URL? = nil, errorMessage: String? = nil) {
        self.id = id; self.url = url; self.filename = filename; self.progress = progress
        self.status = status; self.destination = destination; self.errorMessage = errorMessage
    }
}

@MainActor @Observable
public final class DownloadsManager {
    public private(set) var items: [DownloadItem] = []
    public init() {}
    public func start(url: URL, suggestedFilename: String? = nil) {
        items.append(DownloadItem(url: url, filename: suggestedFilename ?? "Download",
                                  status: .failed, errorMessage: ServiceError.notImplemented.localizedDescription))
    }
    public func cancel(_ id: UUID) {}
    public func reveal(_ id: UUID) {}
    public func clearFinished() {}
}

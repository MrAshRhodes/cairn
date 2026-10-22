import Foundation
import Observation
import CairnEngineKit

public enum SitePermissionDecision: String, Codable, Sendable {
    case allow, block
}

public struct SitePermissionEntry: Codable, Equatable, Identifiable, Sendable {
    public var profileID: String
    public var origin: String
    public var kind: SitePermissionKind
    public var decision: SitePermissionDecision
    public var decidedAt: Date
    public var id: String { "\(profileID)|\(origin)|\(kind.rawValue)" }
}

public enum SiteOrigin {
    /// `scheme://host[:port]` in lowercase, or nil for anything that is not an http(s) origin.
    public static func normalize(_ value: String) -> String? {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let hostText = host.contains(":") ? "[\(host)]" : host
        if let port = components.port, port != defaultPort { return "\(scheme)://\(hostText):\(port)" }
        return "\(scheme)://\(hostText)"
    }

    /// Permission prompts are only offered to secure contexts: https, or http on this machine.
    public static func isSecureContext(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1")
    }
}

/// Per-Space (profile), per-origin site permission decisions. Never decides on its own: a missing entry means
/// "ask". A file that cannot be read is preserved and not overwritten (`isWritable` turns false).
@MainActor @Observable
public final class SitePermissionStore {
    public static let maximumEntries = 10_000
    public private(set) var entries: [SitePermissionEntry] = []
    public private(set) var isWritable = true
    @ObservationIgnored public var onError: ((Error) -> Void)?
    @ObservationIgnored private var url: URL?

    private struct Document: Codable {
        var schemaVersion = 1
        var entries: [SitePermissionEntry]
    }

    public init() {}

    public func load(from url: URL) throws {
        self.url = url
        do {
            guard let data = try JSONStorage.read(url) else { return }
            let document = try JSONStorage.decode(Document.self, from: data, schema: 1)
            guard document.entries.count <= Self.maximumEntries else { throw ServiceError.invalidData("Too many site permissions.") }
            entries = document.entries
        } catch {
            isWritable = false
            throw error
        }
    }

    public func decision(profileID: String, origin: String, kind: SitePermissionKind) -> SitePermissionDecision? {
        entries.first { $0.profileID == profileID && $0.origin == origin && $0.kind == kind }?.decision
    }

    public func entries(profileID: String) -> [SitePermissionEntry] {
        entries.filter { $0.profileID == profileID }
    }

    @discardableResult
    public func set(_ decision: SitePermissionDecision, profileID: String, origin: String, kind: SitePermissionKind,
                    now: Date = Date()) -> Bool {
        guard let origin = SiteOrigin.normalize(origin) else { return false }
        if let index = entries.firstIndex(where: { $0.profileID == profileID && $0.origin == origin && $0.kind == kind }) {
            entries[index].decision = decision
            entries[index].decidedAt = now
        } else {
            guard entries.count < Self.maximumEntries else { return false }
            entries.append(SitePermissionEntry(profileID: profileID, origin: origin, kind: kind, decision: decision, decidedAt: now))
        }
        save()
        return true
    }

    public func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func removeAll(profileID: String? = nil) {
        entries.removeAll { profileID == nil || $0.profileID == profileID }
        save()
    }

    private func save() {
        guard isWritable, let url else { return }
        do { try JSONStorage.write(Document(entries: entries), to: url) }
        catch { onError?(error) }
    }
}

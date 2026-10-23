import Foundation
import Observation

public struct PopupException: Codable, Equatable, Identifiable, Sendable {
    public let spaceID: UUID
    public let profileID: String
    public let origin: String
    public let allowedAt: Date
    public var id: String { "\(spaceID.uuidString)|\(profileID)|\(origin)" }
}

/// Exact HTTP(S) origins, scoped to both the Space and its current storage profile.
/// A grant takes effect only after an atomic save; revocation takes effect even if saving fails.
@MainActor @Observable
public final class PopupExceptionStore {
    public static let maximumEntries = 10_000
    public private(set) var entries: [PopupException] = []
    public private(set) var isWritable = false
    public private(set) var errorMessage: String?
    @ObservationIgnored public var onError: ((Error) -> Void)?
    @ObservationIgnored private var url: URL?

    private struct Document: Codable {
        var schemaVersion = 1
        var entries: [PopupException]
    }

    public init() {}

    public func load(from url: URL) throws {
        self.url = url
        entries = []
        isWritable = false
        errorMessage = nil
        do {
            if let data = try JSONStorage.read(url) {
                let document = try JSONStorage.decode(Document.self, from: data, schema: 1)
                guard document.entries.count <= Self.maximumEntries,
                      Set(document.entries.map(\.id)).count == document.entries.count,
                      document.entries.allSatisfy({
                          SiteOrigin.normalize($0.origin) == $0.origin
                              && $0.origin.utf8.count <= 4_096
                              && $0.profileID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil
                              && $0.allowedAt.timeIntervalSince1970.isFinite
                      }) else { throw ServiceError.invalidData("Invalid popup exceptions.") }
                entries = document.entries
            }
            isWritable = true
        } catch {
            errorMessage = "\(error.localizedDescription) The original file is preserved. Popup exceptions are disabled and cannot be changed this session."
            throw error
        }
    }

    public func allows(spaceID: UUID, profileID: String, origin: String) -> Bool {
        guard let origin = SiteOrigin.normalize(origin) else { return false }
        return entries.contains { $0.spaceID == spaceID && $0.profileID == profileID && $0.origin == origin }
    }

    public func entries(spaceID: UUID, profileID: String) -> [PopupException] {
        entries.filter { $0.spaceID == spaceID && $0.profileID == profileID }.sorted { $0.origin < $1.origin }
    }

    @discardableResult
    public func allow(spaceID: UUID, profileID: String, origin: String, now: Date = Date()) -> Bool {
        guard isWritable, let origin = SiteOrigin.normalize(origin), origin.utf8.count <= 4_096,
              profileID.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil,
              now.timeIntervalSince1970.isFinite else { return false }
        if allows(spaceID: spaceID, profileID: profileID, origin: origin) { return true }
        guard entries.count < Self.maximumEntries else {
            let error = ServiceError.limit("Too many popup exceptions. Revoke an exception before adding another.")
            errorMessage = error.localizedDescription
            onError?(error)
            return false
        }
        let next = entries + [PopupException(spaceID: spaceID, profileID: profileID, origin: origin, allowedAt: now)]
        guard save(next, revoking: false) else { return false }
        entries = next
        return true
    }

    @discardableResult
    public func revoke(_ id: String) -> Bool {
        remove { $0.id == id }
    }

    @discardableResult
    public func removeAll(spaceID: UUID) -> Bool {
        remove { $0.spaceID == spaceID }
    }

    /// Removes stale grants after a successfully loaded workspace, including a changed profile identity.
    @discardableResult
    public func retain(spaces: [Space]) -> Bool {
        remove { entry in !spaces.contains { $0.id == entry.spaceID && $0.profileID == entry.profileID } }
    }

    private func remove(where predicate: (PopupException) -> Bool) -> Bool {
        let next = entries.filter { !predicate($0) }
        guard next != entries else { return true }
        entries = next
        return save(next, revoking: true)
    }

    private func save(_ next: [PopupException], revoking: Bool) -> Bool {
        guard isWritable, let url else {
            if revoking {
                let message = "Revoked exceptions are blocked now, but could not be saved and may return after restarting. The saved file is preserved."
                errorMessage = message
                onError?(ServiceError.invalidData(message))
            }
            return false
        }
        do {
            try JSONStorage.write(Document(entries: next), to: url)
            errorMessage = nil
            return true
        } catch {
            isWritable = false
            errorMessage = revoking
                ? "Popup exceptions could not be saved. Revoked exceptions are blocked now, but may return after restarting. \(error.localizedDescription)"
                : "The popup exception was not allowed because it could not be saved. \(error.localizedDescription)"
            onError?(error)
            return false
        }
    }
}

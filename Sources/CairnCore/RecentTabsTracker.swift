import Foundation

/// Most-recently-used tab ids, newest first, for the ⌃Tab switcher.
public struct RecentTabsTracker: Equatable, Sendable {
    public static let defaultCapacity = 50
    public private(set) var ids: [UUID] = []
    public let capacity: Int

    public init(capacity: Int = RecentTabsTracker.defaultCapacity) { self.capacity = max(2, capacity) }

    public mutating func touch(_ id: UUID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > capacity { ids.removeLast(ids.count - capacity) }
    }

    public mutating func forget(_ id: UUID) { ids.removeAll { $0 == id } }

    /// Recent ids that still exist; the first is the current tab.
    public func candidates(valid: Set<UUID>) -> [UUID] { ids.filter(valid.contains) }
}

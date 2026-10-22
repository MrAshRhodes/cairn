import Foundation

public struct ClosedTab: Equatable, Sendable {
    public var item: TabItem
    public var spaceID: UUID?
    public var list: TabList
    public var index: Int
    /// Tabs closed together (Clear Today) share a batch and are restored together.
    public var batch: UUID?
}

/// Recently closed tabs, newest last. Capacity counts entries; the newest batch is never trimmed so a bulk close stays undoable.
public struct ClosedTabsStack: Equatable, Sendable {
    public static let defaultCapacity = 25
    public private(set) var entries: [ClosedTab] = []
    public let capacity: Int

    public init(capacity: Int = ClosedTabsStack.defaultCapacity) { self.capacity = max(1, capacity) }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public mutating func push(_ tab: ClosedTab) {
        entries.removeAll { $0.item.id == tab.item.id }
        entries.append(tab)
        let protected = tab.batch
        while entries.count > capacity, let first = entries.first, protected == nil || first.batch != protected {
            entries.removeFirst()
        }
    }

    /// Removes and returns the newest closed tab, or its whole batch.
    public mutating func pop() -> [ClosedTab] {
        guard let last = entries.last else { return [] }
        guard let batch = last.batch else { entries.removeLast(); return [last] }
        let group = entries.filter { $0.batch == batch }
        entries.removeAll { $0.batch == batch }
        return group
    }

    public mutating func removeAll() { entries.removeAll() }
}

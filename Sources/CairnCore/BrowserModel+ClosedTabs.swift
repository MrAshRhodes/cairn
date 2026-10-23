import Foundation

extension BrowserModel {
    func recordClosed(_ item: TabItem, at location: TabLocation, batch: UUID? = nil) {
        closedTabs.push(ClosedTab(item: item, spaceID: location.spaceIndex.map { workspace.spaces[$0].id },
                                  list: location.list, index: location.index, batch: batch))
    }

    /// Restores the most recently closed tab (or batch) to its Space, list and position. Returns the restored ids.
    @discardableResult
    public func reopenClosedTab() -> [UUID] {
        var restored: [UUID] = []
        for closed in closedTabs.pop() where locate(closed.item.id) == nil {
            let spaceID = closed.spaceID.flatMap { spaceIndex($0) != nil ? $0 : nil } ?? selectedSpace.id
            let list: TabList = closed.list == .archive ? .today : closed.list
            let target = list == .favorites ? nil : spaceIndex(spaceID)
            var item = closed.item
            item.lastActiveAt = Date()
            insert(item, list: list, spaceIndex: target, at: closed.index)
            restored.append(item.id)
        }
        if let first = restored.last { select(first) } else { changed() }
        return restored
    }

    public var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Closes every unpinned tab of the selected Space. The close is one undoable batch.
    public func clearToday() {
        let space = selectedSpace
        guard !space.tabs.isEmpty else { return }
        let batch = UUID()
        for (originalIndex, tab) in space.tabs.enumerated() {
            guard var location = locate(tab.id) else { continue }
            unloadTab(tab.id)
            let removed = remove(at: location)
            location.index = originalIndex
            recordClosed(removed, at: location, batch: batch)
            recentTabs.forget(tab.id)
        }
        repairReferences()
        if let next = selectedTabID { _ = liveTab(for: next) }
        changed()
    }
}

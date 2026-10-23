import Foundation

// MARK: Split view
extension BrowserModel {
    /// The split holding the selected tab, if it belongs to the selected Space.
    public var activeSplit: SplitGroup? {
        guard let id = selectedTabID, let group = splitGroup(containing: id),
              group.spaceID == selectedSpace.id else { return nil }
        return group
    }

    /// Tab ids of the visible split in pane order; empty when the selected tab is not in a split.
    public var splitTabIDs: [UUID] { activeSplit?.layout.tabIDs ?? [] }

    public func splitGroup(containing id: UUID) -> SplitGroup? {
        splitGroups.first { $0.layout.contains(id) }
    }

    /// Opens `other` next to the selected tab (or `target`) on `edge`, creating the split if needed.
    @discardableResult
    public func addToSplit(_ other: UUID, edge: SplitEdge = .right, beside target: UUID? = nil) -> Bool {
        guard let anchor = target ?? selectedTabID, anchor != other,
              isVisible(anchor, in: selectedSpaceIndex), isVisible(other, in: selectedSpaceIndex) else { return false }
        let existing = splitGroup(containing: anchor)
        if let existing, existing.layout.contains(other) { return false }
        guard (existing?.layout.paneCount ?? 1) < SplitLayout.maximumPanes else {
            report(ServiceError.navigation("Split view holds up to \(SplitLayout.maximumPanes) tabs."))
            return false
        }
        var groups = splitGroups
        // A tab belongs to one split; adding it elsewhere takes it out of its old split.
        if let old = groups.firstIndex(where: { $0.layout.contains(other) }) {
            if let reduced = groups[old].layout.removing(other), reduced.paneCount >= SplitLayout.minimumPanes {
                groups[old].layout = reduced
            } else { groups.remove(at: old) }
        }
        let spaceID = selectedSpace.id
        if let index = groups.firstIndex(where: { $0.layout.contains(anchor) }) {
            guard let layout = groups[index].layout.adding(other, beside: anchor, edge: edge) else { return false }
            groups[index].layout = layout
        } else {
            guard let layout = SplitLayout(tab: anchor).adding(other, beside: anchor, edge: edge) else { return false }
            groups.append(SplitGroup(spaceID: spaceID, layout: layout))
        }
        _ = liveTab(for: other)
        splitGroups = groups
        changed()
        return true
    }

    public func splitSelected(with other: UUID) { addToSplit(other, edge: .right) }

    /// Takes a pane out of its split; the tab itself stays where it is. A split left with one pane dissolves.
    public func removeFromSplit(_ id: UUID) {
        guard let index = splitGroups.firstIndex(where: { $0.layout.contains(id) }) else { return }
        var groups = splitGroups
        if let reduced = groups[index].layout.removing(id), reduced.paneCount >= SplitLayout.minimumPanes {
            groups[index].layout = reduced
        } else { groups.remove(at: index) }
        splitGroups = groups
        changed()
    }

    func detachFromSplit(_ id: UUID) { removeFromSplit(id) }

    /// "Separate All Tabs": dissolves the split holding the selected tab.
    public func closeSplit() {
        guard let group = activeSplit else { return }
        splitGroups.removeAll { $0.id == group.id }
        changed()
    }

    /// Selects pane `index` (0-based) of the visible split.
    public func focusPane(_ index: Int) {
        let ids = splitTabIDs
        guard ids.indices.contains(index) else { return }
        select(ids[index])
    }

    public func moveSplitDivider(group id: UUID, path: [Int], index: Int, to fraction: Double, minimumFraction: Double) {
        guard let position = splitGroups.firstIndex(where: { $0.id == id }) else { return }
        var groups = splitGroups
        groups[position].layout = groups[position].layout.movingDivider(
            path: path, index: index, to: fraction, minimumFraction: minimumFraction)
        splitGroups = groups
        onChange?()
    }

    /// Replaces saved groups at launch. Invalid panes and groups are repaired away.
    public func restoreSplits(_ groups: [SplitGroup]) {
        splitGroups = groups
        repairSplits()
        onChange?()
    }

    func repairSplits() {
        var claimed = Set<UUID>()
        var repaired: [SplitGroup] = []
        for group in splitGroups {
            guard let space = spaceIndex(group.spaceID) else { continue }
            let visible = Set((workspace.favorites + workspace.spaces[space].pinned + workspace.spaces[space].tabs).map(\.id))
            guard let layout = group.layout.repaired(validTabs: visible.subtracting(claimed)) else { continue }
            claimed.formUnion(layout.tabIDs)
            repaired.append(SplitGroup(id: group.id, spaceID: group.spaceID, layout: layout))
        }
        if repaired != splitGroups { splitGroups = repaired }
    }
}

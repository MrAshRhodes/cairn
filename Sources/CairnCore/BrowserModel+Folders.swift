import Foundation

/// Pinned-tab folders, favorites limits and pin maintenance. Folders live in `Space.folders`; a pinned tab joins one
/// through `TabItem.folderID`. Everything here is in-memory and reports through `onChange` like the rest of the model.
extension BrowserModel {
    // MARK: Lookup
    public func folders(in spaceID: UUID? = nil) -> [TabFolder] {
        (spaceIndex(spaceID).map { workspace.spaces[$0] } ?? selectedSpace).folders ?? []
    }

    public func folder(_ id: UUID) -> TabFolder? {
        workspace.spaces.lazy.compactMap { $0.folders?.first { $0.id == id } }.first
    }

    /// Folders directly under `parentID` (nil = top level), in stored order.
    public func childFolders(of parentID: UUID?, in spaceID: UUID? = nil) -> [TabFolder] {
        folders(in: spaceID).filter { $0.parentID == parentID }
    }

    /// Pinned tabs directly inside `folderID` (nil = top level), in pinned order.
    public func pinnedTabs(in folderID: UUID?, spaceID: UUID? = nil) -> [TabItem] {
        let space = spaceIndex(spaceID).map { workspace.spaces[$0] } ?? selectedSpace
        return space.pinned.filter { $0.folderID == folderID }
    }

    /// 1 for a top-level folder.
    public func folderDepth(_ id: UUID) -> Int? {
        guard let space = workspace.spaces.first(where: { $0.folders?.contains { $0.id == id } == true }),
              let folders = space.folders else { return nil }
        return Self.depth(of: id, in: folders)
    }

    // MARK: Folder operations
    @discardableResult
    public func createFolder(name: String, parent: UUID? = nil, in spaceID: UUID? = nil) -> UUID? {
        let s = spaceIndex(spaceID) ?? selectedSpaceIndex
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { report(ServiceError.limit("A folder needs a name.")); return nil }
        let existing = workspace.spaces[s].folders ?? []
        if let parent {
            guard let depth = Self.depth(of: parent, in: existing) else { return nil }
            guard depth < TabFolder.maximumDepth else {
                report(ServiceError.limit("Folders can be nested at most \(TabFolder.maximumDepth) levels deep."))
                return nil
            }
        }
        let folder = TabFolder(name: String(trimmed.prefix(TabFolder.maximumNameLength)), parentID: parent)
        workspace.spaces[s].folders = existing + [folder]
        changed()
        return folder.id
    }

    public func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateFolder(id) { $0.name = String(trimmed.prefix(TabFolder.maximumNameLength)) }
    }

    public func setFolderCollapsed(_ id: UUID, _ collapsed: Bool) {
        mutateFolder(id) { $0.collapsed = collapsed }
    }

    /// Deleting a folder ungroups it: its tabs and sub-folders move up to the parent. No tab is ever closed.
    public func deleteFolder(_ id: UUID) {
        guard let s = folderSpaceIndex(id), var folders = workspace.spaces[s].folders,
              let folder = folders.first(where: { $0.id == id }) else { return }
        folders.removeAll { $0.id == id }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = folder.parentID }
        for i in workspace.spaces[s].pinned.indices where workspace.spaces[s].pinned[i].folderID == id {
            workspace.spaces[s].pinned[i].folderID = folder.parentID
        }
        workspace.spaces[s].folders = folders.isEmpty ? nil : folders
        changed()
    }

    /// Re-parents a folder (nil = top level). Cycles and nesting beyond the depth limit are refused with a message.
    public func moveFolder(_ id: UUID, toParent parentID: UUID?) {
        guard let s = folderSpaceIndex(id), let folders = workspace.spaces[s].folders else { return }
        if let parentID {
            guard folders.contains(where: { $0.id == parentID }) else { return }
            var cursor: UUID? = parentID
            while let current = cursor {
                if current == id { report(ServiceError.limit("A folder cannot be moved into itself.")); return }
                cursor = folders.first { $0.id == current }?.parentID
            }
            let subtreeHeight = Self.height(of: id, in: folders)
            if (Self.depth(of: parentID, in: folders) ?? 0) + subtreeHeight > TabFolder.maximumDepth {
                report(ServiceError.limit("Folders can be nested at most \(TabFolder.maximumDepth) levels deep."))
                return
            }
        }
        mutateFolder(id) { $0.parentID = parentID }
    }

    // MARK: Pinning
    /// Pins a tab into a folder of its Space (or at the top level of Pinned when `folderID` is nil).
    public func pin(_ id: UUID, toFolder folderID: UUID?, at index: Int? = nil) {
        guard let loc = locate(id) else { return }
        let spaceIndex: Int
        if loc.list == .favorites || loc.spaceIndex == nil { spaceIndex = selectedSpaceIndex } else { spaceIndex = loc.spaceIndex! }
        if let folderID, !(workspace.spaces[spaceIndex].folders ?? []).contains(where: { $0.id == folderID }) {
            report(ServiceError.limit("That folder belongs to another Space."))
            return
        }
        moveTab(id, to: .pinned, in: workspace.spaces[spaceIndex].id, at: index)
        update(id) { $0.folderID = folderID }
        changed()
    }

    /// Makes a pinned tab's saved address the page it shows now ("Replace Pin with Current Page").
    public func replacePinWithCurrentPage(_ id: UUID) {
        guard let loc = locate(id), loc.list == .pinned || loc.list == .favorites,
              let url = tabStates[id]?.url ?? item(id)?.url, URLResolver.isNavigable(url) else { return }
        update(id) { $0.homeURL = url }
        changed()
    }

    public func setPinnedCollapsed(_ collapsed: Bool, in spaceID: UUID? = nil) {
        let s = spaceIndex(spaceID) ?? selectedSpaceIndex
        workspace.spaces[s].pinnedCollapsed = collapsed ? true : nil
        changed()
    }

    /// Copies a tab next to the original (same list and folder). The copy is a new tab with the same address.
    @discardableResult
    public func duplicateTab(_ id: UUID) -> UUID? {
        guard let loc = locate(id), loc.list != .archive, loc.list != .favorites, var copy = item(id) else { return nil }
        if loc.list == .pinned { copy.homeURL = copy.homeURL ?? copy.url }
        copy.id = UUID(); copy.createdAt = Date(); copy.lastActiveAt = Date()
        let s = loc.spaceIndex ?? selectedSpaceIndex
        if loc.list == .pinned { workspace.spaces[s].pinned.insert(copy, at: loc.index + 1) }
        else { workspace.spaces[s].tabs.insert(copy, at: loc.index + 1) }
        changed()
        return copy.id
    }

    // MARK: Internals
    func repairFolders(in s: Int) {
        var folders = workspace.spaces[s].folders ?? []
        var seen = Set<UUID>()
        folders = folders.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
        let ids = Set(folders.map(\.id))
        for i in folders.indices {
            if let parent = folders[i].parentID, !ids.contains(parent) || parent == folders[i].id { folders[i].parentID = nil }
        }
        // Break cycles and flatten anything deeper than the limit by lifting it to the top level.
        for i in folders.indices {
            var chain = Set<UUID>([folders[i].id])
            var cursor = folders[i].parentID
            var depth = 1
            while let current = cursor {
                if !chain.insert(current).inserted || depth >= TabFolder.maximumDepth {
                    folders[i].parentID = nil
                    break
                }
                depth += 1
                cursor = folders.first { $0.id == current }?.parentID
            }
        }
        let normalized: [TabFolder]? = folders.isEmpty ? nil : folders
        if normalized != workspace.spaces[s].folders { workspace.spaces[s].folders = normalized }
        let valid = Set(folders.map(\.id))
        for i in workspace.spaces[s].pinned.indices {
            if let f = workspace.spaces[s].pinned[i].folderID, !valid.contains(f) { workspace.spaces[s].pinned[i].folderID = nil }
        }
        for i in workspace.spaces[s].tabs.indices where workspace.spaces[s].tabs[i].folderID != nil {
            workspace.spaces[s].tabs[i].folderID = nil
        }
        for i in workspace.spaces[s].archive.indices where workspace.spaces[s].archive[i].folderID != nil {
            workspace.spaces[s].archive[i].folderID = nil
        }
        if let theme = workspace.spaces[s].theme, !theme.isValid { workspace.spaces[s].theme = nil }
    }

    private func folderSpaceIndex(_ id: UUID) -> Int? {
        workspace.spaces.firstIndex { $0.folders?.contains { $0.id == id } == true }
    }

    private func mutateFolder(_ id: UUID, _ body: (inout TabFolder) -> Void) {
        guard let s = folderSpaceIndex(id), let i = workspace.spaces[s].folders?.firstIndex(where: { $0.id == id }) else { return }
        let before = workspace.spaces[s].folders![i]
        body(&workspace.spaces[s].folders![i])
        guard workspace.spaces[s].folders![i] != before else { return }
        changed()
    }

    static func depth(of id: UUID, in folders: [TabFolder]) -> Int? {
        var depth = 0
        var cursor: UUID? = id
        var seen = Set<UUID>()
        while let current = cursor {
            guard let folder = folders.first(where: { $0.id == current }), seen.insert(current).inserted else { return nil }
            depth += 1
            cursor = folder.parentID
        }
        return depth
    }

    private static func height(of id: UUID, in folders: [TabFolder]) -> Int {
        1 + (folders.filter { $0.parentID == id }.map { height(of: $0.id, in: folders) }.max() ?? 0)
    }
}

import AppKit
import Observation
import CairnEngineKit

public struct TabLocation: Equatable, Sendable {
    public var list: TabList
    public var spaceIndex: Int?
    public var index: Int
    public init(list: TabList, spaceIndex: Int?, index: Int) { self.list = list; self.spaceIndex = spaceIndex; self.index = index }
}

/// Single source of truth for the browser's tabs, spaces and live engine tabs.
/// FROZEN public API (see CairnEngineKit/Engine.swift for the rule). Mutate state only through these methods so that
/// `onChange` (persistence hook) fires. All logic here is in-memory; persistence/history/settings live in other files.
@MainActor @Observable
public final class BrowserModel: EngineTabDelegate {
    public var workspace: Workspace
    /// 0 or 2 tab ids shown side by side (split view).
    public var splitTabIDs: [UUID] = []
    public var tabStates: [UUID: EngineTabState] = [:]
    public var favicons: [UUID: NSImage] = [:]
    public var searchTemplate = URLResolver.defaultSearchTemplate

    public let engine: BrowserEngine
    @ObservationIgnored public private(set) var liveTabs: [UUID: EngineTab] = [:]
    /// Returns the user scripts (Boosts, modules) to inject for a URL. Set by the app at launch.
    @ObservationIgnored public var userScriptProvider: ((URL?) -> [EngineUserScript])?
    @ObservationIgnored public var downloadHandler: ((URL, String?) -> Void)?
    /// Fired after every mutation of `workspace`; persistence subscribes here.
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onNavigationCommitted: ((URL, String) -> Void)?
    @ObservationIgnored public var onError: ((Error) -> Void)?
    public private(set) var errorMessage: String?
    @ObservationIgnored private var liveProfileIDs: [UUID: String] = [:]
    @ObservationIgnored private var liveSpaceIDs: [UUID: UUID] = [:]

    public init(engine: BrowserEngine, workspace: Workspace = .makeDefault()) {
        self.engine = engine
        self.workspace = workspace.spaces.isEmpty ? .makeDefault() : workspace
        repairReferences()
    }

    // MARK: Lookup
    public var selectedSpaceIndex: Int {
        workspace.spaces.firstIndex { $0.id == workspace.selectedSpaceID } ?? 0
    }
    public var selectedSpace: Space { workspace.spaces[selectedSpaceIndex] }
    public var selectedTabID: UUID? { selectedSpace.selectedTabID }
    public var selectedTab: TabItem? { selectedTabID.flatMap(item) }

    public func spaceIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return workspace.spaces.firstIndex { $0.id == id }
    }

    public func locate(_ id: UUID) -> TabLocation? {
        if let i = workspace.favorites.firstIndex(where: { $0.id == id }) { return .init(list: .favorites, spaceIndex: nil, index: i) }
        for (s, space) in workspace.spaces.enumerated() {
            if let i = space.pinned.firstIndex(where: { $0.id == id }) { return .init(list: .pinned, spaceIndex: s, index: i) }
            if let i = space.tabs.firstIndex(where: { $0.id == id }) { return .init(list: .today, spaceIndex: s, index: i) }
            if let i = space.archive.firstIndex(where: { $0.id == id }) { return .init(list: .archive, spaceIndex: s, index: i) }
        }
        return nil
    }

    public func item(_ id: UUID) -> TabItem? {
        guard let loc = locate(id) else { return nil }
        switch loc.list {
        case .favorites: return workspace.favorites[loc.index]
        case .pinned: return workspace.spaces[loc.spaceIndex!].pinned[loc.index]
        case .today: return workspace.spaces[loc.spaceIndex!].tabs[loc.index]
        case .archive: return workspace.spaces[loc.spaceIndex!].archive[loc.index]
        }
    }

    // MARK: Live engine tabs
    /// The engine tab for an item, created (and loaded) on first use.
    public func liveTab(for id: UUID) -> EngineTab? {
        guard let loc = locate(id), loc.list != .archive, let item = item(id) else { return nil }
        let space = workspace.spaces[loc.spaceIndex ?? selectedSpaceIndex]
        if let t = liveTabs[id], liveProfileIDs[id] == space.profileID { return t }
        unloadTab(id)
        // Factories must not start navigation before delegates, scripts and reverse lookup are ready.
        let t = engine.makeTab(configuration: EngineConfiguration(profileID: space.profileID), initialURL: nil)
        liveTabs[id] = t
        liveProfileIDs[id] = space.profileID
        liveSpaceIDs[id] = space.id
        t.delegate = self
        t.setUserScripts(userScriptProvider?(item.url) ?? [])
        if let url = item.url {
            if URLResolver.isNavigable(url) { t.load(url) }
            else { report(ServiceError.navigation("Unsupported navigation URL.")) }
        }
        return t
    }

    public func unloadTab(_ id: UUID) {
        let tab = liveTabs[id]
        liveTabs[id] = nil; tabStates[id] = nil; favicons[id] = nil
        liveProfileIDs[id] = nil; liveSpaceIDs[id] = nil
        tab?.delegate = nil
        tab?.close()
    }

    /// Re-applies `userScriptProvider` to every live tab (call after Boosts change).
    public func refreshUserScripts() {
        for (id, t) in liveTabs { t.setUserScripts(userScriptProvider?(item(id)?.url) ?? []) }
    }

    // MARK: Tabs
    @discardableResult
    public func newTab(url: URL? = nil, in spaceID: UUID? = nil, activate: Bool = true) -> UUID {
        let s = spaceIndex(spaceID) ?? selectedSpaceIndex
        let validURL = url.flatMap { URLResolver.isNavigable($0) ? $0 : nil }
        if url != nil, validURL == nil { report(ServiceError.navigation("Unsupported navigation URL.")) }
        let tab = TabItem(url: validURL)
        workspace.spaces[s].tabs.append(tab)
        if activate { select(tab.id) } else { _ = liveTab(for: tab.id) }
        changed()
        return tab.id
    }

    public func select(_ id: UUID) {
        guard let loc = locate(id) else { return }
        if loc.list == .archive { moveTab(id, to: .today, in: workspace.spaces[loc.spaceIndex!].id) }
        let s = loc.spaceIndex ?? selectedSpaceIndex
        workspace.selectedSpaceID = workspace.spaces[s].id
        workspace.spaces[s].selectedTabID = id
        update(id) { $0.lastActiveAt = Date() }
        repairReferences()
        _ = liveTab(for: id)
        if !splitTabIDs.contains(id) { splitTabIDs = [] }
        changed()
    }

    public func selectSpace(_ id: UUID) {
        guard let s = spaceIndex(id) else { return }
        workspace.selectedSpaceID = id
        repairReferences()
        if let t = workspace.spaces[s].selectedTabID { _ = liveTab(for: t) }
        splitTabIDs = []
        changed()
    }

    /// Closes a tab. Pinned tabs and favorites are only unloaded (they stay in the sidebar); other tabs are removed.
    public func closeTab(_ id: UUID) {
        guard let loc = locate(id) else { return }
        if loc.list == .pinned || loc.list == .favorites {
            unloadTab(id)
            if splitTabIDs.contains(id) { splitTabIDs = [] }
            for s in workspace.spaces.indices where workspace.spaces[s].selectedTabID == id {
                workspace.spaces[s].selectedTabID = nextSelectable(in: s, excluding: id)
            }
            changed()
            return
        }
        removeTab(id)
    }

    public func removeTab(_ id: UUID) {
        guard let loc = locate(id) else { return }
        unloadTab(id)
        splitTabIDs.removeAll { $0 == id }
        if splitTabIDs.count < 2 { splitTabIDs = [] }
        remove(at: loc)
        repairReferences()
        if let next = selectedTabID { _ = liveTab(for: next) }
        changed()
    }

    public func moveTab(_ id: UUID, to list: TabList, in spaceID: UUID? = nil, at index: Int? = nil) {
        guard let loc = locate(id), var moved = item(id) else { return }
        if list == .favorites, loc.list != .favorites, workspace.favorites.count >= Workspace.maximumFavorites {
            report(ServiceError.limit("Favorites hold at most \(Workspace.maximumFavorites) tabs. Remove one first."))
            return
        }
        let target = list == .favorites ? nil : (spaceIndex(spaceID) ?? loc.spaceIndex ?? selectedSpaceIndex)
        if list == .archive || target != loc.spaceIndex || (list == .favorites) != (loc.list == .favorites) {
            unloadTab(id)
        }
        remove(at: loc)
        if list != .pinned || target != loc.spaceIndex || loc.list != .pinned { moved.folderID = nil }
        if list == .pinned || list == .favorites { moved.homeURL = moved.homeURL ?? moved.url } else { moved.homeURL = nil }
        insert(moved, list: list, spaceIndex: target, at: index)
        changed()
    }

    public func pin(_ id: UUID) { moveTab(id, to: .pinned) }
    public func unpin(_ id: UUID) { moveTab(id, to: .today) }
    public func favorite(_ id: UUID) { moveTab(id, to: .favorites) }
    public func unfavorite(_ id: UUID) { moveTab(id, to: .today) }

    /// Sets a persistent display name without changing page metadata. Nil or a blank name restores the page title.
    public func renameTab(_ id: UUID, title: String?) {
        guard let tab = item(id) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(TabItem.maximumTitleLength))
        guard tab.customTitle != customTitle else { return }
        update(id) { $0.customTitle = customTitle }
        changed()
    }

    /// Moves inactive "today" tabs older than `interval` into the Space's archive.
    public func archiveStaleTabs(olderThan interval: TimeInterval, now: Date = Date()) {
        guard interval.isFinite, interval > 0 else { return }
        for s in workspace.spaces.indices {
            let stale = workspace.spaces[s].tabs.filter {
                $0.id != workspace.spaces[s].selectedTabID && !splitTabIDs.contains($0.id)
                    && now.timeIntervalSince($0.lastActiveAt) > interval
            }
            for t in stale { unloadTab(t.id); moveTab(t.id, to: .archive, in: workspace.spaces[s].id) }
        }
    }

    // MARK: Navigation
    public func navigate(_ input: String) {
        guard let url = URLResolver.resolve(input, searchTemplate: searchTemplate) else {
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report(ServiceError.navigation("The address or search template is invalid."))
            }
            return
        }
        if let id = selectedTabID, item(id) != nil { load(url, in: id) } else { newTab(url: url) }
    }

    public func load(_ url: URL, in id: UUID) {
        guard URLResolver.isNavigable(url) else { report(ServiceError.navigation("Unsupported navigation URL.")); return }
        guard let loc = locate(id) else { return }
        if loc.list == .archive { moveTab(id, to: .today, in: workspace.spaces[loc.spaceIndex!].id) }
        errorMessage = nil
        update(id) { $0.url = url }
        if let t = liveTabs[id] {
            t.setUserScripts(userScriptProvider?(url) ?? [])
            t.load(url)
        } else { _ = liveTab(for: id) }
        changed()
    }

    // MARK: Split view
    public func splitSelected(with other: UUID) {
        guard let current = selectedTabID, current != other, isVisible(current, in: selectedSpaceIndex),
              isVisible(other, in: selectedSpaceIndex) else { return }
        _ = liveTab(for: other)
        splitTabIDs = [current, other]
    }
    public func closeSplit() { splitTabIDs = [] }

    // MARK: Spaces
    @discardableResult
    public func addSpace(name: String, icon: String = "circle.grid.2x2", colorHex: String = "#7C5CFF") -> UUID {
        let space = Space(name: name, icon: icon, colorHex: colorHex)
        workspace.spaces.append(space)
        selectSpace(space.id)
        return space.id
    }

    public func updateSpace(_ id: UUID, _ body: (inout Space) -> Void) {
        guard let s = spaceIndex(id) else { return }
        let previous = workspace
        body(&workspace.spaces[s])
        do { try workspace.validate() }
        catch { workspace = previous; report(error); return }
        changed()
    }

    /// The last remaining Space cannot be removed.
    public func removeSpace(_ id: UUID) {
        guard workspace.spaces.count > 1, let s = spaceIndex(id) else { return }
        let space = workspace.spaces[s]
        (space.pinned + space.tabs + space.archive).forEach { unloadTab($0.id) }
        workspace.spaces.remove(at: s)
        if workspace.selectedSpaceID == id {
            workspace.selectedSpaceID = workspace.spaces[0].id
            splitTabIDs = []
        }
        repairReferences()
        changed()
    }

    // MARK: EngineTabDelegate
    private func itemID(for tab: EngineTab) -> UUID? { liveTabs.first { $0.value === tab }?.key }

    public func engineTab(_ tab: EngineTab, didChange state: EngineTabState) {
        guard let id = itemID(for: tab) else { return }
        var state = state
        state.title = String(state.title.prefix(TabItem.maximumTitleLength))
        let previous = tabStates[id]
        tabStates[id] = state
        let before = item(id)
        update(id) {
            if let url = state.url, URLResolver.isNavigable(url) { $0.url = url }
            if !state.title.isEmpty { $0.title = state.title }
        }
        if item(id) != before { changed() }
        if let error = state.errorMessage, error != previous?.errorMessage {
            report(ServiceError.navigation(error))
        }
        if !state.isLoading, state.errorMessage == nil, previous?.isLoading == true, let url = state.url,
           URLResolver.isWebURL(url) {
            onNavigationCommitted?(url, state.title)
        }
    }
    public func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) {
        if let id = itemID(for: tab) { favicons[id] = image }
    }
    public func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) {
        guard let id = itemID(for: tab), let origin = liveSpaceIDs[id], spaceIndex(origin) != nil else { return }
        newTab(url: url, in: origin, activate: activate)
    }
    public func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {
        guard itemID(for: tab) != nil else { return }
        guard let downloadHandler else { report(ServiceError.invalidDownload("No download handler is configured.")); return }
        downloadHandler(url, suggestedFilename)
    }
    public func engineTabDidRequestClose(_ tab: EngineTab) { if let id = itemID(for: tab) { closeTab(id) } }

    // MARK: Internals
    func changed() { repairReferences(); onChange?() }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        onError?(error)
    }

    func isVisible(_ id: UUID, in space: Int) -> Bool {
        workspace.favorites.contains { $0.id == id }
            || workspace.spaces[space].pinned.contains { $0.id == id }
            || workspace.spaces[space].tabs.contains { $0.id == id }
    }

    private func nextSelectable(in space: Int, excluding id: UUID) -> UUID? {
        workspace.spaces[space].tabs.last(where: { $0.id != id })?.id
            ?? workspace.spaces[space].pinned.last(where: { $0.id != id })?.id
            ?? workspace.favorites.first(where: { $0.id != id })?.id
    }

    private func repairReferences() {
        if spaceIndex(workspace.selectedSpaceID) == nil { workspace.selectedSpaceID = workspace.spaces.first?.id }
        for s in workspace.spaces.indices {
            if let selected = workspace.spaces[s].selectedTabID, !isVisible(selected, in: s) {
                workspace.spaces[s].selectedTabID = nextSelectable(in: s, excluding: selected)
            }
        }
        if splitTabIDs.count != 2 || Set(splitTabIDs).count != 2
            || !splitTabIDs.allSatisfy({ isVisible($0, in: selectedSpaceIndex) })
            || !(selectedTabID.map { splitTabIDs.contains($0) } ?? false) {
            splitTabIDs = []
        }
        for s in workspace.spaces.indices { repairFolders(in: s) }
        // A favorite is global metadata, not a global cookie jar. Recreate its live view on Space changes.
        for id in Array(liveTabs.keys) {
            guard let location = locate(id), location.list != .archive else { unloadTab(id); continue }
            let space = workspace.spaces[location.spaceIndex ?? selectedSpaceIndex]
            if liveProfileIDs[id] != space.profileID || liveSpaceIDs[id] != space.id { unloadTab(id) }
        }
    }

    func update(_ id: UUID, _ body: (inout TabItem) -> Void) {
        guard let loc = locate(id) else { return }
        switch loc.list {
        case .favorites: body(&workspace.favorites[loc.index])
        case .pinned: body(&workspace.spaces[loc.spaceIndex!].pinned[loc.index])
        case .today: body(&workspace.spaces[loc.spaceIndex!].tabs[loc.index])
        case .archive: body(&workspace.spaces[loc.spaceIndex!].archive[loc.index])
        }
    }

    @discardableResult
    private func remove(at loc: TabLocation) -> TabItem {
        switch loc.list {
        case .favorites: return workspace.favorites.remove(at: loc.index)
        case .pinned: return workspace.spaces[loc.spaceIndex!].pinned.remove(at: loc.index)
        case .today: return workspace.spaces[loc.spaceIndex!].tabs.remove(at: loc.index)
        case .archive: return workspace.spaces[loc.spaceIndex!].archive.remove(at: loc.index)
        }
    }

    private func insert(_ item: TabItem, list: TabList, spaceIndex s: Int?, at index: Int?) {
        func put(_ array: inout [TabItem]) { array.insert(item, at: min(max(index ?? array.count, 0), array.count)) }
        switch list {
        case .favorites: put(&workspace.favorites)
        case .pinned: put(&workspace.spaces[s ?? selectedSpaceIndex].pinned)
        case .today: put(&workspace.spaces[s ?? selectedSpaceIndex].tabs)
        case .archive: put(&workspace.spaces[s ?? selectedSpaceIndex].archive)
        }
    }
}

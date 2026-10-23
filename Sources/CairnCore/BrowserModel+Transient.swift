import Foundation
import CairnEngineKit

public struct TransientPage: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case peek, quickWindow }
    public let id: UUID
    public let kind: Kind
    public let spaceID: UUID
    public let profileID: String
    public let ownerTabID: UUID?
}

extension BrowserModel: EngineTabNavigationEvents {
    public func engineTab(_ tab: EngineTab, interceptsUserNavigation url: URL) -> Bool {
        guard !isClosingWorkspace, !isWorkspaceSuspended, closeRequests.isEmpty,
              !peek.isOpen, let id = itemID(for: tab), !openerBoundTabIDs.contains(id), let location = locate(id),
              let origin = liveSpaceIDs[id], let index = spaceIndex(origin),
              workspace.spaces[index].profileID == liveProfileIDs[id],
              PeekPolicy.decide(from: tab.state.url ?? item(id)?.url, to: url,
                                sourceIsPinnedOrFavorite: location.list == .pinned || location.list == .favorites,
                                enabled: peekEnabled?() ?? false) == .peek else { return false }
        let page = createTransient(url: url, kind: .peek, space: workspace.spaces[index], owner: id)
        peek.open(url, in: origin, tabID: page, ownerTabID: id)
        return true
    }

    /// Creates a non-private page in the named Space's profile, without adding session metadata.
    @discardableResult
    public func openQuickPage(url: URL? = nil, in spaceID: UUID, activate: Bool = true) -> UUID? {
        guard !isClosingWorkspace, !isWorkspaceSuspended, closeRequests.isEmpty,
              let index = spaceIndex(spaceID), url.map(URLResolver.isWebURL) ?? true else { return nil }
        return createTransient(url: url, kind: .quickWindow, space: workspace.spaces[index], owner: nil, activate: activate)
    }

    private func createTransient(url: URL?, kind: TransientPage.Kind, space: Space, owner: UUID?,
                                 adopting popup: EngineTab? = nil, activate: Bool = true) -> UUID {
        let id = UUID()
        let tab = popup ?? engine.makeTab(configuration: EngineConfiguration(profileID: space.profileID), initialURL: nil)
        transientPages[id] = TransientPage(id: id, kind: kind, spaceID: space.id, profileID: space.profileID, ownerTabID: owner)
        liveTabs[id] = tab
        liveSpaceIDs[id] = space.id
        liveProfileIDs[id] = space.profileID
        if popup != nil { openerBoundTabIDs.insert(id) }
        tab.delegate = self
        tab.setUserScripts(userScriptProvider?(url) ?? [])
        if popup == nil, let url { tab.load(url) }
        if kind == .quickWindow { onQuickPageCreated?(id, activate) }
        return id
    }

    /// CEF-created popup keeps its opener and profile. Geometry never controls Cairn's chrome.
    func adoptTransientPopup(_ popup: EngineTab, from opener: UUID, activate: Bool) -> Bool {
        guard let page = transientPages[opener], let index = spaceIndex(page.spaceID),
              page.profileID == workspace.spaces[index].profileID, onQuickPageCreated != nil,
              !isClosingWorkspace, closeRequests[opener] == nil else { return false }
        _ = createTransient(url: popup.state.url, kind: .quickWindow, space: workspace.spaces[index],
                            owner: opener, adopting: popup, activate: activate)
        return true
    }

    public func loadTransient(_ url: URL, in id: UUID) {
        guard transientPages[id] != nil, closeRequests[id] == nil, !isClosingWorkspace,
              URLResolver.isWebURL(url), let tab = liveTabs[id] else { return }
        tab.setUserScripts(userScriptProvider?(url) ?? [])
        tab.load(url)
    }

    public func dismissTransient(_ id: UUID, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard transientPages[id] != nil else { completion(true); return }
        requestTabClose(id) { [weak self] approved in
            if approved { self?.discardClosedTab(id) }
            completion(approved)
        }
    }

    /// Same-profile promotion transfers the exact engine/view, including DOM, history and form state.
    /// Different profiles require approval to discard that view, then a fresh GET of its current web URL.
    public func promoteTransient(_ id: UUID, to spaceID: UUID,
                                 completion: @escaping @MainActor (UUID?) -> Void = { _ in }) {
        guard !isClosingWorkspace, closeRequests[id] == nil,
              let page = transientPages[id], let tab = liveTabs[id], let index = spaceIndex(spaceID) else {
            completion(nil); return
        }
        if workspace.spaces[index].profileID == page.profileID {
            let state = tabStates[id] ?? tab.state
            let item = TabItem(id: id, url: state.url, title: state.title)
            workspace.spaces[index].tabs.append(item)
            liveSpaceIDs[id] = spaceID
            discardTransientPresentation(id)
            select(id)
            completion(id)
            return
        }
        // Never recreate a POST/body, cookies, credentials or an authenticated view across profiles.
        guard let url = (tabStates[id] ?? tab.state).url, URLResolver.isWebURL(url) else {
            completion(nil); return
        }
        let destinationProfile = workspace.spaces[index].profileID
        dismissTransient(id) { [weak self] approved in
            guard approved, let self, let target = self.spaceIndex(spaceID),
                  self.workspace.spaces[target].profileID == destinationProfile else { completion(nil); return }
            completion(self.newTab(url: url, in: spaceID))
        }
    }

    public func expandPeek() {
        guard let id = peek.tabID, let space = peek.spaceID else { return }
        promoteTransient(id, to: space)
    }

    func discardTransientPresentation(_ id: UUID) {
        guard let page = transientPages.removeValue(forKey: id) else { return }
        if peek.tabID == id { peek.close() }
        onTransientRemoved?(page)
    }

    func requestCloseOwnedTransients(_ owner: UUID, force: Bool,
                                    completion: @escaping @MainActor (Bool) -> Void) {
        guard let child = transientPages.values.filter({ $0.ownerTabID == owner })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }).first else { completion(true); return }
        requestTabClose(child.id, force: force || closeRequests[owner]?.force == true) { [weak self] approved in
            guard approved, let self else { completion(false); return }
            self.discardClosedTab(child.id)
            self.requestCloseOwnedTransients(owner, force: force, completion: completion)
        }
    }
}

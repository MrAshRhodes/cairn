import Foundation
import CairnEngineKit

public struct PopupGrantRequest: Equatable, Sendable {
    public let tabID: UUID
    public let spaceID: UUID
    public let profileID: String
    public let origin: String
    public let spaceName: String
}

extension BrowserModel: EngineTabPopupEvents {
    /// Adopts a popup the engine created for `tab` as a new tab in the opener's Space. The popup already
    /// shares the opener's profile (and its `window.opener`); the model only has to track it like any tab.
    public func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool {
        if let opener = itemID(for: tab), transientPages[opener] != nil {
            return adoptTransientPopup(popup, from: opener, activate: activate)
        }
        guard let openerID = itemID(for: tab), let spaceID = liveSpaceIDs[openerID], let space = spaceIndex(spaceID),
              let profileID = liveProfileIDs[openerID], profileID == workspace.spaces[space].profileID else { return false }
        let blank = URL(string: "about:blank")!
        let url = popup.state.url.flatMap { URLResolver.isNavigable($0) ? $0 : nil } ?? blank
        let item = TabItem(url: url)
        workspace.spaces[space].tabs.append(item)
        liveTabs[item.id] = popup
        liveProfileIDs[item.id] = profileID
        liveSpaceIDs[item.id] = spaceID
        openerBoundTabIDs.insert(item.id)
        popup.delegate = self
        popup.setUserScripts(userScriptProvider?(url) ?? [])
        if activate { select(item.id) }
        changed()
        return true
    }

    public func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) {
        engineTab(tab, blockedPopup: url, reason: reason, requestingURL: nil)
    }

    public func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason, requestingURL: URL?) {
        guard let id = itemID(for: tab) else { return }
        blockedPopups[id] = min((blockedPopups[id] ?? 0) + 1, 1_000)
        blockedPopupReasons[id] = reason
        blockedPopupOrigins[id] = nil
        if reason == .noUserGesture, let requestingURL,
           let context = popupContext(id, requestingURL: requestingURL) {
            blockedPopupOrigins[id] = context.origin
        }
    }

    public func engineTab(_ tab: EngineTab, allowsPopupsFrom requestingURL: URL) -> Bool {
        guard let id = itemID(for: tab), let context = popupContext(id, requestingURL: requestingURL) else { return false }
        return popupExceptions.allows(spaceID: context.space.id, profileID: context.space.profileID, origin: context.origin)
    }

    public func blockedPopupOrigin(for id: UUID) -> String? {
        popupGrantRequest(for: id)?.origin
    }

    public func popupGrantRequest(for id: UUID) -> PopupGrantRequest? {
        guard let origin = blockedPopupOrigins[id], let url = URL(string: origin),
              let context = popupContext(id, requestingURL: url) else { return nil }
        return PopupGrantRequest(tabID: id, spaceID: context.space.id, profileID: context.space.profileID,
                                 origin: origin, spaceName: context.space.name)
    }

    /// Does not replay a lost popup: the site must retry so CEF preserves its original opener semantics.
    @discardableResult
    public func allowBlockedPopups(_ id: UUID) -> Bool {
        guard let request = popupGrantRequest(for: id) else { return false }
        return allowBlockedPopups(request)
    }

    @discardableResult
    public func allowBlockedPopups(_ request: PopupGrantRequest) -> Bool {
        guard popupGrantRequest(for: request.tabID) == request,
              popupExceptions.allow(spaceID: request.spaceID, profileID: request.profileID, origin: request.origin) else { return false }
        dismissBlockedPopups(request.tabID)
        return true
    }

    public func dismissBlockedPopups(_ id: UUID) {
        blockedPopups[id] = nil
        blockedPopupOrigins[id] = nil
        blockedPopupReasons[id] = nil
    }

    private func popupContext(_ id: UUID, requestingURL: URL) -> (space: Space, origin: String)? {
        guard !isClosingWorkspace, !isWorkspaceSuspended, closeRequests[id] == nil,
              let tab = liveTabs[id], let spaceID = liveSpaceIDs[id], let index = spaceIndex(spaceID),
              let profileID = liveProfileIDs[id], profileID == workspace.spaces[index].profileID,
              let page = tab.state.url, let origin = SiteOrigin.normalize(requestingURL.absoluteString),
              SiteOrigin.normalize(page.absoluteString) == origin else { return nil }
        return (workspace.spaces[index], origin)
    }
}

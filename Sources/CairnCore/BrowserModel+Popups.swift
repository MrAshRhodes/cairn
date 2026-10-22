import Foundation
import CairnEngineKit

extension BrowserModel: EngineTabPopupEvents {
    /// Adopts a popup the engine created for `tab` as a new tab in the opener's Space. The popup already
    /// shares the opener's profile (and its `window.opener`); the model only has to track it like any tab.
    public func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool {
        guard let openerID = itemID(for: tab), let spaceID = liveSpaceIDs[openerID], let space = spaceIndex(spaceID),
              let profileID = liveProfileIDs[openerID], profileID == workspace.spaces[space].profileID else { return false }
        let blank = URL(string: "about:blank")!
        let url = popup.state.url.flatMap { URLResolver.isNavigable($0) ? $0 : nil } ?? blank
        let item = TabItem(url: url)
        workspace.spaces[space].tabs.append(item)
        liveTabs[item.id] = popup
        liveProfileIDs[item.id] = profileID
        liveSpaceIDs[item.id] = spaceID
        popup.delegate = self
        popup.setUserScripts(userScriptProvider?(url) ?? [])
        if activate { select(item.id) }
        changed()
        return true
    }

    public func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) {
        guard let id = itemID(for: tab) else { return }
        blockedPopups[id, default: 0] += 1
    }

    public func dismissBlockedPopups(_ id: UUID) { blockedPopups[id] = nil }
}

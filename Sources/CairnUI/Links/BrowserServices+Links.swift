import Foundation
import CairnCore

extension BrowserServices {
    func loadLinkRules() {
        linkRules.load()
        if let error = linkRules.loadError { report("Link rules are read-only", detail: error) }
        else if let notice = linkRules.notice { report("Link rules were reset", detail: notice) }
        try? linkRules.prune(validSpaceIDs: Set(model.workspace.spaces.map(\.id)))
    }

    /// The Space whose tabs were used most recently; falls back to the selected Space.
    var mostRecentSpaceID: UUID {
        let latest = model.workspace.spaces.max { lhs, rhs in
            let lhsLastActiveAt: Date = (lhs.tabs + lhs.pinned).map(\.lastActiveAt).max() ?? .distantPast
            let rhsLastActiveAt: Date = (rhs.tabs + rhs.pinned).map(\.lastActiveAt).max() ?? .distantPast
            return lhsLastActiveAt < rhsLastActiveAt
        }
        return latest?.id ?? model.selectedSpace.id
    }

    /// Opens a link from outside the app (Finder, another app) in the Space chosen by the link rules.
    /// The quick window is not built yet, so that destination opens in the most recent Space.
    func openExternalLink(_ url: URL) {
        guard let destination = linkRules.destination(for: url) else {
            model.newTab(url: url)
            return
        }
        var spaceID = mostRecentSpaceID
        if case .space(let id) = destination, model.workspace.spaces.contains(where: { $0.id == id }) { spaceID = id }
        model.newTab(url: url, in: spaceID)
        if model.selectedSpace.id != spaceID { model.selectSpace(spaceID) }
    }
}

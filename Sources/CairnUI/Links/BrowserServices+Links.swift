import Foundation
import CairnCore

extension BrowserServices {
    func loadLinkRules() {
        linkRules.load()
        if let error = linkRules.loadError { report("Link rules are read-only", detail: error) }
        else if let notice = linkRules.notice { report("Link rules were reset", detail: notice) }
        let previousRules = linkRules.rules
        let previousDefault = linkRules.defaultDestination
        do {
            try linkRules.prune(validSpaceIDs: Set(model.workspace.spaces.map(\.id)))
            if previousRules != linkRules.rules || previousDefault != linkRules.defaultDestination {
                report("Link destinations were removed", detail: "Rules for deleted Spaces were removed. A deleted default destination now uses the most recent Space. Review Settings ▸ Links.")
            }
        } catch { report("Link destinations could not be updated", error: error) }
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

    /// Resolves current persisted rules at activation time for both external and in-app new-tab links.
    func routedLinkSpace(for url: URL) -> UUID? {
        guard let decision = LinkRouter.decision(for: url, rules: linkRules.rules, default: linkRules.defaultDestination,
                                                spaceIDs: Set(model.workspace.spaces.map(\.id)),
                                                mostRecentSpaceID: mostRecentSpaceID) else { return nil }
        let spaceName = model.workspace.spaces.first { $0.id == decision.spaceID }?.name ?? "the most recent Space"
        switch decision.fallback {
        case .deletedSpace:
            report("Link destination is unavailable", detail: "The configured Space was deleted. The link was opened in “\(spaceName)” instead. Review Settings ▸ Links.")
        case .quickWindowUnavailable:
            report("Quick window could not open", detail: "The link was opened in “\(spaceName)” instead, using that Space's profile.")
        case nil: break
        }
        return decision.spaceID
    }

    func openRoutedQuickWindow(_ url: URL, activate: Bool) -> Bool {
        guard let decision = LinkRouter.decision(for: url, rules: linkRules.rules, default: linkRules.defaultDestination,
                                                spaceIDs: Set(model.workspace.spaces.map(\.id)),
                                                mostRecentSpaceID: mostRecentSpaceID),
              decision.opensQuickWindow else { return false }
        if model.openQuickPage(url: url, in: decision.spaceID, activate: activate) == nil {
            report("Quick window could not open", detail: "Finish the pending page-close decision, then open the link again. No tab or request was created.")
        }
        return true
    }

    /// Opens exactly one destination; routing never transfers cookies or a live authenticated view.
    func openExternalLink(_ url: URL) {
        if openRoutedQuickWindow(url, activate: true) { return }
        model.newTab(url: url, in: routedLinkSpace(for: url))
    }
}

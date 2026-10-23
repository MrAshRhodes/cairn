import Foundation
import CairnEngineKit

/// Crash-loop guard for renderer crashes: the first crash in the window reloads silently, the second shows the
/// recovery banner, and from the third on the tab stops reloading by itself.
struct RecoveryPolicy {
    enum Action: Equatable { case reload, showBanner, giveUp }
    static let window: TimeInterval = 60

    private(set) var crashes: [Date] = []

    mutating func recordCrash(at date: Date) -> Action {
        crashes = crashes.filter { date.timeIntervalSince($0) < Self.window } + [date]
        switch crashes.count {
        case 1: return .reload
        case 2: return .showBanner
        default: return .giveUp
        }
    }
}

extension BrowserModel: EngineTabHealthEvents {
    public func engineTab(_ tab: EngineTab, healthDidChange health: EngineTabHealth) {
        guard let id = itemID(for: tab) else { return }
        switch health {
        case .crashed:
            handleCrash(id, health: health, tab: tab)
        case .healthy:
            tabHealth[id] = nil
        case .unresponsive, .navigationStalled, .automationUnavailable:
            tabHealth[id] = health
        }
    }

    private func handleCrash(_ id: UUID, health: EngineTabHealth, tab: EngineTab) {
        var policy = recoveryPolicies[id] ?? RecoveryPolicy()
        let action = policy.recordCrash(at: recoveryClock())
        recoveryPolicies[id] = policy
        switch action {
        case .reload:
            if isVisibleTab(id) {
                tabHealth[id] = nil
                tab.reload(ignoringCache: false)
            } else {
                tabHealth[id] = health
                needsReload.insert(id)
            }
        case .showBanner, .giveUp:
            tabHealth[id] = health
            if case .crashed(let reason, _) = health { report(ServiceError.navigation("The page \(reason).")) }
        }
    }

    /// Reloads a tab whose renderer died while it was in the background. Called when it becomes visible.
    func reloadIfNeeded(_ id: UUID) {
        guard needsReload.remove(id) != nil, let tab = liveTabs[id] else { return }
        tabHealth[id] = nil
        tab.reload(ignoringCache: false)
    }

    /// The recovery action behind the banner's Reload button; a manual reload always resets the crash-loop guard.
    public func recoverTab(_ id: UUID) {
        guard let tab = liveTab(for: id) else { return }
        recoveryPolicies[id] = nil
        needsReload.remove(id)
        tabHealth[id] = nil
        tab.reload(ignoringCache: true)
    }

    public func dismissHealthNotice(_ id: UUID) { tabHealth[id] = nil }

    func isVisibleTab(_ id: UUID) -> Bool {
        selectedTabID == id || splitTabIDs.contains(id)
            || (transientPages[id] != nil && liveTabs[id]?.view.window?.isVisible == true)
    }
}

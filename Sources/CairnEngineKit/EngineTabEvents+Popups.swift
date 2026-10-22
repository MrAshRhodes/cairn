import Foundation

/// Popup events from the engine. A popup is a real browser that shares the opener's profile (an ephemeral
/// opener gives an ephemeral popup) and keeps `window.opener`; the app shows it as a new tab.
@MainActor
public protocol EngineTabPopupEvents: EngineTabEvents {
    /// Called synchronously while the engine creates a popup for `tab`. Return `true` once `popup` is
    /// registered as a new tab (`activate` says whether to show it); return `false` to refuse, and the
    /// engine discards the popup. The popup's own `delegate` is the app's to set.
    func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool
    /// A popup from `tab` was refused. `url` is nil when the page gave no valid URL.
    func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason)
}

public extension EngineTabPopupEvents {
    func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool { false }
    func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) {}
}

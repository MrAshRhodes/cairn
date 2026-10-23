import Foundation

/// A close request is not a teardown authorization. Keep the tab, delegate and view alive until the
/// decision arrives. `true` means CEF has irrevocably approved closing, not that its browser is destroyed.
@MainActor
public protocol EngineTabCloseControlling: EngineTab {
    func requestClose(completion: @escaping @MainActor (Bool) -> Void)
    /// Only for an explicit user decision to discard the page, never a timeout waiting for a decision.
    func forceClose()
}

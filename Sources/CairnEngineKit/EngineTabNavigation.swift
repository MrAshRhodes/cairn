import Foundation

/// Optional interception of an ordinary, user-activated top-level GET link.
/// Engines must exclude redirects, form submissions and opener-dependent popups.
@MainActor
public protocol EngineTabNavigationEvents: AnyObject {
    /// True consumes the navigation; the source document must not also navigate.
    func engineTab(_ tab: EngineTab, interceptsUserNavigation url: URL) -> Bool
}

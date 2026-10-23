import Foundation

/// Page-initiated requests that need the app: context-menu actions and external protocol links.
/// Everything else the context menu does (copy link, save image, back/forward, spelling) stays in the engine.
@MainActor
public protocol EngineTabContextMenuEvents: EngineTabEvents {
    /// "Search for <selection>" was chosen. The app resolves the query with the user's search engine.
    func engineTab(_ tab: EngineTab, requestsSearchFor query: String, activate: Bool)
    /// The page navigated to a non-web URL (mailto:, tel:, a custom scheme). The engine never launches it;
    /// the app decides whether and how to open it.
    func engineTab(_ tab: EngineTab, requestsExternalURL url: URL)
}

public extension EngineTabContextMenuEvents {
    func engineTab(_ tab: EngineTab, requestsSearchFor query: String, activate: Bool) {}
    func engineTab(_ tab: EngineTab, requestsExternalURL url: URL) {}
}

/// Optional capability of an `EngineTab`: move keyboard focus into the page content.
@MainActor
public protocol EngineTabContentFocus: EngineTab {
    func focusContent()
}

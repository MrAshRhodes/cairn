import Foundation
import CairnEngineKit

extension BrowserModel: EngineTabZoomEvents {
    public func engineTab(_ tab: EngineTab, zoomDidChange zoom: Double) {
        if let id = liveTabs.first(where: { $0.value === tab })?.key { onTabZoomChanged?(id, tab, zoom) }
    }

    public func profileID(forLiveTab id: UUID) -> String? { liveProfileID(id) }

    /// The `view-source:` URL for the selected tab, or nil when its page cannot be viewed as source.
    public var viewSourceURLForSelectedTab: URL? {
        selectedTabID.flatMap { tabStates[$0]?.url ?? item($0)?.url }.flatMap(ViewSource.url(for:))
    }
}

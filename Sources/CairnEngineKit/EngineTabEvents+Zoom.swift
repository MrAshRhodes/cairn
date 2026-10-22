import Foundation

/// Reports a change of a tab's zoom factor, from any source (menu, keyboard, module command, persisted restore).
@MainActor
public protocol EngineTabZoomEvents: EngineTabEvents {
    func engineTab(_ tab: EngineTab, zoomDidChange zoom: Double)
}

public extension EngineTabZoomEvents {
    func engineTab(_ tab: EngineTab, zoomDidChange zoom: Double) {}
}

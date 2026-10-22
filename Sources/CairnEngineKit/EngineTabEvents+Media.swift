import Foundation

/// Optional engine → app events for media. `EngineTabState` is frozen, so audible state travels here instead.
@MainActor
public protocol EngineTabMediaEvents: EngineTabEvents {
    /// The tab started or stopped producing sound (with Chromium's own short debounce after silence).
    func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool)
}

public extension EngineTabMediaEvents {
    func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool) {}
}

/// Implemented by engine tabs that can silence themselves. The wanted state survives navigation.
@MainActor
public protocol EngineTabAudioControl: EngineTab {
    var isAudioMuted: Bool { get set }
}

/// The audible/muted state of one tab as the app tracks it.
public struct EngineTabMediaState: Equatable, Sendable {
    public var isAudible: Bool
    public var isMuted: Bool
    public init(isAudible: Bool = false, isMuted: Bool = false) {
        self.isAudible = isAudible; self.isMuted = isMuted
    }
    public var showsIndicator: Bool { isAudible || isMuted }
}

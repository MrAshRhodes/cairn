import Foundation

// EXTENSION POINT for tab events added after `EngineTabDelegate` was frozen.
//
// `EngineTabDelegate` (Engine.swift) must not change, so the engine reports each NEW event through a small
// optional protocol of its own. A feature adds three things, each in its own file, and edits no shared one:
//
//   1. `Sources/CairnEngineKit/EngineTabEvents+<Feature>.swift` declares the protocol and no-op defaults:
//
//          @MainActor public protocol EngineTabAudioEvents: EngineTabEvents {
//              func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool)
//          }
//          public extension EngineTabAudioEvents {
//              func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool) {}
//          }
//
//   2. The app adopts it where it handles the event, e.g. `BrowserModel+<Feature>.swift`
//      (`extension BrowserModel: EngineTabAudioEvents { ... }`). Code that does not adopt it is unaffected.
//
//   3. `Sources/CairnChromiumEngine/ChromiumTab+<Feature>.swift` delivers it from the engine:
//      `(delegate as? EngineTabAudioEvents)?.engineTab(self, audioPlayingDidChange: true)`.
//      A delegate that did not adopt the protocol simply receives nothing. The same file adopts the
//      bridge's protocol for the feature: `extension ChromiumTab: @preconcurrency CCChromiumTabAudioDelegate`.
//
// The bridge side of the same feature (handler and public-header slot) is described in
// Sources/CairnChromiumBridge/CCInternal.h.

/// Marker for the optional, per-feature protocols that carry engine → app tab events. Feature
/// protocols refine it and give every method a no-op default, so adopting one is always optional.
@MainActor
public protocol EngineTabEvents: AnyObject {}

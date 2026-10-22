import AppKit
import CairnEngineKit

/// Per-tab audio state, mute commands, media-key playback control and favicon lookup.
extension BrowserModel: EngineTabMediaEvents {
    public func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool) {
        guard let id = liveTabs.first(where: { $0.value === tab })?.key else { return }
        var state = mediaStates[id] ?? EngineTabMediaState()
        state.isAudible = isPlaying
        state.isMuted = (tab as? EngineTabAudioControl)?.isAudioMuted ?? state.isMuted
        mediaStates[id] = state
        if isPlaying { lastAudibleTabID = id }
    }

    public func isMuted(_ id: UUID) -> Bool { mediaStates[id]?.isMuted ?? false }

    public func setMuted(_ muted: Bool, for id: UUID) {
        guard let control = liveTabs[id] as? EngineTabAudioControl else { return }
        control.isAudioMuted = muted
        var state = mediaStates[id] ?? EngineTabMediaState()
        state.isMuted = muted
        mediaStates[id] = state.showsIndicator ? state : nil
    }

    public func toggleMute(_ id: UUID) { setMuted(!isMuted(id), for: id) }

    /// Mutes every other audible tab, which is what "Mute Other Tabs" means; nothing is unmuted.
    public func muteOtherTabs(except keep: UUID?) {
        for (id, state) in mediaStates where id != keep && state.isAudible && !state.isMuted { setMuted(true, for: id) }
    }

    /// The tab the media keys act on: the audible tab, the one that last made sound, or else the selected tab.
    public var mediaTargetTabID: UUID? {
        if let id = selectedTabID, mediaStates[id]?.isAudible == true { return id }
        if let id = mediaStates.first(where: { $0.value.isAudible })?.key { return id }
        if let id = lastAudibleTabID, liveTabs[id] != nil { return id }
        return selectedTabID
    }

    public var isAnyTabAudible: Bool { mediaStates.values.contains { $0.isAudible && !$0.isMuted } }

    /// Plays or pauses the page's primary media element. Pages that use custom players without a media element are not reachable.
    public func toggleMediaPlayback(completion: ((String?) -> Void)? = nil) {
        guard let id = mediaTargetTabID, let tab = liveTabs[id] else { completion?(nil); return }
        tab.evaluateJavaScript(Self.togglePlaybackScript) { result in
            completion?(try? result.get() as? String)
        }
    }

    static let togglePlaybackScript = """
    (() => {
      const media = [...document.querySelectorAll('video,audio')];
      const target = media.find(e => !e.paused && !e.ended)
        || media.sort((a, b) => (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight))[0];
      if (!target) return 'none';
      if (target.paused) { target.play().catch(() => {}); return 'playing'; }
      target.pause();
      return 'paused';
    })()
    """

    // MARK: Favicons
    /// The icon for a tab: the live one, else the cached icon for its site in its profile.
    public func favicon(for tab: TabItem) -> NSImage? {
        if let image = favicons[tab.id] { return image }
        guard let host = tab.url?.host, let profile = faviconProfileID(for: tab.id) else { return nil }
        return faviconStore?.image(profileID: profile, host: host)
    }

    func cacheFavicon(_ image: NSImage?, for id: UUID) {
        guard let image, let store = faviconStore, let profile = faviconProfileID(for: id),
              let host = (tabStates[id]?.url ?? item(id)?.url)?.host,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        store.store(png, profileID: profile, host: host)
    }

    private func faviconProfileID(for id: UUID) -> String? {
        if let live = liveProfileIDs[id] { return live }
        guard let loc = locate(id), let index = loc.spaceIndex else { return selectedSpace.profileID }
        return workspace.spaces[index].profileID
    }
}

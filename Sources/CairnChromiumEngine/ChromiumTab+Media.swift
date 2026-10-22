import AppKit
import CairnEngineKit
import CairnChromiumBridge

extension ChromiumTab: EngineTabAudioControl {
    var isAudioMuted: Bool {
        get { bridge.audioMuted }
        set { if !closed { bridge.audioMuted = newValue } }
    }
}

extension ChromiumTab: @preconcurrency CCChromiumTabAudioDelegate {
    func chromiumTab(_ tab: CCChromiumTab, audioPlayingChanged playing: Bool) {
        guard !closed else { return }
        (delegate as? EngineTabMediaEvents)?.engineTab(self, audioPlayingDidChange: playing)
    }
}

extension ChromiumTab: @preconcurrency CCChromiumTabFaviconDelegate {
    func chromiumTab(_ tab: CCChromiumTab, faviconPNG png: Data?, iconURL: String?) {
        guard !closed else { return }
        delegate?.engineTab(self, didReceiveFavicon: png.flatMap { NSImage(data: $0) })
    }
}

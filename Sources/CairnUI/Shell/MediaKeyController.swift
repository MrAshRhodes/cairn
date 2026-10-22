import AppKit
import MediaPlayer
import Observation
import CairnCore

/// Routes the keyboard's play/pause key to the audible tab. macOS delivers media keys to the "Now Playing"
/// app, so Cairn claims that role only while a tab is making sound and releases it when the sound stops.
@MainActor
final class MediaKeyController {
    private let model: BrowserModel
    private var claimed = false

    init(model: BrowserModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.model.toggleMediaPlayback() }
                return .success
            }
        }
        track()
    }

    private func track() {
        withObservationTracking {
            update(audible: model.isAnyTabAudible)
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func update(audible: Bool) {
        guard audible != claimed else { return }
        claimed = audible
        MPNowPlayingInfoCenter.default().playbackState = audible ? .playing : .stopped
    }
}

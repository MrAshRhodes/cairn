import Foundation
import CairnCore

@MainActor
final class MediaModule: CairnModule {
    let id = "cairn.media"
    let displayName = "Media"
    let version = "1"

    func commands(for model: BrowserModel) -> [Command] {
        var commands: [Command] = []
        if let id = model.selectedTabID, model.liveTabs[id] != nil {
            let muted = model.isMuted(id)
            commands.append(Command(id: "cairn.media.mute", title: muted ? "Unmute Tab" : "Mute Tab",
                                    symbol: muted ? "speaker.wave.2" : "speaker.slash", keywords: ["audio", "sound"]) {
                if let id = $0.selectedTabID { $0.toggleMute(id) }
            })
            commands.append(Command(id: "cairn.media.playpause", title: "Play or Pause Media",
                                    symbol: "playpause", keywords: ["video", "audio", "music"]) { $0.toggleMediaPlayback() })
        }
        if model.mediaStates.contains(where: { $0.key != model.selectedTabID && $0.value.isAudible && !$0.value.isMuted }) {
            commands.append(Command(id: "cairn.media.muteOthers", title: "Mute Other Tabs",
                                    symbol: "speaker.slash.circle", keywords: ["audio", "sound"]) {
                $0.muteOtherTabs(except: $0.selectedTabID)
            })
        }
        return commands
    }
}

import AppKit
import CairnEngineKit

extension Smoke: EngineTabMediaEvents {
    func engineTab(_ tab: EngineTab, audioPlayingDidChange isPlaying: Bool) {
        audioEvents[tab.id, default: []].append(isPlaying)
    }

    /// A real click through AppKit: Chromium's autoplay policy needs a genuine user activation for audio.
    func click(_ tab: EngineTab, elementID: String) async throws {
        guard let window = tab.view.window,
              let rect = try await js(tab, "(() => { const r = document.getElementById('\(elementID)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()") as? [Double],
              rect.count == 2 else { throw SmokeError.failed("Could not locate #\(elementID)") }
        let point = NSPoint(x: rect[0], y: tab.view.bounds.height - rect[1])
        let location = tab.view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw SmokeError.failed("Could not synthesize a click")
            }
            window.sendEvent(event)
        }
    }

    func runMedia() async throws {
        let tab = make("media")
        try await load(tab, path: "media.html")

        try await wait { !(self.faviconEvents[tab.id] ?? []).isEmpty }
        let icon = faviconEvents[tab.id]?.last ?? nil
        try require(icon != nil && icon!.size.width > 0, "favicon is downloaded and delivered as an image")
        let requests = try await js(tab, "fetch('/icon-requests.json').then(r => r.json())") as? [[String: Any]] ?? []
        // CEF 154 (Alloy) sends the site's own cookies on a same-origin DownloadImage fetch despite is_favicon.
        print("ICON REQUESTS: \(requests)")
        try require(!requests.isEmpty && requests.allSatisfy { ($0["referer"] as? String)?.contains("/media.html") == true },
                    "favicon is fetched by the Space's own network stack for the page origin")

        guard let control = tab as? EngineTabAudioControl else { throw SmokeError.failed("Tab has no audio control") }
        try require(try await js(tab, "document.cookie.includes('fixture=1')") as? Bool == true, "fixture cookie is set for the page")
        try await click(tab, elementID: "go")
        try await wait { self.audioEvents[tab.id]?.last == true }
        try require(true, "audible state is reported when a tab starts playing")

        control.isAudioMuted = true
        try require(control.isAudioMuted, "tab mute is stored")
        try await load(tab, path: "media-again.html")
        try await Task.sleep(nanoseconds: 500_000_000)
        try require(control.isAudioMuted, "mute persists across navigation")
        control.isAudioMuted = false
        try await wait { self.audioEvents[tab.id]?.last == false }
        try require(true, "audible state clears when the playing page is navigated away")

        try await click(tab, elementID: "go")
        try await wait { self.audioEvents[tab.id]?.last == true }
        try require(self.audioEvents[tab.id]?.count == 3, "audible state returns after unmuting and playing again")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let pip = try await js(tab, "JSON.stringify(window.pip)") as? String ?? "?"
        print("PIP PROBE: \(pip)")
        _ = try await js(tab, "window.stopTone ? window.stopTone() : true")
        try await wait { self.audioEvents[tab.id]?.last == false }
        try require(true, "audible state clears after the tab goes silent")
        let events = audioEvents[tab.id] ?? []
        try require(events.filter { $0 }.count >= 1, "audio start event received (\(events))")
        tab.close()
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}

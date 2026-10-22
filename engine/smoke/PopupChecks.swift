import AppKit
import CairnEngineKit

extension Smoke: EngineTabPopupEvents {
    func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool {
        popup.delegate = self
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = popup.view
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        popupTabs.append(popup)
        return true
    }

    func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) { blockedPopups += 1 }

    /// A native click, so the page sees a trusted user gesture (DevTools evaluation never carries one).
    func click(_ tab: EngineTab, _ id: String) async throws {
        guard let rect = try await js(tab, """
            (() => { const r = document.getElementById('\(id)').getBoundingClientRect();
                     return [r.left + r.width / 2, r.top + r.height / 2]; })()
            """) as? [Double], let window = tab.view.window else { throw SmokeError.failed("No click target \(id)") }
        window.makeKeyAndOrderFront(nil)
        let point = NSPoint(x: rect[0], y: tab.view.bounds.height - rect[1])
        let base = tab.view.convert(point, to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: base, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw SmokeError.failed("Could not synthesize a mouse event") }
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func loadPage(_ tab: EngineTab, _ path: String) async throws {
        let url = URL(string: base.absoluteString + path)!
        tab.load(url)
        try await wait { !tab.state.isLoading && tab.state.url == url && tab.state.progress >= 1 }
    }

    func jsonLog(_ tab: EngineTab) async throws -> [[String: Any]] {
        let text = try await js(tab, "JSON.stringify(window.log)") as? String ?? "[]"
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
    }

    func closePopups() async throws {
        for popup in popupTabs { popup.close() }
        popupTabs.removeAll()
        try await Task.sleep(for: .milliseconds(300))
    }

    func checkPopups() async throws {
        for (profile, ephemeral, cookie) in [("popups-a", false, "pa"), ("popups-private", true, "pe")] {
            let label = ephemeral ? "ephemeral" : "persistent"
            let opener = make(profile, ephemeral: ephemeral)
            try await loadPage(opener, "popups/opener?cookie=\(cookie)")
            popupTabs.removeAll()
            let blockedBefore = blockedPopups

            _ = try await js(opener, "window.open('/popups/child', 'script'); true")
            try await Task.sleep(for: .milliseconds(300))
            try require(popupTabs.isEmpty && blockedPopups == blockedBefore + 1,
                        "\(label): script popup without a gesture is blocked and counted")

            try await click(opener, "btnOpen")
            try await wait { self.popupTabs.count == 1 }
            let popup = popupTabs[0]
            try require(true, "\(label): gesture popup adopted as a new engine tab")
            try await wait { !popup.state.isLoading && popup.state.title == "popup child" }
            try require(try await js(opener, "window.openedNonNull === true && window.win.closed === false") as? Bool == true,
                        "\(label): window.open returns a live window handle")
            for _ in 0..<100 where try await jsonLog(opener).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            let message = try await jsonLog(opener)[0]
            let data = message["data"] as? [String: Any] ?? [:]
            try require(message["fromPopup"] as? Bool == true && data["hasOpener"] as? Bool == true,
                        "\(label): popup keeps window.opener and postMessage reaches the opener")
            try require(message["origin"] as? String == base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        && data["name"] as? String == "win1", "\(label): message origin and window.name are preserved")
            try require((data["cookie"] as? String ?? "").contains("\(cookie)=1"),
                        "\(label): popup shares the opener's request context")

            let outsider = make(profile, ephemeral: !ephemeral)
            try await loadPage(outsider, "popups/child")
            try require(try await js(outsider, "document.cookie.includes('\(cookie)=')") as? Bool == false,
                        "\(label): a different context cannot see the popup's cookies")

            let closesBefore = closeRequests.count
            _ = try? await js(popup, "window.close(); true") // the tab can close before the reply
            try await wait { self.closeRequests.count > closesBefore && self.closeRequests.last == popup.id }
            try require(try await js(opener, "window.win.closed === true") as? Bool == true,
                        "\(label): window.close() from the popup closes only that tab")
            try require(!closeRequests.contains(opener.id), "\(label): the opener stays open")
            popupTabs.removeAll()

            try await click(opener, "btnBlank")
            try await wait { self.popupTabs.count == 1 }
            let blank = popupTabs[0]
            try await wait { blank.state.title == "blank popup" }
            try require(try await js(opener, "window.win.document.body.textContent") as? String == "written by opener",
                        "\(label): empty-URL popup is scriptable by its opener")
            blank.close()
            popupTabs.removeAll()

            let count = popupTabs.count
            try await click(opener, "lnkNoopener")
            try await wait { self.popupTabs.count == count + 1 }
            let noopener = popupTabs[count]
            try await wait { !noopener.state.isLoading && noopener.state.title == "popup child" }
            try require(try await js(noopener, "window.opener === null") as? Bool == true,
                        "\(label): rel=noopener link opens a tab without an opener")
            try await closePopups()
        }

        let flooder = make("popups-a")
        try await load(flooder, path: "popups/opener")
        popupTabs.removeAll()
        try await click(flooder, "btnFlood")
        try await Task.sleep(for: .seconds(1))
        try require(popupTabs.count <= 3, "popup flood is capped by the per-tab budget (\(popupTabs.count) adopted)")
        try await closePopups()
    }
}

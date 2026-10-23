import AppKit
import CairnEngineKit

/// Exercises the native initiating-frame boundary. Store/Space persistence is covered by Core/UI tests.
@MainActor
private final class PopupExceptionProbe: EngineTabDelegate, EngineTabPopupEvents {
    let smoke: Smoke
    var allowedTab: UUID?
    var allowedOrigin: URL?
    var blocked: [PopupBlockReason] = []
    init(_ smoke: Smoke) { self.smoke = smoke }

    func engineTab(_ tab: EngineTab, didChange state: EngineTabState) {}
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) {}
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) {
        smoke.engineTab(tab, requestsNewTab: url, activate: activate)
    }
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {
        smoke.engineTab(tab, requestsDownload: url, suggestedFilename: suggestedFilename)
    }
    func engineTabDidRequestClose(_ tab: EngineTab) { smoke.engineTabDidRequestClose(tab) }
    func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool {
        smoke.engineTab(tab, hostsPopup: popup, activate: activate)
    }
    func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) { blocked.append(reason) }
    func engineTab(_ tab: EngineTab, allowsPopupsFrom requestingURL: URL) -> Bool {
        guard tab.id == allowedTab, let allowedOrigin else { return false }
        return requestingURL.scheme == allowedOrigin.scheme && requestingURL.host == allowedOrigin.host
            && requestingURL.port == allowedOrigin.port
    }
}

extension Smoke {
    func checkPopupExceptions() async throws {
        let opener = make("popup-exceptions")
        let probe = PopupExceptionProbe(self)
        opener.delegate = probe
        defer { opener.delegate = self }
        try await load(opener, path: "popup-exceptions.html")
        popupTabs.removeAll()
        _ = try await js(opener, "attemptPopup(); true")
        try await wait { probe.blocked.count == 1 }
        try require(popupTabs.isEmpty && probe.blocked.last == .noUserGesture,
                    "popup exception: default denies script popup before native creation")

        probe.allowedTab = opener.id
        probe.allowedOrigin = base
        _ = try await js(opener, "attemptPopup(); true")
        try await wait { self.popupTabs.count == 1 && self.popupTabs[0].state.title == "popup exception child" }
        for _ in 0..<100 where try await jsonLog(opener).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let message = try await jsonLog(opener).first ?? [:]
        let data = message["data"] as? [String: Any] ?? [:]
        try require(message["fromPopup"] as? Bool == true && data["hasOpener"] as? Bool == true
                    && data["name"] as? String == "exception-popup",
                    "popup exception: adopted popup retains opener, name and postMessage")
        _ = try await js(opener, "window.previous = window.win; attemptPopup(); true")
        try require(try await js(opener, "window.previous === window.win") as? Bool == true && popupTabs.count == 1,
                    "popup exception: named target reuses the existing CEF window")

        probe.allowedOrigin = nil
        let beforeRevoke = probe.blocked.count
        _ = try await js(opener, "attemptPopup('revoked'); true")
        try await wait { probe.blocked.count > beforeRevoke }
        try require(popupTabs.count == 1 && probe.blocked.last == .noUserGesture,
                    "popup exception: revocation immediately blocks a new script popup")

        probe.allowedOrigin = base
        let beforeFrame = probe.blocked.count
        _ = try await js(opener, """
            (() => { const frame = document.createElement('iframe');
                     frame.src = '/popup-exceptions.html?frame=1'; document.body.append(frame); return true; })()
            """)
        try await wait { probe.blocked.count > beforeFrame }
        try require(popupTabs.count == 1 && probe.blocked.last == .noUserGesture,
                    "popup exception: a same-origin embedded frame cannot inherit the top-level grant")

        _ = try await js(opener, """
            for (let i = 0; i < 20; i++) window.open('/popup-exceptions.html?child=1', 'budget-' + i); true
            """)
        try await wait { probe.blocked.contains(.rateLimited) }
        try require(popupTabs.count <= 3, "popup exception: grant retains the shared per-opener abuse budget")
        try await closePopups()

        var otherOrigin = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        otherOrigin.host = base.host == "localhost" ? "127.0.0.1" : "localhost"
        let otherURL = otherOrigin.url!.appendingPathComponent("popup-exceptions.html")
        opener.load(otherURL)
        try await wait { !opener.state.isLoading && opener.state.url == otherURL && opener.state.progress >= 1 }
        let beforeNavigation = probe.blocked.count
        _ = try await js(opener, "attemptPopup('navigated'); true")
        try await wait { probe.blocked.count > beforeNavigation }
        try require(popupTabs.isEmpty && probe.blocked.last == .noUserGesture,
                    "popup exception: navigating to another origin does not inherit a grant")
        opener.close()
    }
}

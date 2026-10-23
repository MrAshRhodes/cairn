import AppKit
import CairnEngineKit

/// Verifies the native navigation callback, not the BrowserModel policy or SwiftUI presentation.
@MainActor
private final class TransientNavigationProbe: EngineTabDelegate, EngineTabNavigationEvents, EngineTabPopupEvents {
    weak var downstream: Smoke?
    var consumed: [URL] = []
    var shouldConsume = true
    init(_ downstream: Smoke) { self.downstream = downstream }
    func engineTab(_ tab: EngineTab, interceptsUserNavigation url: URL) -> Bool {
        consumed.append(url)
        return shouldConsume
    }
    func engineTab(_ tab: EngineTab, didChange state: EngineTabState) { downstream?.engineTab(tab, didChange: state) }
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) { downstream?.engineTab(tab, didReceiveFavicon: image) }
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) {
        downstream?.engineTab(tab, requestsNewTab: url, activate: activate)
    }
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {
        downstream?.engineTab(tab, requestsDownload: url, suggestedFilename: suggestedFilename)
    }
    func engineTabDidRequestClose(_ tab: EngineTab) { downstream?.engineTabDidRequestClose(tab) }
    func engineTab(_ tab: EngineTab, hostsPopup popup: EngineTab, activate: Bool) -> Bool {
        downstream?.engineTab(tab, hostsPopup: popup, activate: activate) ?? false
    }
    func engineTab(_ tab: EngineTab, blockedPopup url: URL?, reason: PopupBlockReason) {
        downstream?.engineTab(tab, blockedPopup: url, reason: reason)
    }
}

extension Smoke {
    func checkTransientNavigation() async throws {
        let source = make("transient-native")
        let probe = TransientNavigationProbe(self)
        source.delegate = probe
        defer { source.delegate = self }
        try await load(source, path: "transient.html")
        let initial = source.state.url
        try await click(source, "cross")
        try await wait { probe.consumed.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        try require(source.state.url == initial, "consumed user link leaves the source document untouched")
        guard let target = probe.consumed.first else { throw SmokeError.failed("Missing intercepted link") }

        let preview = make("transient-native")
        guard let previewWindow = preview.view.window else { throw SmokeError.failed("No preview window") }
        let liveView = preview.view
        let previewContainer = NSView(frame: liveView.frame)
        previewWindow.contentView = previewContainer
        liveView.frame = previewContainer.bounds
        liveView.autoresizingMask = [.width, .height]
        previewContainer.addSubview(liveView)
        preview.load(target)
        try await wait { !preview.state.isLoading && preview.state.url == target && preview.state.progress >= 1 }
        _ = try await js(preview, """
            document.cookie = 'cairnTransient=source-profile; Path=/; SameSite=Lax';
            document.querySelector('#draft').value = 'Live draft survives promotion';
            window.__transientState = {value: 42}; history.pushState({cairn: true}, '', '#kept');
            window.scrollTo(0, 900); true
            """)
        let preservationState = """
            JSON.stringify({draft: document.querySelector('#draft').value, state: window.__transientState,
                            history: history.state, hash: location.hash, scroll: scrollY,
                            viewport: innerHeight, height: document.documentElement.scrollHeight,
                            active: document.activeElement?.tagName, focused: document.hasFocus()})
            """
        print("TRANSIENT BEFORE REPARENT: \(String(describing: try await js(preview, preservationState)))")
        let expanded = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 900, height: 700),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        expanded.isReleasedWhenClosed = false
        guard let expandedContainer = expanded.contentView else { throw SmokeError.failed("No expanded container") }
        liveView.removeFromSuperview()
        liveView.frame = expandedContainer.bounds
        liveView.autoresizingMask = [.width, .height]
        expandedContainer.addSubview(liveView)
        expanded.makeKeyAndOrderFront(nil)
        windows.append(expanded)
        try await Task.sleep(for: .milliseconds(150))
        try require(preview.view === liveView && preview.view.window === expanded,
                    "Chromium's same live view can move from preview to a normal window")
        print("TRANSIENT AFTER REPARENT: \(String(describing: try await js(preview, preservationState)))")
        try require(try await js(preview, """
            document.querySelector('#draft').value === 'Live draft survives promotion' &&
            window.__transientState.value === 42 && history.state.cairn && location.hash === '#kept' && scrollY > 0
            """) as? Bool == true, "native reparent keeps DOM state, history and scroll without a reload")

        let sameProfile = make("transient-native")
        sameProfile.load(target)
        try await wait { !sameProfile.state.isLoading && sameProfile.state.progress >= 1 }
        try require(try await js(sameProfile, "document.cookie.includes('cairnTransient=source-profile')") as? Bool == true,
                    "transient page uses its explicit originating profile")
        let otherProfile = make("transient-native-other")
        otherProfile.load(target)
        try await wait { !otherProfile.state.isLoading && otherProfile.state.progress >= 1 }
        try require(try await js(otherProfile, "!document.cookie.includes('cairnTransient=')") as? Bool == true,
                    "fresh destination profile cannot see transient source cookies")

        // The wrapper does not invent a user gesture for JavaScript navigation.
        let count = probe.consumed.count
        _ = try? await js(source, "document.querySelector('#cross').click(); true")
        try await wait { !source.state.isLoading && source.state.url == target && source.state.progress >= 1 }
        try require(probe.consumed.count == count, "untrusted script click bypasses user-link interception")

        try await load(source, path: "transient.html")
        let popupCount = popupTabs.count
        try await click(source, "popup")
        try await wait { self.popupTabs.count == popupCount + 1 }
        let popup = popupTabs[popupCount]
        try await wait { !popup.state.isLoading && popup.state.progress >= 1 }
        try require(probe.consumed.count == count, "opener-dependent popup is never reconstructed as a Peek URL")
        try require(try await js(popup, "window.opener !== null") as? Bool == true,
                    "native popup retains window.opener while transient navigation hooks are installed")
        try require(popup.view.window?.frame.width ?? 0 >= 500,
                    "popup feature geometry cannot remove the host window's native chrome")
        print("CAIRN_TRANSIENT_NAVIGATION_OK")
    }
}

import AppKit
import CairnEngineKit
import CairnChromiumEngine

enum SmokeError: Error { case failed(String) }

@MainActor final class Smoke: NSObject, EngineTabDelegate {
    let engine: ChromiumEngine
    let base: URL
    var windows: [NSWindow] = []
    var tabs: [EngineTab] = []
    var popups = 0

    init(root: URL, base: URL) {
        self.base = base
        engine = ChromiumEngine(dataRoot: root)
    }

    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeError.failed(message) }
        print("PASS: \(message)")
    }

    func make(_ profile: String, ephemeral: Bool = false) -> EngineTab {
        let tab = engine.makeTab(configuration: .init(profileID: profile, isEphemeral: ephemeral), initialURL: nil)
        tab.delegate = self
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.view
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        tabs.append(tab)
        return tab
    }

    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SmokeError.failed("Timed out waiting for navigation")
    }

    func load(_ tab: EngineTab, path: String = "") async throws {
        let url = base.appendingPathComponent(path)
        tab.load(url)
        try await wait { !tab.state.isLoading && tab.state.url == url && tab.state.progress >= 1 }
        if let error = tab.state.errorMessage { throw SmokeError.failed(error) }
    }

    func js(_ tab: EngineTab, _ source: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            tab.evaluateJavaScript(source) { continuation.resume(with: $0) }
        }
    }

    func run() async {
        do {
            if let error = engine.initializationError { throw error }
            print(engine.versionDescription)
            let first = make("first")
            first.setUserScripts([.init(id: "obsolete", source: "window.__obsolete = true;")])
            first.setUserScripts([
                .init(id: "start", source: "window.__cairnStart = document.readyState === 'loading';", injection: .documentStart),
                .init(id: "end", source: "window.__cairnEnd = !!document.body;", injection: .documentEnd)
            ])
            try await load(first)
            let scriptState = try await js(first, "[window.__cairnStart, window.__cairnEnd, document.readyState]")
            print("SCRIPT STATE: \(String(describing: scriptState))")
            try require(try await js(first, "window.__cairnStart && window.__cairnEnd") as? Bool == true,
                        "document-start/end scripts execute")
            try require(try await js(first, "typeof window.__obsolete === 'undefined'") as? Bool == true,
                        "rapid script replacement does not retain obsolete scripts")
            try require(try await js(first, "Promise.resolve(6 * 7)") as? Int == 42, "async JavaScript returns a value")
            try require(first.state.title == "Cairn CEF smoke", "title and navigation state")
            try require(!first.state.isSecure, "HTTP is not marked secure")
            first.zoom = 1.2
            try require(abs(first.zoom - 1.2) < 0.001, "zoom")
            let found = await withCheckedContinuation { continuation in
                first.find("needle", forward: true) { continuation.resume(returning: $0) }
            }
            try require(found, "find in native browser")
            first.clearFind()
            let image = await withCheckedContinuation { continuation in
                first.takeSnapshot { continuation.resume(returning: $0) }
            }
            try require(image != nil && image!.size.width > 0, "compositor snapshot")
            _ = try await js(first, "localStorage.setItem('space', 'first'); document.cookie='space=first; path=/'; true")
            let second = make("second")
            try await load(second)
            try require(try await js(second, "localStorage.getItem('space') === null && document.cookie === ''") as? Bool == true,
                        "Space request contexts isolate cookies and localStorage")
            let privateTab = make("first", ephemeral: true)
            try await load(privateTab)
            try require(try await js(privateTab, "localStorage.getItem('space') === null && document.cookie === ''") as? Bool == true,
                        "private context does not inherit persistent data")
            _ = try await js(privateTab, "localStorage.setItem('private', 'yes'); true")
            privateTab.close()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let privateAgain = make("first", ephemeral: true)
            try await load(privateAgain)
            try require(try await js(privateAgain, "localStorage.getItem('private') === null") as? Bool == true,
                        "last private tab close discards session data")
            first.setUserScripts([])
            try await load(first, path: "second")
            try require(try await js(first, "typeof window.__cairnStart === 'undefined'") as? Bool == true,
                        "removed scripts stay removed on next navigation")
            try require(first.state.canGoBack, "back navigation availability")
            first.goBack()
            try await wait { !first.state.isLoading && first.state.url == self.base }
            await engine.clearBrowsingData(profileID: "first", kinds: [.cookies, .cache])
            try require(try await js(first, "document.cookie === ''") as? Bool == true, "profile cookie removal completes")
            _ = try await js(first, "window.open('/popup'); true")
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(popups == 0, "unsolicited popup is blocked")
            print("CAIRN_CEF_SMOKE_OK")
        } catch {
            fputs("CEF SMOKE FAILED: \(error)\n", stderr)
        }
        engine.shutdown()
        NSApp.terminate(nil)
    }

    func engineTab(_ tab: EngineTab, didChange state: EngineTabState) {
        print("STATE \(tab.id): \(state.url?.absoluteString ?? "-") loading=\(state.isLoading) progress=\(state.progress) title=\(state.title) error=\(state.errorMessage ?? "-")")
    }
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) {}
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) { popups += 1 }
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {}
    func engineTabDidRequestClose(_ tab: EngineTab) { tab.close() }
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    guard ChromiumEngineModule.prepareApplication(),
          let root = ProcessInfo.processInfo.environment["CAIRN_SMOKE_DATA_ROOT"],
          let base = ProcessInfo.processInfo.environment["CAIRN_SMOKE_URL"].flatMap(URL.init(string:)) else {
        fatalError("Run with python3 engine/smoke.py")
    }
    NSApp.setActivationPolicy(.regular)
    let smoke = Smoke(root: URL(fileURLWithPath: root), base: base)
    Task { @MainActor in await smoke.run() }
    NSApp.run()
    withExtendedLifetime(smoke) {}
}

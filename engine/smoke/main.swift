import AppKit
import CairnEngineKit
import CairnChromiumEngine

enum SmokeError: Error { case failed(String) }

@MainActor final class Smoke: NSObject, EngineTabDelegate, EngineTabContextMenuEvents {
    let engine: ChromiumEngine
    let root: URL
    let base: URL
    var windows: [NSWindow] = []
    var tabs: [EngineTab] = []
    var popups = 0
    var externalURLs: [URL] = []
    var faviconEvents: [UUID: [NSImage?]] = [:]
    var audioEvents: [UUID: [Bool]] = [:]
    var popupTabs: [EngineTab] = []
    var blockedPopups = 0
    var closeRequests: [UUID] = []

    init(root: URL, base: URL) {
        self.root = root
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

    func checkRendering(_ tab: EngineTab) async throws {
        for _ in 0..<100 {
            if try await js(tab, "window.renderingProbe?.ready === true") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(try await js(tab, "window.renderingProbe?.ready === true") as? Bool == true,
                    "module script and same-origin fetch complete")
        guard let major = ProcessInfo.processInfo.environment["CAIRN_SMOKE_CHROMIUM_MAJOR"],
              Int(major) != nil else { throw SmokeError.failed("Missing expected Chromium major") }
        try require(try await js(tab, """
            navigator.userAgent.includes('Chrome/\(major).') &&
            window.renderingProbe.userAgent === navigator.userAgent
            """) as? Bool == true, "network and JavaScript expose the locked Chromium browser identity")
        try require(try await js(tab, """
            (() => {
              const grid = document.querySelector('.grid');
              const a = grid.children[0].getBoundingClientRect();
              const b = grid.children[1].getBoundingClientRect();
              return getComputedStyle(grid).display === 'grid' && Math.abs(a.top - b.top) < 1 &&
                Math.abs(a.width - b.width) < 1 && b.left >= a.right + 15 && a.width > 250;
            })()
            """) as? Bool == true, "CSS grid and container query produce two equal desktop columns")
        try require(try await js(tab, """
            getComputedStyle(document.querySelector('#interaction-card')).backgroundColor === 'rgb(228, 235, 221)'
            """) as? Bool == true, "CSS :has selector styles the interactive card")
        try require(try await js(tab, """
            document.querySelector('#collect').click(); document.querySelector('#count').value === '1'
            """) as? Bool == true, "module event handler updates the live DOM")
        windows[0].setContentSize(NSSize(width: 480, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        try require(try await js(tab, """
            (() => {
              const cards = document.querySelector('.grid').children;
              return cards[1].getBoundingClientRect().top >= cards[0].getBoundingClientRect().bottom + 15;
            })()
            """) as? Bool == true, "native viewport resize switches the container to stacked cards")
        windows[0].setContentSize(NSSize(width: 800, height: 600))
        try await Task.sleep(for: .milliseconds(150))
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
            try await checkRendering(first)
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
            guard let tiff = image?.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]),
                  let snapshot = ProcessInfo.processInfo.environment["CAIRN_SMOKE_SNAPSHOT"] else {
                throw SmokeError.failed("Could not encode the rendering snapshot")
            }
            try require(bitmap.pixelsWide >= 800 && bitmap.pixelsHigh >= 600, "compositor snapshot retains viewport resolution")
            try png.write(to: URL(fileURLWithPath: snapshot))
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
            try await siteDataScenario()
            _ = try await js(first, "window.open('/popup'); true")
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(popups == 0, "unsolicited popup is blocked")
            _ = try await js(first, "location.href = 'mailto:smoke@example.com'; true")
            try await wait { !self.externalURLs.isEmpty }
            try require(externalURLs.first?.absoluteString == "mailto:smoke@example.com" && first.state.errorMessage == nil,
                        "external protocol is reported to the app, never launched by Chromium")
            try await runMedia()
            try await checkPopups()
            try await checkPrompts()
            try await checkDownloads()
            print("CAIRN_CEF_SMOKE_OK")
        } catch {
            fputs("CEF SMOKE FAILED: \(error)\n", stderr)
        }
        engine.shutdown()
        ChromiumEngineModule.prepareForTermination {
            NSApp.terminate(nil)
        }
    }

    func engineTab(_ tab: EngineTab, didChange state: EngineTabState) {
        print("STATE \(tab.id): \(state.url?.absoluteString ?? "-") loading=\(state.isLoading) progress=\(state.progress) title=\(state.title) error=\(state.errorMessage ?? "-")")
    }
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) { faviconEvents[tab.id, default: []].append(image) }
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) { popups += 1 }
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {}
    func engineTab(_ tab: EngineTab, requestsExternalURL url: URL) { externalURLs.append(url) }
    func engineTabDidRequestClose(_ tab: EngineTab) { closeRequests.append(tab.id); tab.close() }
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    guard ChromiumEngineModule.prepareApplication(mockKeychain: true),
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

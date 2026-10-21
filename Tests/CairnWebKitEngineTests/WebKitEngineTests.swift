import AppKit
import Network
import Testing
import WebKit
@testable import CairnWebKitEngine
import CairnEngineKit

@Suite struct WebKitProfileTests {
    @Test func profileMappingIsStableAndNamespaced() {
        // Pin the on-disk mapping so refactoring cannot silently orphan existing Spaces.
        #expect(WebKitEngine.profileIdentifier("default").uuidString == "7AD43C44-984D-839B-9A1A-77228E8A017A")
        #expect(WebKitEngine.profileIdentifier("work") == WebKitEngine.profileIdentifier("work"))
        #expect(WebKitEngine.profileIdentifier("work") != WebKitEngine.profileIdentifier("Work"))
        #expect(WebKitEngine.profileIdentifier("") != WebKitEngine.profileIdentifier("default"))
        #expect(WebKitEngine.profileIdentifier("e\u{301}") == WebKitEngine.profileIdentifier("é"))
    }
}

@Suite(.serialized) @MainActor
struct WebKitEngineTests {
    @Test func registersARealEngineAndStableView() throws {
        _ = NSApplication.shared
        let registry = EngineRegistry()
        WebKitEngineModule.register(in: registry)
        let engine = try #require(registry.make(.webkit))
        defer { engine.shutdown() }
        #expect(WebKitEngineModule.kind == .webkit)
        #expect(engine.kind == .webkit)
        #expect(engine.displayName == "WebKit")
        #expect(engine.versionDescription.hasPrefix("WebKit "))
        let tab = engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil)
        let view = tab.view
        #expect(view is WKWebView)
        #expect(view === tab.view)
        #expect(tab.state.url == nil)
        #expect(!tab.state.isSecure)
    }

    @Test func profilesShareOnlyTheirOwnData() async throws {
        let profile = "test-\(UUID())"
        func exerciseStores() async throws {
            let engine = WebKitEngine()
            defer { engine.shutdown() }
            let persistent = engine.dataStore(for: .init(profileID: profile))
            let sameProfile = engine.dataStore(for: .init(profileID: profile))
            let differentProfile = engine.dataStore(for: .init(profileID: "\(profile)-other"))
            let ephemeral = engine.dataStore(for: .init(profileID: profile, isEphemeral: true))
            let ephemeralAgain = engine.dataStore(for: .init(profileID: profile, isEphemeral: true))
            #expect(persistent === sameProfile)
            #expect(ephemeral === ephemeralAgain)
            #expect(persistent.isPersistent)
            #expect(persistent.identifier == WebKitEngine.profileIdentifier(profile))
            #expect(differentProfile.identifier != persistent.identifier)
            #expect(!ephemeral.isPersistent)
            #expect(ephemeral.identifier == nil)

            let cookie = try #require(HTTPCookie(properties: [
                .domain: "cairn.invalid", .path: "/", .name: "space", .value: "private",
            ]))
            await persistent.httpCookieStore.setCookie(cookie)
            let secondEngine = WebKitEngine()
            defer { secondEngine.shutdown() }
            let reopened = secondEngine.dataStore(for: .init(profileID: profile))
            #expect(await reopened.httpCookieStore.allCookies().contains { $0.name == "space" })
            #expect(reopened.identifier == persistent.identifier)
            #expect(secondEngine.dataStore(for: .init(profileID: profile, isEphemeral: true)) !== ephemeral)
            #expect(await sameProfile.httpCookieStore.allCookies().contains { $0.name == "space" })
            #expect(await differentProfile.httpCookieStore.allCookies().isEmpty)
            #expect(await ephemeral.httpCookieStore.allCookies().isEmpty)
            await differentProfile.httpCookieStore.setCookie(cookie)
            await ephemeral.httpCookieStore.setCookie(cookie)
            await engine.clearBrowsingData(profileID: profile, kinds: [.cookies])
            #expect(await persistent.httpCookieStore.allCookies().isEmpty)
            #expect(await ephemeral.httpCookieStore.allCookies().isEmpty)
            #expect(await differentProfile.httpCookieStore.allCookies().contains { $0.name == "space" })
        }
        try await exerciseStores()
        // Release stores before asking the network process to remove the test profiles.
        try await Task.sleep(for: .milliseconds(50))
        try await WKWebsiteDataStore.remove(forIdentifier: WebKitEngine.profileIdentifier(profile))
        try await WKWebsiteDataStore.remove(forIdentifier: WebKitEngine.profileIdentifier("\(profile)-other"))
    }

    @Test func browsingDataKindsAreSelective() {
        #expect(WebKitEngine.websiteDataTypes(for: []).isEmpty)
        #expect(WebKitEngine.websiteDataTypes(for: [.cookies]) == [WKWebsiteDataTypeCookies])
        #expect(!WebKitEngine.websiteDataTypes(for: [.cache]).contains(WKWebsiteDataTypeCookies))
        #expect(WebKitEngine.websiteDataTypes(for: [.localStorage]).contains(WKWebsiteDataTypeIndexedDBDatabases))
        #expect(WebKitEngine.websiteDataTypes(for: [.localStorage]).contains(WKWebsiteDataTypeServiceWorkerRegistrations))
    }

    @Test func clearingPrivateDataDoesNotCreateAPersistentProfile() async throws {
        let engine = WebKitEngine()
        defer { engine.shutdown() }
        let profile = "private-clear-\(UUID())"
        let store = engine.dataStore(for: .init(profileID: profile, isEphemeral: true))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "cairn.invalid", .path: "/", .name: "private", .value: "session",
        ]))
        await store.httpCookieStore.setCookie(cookie)
        await engine.clearBrowsingData(profileID: profile, kinds: [.cookies])
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        #expect(!(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(WebKitEngine.profileIdentifier(profile))))
    }

    @Test func securityRequiresSuccessfulUnmixedHTTPS() {
        let https = URL(string: "https://cairn.invalid")!
        #expect(WebKitTab.isSecurePage(url: https, completed: true, loading: false,
                                     hasOnlySecureContent: true, hasServerTrust: true, errorMessage: nil))
        for index in 0..<6 {
            #expect(!WebKitTab.isSecurePage(
                url: index == 0 ? URL(string: "http://cairn.invalid") : https,
                completed: index != 1, loading: index == 2, hasOnlySecureContent: index != 3,
                hasServerTrust: index != 4, errorMessage: index == 5 ? "Failed" : nil
            ))
        }
    }

    @Test func scriptsArePresentOnFirstLoadAndRemainSelfGuarded() async throws {
        let engine = WebKitEngine()
        defer { engine.shutdown() }
        let tab = engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil)
        let delegate = RecordingDelegate()
        tab.delegate = delegate
        tab.setUserScripts([
            .init(id: "start", source: "if (location.protocol === 'data:') window.cairnStart = 42;", injection: .documentStart),
            .init(id: "end", source: "if (location.protocol === 'data:') document.body.dataset.cairn = 'ready';"),
        ])
        tab.load(page("<title>First page</title><script>window.inlineValue = window.cairnStart;</script><p>Find the otter</p>"))
        try await waitFor("initial data page") { tab.state.title == "First page" && !tab.state.isLoading }
        #expect(try await javaScript(tab, "window.inlineValue") as? Int == 42)
        #expect(try await javaScript(tab, "document.body.dataset.cairn") as? String == "ready")
        #expect(delegate.states.contains { $0.isLoading })
        #expect(!tab.state.isSecure)

        tab.load(URL(string: "about:blank")!)
        try await waitFor("about:blank navigation") { tab.state.url?.absoluteString == "about:blank" && !tab.state.isLoading }
        #expect(try await javaScript(tab, "typeof window.cairnStart") as? String == "undefined")

        tab.setUserScripts([])
        tab.load(page("<title>Removed</title><script>window.inlineValue = typeof window.cairnStart;</script>"))
        try await waitFor("script removal") { tab.state.title == "Removed" && !tab.state.isLoading }
        #expect(try await javaScript(tab, "window.inlineValue") as? String == "undefined")
    }

    @Test func navigationFindZoomAndJavaScript() async throws {
        let engine = WebKitEngine()
        defer { engine.shutdown() }
        let tab = engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil)
        tab.load(page("<title>One</title><p>Needle in a haystack</p>"))
        try await waitFor("page one") { tab.state.title == "One" && !tab.state.isLoading }
        #expect(await find(tab, "needle"))
        #expect(!(await find(tab, "missing")))
        tab.clearFind()
        #expect(!(await find(tab, "")))
        tab.zoom = 1.5
        #expect(tab.zoom == 1.5)
        tab.zoom = .nan
        #expect(tab.zoom == 1.5)
        tab.zoom = 100
        #expect(tab.zoom == 5)
        tab.zoom = -1
        #expect(tab.zoom == 0.25)
        do {
            _ = try await javaScript(tab, "throw new Error('test error')")
            Issue.record("JavaScript exception should produce failure")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
        tab.load(page("<title>Two</title>"))
        try await waitFor("page two") { tab.state.title == "Two" && !tab.state.isLoading }
        #expect(tab.state.canGoBack)
        tab.goBack()
        try await waitFor("back navigation") { tab.state.title == "One" && !tab.state.isLoading }
        #expect(tab.state.canGoForward)
        tab.goForward()
        try await waitFor("forward navigation") { tab.state.title == "Two" && !tab.state.isLoading }
        tab.reload(ignoringCache: true)
        try await waitFor("reload") { !tab.state.isLoading }
        #expect(tab.state.title == "Two")
        tab.stopLoading()
        #expect(!tab.state.isLoading)
    }

    @Test func localFileLoadAndFailuresAreVisible() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixture-\(UUID()).html")
        try Data("<html><title>Local fixture</title><p>Offline</p></html>".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let engine = WebKitEngine()
        defer { engine.shutdown() }
        let tab = engine.makeTab(configuration: .init(isEphemeral: true), initialURL: fixture)
        try await waitFor("file page") { tab.state.title == "Local fixture" && !tab.state.isLoading }
        #expect(tab.state.url == fixture)
        #expect(!tab.state.isSecure)
        tab.load(URL(string: "cairn-not-supported://test")!)
        #expect(tab.state.errorMessage?.contains("Unsupported") == true)
        #expect(!tab.state.isSecure)
        let missing = fixture.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).html")
        tab.load(missing)
        try await waitFor("missing file error") { tab.state.errorMessage != nil && !tab.state.isLoading }
        #expect(tab.state.url == missing)
        #expect(!tab.state.isSecure)
    }

    @Test func closingIsIdempotentAndCompletesPendingOperations() async throws {
        let engine = WebKitEngine()
        let tab = try #require(engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil) as? WebKitTab)
        let delegate = RecordingDelegate()
        tab.delegate = delegate
        tab.webViewDidClose(tab.webView)
        #expect(delegate.closeRequests == 1)
        tab.setUserScripts([.init(id: "x", source: "window.test = true")])
        var callbacks = 0
        tab.evaluateJavaScript("1 + 1") { _ in callbacks += 1 }
        tab.close()
        tab.close()
        #expect(callbacks == 1)
        #expect(tab.isClosed)
        #expect(tab.delegate == nil)
        #expect(tab.webView.navigationDelegate == nil)
        #expect(tab.webView.uiDelegate == nil)
        #expect(tab.webView.configuration.userContentController.userScripts.isEmpty)
        #expect(!(await find(tab, "anything")))
        let image = await withCheckedContinuation { continuation in
            tab.takeSnapshot { continuation.resume(returning: $0) }
        }
        #expect(image == nil)
        do {
            _ = try await javaScript(tab, "1")
            Issue.record("Closed tab must reject JavaScript")
        } catch { #expect(error is WebKitEngineError) }
        tab.load(page("<title>Should not load</title>"))
        #expect(!tab.state.isLoading)
        engine.shutdown()
        try await Task.sleep(for: .milliseconds(50))
        #expect(callbacks == 1)
    }

    @Test func engineDoesNotRetainTabsAndShutdownClosesLiveTabs() async throws {
        let engine = WebKitEngine()
        weak var released: AnyObject?
        autoreleasepool {
            let tab = engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil)
            released = tab
        }
        try await waitFor("tab deallocation") { released == nil }
        let live = try #require(engine.makeTab(configuration: .init(isEphemeral: true), initialURL: nil) as? WebKitTab)
        let oldStore = engine.dataStore(for: .init(isEphemeral: true))
        engine.shutdown()
        #expect(live.isClosed)
        #expect(engine.dataStore(for: .init(isEphemeral: true)) !== oldStore)
        engine.shutdown()
    }

    @Test func popupDelegatesAndDeallocationUnloadsTheDocument() async throws {
        var tab: WebKitTab? = WebKitTab(dataStore: .nonPersistent())
        weak var released: WebKitTab?
        released = tab
        let view = try #require(tab?.webView)
        let delegate = RecordingDelegate()
        tab?.delegate = delegate
        tab?.load(page("<title>Popup fixture</title><p>Content to unload</p>"))
        try await waitFor("popup fixture") { tab?.state.title == "Popup fixture" && tab?.state.isLoading == false }
        #expect(!view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await javaScript(try #require(tab), "void window.open('about:blank', '_blank')")
        try await waitFor("new-tab callback") { delegate.newTabs.count == 1 }
        #expect(delegate.newTabs == [URL(string: "about:blank")!])
        tab = nil
        try await waitFor("tab deallocation") { released == nil }
        try await waitFor("document unloading") { view.url?.absoluteString == "about:blank" && !view.isLoading }
        #expect(view.navigationDelegate == nil)
        #expect(view.uiDelegate == nil)
        #expect(view.title == "")
    }

    @Test func downloadNamesDoNotEscapeTheChosenDirectory() {
        #expect(WebKitDownload.safeFilename("../../secret.txt") == "secret.txt")
        #expect(WebKitDownload.safeFilename("a:b\n.txt") == "a-b.txt")
        #expect(WebKitDownload.safeFilename("..") == "Download")
        #expect(WebKitDownload.safeFilename("") == "Download")
    }

    @Test func nativeDownloadsPreserveCookiesAndReplaceOnlyAfterSuccess() async throws {
        let server = try LocalHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let destination = fixtureURL("download.txt")
        try Data("previous contents".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let delegate = RecordingDelegate()
        var suggestions: [String] = []
        let tab = WebKitTab(dataStore: .nonPersistent()) { suggestion, completion in
            suggestions.append(suggestion)
            completion(destination)
        }
        tab.delegate = delegate
        defer { tab.close() }
        tab.load(root.appendingPathComponent("page"))
        try await waitFor("authenticated page") { tab.state.title == "Fixture" && !tab.state.isLoading }
        tab.load(root.appendingPathComponent("download"))
        try await waitFor("authenticated download") {
            (try? String(contentsOf: destination, encoding: .utf8)) == "authenticated content"
        }
        #expect(suggestions == ["session.txt"])
        #expect(server.requests.contains { $0.contains("GET /download ") && $0.contains("session=cairn-test") })
        #expect(tab.state.errorMessage == nil)
        #expect(!tab.state.isLoading)
        try Data("post pending".utf8).write(to: destination)
        _ = try await javaScript(tab, """
            const form = document.createElement('form');
            form.action = '/download'; form.method = 'POST';
            const input = document.createElement('input');
            input.name = 'receipt'; input.value = 'cairn'; form.appendChild(input);
            document.body.appendChild(form); form.submit();
            """)
        try await waitFor("POST download") {
            (try? String(contentsOf: destination, encoding: .utf8)) == "authenticated content"
        }
        #expect(server.requests.contains {
            $0.contains("POST /download ") && $0.contains("session=cairn-test") && $0.contains("receipt=cairn")
        })
        #expect(suggestions.count == 2)
    }

    @Test func downloadCancellationAndFailureAreExplicit() async throws {
        let server = try LocalHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "session", .value: "cairn-test",
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let cancelled = WebKitTab(dataStore: store) { _, completion in completion(nil) }
        defer { cancelled.close() }
        cancelled.load(root.appendingPathComponent("download"))
        try await waitFor("download cancellation") { cancelled.state.errorMessage?.contains("cancelled") == true }

        let impossible = fixtureURL("nonexistent-directory").appendingPathComponent("download.txt")
        let failed = WebKitTab(dataStore: store) { _, completion in completion(impossible) }
        defer { failed.close() }
        failed.load(root.appendingPathComponent("download"))
        try await waitFor("download failure") { failed.state.errorMessage?.contains("failed") == true }
        #expect(!FileManager.default.fileExists(atPath: impossible.path))

        let isolated = WebKitTab(dataStore: .nonPersistent())
        defer { isolated.close() }
        isolated.load(root.appendingPathComponent("download"))
        try await waitFor("isolated cookie rejection") { isolated.state.errorMessage?.contains("401") == true }
    }

    @Test func faviconUsesOnlySameOriginAndSnapshotWorks() async throws {
        let server = try LocalHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let tab = WebKitTab(dataStore: .nonPersistent())
        let delegate = RecordingDelegate()
        tab.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tab.view
        defer { tab.close(); window.close() }
        tab.load(root.appendingPathComponent("icon-page"))
        try await waitFor("same-origin favicon") { delegate.favicons.contains { $0 != nil } }
        #expect(server.requests.contains {
            $0.contains("GET /icon.png ") && $0.contains("session=cairn-test")
                && !$0.lowercased().contains("referer:")
        })
        let snapshot = await withCheckedContinuation { continuation in
            tab.takeSnapshot { continuation.resume(returning: $0) }
        }
        #expect(snapshot != nil)
        tab.load(root.appendingPathComponent("cross-origin-icon"))
        try await waitFor("cross-origin icon page") { tab.state.title == "Cross origin" && !tab.state.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!server.requests.contains { $0.contains("GET /foreign.png ") })
        #expect(delegate.favicons.last! == nil)
    }
}

@MainActor
private final class RecordingDelegate: EngineTabDelegate {
    var states: [EngineTabState] = []
    var closeRequests = 0
    var newTabs: [URL] = []
    var favicons: [NSImage?] = []
    func engineTab(_ tab: EngineTab, didChange state: EngineTabState) { states.append(state) }
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?) { favicons.append(image) }
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool) { newTabs.append(url) }
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?) {
        Issue.record("WebKit downloads must not be degraded to a cookie-less URL callback")
    }
    func engineTabDidRequestClose(_ tab: EngineTab) { closeRequests += 1 }
}

@MainActor
private func waitFor(_ description: String, condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(condition(), Comment(rawValue: "Timed out: \(description)"))
}

private func page(_ html: String) -> URL {
    URL(string: "data:text/html;base64,\(Data(("<!doctype html>" + html).utf8).base64EncodedString())")!
}

private func fixtureURL(_ suffix: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("fixture-\(UUID())-\(suffix)")
}

@MainActor
private func javaScript(_ tab: EngineTab, _ source: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        tab.evaluateJavaScript(source) { continuation.resume(with: $0) }
    }
}

@MainActor
private func find(_ tab: EngineTab, _ query: String) async -> Bool {
    await withCheckedContinuation { continuation in
        tab.find(query, forward: true) { continuation.resume(returning: $0) }
    }
}

/// Loopback-only fixture: no Internet, process launch, test dependency or temporary-directory access.
private final class LocalHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Cairn.WebKitTests.HTTP")
    private let lock = NSLock()
    private var receivedRequests: [String] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startCompleted = false
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequests
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startCompleted else { return }
                switch state {
                case .ready:
                    self.startCompleted = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.startCompleted = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var requestData = data
            requestData.append(chunk ?? Data())
            let request = String(data: requestData, encoding: .utf8) ?? ""
            let requestHeaders = request.components(separatedBy: "\r\n\r\n").first ?? ""
            let contentLength = requestHeaders.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.contains("\r\n\r\n"), requestData.count >= requestHeaders.utf8.count + 4 + contentLength else {
                if !complete && error == nil && requestData.count < 16_384 {
                    self.receive(connection, data: requestData)
                } else {
                    connection.cancel()
                    self.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
                return
            }
            self.lock.lock()
            self.receivedRequests.append(request)
            self.lock.unlock()
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let status: Int
            let body: Data
            var headers = "Content-Type: text/html\r\n"
            switch path {
            case "/download":
                if request.contains("session=cairn-test"),
                   !request.hasPrefix("POST") || request.contains("receipt=cairn") {
                    status = 200
                    body = Data("authenticated content".utf8)
                    headers = "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"session.txt\"\r\n"
                } else {
                    status = 401
                    body = Data("Missing session cookie".utf8)
                }
            case "/icon.png":
                status = 200
                body = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII=")!
                headers = "Content-Type: image/png\r\n"
            case "/cross-origin-icon":
                status = 200
                body = Data("<title>Cross origin</title><link rel=icon href='http://localhost:\(self.listener.port!.rawValue)/foreign.png'>".utf8)
            default:
                status = 200
                body = Data("<title>Fixture</title><link rel=icon href='/icon.png'><p>Local HTTP fixture</p>".utf8)
                headers += "Set-Cookie: session=cairn-test; Path=/; HttpOnly; SameSite=Lax\r\n"
            }
            var response = Data("HTTP/1.1 \(status) Response\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            })
        }
    }
}

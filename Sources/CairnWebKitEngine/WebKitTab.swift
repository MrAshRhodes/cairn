import AppKit
import CairnEngineKit
import ImageIO
import WebKit

enum WebKitEngineError: LocalizedError {
    case closed
    var errorDescription: String? { "This tab is closed." }
}

@MainActor
final class WebKitTab: NSObject, EngineTab, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    var view: NSView { webView }
    private(set) var state = EngineTabState()
    weak var delegate: EngineTabDelegate? {
        didSet {
            guard !isClosed else { return }
            delegate?.engineTab(self, didChange: state)
        }
    }
    var zoom: Double {
        get { webView.pageZoom }
        set {
            guard !isClosed, newValue.isFinite else { return }
            webView.pageZoom = min(5, max(0.25, newValue))
        }
    }

    private(set) var isClosed = false
    private var observations: [NSKeyValueObservation] = []
    private var completedNavigation = false
    private var failedNavigation = false
    private var pageGeneration = UUID()
    private var pendingCompletions: [UUID: () -> Void] = [:]
    private var downloads: [ObjectIdentifier: WebKitDownload] = [:]
    private var dialogs: [UUID: () -> Void] = [:]
    private var currentNavigation: WKNavigation?
    private let downloadDestinationPicker: WebKitDownload.DestinationPicker?

    init(dataStore: WKWebsiteDataStore, downloadDestinationPicker: WebKitDownload.DestinationPicker? = nil) {
        self.downloadDestinationPicker = downloadDestinationPicker
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = WKUserContentController()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observe(\.url)
        observe(\.title)
        observe(\.isLoading)
        observe(\.estimatedProgress)
        observe(\.canGoBack)
        observe(\.canGoForward)
        observe(\.hasOnlySecureContent)
        observe(\.serverTrust)
    }

    deinit {
        observations.forEach { $0.invalidate() }
        let pending = Array(pendingCompletions.values)
        // WKWebView delegates are weak. Cleanup also applies if an owner forgets close().
        let view = webView
        let activeDownloads = Array(downloads.values)
        let activeDialogs = Array(dialogs.values)
        Task { @MainActor in
            pending.forEach { $0() }
            activeDialogs.forEach { $0() }
            activeDownloads.forEach { $0.cancel(report: false) }
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.stopLoading()
            view.pauseAllMediaPlayback(completionHandler: nil)
            view.closeAllMediaPresentations(completionHandler: nil)
            view.configuration.userContentController.removeAllUserScripts()
            view.loadHTMLString("", baseURL: nil)
            view.removeFromSuperview()
        }
    }

    private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
        observations.append(webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshState() }
        })
    }

    private func refreshState() {
        guard !isClosed else { return }
        var next = state
        if !failedNavigation { next.url = webView.url ?? next.url }
        next.title = webView.title ?? ""
        next.isLoading = failedNavigation ? false : webView.isLoading
        next.progress = webView.estimatedProgress
        next.canGoBack = webView.canGoBack
        next.canGoForward = webView.canGoForward
        next.isSecure = Self.isSecurePage(
            url: next.url, completed: completedNavigation, loading: next.isLoading,
            hasOnlySecureContent: webView.hasOnlySecureContent, hasServerTrust: webView.serverTrust != nil,
            errorMessage: next.errorMessage
        )
        publish(next)
    }

    static func isSecurePage(url: URL?, completed: Bool, loading: Bool, hasOnlySecureContent: Bool,
                             hasServerTrust: Bool, errorMessage: String?) -> Bool {
        url?.scheme?.lowercased() == "https" && completed && !loading && hasOnlySecureContent
            && hasServerTrust && errorMessage == nil
    }

    private func publish(_ next: EngineTabState) {
        guard next != state else { return }
        state = next
        delegate?.engineTab(self, didChange: next)
    }

    private func beginNavigation(to url: URL?) {
        completedNavigation = false
        failedNavigation = false
        pageGeneration = UUID()
        var next = state
        next.url = url ?? next.url
        next.title = ""
        next.errorMessage = nil
        next.isSecure = false
        next.isLoading = true
        next.progress = 0
        publish(next)
        delegate?.engineTab(self, didReceiveFavicon: nil)
    }

    private static func supports(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "about", "data", "blob"].contains(scheme)
    }

    func load(_ url: URL) {
        navigate(to: url, ignoringCache: false)
    }

    private func navigate(to url: URL, ignoringCache: Bool) {
        guard !isClosed else { return }
        guard Self.supports(url) else {
            reportError("Unsupported URL scheme: \(url.scheme ?? "(none)").")
            return
        }
        beginNavigation(to: url)
        if url.isFileURL {
            currentNavigation = webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            currentNavigation = webView.load(URLRequest(
                url: url, cachePolicy: ignoringCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            ))
        }
    }

    func goBack() {
        guard !isClosed, webView.canGoBack else { return }
        beginNavigation(to: webView.backForwardList.backItem?.url)
        currentNavigation = webView.goBack()
    }

    func goForward() {
        guard !isClosed, webView.canGoForward else { return }
        beginNavigation(to: webView.backForwardList.forwardItem?.url)
        currentNavigation = webView.goForward()
    }

    func reload(ignoringCache: Bool) {
        guard !isClosed else { return }
        // A failed provisional navigation can leave WebKit displaying the previous document.
        if failedNavigation, let url = state.url {
            navigate(to: url, ignoringCache: ignoringCache)
            return
        }
        guard webView.url != nil else { return }
        beginNavigation(to: webView.url)
        currentNavigation = ignoringCache ? webView.reloadFromOrigin() : webView.reload()
    }

    func stopLoading() {
        guard !isClosed, webView.isLoading || state.isLoading else { return }
        completedNavigation = false
        webView.stopLoading()
        var next = state
        next.isLoading = false
        next.isSecure = false
        publish(next)
    }

    private func tracked<Value>(_ completion: @escaping (Value) -> Void, closedValue: Value) -> (Value) -> Void {
        let key = UUID()
        pendingCompletions[key] = { completion(closedValue) }
        return { [weak self] value in
            guard let self, self.pendingCompletions.removeValue(forKey: key) != nil else { return }
            completion(value)
        }
    }

    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) {
        guard !isClosed else { completion(false); return }
        if query.isEmpty { clearFind(); completion(false); return }
        let finish = tracked(completion, closedValue: false)
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { result in finish(result.matchFound) }
    }

    func clearFind() {
        guard !isClosed else { return }
        webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        guard !isClosed else { completion?(.failure(WebKitEngineError.closed)); return }
        let finish = tracked(completion ?? { _ in }, closedValue: Result<Any?, Error>.failure(WebKitEngineError.closed))
        webView.evaluateJavaScript(source) { value, error in
            if let error { finish(.failure(error)) } else { finish(.success(value)) }
        }
    }

    func setUserScripts(_ scripts: [EngineUserScript]) {
        guard !isClosed else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in scripts {
            controller.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.injection == .documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: false
            ))
        }
    }

    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        guard !isClosed else { completion(nil); return }
        let finish = tracked(completion, closedValue: nil)
        webView.takeSnapshot(with: nil) { image, _ in finish(image) }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pageGeneration = UUID()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        let pending = Array(pendingCompletions.values)
        pendingCompletions.removeAll()
        pending.forEach { $0() }
        let activeDialogs = Array(dialogs.values)
        dialogs.removeAll()
        activeDialogs.forEach { $0() }
        let activeDownloads = Array(downloads.values)
        downloads.removeAll()
        activeDownloads.forEach { $0.cancel(report: false) }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.configuration.userContentController.removeAllUserScripts()
        // A caller may retain a closed tab/view. Unload its document so timers and requests cannot continue.
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        currentNavigation = nil
        var next = state
        next.isLoading = false
        next.isSecure = false
        publish(next)
        delegate = nil
    }

    func reportError(_ message: String) {
        guard !isClosed else { return }
        var next = state
        next.errorMessage = message
        next.isSecure = false
        publish(next)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !isClosed, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme?.lowercased() == "javascript", navigationAction.targetFrame != nil {
            decisionHandler(.allow)
            return
        }
        guard Self.supports(url) else {
            reportError("Unsupported URL scheme: \(url.scheme ?? "(none)").")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2 {
            delegate?.engineTab(self, requestsNewTab: url, activate: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !isClosed else { decisionHandler(.cancel); return }
        let response = navigationResponse.response as? HTTPURLResponse
        let attachment = response?.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
        if attachment || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if navigationResponse.isForMainFrame, let response, response.statusCode >= 400 {
            reportError("HTTP \(response.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)).")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { return }
        currentNavigation = navigation
        beginNavigation(to: webView.url)
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { refreshState() }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed, navigation == nil || navigation === currentNavigation else { return }
        completedNavigation = true
        refreshState()
        fetchFavicon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard !isClosed, navigation == nil || currentNavigation == nil || navigation === currentNavigation else { return }
        let nsError = error as NSError
        // Cancellations caused by stop/replacement/download conversion are not page errors.
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        // WKDownload conversion still reports the legacy WebKit policy-interruption error (102).
        guard nsError.domain != "WebKitErrorDomain" || nsError.code != 102 else { return }
        failedNavigation = true
        completedNavigation = false
        var next = state
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL { next.url = url }
        next.errorMessage = error.localizedDescription
        next.isLoading = false
        next.isSecure = false
        publish(next)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failedNavigation = true
        completedNavigation = false
        reportError("The web content process stopped. Reload this tab to continue.")
        refreshState()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The system validates TLS and uses its authentication machinery; never trust arbitrary certificates.
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isClosed, let url = navigationAction.request.url, Self.supports(url) else { return nil }
        if let method = navigationAction.request.httpMethod, method != "GET" {
            // The shared delegate only carries a URL, not a body. Keep form popups in this tab.
            currentNavigation = webView.load(navigationAction.request)
            return nil
        }
        delegate?.engineTab(self, requestsNewTab: url, activate: true)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard !isClosed else { return }
        delegate?.engineTabDidRequestClose(self)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    private func adopt(_ download: WKDownload) {
        guard !isClosed else { download.cancel(nil); return }
        let key = ObjectIdentifier(download)
        downloads[key] = WebKitDownload(download: download, tab: self, destinationPicker: downloadDestinationPicker) { [weak self] in
            self?.downloads.removeValue(forKey: key)
        }
    }

    private func fetchFavicon() {
        guard state.errorMessage == nil, ["http", "https"].contains(webView.url?.scheme ?? "") else { return }
        let generation = pageGeneration
        // Isolated-world fetch uses this tab's WebKit cookie store, never a global URLSession or icon service.
        // Only declared, same-origin icons; reject redirects rather than contacting an unexpected origin.
        webView.callAsyncJavaScript("""
            const link = Array.from(document.querySelectorAll('link[rel]'))
                .find(item => item.rel.toLowerCase().split(/\\s+/).includes('icon'));
            if (!link) return null;
            const url = new URL(link.href, document.baseURI);
            if (url.origin !== location.origin || !['http:', 'https:'].includes(url.protocol)) return null;
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 4000);
            try {
                const response = await fetch(url.href, { credentials: 'same-origin', mode: 'same-origin',
                    redirect: 'error', referrerPolicy: 'no-referrer', signal: controller.signal });
                if (!response.ok || !response.headers.get('content-type')?.startsWith('image/')) return null;
                if (Number(response.headers.get('content-length')) > 262144) return null;
                const reader = response.body.getReader();
                let length = 0; const chunks = [];
                while (true) {
                    const item = await reader.read();
                    if (item.done) break;
                    length += item.value.length;
                    if (length > 262144) { await reader.cancel(); return null; }
                    chunks.push(item.value);
                }
                let binary = '';
                for (const chunk of chunks) for (const byte of chunk) binary += String.fromCharCode(byte);
                return btoa(binary);
            } catch (_) { return null; } finally { clearTimeout(timer); }
            """, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, !self.isClosed, self.pageGeneration == generation,
                      case .success(let value) = result, let encoded = value as? String,
                      let data = Data(base64Encoded: encoded), let image = Self.faviconImage(from: data) else { return }
                self.delegate?.engineTab(self, didReceiveFavicon: image)
            }
    }

    private static func faviconImage(from data: Data) -> NSImage? {
        guard data.count <= 262_144,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func showDialog(_ alert: NSAlert, cancelled: @escaping () -> Void,
                            completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isClosed, let window = webView.window else { cancelled(); return }
        let key = UUID()
        dialogs[key] = {
            window.endSheet(alert.window)
            cancelled()
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard self?.dialogs.removeValue(forKey: key) != nil else { return }
            completion(response)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = makeAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        showDialog(alert, cancelled: completionHandler) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = makeAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        showDialog(alert, cancelled: { completionHandler(false) }) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = makeAlert(prompt, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        showDialog(alert, cancelled: { completionHandler(nil) }) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func makeAlert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Web page"
        alert.informativeText = String(message.prefix(4096))
        return alert
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard !isClosed, let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let key = UUID()
        dialogs[key] = { panel.cancel(nil); completionHandler(nil) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard self?.dialogs.removeValue(forKey: key) != nil else { return }
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

import AppKit
import CairnEngineKit
import CairnChromiumBridge

/// The Chromium implementation of `EngineTab`, wrapping one bridge tab (`CCChromiumTab`).
///
/// Internal rather than private so feature work can live in its own `ChromiumTab+<Feature>.swift`
/// extension instead of editing this file. To report a NEW tab event to the app, do not extend
/// `EngineTabDelegate` (frozen); deliver it through an optional feature protocol, e.g.
/// `(delegate as? EngineTabAudioEvents)?.engineTab(self, ...)` (see `EngineTabEvents.swift`).
/// The bridge reports a feature through that feature's own protocol, declared in its slot of
/// `CairnChromiumBridge.h` and adopted in the same extension file:
/// `extension ChromiumTab: @preconcurrency CCChromiumTabAudioDelegate`.
@MainActor
final class ChromiumTab: NSObject, EngineTab, EngineTabCloseControlling, @preconcurrency CCChromiumTabDelegate {
    let id = UUID()
    let profileID: String
    let bridge: CCChromiumTab
    private let startupError: Error?
    private(set) var closed = false
    weak var engine: ChromiumEngine?
    var popupBudget = PopupBudget()
    /// CEF reports a source view's address without the `view-source:` prefix; remember it so the app keeps the real URL.
    private var viewSourceURL: URL?
    var view: NSView { bridge.view }
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate? {
        didSet { delegate?.engineTab(self, didChange: state) }
    }
    var zoom: Double {
        get { bridge.zoom }
        set {
            bridge.zoom = newValue
            (delegate as? EngineTabZoomEvents)?.engineTab(self, zoomDidChange: bridge.zoom)
        }
    }

    init(configuration: EngineConfiguration, error: Error?) {
        profileID = configuration.profileID
        ChromiumDownloadBridge.shared.remember(profileID: configuration.profileID)
        startupError = error
        bridge = CCChromiumTab(profile: ChromiumEngine.profileDirectory(configuration.profileID),
                               ephemeral: configuration.isEphemeral)
        super.init()
        bridge.delegate = self
        if let error { report(error.localizedDescription) }
    }

    /// A popup CEF creates for `opener`: same profile and request context, `window.opener` intact.
    init(popupOf opener: ChromiumTab) {
        profileID = opener.profileID
        startupError = nil
        engine = opener.engine
        bridge = CCChromiumTab(adoptingPopupFrom: opener.bridge)
        super.init()
        bridge.delegate = self
    }

    func report(_ message: String) {
        state.errorMessage = message
        state.isLoading = false
        state.isSecure = false
        delegate?.engineTab(self, didChange: state)
    }
    func load(_ url: URL) {
        guard !closed, startupError == nil else { return }
        guard ["https", "http", "about", "file"].contains(url.scheme?.lowercased() ?? "") || ViewSource.isViewSource(url) else {
            report("Unsupported URL scheme"); return
        }
        viewSourceURL = ViewSource.isViewSource(url) ? url : nil
        state.url = url
        // Only a tab that is on screen gets a browser; a detached tab loads once it is attached, so it must not spin.
        state.isLoading = bridge.view.window != nil
        state.progress = 0
        state.isSecure = false
        state.errorMessage = nil
        delegate?.engineTab(self, didChange: state)
        bridge.loadURL(url.absoluteString)
    }
    func goBack() { if !closed { bridge.goBack() } }
    func goForward() { if !closed { bridge.goForward() } }
    func reload(ignoringCache: Bool) { if !closed { bridge.reloadIgnoringCache(ignoringCache) } }
    func stopLoading() { bridge.stop() }
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) {
        bridge.find(query, forward: forward) { completion($0) }
    }
    func clearFind() { bridge.clearFind() }
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        bridge.evaluate(source) { value, error in
            if let error { completion?(.failure(error)) } else { completion?(.success(value)) }
        }
    }
    func setUserScripts(_ scripts: [EngineUserScript]) {
        bridge.setScripts(scripts.map { ["source": $0.source, "injection": $0.injection.rawValue] })
    }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { bridge.snapshot { completion($0) } }
    func close() {
        requestClose { _ in }
    }
    func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        guard !closed else { completion(true); return }
        // Retain the Swift/bridge tab until CEF decides. Stay must leave its delegate and state intact.
        bridge.requestClose { [self] approved in
            MainActor.assumeIsolated {
                if approved { closed = true }
                completion(approved)
            }
        }
    }
    func forceClose() {
        bridge.forceClose()
        closed = true
    }

    func chromiumTab(_ tab: CCChromiumTab, changed value: [String: Any]) {
        guard !closed else { return }
        var reported = (value["url"] as? String).flatMap(URL.init(string:))
        if let viewSourceURL, reported == ViewSource.inner(of: viewSourceURL) { reported = viewSourceURL }
        else if let reported, reported.absoluteString != "about:blank" { viewSourceURL = nil }
        state = EngineTabState(url: reported,
                               title: value["title"] as? String ?? "",
                               isLoading: value["isLoading"] as? Bool ?? false,
                               progress: value["progress"] as? Double ?? 0,
                               canGoBack: value["canGoBack"] as? Bool ?? false,
                               canGoForward: value["canGoForward"] as? Bool ?? false,
                               isSecure: value["isSecure"] as? Bool ?? false,
                               errorMessage: value["error"] as? String)
        delegate?.engineTab(self, didChange: state)
    }
    func chromiumTab(_ tab: CCChromiumTab, popup url: String, activate: Bool) {
        guard let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        delegate?.engineTab(self, requestsNewTab: url, activate: activate)
    }
    func chromiumTab(_ tab: CCChromiumTab, download url: String, filename: String) {
        guard let url = URL(string: url) else { return }
        delegate?.engineTab(self, requestsDownload: url, suggestedFilename: filename)
    }
    func chromiumTabRequestsClose(_ tab: CCChromiumTab) { delegate?.engineTabDidRequestClose(self) }
}

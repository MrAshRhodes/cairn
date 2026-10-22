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
final class ChromiumTab: NSObject, EngineTab, @preconcurrency CCChromiumTabDelegate {
    let id = UUID()
    let profileID: String
    let bridge: CCChromiumTab
    private let startupError: Error?
    private(set) var closed = false
    var view: NSView { bridge.view }
    private(set) var state = EngineTabState()
    weak var delegate: EngineTabDelegate? {
        didSet { delegate?.engineTab(self, didChange: state) }
    }
    var zoom: Double {
        get { bridge.zoom }
        set { bridge.zoom = newValue }
    }

    init(configuration: EngineConfiguration, error: Error?) {
        profileID = configuration.profileID
        startupError = error
        bridge = CCChromiumTab(profile: ChromiumEngine.profileDirectory(configuration.profileID),
                               ephemeral: configuration.isEphemeral)
        super.init()
        bridge.delegate = self
        if let error { report(error.localizedDescription) }
    }

    func report(_ message: String) {
        state.errorMessage = message
        state.isLoading = false
        state.isSecure = false
        delegate?.engineTab(self, didChange: state)
    }
    func load(_ url: URL) {
        guard !closed, startupError == nil else { return }
        guard ["https", "http", "about", "file"].contains(url.scheme?.lowercased() ?? "") else {
            report("Unsupported URL scheme"); return
        }
        state.url = url
        state.isLoading = true
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
        guard !closed else { return }
        closed = true
        bridge.close()
        bridge.delegate = nil
    }

    func chromiumTab(_ tab: CCChromiumTab, changed value: [String: Any]) {
        guard !closed else { return }
        state = EngineTabState(url: (value["url"] as? String).flatMap(URL.init(string:)),
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

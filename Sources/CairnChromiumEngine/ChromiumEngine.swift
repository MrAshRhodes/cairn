import AppKit
import CryptoKit
import CairnEngineKit
import CairnChromiumBridge

public enum ChromiumEngineModule {
    /// Must run before anything touches NSApplication.shared (AppKit, Sparkle) so CEF's application subclass is the one instantiated.
    @MainActor @discardableResult public static func prepareApplication() -> Bool {
        CCChromiumRuntime.prepareApplication()
    }

    @MainActor public static func register(in registry: EngineRegistry) {
        registry.register(.chromium) { ChromiumEngine() }
    }

    /// Invoke only after the app delegate's save/discard checks have approved quitting.
    @MainActor public static func prepareForTermination(completion: @escaping @MainActor () -> Void) {
        CCChromiumRuntime.shutdown {
            MainActor.assumeIsolated { completion() }
        }
    }
}

@MainActor
public final class ChromiumEngine: BrowserEngine {
    public let kind = EngineKind.chromium
    public let displayName = "Chromium (CEF, experimental)"
    public var versionDescription: String { CCChromiumRuntime.versionDescription() }
    public private(set) var initializationError: Error?
    public private(set) var lastDataRemovalError: String?
    private var tabs: [UUID: WeakTab] = [:]

    public init(dataRoot: URL? = nil) {
        let support = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn/Chromium")
        do {
            try CCChromiumRuntime.start(withRoot: support.path)
        } catch {
            initializationError = error
        }
    }

    public func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = ChromiumTab(configuration: configuration, error: initializationError)
        tabs[tab.id] = WeakTab(tab)
        tabs = tabs.filter { $0.value.value != nil }
        if let initialURL { tab.load(initialURL) }
        return tab
    }

    public func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {
        lastDataRemovalError = nil
        if kinds.contains(.localStorage) {
            let message = "Chromium cannot yet clear all origins' local storage while running. Quit Cairn and remove the Space's Chromium profile directory; this also removes that Space's cookies and cache."
            lastDataRemovalError = message
            NSLog("%@", message)
            for tab in tabs.values.compactMap(\.value) where tab.profileID == profileID {
                tab.report(message)
            }
        }
        guard initializationError == nil else { return }
        await withCheckedContinuation { continuation in
            CCChromiumRuntime.clearProfile(Self.profileDirectory(profileID),
                                           cookies: kinds.contains(.cookies), cache: kinds.contains(.cache)) {
                continuation.resume()
            }
        }
    }

    public func shutdown() {
        for tab in tabs.values.compactMap(\.value) { tab.close() }
        tabs.removeAll()
        // The CEF runtime is process-wide and initialized once, so closing tabs here does not shut it down.
        // The approved application-termination hook shuts the runtime down exactly once.
    }

    public static func profileDirectory(_ profileID: String) -> String {
        SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor private final class WeakTab {
    weak var value: ChromiumTab?
    init(_ value: ChromiumTab) { self.value = value }
}

@MainActor
private final class ChromiumTab: NSObject, EngineTab, @preconcurrency CCChromiumTabDelegate {
    let id = UUID()
    let profileID: String
    private let bridge: CCChromiumTab
    private let startupError: Error?
    private var closed = false
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

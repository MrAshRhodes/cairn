import AppKit

// FROZEN API — owned by the parent/integrator. Agents may ADD public API (new files/extensions) but must not
// rename, remove, or change existing signatures. Both CairnWebKitEngine and the gated Chromium engine implement it.

public enum EngineKind: String, Codable, Sendable, CaseIterable {
    case webkit, chromium
}

public enum BrowsingDataKind: String, CaseIterable, Sendable {
    case cookies, cache, localStorage
}

public struct EngineConfiguration: Sendable {
    /// Cookies/storage are isolated per profile; every Space maps to one profile.
    public var profileID: String
    /// Private (non-persistent) data store.
    public var isEphemeral: Bool
    public init(profileID: String = "default", isEphemeral: Bool = false) {
        self.profileID = profileID
        self.isEphemeral = isEphemeral
    }
}

public struct EngineTabState: Equatable, Sendable {
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var progress: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isSecure: Bool
    public var errorMessage: String?
    public init(url: URL? = nil, title: String = "", isLoading: Bool = false, progress: Double = 0,
                canGoBack: Bool = false, canGoForward: Bool = false, isSecure: Bool = false,
                errorMessage: String? = nil) {
        self.url = url; self.title = title; self.isLoading = isLoading; self.progress = progress
        self.canGoBack = canGoBack; self.canGoForward = canGoForward; self.isSecure = isSecure
        self.errorMessage = errorMessage
    }
}

/// A script the engine injects into every page of the tab. Scripts must guard themselves (e.g. by `location.hostname`);
/// per-site targeting is done by the producer (see CairnBoosts), not by the engine.
public struct EngineUserScript: Hashable, Sendable {
    public enum Injection: String, Sendable { case documentStart, documentEnd }
    public var id: String
    public var source: String
    public var injection: Injection
    public init(id: String, source: String, injection: Injection = .documentEnd) {
        self.id = id; self.source = source; self.injection = injection
    }
}

@MainActor
public protocol EngineTabDelegate: AnyObject {
    func engineTab(_ tab: EngineTab, didChange state: EngineTabState)
    func engineTab(_ tab: EngineTab, didReceiveFavicon image: NSImage?)
    func engineTab(_ tab: EngineTab, requestsNewTab url: URL, activate: Bool)
    func engineTab(_ tab: EngineTab, requestsDownload url: URL, suggestedFilename: String?)
    func engineTabDidRequestClose(_ tab: EngineTab)
}

@MainActor
public protocol EngineTab: AnyObject {
    var id: UUID { get }
    /// The view to embed in the window; stable for the lifetime of the tab.
    var view: NSView { get }
    var state: EngineTabState { get }
    var delegate: EngineTabDelegate? { get set }
    var zoom: Double { get set }
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload(ignoringCache: Bool)
    func stopLoading()
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void)
    func clearFind()
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?)
    func setUserScripts(_ scripts: [EngineUserScript])
    func takeSnapshot(completion: @escaping (NSImage?) -> Void)
    func close()
}

@MainActor
public protocol BrowserEngine: AnyObject {
    var kind: EngineKind { get }
    var displayName: String { get }
    /// Human-readable engine version, e.g. "WebKit 21619" or "Chromium 154.0.8037.98".
    var versionDescription: String { get }
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async
    func shutdown()
}

/// Engines register a factory at launch; the app picks one by `EngineKind` (user setting).
@MainActor
public final class EngineRegistry {
    public static let shared = EngineRegistry()
    private var factories: [EngineKind: () -> BrowserEngine] = [:]
    public init() {}
    public func register(_ kind: EngineKind, factory: @escaping () -> BrowserEngine) { factories[kind] = factory }
    public var available: [EngineKind] { EngineKind.allCases.filter { factories[$0] != nil } }
    public func make(_ kind: EngineKind) -> BrowserEngine? { factories[kind]?() }
}

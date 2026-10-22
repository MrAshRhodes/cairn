import AppKit
import CryptoKit
import CairnEngineKit
import CairnChromiumBridge

public enum ChromiumEngineModule {
    /// Must run before anything touches NSApplication.shared (AppKit, Sparkle) so CEF's application subclass is the one instantiated.
    /// `mockKeychain` is for unattended test harnesses only: Chromium then encrypts cookies with a fixed mock key instead of the
    /// user's Keychain, so a Keychain authorization dialog cannot block loading. Shipping builds must keep it `false`.
    @MainActor @discardableResult public static func prepareApplication(mockKeychain: Bool = false) -> Bool {
        CCChromiumRuntime.prepareApplication(withMockKeychain: mockKeychain)
    }

    @MainActor public static func register(in registry: EngineRegistry) {
        registry.register(.chromium) { ChromiumEngine() }
    }

    /// Test harnesses only: crashes the tab's renderer process to exercise crash recovery.
    @MainActor public static func crashRendererForTesting(_ tab: EngineTab) {
        (tab as? ChromiumTab)?.bridge.crashRendererForTesting()
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
    /// Why the last clear could not remove everything, shown in Preferences (never as a per-tab error).
    public private(set) var lastDataRemovalError: String?
    private var tabs: [UUID: WeakTab] = [:]

    public init(dataRoot: URL? = nil) {
        let support = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn/Chromium")
        do {
            try CCChromiumRuntime.start(withRoot: EngineStorageRoot.resolve(support).path)
        } catch {
            if (error as NSError).domain == "org.cairn.Chromium.Startup",
               case .alreadyRunning(let code) = EngineStartupOutcome(exitCode: (error as NSError).code) {
                // Another Cairn owns this profile and has been told to show itself; nothing is left to do here.
                exit(code)
            }
            initializationError = error
        }
    }

    public func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = ChromiumTab(configuration: configuration, error: initializationError)
        track(tab)
        if let initialURL { tab.load(initialURL) }
        return tab
    }

    func track(_ tab: ChromiumTab) {
        tab.engine = self
        tabs[tab.id] = WeakTab(tab)
        tabs = tabs.filter { $0.value.value != nil }
    }

    public func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {
        var selected: SiteDataKinds = []
        if kinds.contains(.cookies) { selected.insert(.cookies) }
        if kinds.contains(.cache) { selected.insert(.cache) }
        if kinds.contains(.localStorage) { selected.insert(.storage) }
        _ = await clearSiteData(profileID: profileID, site: nil, kinds: selected)
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

extension ChromiumEngine: EngineSiteDataManaging {
    public func clearSiteData(profileID: String, site: String?, kinds: SiteDataKinds) async -> SiteDataClearResult {
        lastDataRemovalError = nil
        if let initializationError {
            lastDataRemovalError = initializationError.localizedDescription
            return SiteDataClearResult(failures: [initializationError.localizedDescription])
        }
        let failures: [String] = await withCheckedContinuation { continuation in
            CCChromiumRuntime.clearSiteData(forProfile: Self.profileDirectory(profileID), site: site,
                                            cookies: kinds.contains(.cookies), cache: kinds.contains(.cache),
                                            storage: kinds.contains(.storage)) { continuation.resume(returning: $0) }
        }
        lastDataRemovalError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return SiteDataClearResult(failures: failures)
    }

    public func deleteProfileData(profileID: String) async {
        guard initializationError == nil else { return }
        await withCheckedContinuation { continuation in
            CCChromiumRuntime.deleteProfile(Self.profileDirectory(profileID)) { continuation.resume() }
        }
    }

    @discardableResult
    public func removeOrphanProfiles(keeping profileIDs: Set<String>) -> [String] {
        guard initializationError == nil else { return [] }
        return CCChromiumRuntime.removeOrphanProfilesKeeping(profileIDs.map(Self.profileDirectory))
    }

    public func configureContentBlocking(_ configuration: ContentBlockingConfiguration) {
        CCChromiumRuntime.setContentBlockingEnabled(configuration.isEnabled, blockedHosts: configuration.blockedHosts,
                                                    exemptSites: configuration.exemptSites)
    }

    public var blockedRequestCount: Int { Int(CCChromiumRuntime.blockedRequestCount()) }
}

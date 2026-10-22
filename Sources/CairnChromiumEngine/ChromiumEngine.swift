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

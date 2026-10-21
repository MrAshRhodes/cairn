import AppKit
import CairnEngineKit
import CryptoKit
import WebKit

public enum WebKitEngineModule {
    public static let kind: EngineKind = .webkit
    @MainActor public static func register(in registry: EngineRegistry) {
        registry.register(.webkit) { WebKitEngine() }
    }
}

/// Uses the system WebKit without a shared/default website data store.
/// For first-load injection, create a tab with `initialURL: nil`, set its scripts/delegate, then load.
/// Downloads stay in WebKit's authenticated session and use a native save dialog; the URL-only
/// `requestsDownload` delegate is intentionally not used because it cannot preserve that session.
@MainActor
public final class WebKitEngine: BrowserEngine {
    public let kind: EngineKind = .webkit
    public let displayName = "WebKit"
    public var versionDescription: String {
        let version = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String
        return version.map { "WebKit \($0)" } ?? "WebKit (system)"
    }

    private struct StoreKey: Hashable {
        let profileID: String
        let ephemeral: Bool
    }
    private final class WeakTab {
        weak var value: WebKitTab?
        init(_ value: WebKitTab) { self.value = value }
    }
    private var stores: [StoreKey: WKWebsiteDataStore] = [:]
    private var tabs: [UUID: WeakTab] = [:]

    public init() {}

    public func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        tabs = tabs.filter { $0.value.value != nil }
        let tab = WebKitTab(dataStore: dataStore(for: configuration))
        tabs[tab.id] = WeakTab(tab)
        if let initialURL { tab.load(initialURL) }
        return tab
    }

    public func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {
        let types = Self.websiteDataTypes(for: kinds)
        guard !types.isEmpty else { return }
        var matchingStores: [WKWebsiteDataStore] = []
        if let persistent = stores[StoreKey(profileID: profileID, ephemeral: false)] {
            matchingStores.append(persistent)
        } else {
            let identifier = Self.profileIdentifier(profileID)
            // Clearing a private-only profile must not create a persistent store on disk.
            if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(identifier) {
                matchingStores.append(WKWebsiteDataStore(forIdentifier: identifier))
            }
        }
        if let privateStore = stores[StoreKey(profileID: profileID, ephemeral: true)] {
            matchingStores.append(privateStore)
        }
        for store in matchingStores {
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        }
    }

    /// Closes live tabs and releases private sessions. The engine can subsequently create new tabs.
    public func shutdown() {
        let liveTabs = tabs.values.compactMap(\.value)
        tabs.removeAll()
        liveTabs.forEach { $0.close() }
        stores.removeAll()
    }

    func dataStore(for configuration: EngineConfiguration) -> WKWebsiteDataStore {
        let key = StoreKey(profileID: configuration.profileID, ephemeral: configuration.isEphemeral)
        if let store = stores[key] { return store }
        let store = configuration.isEphemeral
            ? WKWebsiteDataStore.nonPersistent()
            : WKWebsiteDataStore(forIdentifier: Self.profileIdentifier(configuration.profileID))
        stores[key] = store
        return store
    }

    /// Stable, domain-separated UUIDv8. Do not change this mapping: it locates existing profile data.
    nonisolated static func profileIdentifier(_ profileID: String) -> UUID {
        let normalized = profileID.precomposedStringWithCanonicalMapping
        var bytes = Array(SHA256.hash(data: Data(("Cairn.WebKit.Profile.v1\0" + normalized).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func websiteDataTypes(for kinds: Set<BrowsingDataKind>) -> Set<String> {
        var types: Set<String> = []
        if kinds.contains(.cookies) { types.insert(WKWebsiteDataTypeCookies) }
        if kinds.contains(.cache) {
            types.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                             WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache])
        }
        if kinds.contains(.localStorage) {
            types.formUnion([WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                             WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                             WKWebsiteDataTypeServiceWorkerRegistrations])
        }
        return types
    }
}

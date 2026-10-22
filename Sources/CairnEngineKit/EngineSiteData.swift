import Foundation

// ADDITIVE API next to the frozen `BrowserEngine`: fine-grained site-data clearing, Space deletion and
// content blocking. An engine opts in by adopting `EngineSiteDataManaging`; callers reach it with
// `engine as? EngineSiteDataManaging`.

public struct SiteDataKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Cookies and HTTP-auth credentials.
    public static let cookies = SiteDataKinds(rawValue: 1 << 0)
    /// HTTP cache. Chromium cannot clear it per site, so a per-site clear leaves it alone unless this is set,
    /// and then clears the whole Space's cache.
    public static let cache = SiteDataKinds(rawValue: 1 << 1)
    /// localStorage, IndexedDB, Cache Storage, service workers, File System API data and WebSQL.
    public static let storage = SiteDataKinds(rawValue: 1 << 2)
    public static let all: SiteDataKinds = [.cookies, .cache, .storage]
}

/// What a clear could not do. An empty list means everything requested was removed.
public struct SiteDataClearResult: Sendable, Equatable {
    public var failures: [String]
    public init(failures: [String] = []) { self.failures = failures }
    public var isComplete: Bool { failures.isEmpty }
}

public struct ContentBlockingConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    /// Lower-case host names; a host also blocks its subdomains.
    public var blockedHosts: [String]
    /// Sites (host names, subdomains included) on which blocking is off.
    public var exemptSites: [String]
    public init(isEnabled: Bool = false, blockedHosts: [String] = [], exemptSites: [String] = []) {
        self.isEnabled = isEnabled
        self.blockedHosts = blockedHosts
        self.exemptSites = exemptSites
    }
}

@MainActor
public protocol EngineSiteDataManaging: AnyObject {
    /// Clears one Space's data. `site` is a host name; nil clears the whole Space.
    func clearSiteData(profileID: String, site: String?, kinds: SiteDataKinds) async -> SiteDataClearResult
    /// Removes a Space's profile directory for good. Close the Space's tabs first.
    func deleteProfileData(profileID: String) async
    /// Deletes profile directories no Space references. Returns the removed directory names.
    @discardableResult func removeOrphanProfiles(keeping profileIDs: Set<String>) -> [String]
    func configureContentBlocking(_ configuration: ContentBlockingConfiguration)
    /// Requests refused by content blocking since launch.
    var blockedRequestCount: Int { get }
}

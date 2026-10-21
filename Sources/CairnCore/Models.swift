import Foundation
import Darwin

// FROZEN API (see CairnEngineKit/Engine.swift for the rule). Persistent, Codable value types.

public enum TabList: String, Codable, Sendable {
    case favorites   // global, shown as an icon grid at the top of the sidebar
    case pinned      // per Space, survive restarts, "reset to home URL"
    case today       // per Space, ordinary tabs; auto-archived after inactivity
    case archive     // per Space, auto-archived tabs
}

public struct TabItem: Codable, Identifiable, Hashable, Sendable {
    public static let maximumTitleLength = 32_768
    public var id: UUID
    public var url: URL?
    /// The latest page title, independent of a user-supplied tab name.
    public var title: String
    /// Missing in older workspaces; nil follows the page title.
    public var customTitle: String?
    /// For pinned/favorite tabs: the URL "reset" returns to.
    public var homeURL: URL?
    public var createdAt: Date
    public var lastActiveAt: Date
    public init(id: UUID = UUID(), url: URL? = nil, title: String = "", homeURL: URL? = nil,
                createdAt: Date = Date(), lastActiveAt: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.homeURL = homeURL
        self.customTitle = nil
        self.createdAt = createdAt; self.lastActiveAt = lastActiveAt
    }
    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        return url?.host ?? "New Tab"
    }
}

public struct Space: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// An emoji or an SF Symbol name.
    public var icon: String
    public var colorHex: String
    /// Engine data-store isolation key (cookies, storage).
    public var profileID: String
    public var pinned: [TabItem]
    public var tabs: [TabItem]
    public var archive: [TabItem]
    public var selectedTabID: UUID?
    public init(id: UUID = UUID(), name: String, icon: String = "circle.grid.2x2", colorHex: String = "#7C5CFF",
                profileID: String? = nil, pinned: [TabItem] = [], tabs: [TabItem] = [], archive: [TabItem] = [],
                selectedTabID: UUID? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.colorHex = colorHex
        self.profileID = profileID ?? id.uuidString
        self.pinned = pinned; self.tabs = tabs; self.archive = archive; self.selectedTabID = selectedTabID
    }
}

public struct Workspace: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var spaces: [Space]
    public var favorites: [TabItem]
    public var selectedSpaceID: UUID?
    public init(spaces: [Space], favorites: [TabItem] = [], selectedSpaceID: UUID? = nil,
                schemaVersion: Int = Workspace.currentSchemaVersion) {
        self.spaces = spaces; self.favorites = favorites
        self.selectedSpaceID = selectedSpaceID ?? spaces.first?.id; self.schemaVersion = schemaVersion
    }
    public static func makeDefault() -> Workspace {
        Workspace(spaces: [Space(name: "Home", icon: "house", colorHex: "#7C5CFF", profileID: "default")])
    }
}

/// Turns address-bar input into a URL: explicit URLs and hosts are opened, anything else becomes a search.
/// `searchTemplate` uses `%s` as the query placeholder.
public enum URLResolver {
    public static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"
    public static func resolve(_ input: String, searchTemplate: String = defaultSearchTemplate) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) {
            let scheme = text[range].dropLast().lowercased()
            if ["http", "https", "file", "about"].contains(scheme) {
                guard let url = URL(string: text) else { return nil }
                return isNavigable(url) ? url : nil
            }
            // A host:port is not a scheme. Everything else with an explicit scheme is rejected,
            // particularly javascript:, data:, and external application protocols.
            if !looksLikeHostWithPort(text) { return nil }
        }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            let prefix = text.lowercased().hasPrefix("localhost") ? "http://" : "https://"
            if let url = URL(string: prefix + text), isWebURL(url),
               let host = url.host, host == "localhost" || host.contains(".") || host.contains(":") {
                return url
            }
        }
        guard isValidSearchTemplate(searchTemplate),
              let query = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { return nil }
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: query))
    }

    public static func isNavigable(_ url: URL) -> Bool {
        if isWebURL(url) { return true }
        if url.absoluteString == "about:blank" { return true }
        return url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.path.hasPrefix("/") && !url.path.contains("\0")
    }

    /// A conservative navigation/download boundary; page scripts are handled by the script API, never URLs.
    public static func isWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let componentHost = components.host, !componentHost.isEmpty else { return false }
        // URL.host is IDNA-normalized; URLComponents.host deliberately exposes Unicode for display.
        let host = componentHost.hasPrefix("[") ? componentHost : (url.host ?? componentHost)
        if let port = components.port, !(1...65_535).contains(port) { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            var address = in6_addr()
            return String(host.dropFirst().dropLast()).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        let labels = (host.hasSuffix(".") ? String(host.dropLast()) : host).split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        }
        return host.utf8.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    public static func isValidSearchTemplate(_ template: String) -> Bool {
        guard !template.contains("cairnquerytoken"), template.components(separatedBy: "%s").count == 2,
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "cairnquerytoken")),
              isWebURL(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil else { return false }
        return components.queryItems?.contains(where: { $0.value?.contains("cairnquerytoken") == true }) == true
            && !(components.host?.contains("cairnquerytoken") ?? false)
            && !components.path.contains("cairnquerytoken")
    }

    private static func looksLikeHostWithPort(_ text: String) -> Bool {
        let authority = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard let colon = authority.lastIndex(of: ":"), !authority[authority.index(after: colon)...].isEmpty,
              authority[authority.index(after: colon)...].allSatisfy(\.isNumber) else { return false }
        return authority[..<colon] == "localhost" || authority[..<colon].contains(".")
    }
}

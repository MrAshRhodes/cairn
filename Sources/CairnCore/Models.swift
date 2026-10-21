import Foundation

// FROZEN API (see CairnEngineKit/Engine.swift for the rule). Persistent, Codable value types.

public enum TabList: String, Codable, Sendable {
    case favorites   // global, shown as an icon grid at the top of the sidebar
    case pinned      // per Space, survive restarts, "reset to home URL"
    case today       // per Space, ordinary tabs; auto-archived after inactivity
    case archive     // per Space, auto-archived tabs
}

public struct TabItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL?
    public var title: String
    /// For pinned/favorite tabs: the URL "reset" returns to.
    public var homeURL: URL?
    public var createdAt: Date
    public var lastActiveAt: Date
    public init(id: UUID = UUID(), url: URL? = nil, title: String = "", homeURL: URL? = nil,
                createdAt: Date = Date(), lastActiveAt: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.homeURL = homeURL
        self.createdAt = createdAt; self.lastActiveAt = lastActiveAt
    }
    public var displayTitle: String {
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
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host?.contains(".") == true {
            return url
        }
        if text.lowercased().hasPrefix("localhost"), let url = URL(string: "http://" + text) { return url }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }
}

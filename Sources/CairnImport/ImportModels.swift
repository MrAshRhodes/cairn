import Foundation
import CairnCore

/// A bookmark read from an external source. `folderPath` is the chain of folder names from the top.
public struct ImportedBookmark: Hashable, Sendable {
    public var title: String
    public var url: URL
    public var folderPath: [String]
    public init(title: String, url: URL, folderPath: [String] = []) {
        self.title = title; self.url = url; self.folderPath = folderPath
    }
}

public struct ImportedHistoryEntry: Hashable, Sendable {
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public init(url: URL, title: String, lastVisit: Date) { self.url = url; self.title = title; self.lastVisit = lastVisit }
}

/// Why an item was left out. Counted and shown in the preview and result; never silently dropped.
public enum SkipReason: String, CaseIterable, Hashable, Sendable, Error {
    case unsupportedScheme = "Not a web address (javascript:, data:, about:, chrome:, file:…)"
    case invalidURL = "Invalid or over-long address"
    case hidden = "Hidden history rows"
    case duplicate = "Already present"
    case overLimit = "Over the import size limit"
}

public typealias SkipCounts = [SkipReason: Int]

public enum ImportError: LocalizedError, Equatable {
    case unreadable(String)
    case tooLarge(String)
    case malformed(String)
    case unsupportedSource(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "Cannot read the import source: \(reason)"
        case .tooLarge(let name): return "\(name) is larger than the import limit."
        case .malformed(let reason): return "The import file is not valid: \(reason)"
        case .unsupportedSource(let reason): return reason
        case .database(let reason): return "History import: \(reason)"
        }
    }
}

/// Fixed limits that bound memory and time while reading untrusted local files.
public enum ImportLimits {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let maximumHistoryRows = 200_000
    public static let maximumBookmarks = 20_000
    public static let maximumTitleLength = 1_024
    public static let maximumURLBytes = 8_192
    public static let maximumFolderNameLength = 128
}

enum Sanitizer {
    /// Returns a web URL or the reason it was rejected. Only http/https are allowed; credentials in URLs are refused.
    static func webURL(_ text: String) -> Result<URL, SkipReason> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= ImportLimits.maximumURLBytes else { return .failure(.invalidURL) }
        let scheme = trimmed.prefix { $0 != ":" }.lowercased()
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let url = URL(string: trimmed), URLResolver.isWebURL(url) else { return .failure(.invalidURL) }
        return .success(url)
    }

    static func title(_ text: String) -> String {
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ImportLimits.maximumTitleLength))
    }

    static func folder(_ text: String) -> String {
        String(title(text).prefix(ImportLimits.maximumFolderNameLength))
    }

    /// Identity used for de-duplication: lowercase scheme/host, default port and bare "/" path dropped.
    static func key(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased()
        if (c.scheme == "http" && c.port == 80) || (c.scheme == "https" && c.port == 443) { c.port = nil }
        if c.path == "/" && c.query == nil && c.fragment == nil { c.path = "" }
        return c.string ?? url.absoluteString
    }
}

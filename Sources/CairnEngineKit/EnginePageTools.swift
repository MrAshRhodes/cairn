import CoreGraphics
import Foundation

/// Page-level language and identity the engine applies to every tab. Empty values keep the engine's defaults.
public struct PagePreferences: Equatable, Sendable {
    /// Comma-separated language tags, most preferred first (the `Accept-Language` and `navigator.languages` value).
    public var acceptLanguages: String
    /// Complete user agent string. Overriding it is an advanced setting: the default Chromium identity is what sites expect.
    public var userAgent: String
    public init(acceptLanguages: String = "", userAgent: String = "") {
        self.acceptLanguages = acceptLanguages; self.userAgent = userAgent
    }

    public static let maximumUserAgentLength = 512

    /// Returns a canonical list ("de-DE, de;q=0.9" and "de-DE,de" both become "de-DE,de") or nil when any entry is not a language tag.
    public static func normalizedLanguages(_ text: String) -> String? {
        var tags: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: true) {
            let tag = part.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard isLanguageTag(tag) else { return nil }
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
        }
        return tags.isEmpty ? nil : tags.joined(separator: ",")
    }

    /// A list built from the system's preferred languages, with each regional tag followed by its base language ("de-DE" -> "de-DE,de").
    public static func systemLanguages(_ preferred: [String] = Locale.preferredLanguages) -> String {
        var tags: [String] = []
        for identifier in preferred {
            let tag = identifier.replacingOccurrences(of: "_", with: "-")
            guard isLanguageTag(tag) else { continue }
            for candidate in [tag, tag.split(separator: "-").first.map(String.init) ?? tag]
            where !tags.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                tags.append(candidate)
            }
        }
        return tags.joined(separator: ",")
    }

    public static func isValidUserAgent(_ text: String) -> Bool {
        text.isEmpty || (text.count <= maximumUserAgentLength && text.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) })
    }

    private static func isLanguageTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 35 else { return false }
        let subtags = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = subtags.first, (2...8).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return subtags.dropFirst().allSatisfy { (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }
}

/// `view-source:` is only ever opened by the browser itself (page script cannot), and only for pages Cairn can load.
public enum ViewSource {
    private static let prefix = "view-source:"

    public static func url(for page: URL) -> URL? {
        guard ["http", "https", "file"].contains(page.scheme?.lowercased() ?? "") else { return nil }
        return URL(string: prefix + page.absoluteString)
    }

    public static func isViewSource(_ url: URL) -> Bool { inner(of: url) != nil }

    public static func inner(of url: URL) -> URL? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix(prefix),
              let inner = URL(string: String(text.dropFirst(prefix.count))),
              ["http", "https", "file"].contains(inner.scheme?.lowercased() ?? "") else { return nil }
        return inner
    }
}

/// Optional capabilities of a tab beyond the frozen `EngineTab` API; the app discovers them with `as?`.
@MainActor
public protocol EngineTabPageTools: EngineTab {
    var hasDevTools: Bool { get }
    /// Opens (or focuses) the DevTools window; a point inspects the element at that view coordinate.
    func showDevTools(inspectingAt point: CGPoint?)
    func closeDevTools()
    /// Presents the system print panel (which also offers Save as PDF).
    func printPage()
    func printToPDF(at url: URL, completion: @escaping (Result<Void, Error>) -> Void)
    func setPagePreferences(_ preferences: PagePreferences)
}

/// Optional engine capability: preferences that apply to every current and future tab.
@MainActor
public protocol EnginePagePreferences: BrowserEngine {
    var pagePreferences: PagePreferences { get set }
}

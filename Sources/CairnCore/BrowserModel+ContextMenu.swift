import AppKit
import CairnEngineKit

/// Decides whether and how a page-requested non-web URL (mailto:, tel:, custom schemes) is opened:
/// allow-listed by scheme, only when an application can handle it, and only after the user confirms.
@MainActor
public final class ExternalURLLauncher {
    public static let shared = ExternalURLLauncher()

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(String)
    }

    // Schemes that reach local files, settings, shells or remote shares, or that the browser itself owns.
    static let deniedSchemes: Set<String> = [
        "http", "https", "file", "about", "javascript", "data", "blob", "vbscript", "filesystem", "view-source",
        "chrome", "chrome-extension", "devtools", "ftp", "ssh", "sftp", "telnet", "smb", "afp", "nfs", "vnc",
        "x-apple.systempreferences", "x-man-page", "applescript", "osascript", "ms-msdt", "search-ms",
    ]

    public static func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(),
              scheme.range(of: "^[a-z][a-z0-9+.-]{0,63}$", options: .regularExpression) != nil else {
            return .deny("Cairn will not open this link.")
        }
        if deniedSchemes.contains(scheme) { return .deny("Cairn will not open “\(scheme):” links from a page.") }
        if url.absoluteString.count > 8_192 { return .deny("The link is too long.") }
        return .allow
    }

    /// Display name of the application that would handle `url`; nil when none is installed.
    var applicationName: (URL) -> String? = { url in
        NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) }
    }
    var confirm: (URL, String) -> Bool = { url, app in
        let alert = NSAlert()
        alert.messageText = "Open \(app)?"
        alert.informativeText = "A page wants to open “\(url.absoluteString.prefix(200))” with \(app)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var now: () -> ContinuousClock.Instant = { .now }
    private var lastDecision: ContinuousClock.Instant?
    static let cooldown: Duration = .seconds(1)

    public init() {}

    /// Returns an error to show the user, or nil when the URL was opened, declined or deliberately ignored.
    @discardableResult
    public func handle(_ url: URL) -> Error? {
        if case .deny(let reason) = Self.decision(for: url) { return ServiceError.navigation(reason) }
        // A page can fire this repeatedly; once per second at most, counted from the previous answer.
        if let last = lastDecision, now() - last < Self.cooldown { return nil }
        defer { lastDecision = now() }
        guard let app = applicationName(url) else {
            return ServiceError.navigation("No application is installed that can open “\(url.scheme ?? "")” links.")
        }
        if confirm(url, app) { open(url) }
        return nil
    }
}

extension BrowserModel: EngineTabContextMenuEvents {
    public func engineTab(_ tab: EngineTab, requestsSearchFor query: String, activate: Bool) {
        guard let id = liveTabs.first(where: { $0.value === tab })?.key, let origin = liveSpaceIDs[id], spaceIndex(origin) != nil,
              let url = Self.searchURL(for: query, template: searchTemplate) else { return }
        newTab(url: url, in: origin, activate: activate)
    }

    public func engineTab(_ tab: EngineTab, requestsExternalURL url: URL) {
        guard liveTabs.contains(where: { $0.value === tab }) else { return }
        if let error = ExternalURLLauncher.shared.handle(url) { onError?(error) }
    }

    /// A search for `query` as typed text, never interpreted as a URL or scheme.
    static func searchURL(for query: String, template: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, URLResolver.isValidSearchTemplate(template),
              let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

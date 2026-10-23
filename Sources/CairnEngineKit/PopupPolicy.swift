import Foundation

/// How a page asked for its new window, reduced to what the policy needs.
public enum PopupDisposition: Sendable {
    /// `window.open`, `target=_blank` and popup windows: shown immediately.
    case foreground
    case background
    /// Save-to-disk, Picture-in-Picture and similar requests Cairn does not host.
    case unsupported
}

public enum PopupBlockReason: String, Sendable {
    case noUserGesture, unsupportedScheme, rateLimited
}

public enum PopupDecision: Equatable, Sendable {
    /// Create a real browser that keeps `window.opener`, shown as a new tab.
    case adopt
    /// A plain link to a background tab: no opener is needed, so open the URL as an ordinary new tab.
    case openInTab(activate: Bool)
    /// Refuse and surface it to the user.
    case block(PopupBlockReason)
    /// Refuse quietly (nothing the user asked for was lost).
    case cancel
}

/// At most `limit` popups per `interval` seconds per opener tab, so a page cannot flood the window.
public struct PopupBudget: Sendable {
    public var limit: Int
    public var interval: TimeInterval
    private var grants: [Date] = []
    public init(limit: Int = 3, interval: TimeInterval = 10) { self.limit = limit; self.interval = interval }

    public mutating func consume(at now: Date) -> Bool {
        grants.removeAll { now.timeIntervalSince($0) >= interval || $0 > now }
        guard grants.count < limit else { return false }
        grants.append(now)
        return true
    }
}

public enum PopupPolicy {
    /// The only decision point for page-initiated windows. `url` is the raw target (empty for `window.open('')`).
    public static func decide(url: String, disposition: PopupDisposition, userGesture: Bool,
                              budget: inout PopupBudget, now: Date = Date(),
                              allowsWithoutGesture: Bool = false) -> PopupDecision {
        guard disposition != .unsupported else { return .cancel }
        let blank = url.isEmpty || url.lowercased() == "about:blank"
        let scheme = blank ? "about" : URL(string: url)?.scheme?.lowercased()
        guard blank || scheme == "http" || scheme == "https" else { return .block(.unsupportedScheme) }
        // An exception bypasses only the gesture requirement, never the scheme or abuse checks.
        guard userGesture || allowsWithoutGesture else { return .block(.noUserGesture) }
        guard budget.consume(at: now) else { return .block(.rateLimited) }
        if disposition == .background, !blank { return .openInTab(activate: false) }
        return .adopt
    }
}

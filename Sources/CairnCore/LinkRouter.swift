import Foundation

public enum LinkDestination: Codable, Hashable, Sendable {
    case space(UUID)
    case mostRecent
    case quickWindow
}

public struct LinkRoutingDecision: Equatable, Sendable {
    public enum Fallback: Equatable, Sendable {
        case deletedSpace(UUID)
        case quickWindowUnavailable
    }
    public let spaceID: UUID
    public let fallback: Fallback?
    /// A quick window uses `spaceID`'s non-private profile without adding a persistent tab.
    public var opensQuickWindow = false
}

public struct LinkRule: Codable, Identifiable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case contains, equals }
    public var id: UUID
    public var match: Match
    public var text: String
    public var destination: LinkDestination
    public init(id: UUID = UUID(), match: Match = .contains, text: String, destination: LinkDestination) {
        self.id = id; self.match = match; self.text = text; self.destination = destination
    }

    /// Case-insensitive; `equals` compares the whole URL string, `contains` a substring. Empty text never matches.
    public func matches(_ url: URL) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        let haystack = url.absoluteString.lowercased()
        return match == .equals ? haystack == needle : haystack.contains(needle)
    }
}

/// Pure routing: the first matching rule wins, otherwise the default destination applies. Only http(s) is routed.
public enum LinkRouter {
    public static func isRoutable(_ url: URL) -> Bool { URLResolver.isWebURL(url) }

    public static func destination(for url: URL, rules: [LinkRule], default fallback: LinkDestination) -> LinkDestination? {
        guard isRoutable(url) else { return nil }
        return rules.first { $0.matches(url) }?.destination ?? fallback
    }

    /// Shared by external opens and opener-free new-tab requests. Only a URL is transferred, never a live view.
    public static func decision(for url: URL, rules: [LinkRule], default fallback: LinkDestination,
                                spaceIDs: Set<UUID>, mostRecentSpaceID: UUID) -> LinkRoutingDecision? {
        guard spaceIDs.contains(mostRecentSpaceID),
              let destination = destination(for: url, rules: rules, default: fallback) else { return nil }
        switch destination {
        case .space(let id) where spaceIDs.contains(id):
            return LinkRoutingDecision(spaceID: id, fallback: nil)
        case .space(let id):
            return LinkRoutingDecision(spaceID: mostRecentSpaceID, fallback: .deletedSpace(id))
        case .quickWindow:
            return LinkRoutingDecision(spaceID: mostRecentSpaceID, fallback: nil, opensQuickWindow: true)
        case .mostRecent:
            return LinkRoutingDecision(spaceID: mostRecentSpaceID, fallback: nil)
        }
    }

    /// Drops rules that point at deleted Spaces; a deleted default falls back to the most recent Space.
    public static func pruned(rules: [LinkRule], default fallback: LinkDestination, spaceIDs: Set<UUID>)
        -> (rules: [LinkRule], default: LinkDestination) {
        func alive(_ destination: LinkDestination) -> Bool {
            if case .space(let id) = destination { return spaceIDs.contains(id) }
            return true
        }
        return (rules.filter { alive($0.destination) }, alive(fallback) ? fallback : .mostRecent)
    }
}

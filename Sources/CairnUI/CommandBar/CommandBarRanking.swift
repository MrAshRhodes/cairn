import Foundation
import CairnCore
import CairnModules

public enum CommandBarMode: Equatable, Sendable {
    /// ⌘K: search everything; opening a page uses a new tab.
    case search
    /// ⌘T: Enter opens a new tab.
    case newTab
    /// ⌘L: prefilled with the current address; Enter navigates the current (focused) tab.
    case navigate
}

public struct CommandBarContext {
    public var workspace: Workspace
    public var selectedTabID: UUID?
    public var commands: [Command] = []
    public var history: [HistoryEntry] = []
    public var engines: [SiteSearchEngine] = []
    public var searchTemplate = URLResolver.defaultSearchTemplate
    public var mode: CommandBarMode = .search
    public var now = Date()

    public init(workspace: Workspace, selectedTabID: UUID? = nil, commands: [Command] = [], history: [HistoryEntry] = [],
                engines: [SiteSearchEngine] = [], searchTemplate: String = URLResolver.defaultSearchTemplate,
                mode: CommandBarMode = .search, now: Date = Date()) {
        self.workspace = workspace; self.selectedTabID = selectedTabID; self.commands = commands; self.history = history
        self.engines = engines; self.searchTemplate = searchTemplate; self.mode = mode; self.now = now
    }
}

/// Orders results: open tabs, then pinned tabs and favorites, then history, then actions, then the open/search fallback.
/// Pure, so keyboard behavior can be tested without SwiftUI.
public enum CommandBarRanking {
    public static let resultLimit = 60
    public static let historyLimit = 8

    public static func rank(query: String, context: CommandBarContext) -> [CommandBarMatch] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandOnly = text.hasPrefix(">")
        let needle = commandOnly ? String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : text
        let words = needle.split(separator: " ").map(String.init)

        func score(_ values: [String]) -> Int? {
            guard !words.isEmpty else { return 0 }
            var total = 0
            for word in words {
                var best: Int?
                for value in values {
                    if value.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { best = max(best ?? 0, 3) }
                    else if value.localizedCaseInsensitiveContains(word) { best = max(best ?? 0, 1) }
                }
                guard let best else { return nil }
                total += best
            }
            return total
        }

        var results: [CommandBarMatch] = []
        var siteSearchMatch: CommandBarMatch?
        var shownURLs = Set<String>()

        if !commandOnly {
            if let search = SiteSearch.parse(text, engines: context.engines) {
                siteSearchMatch = .init(id: "sitesearch:\(search.engine.keyword)", title: "Search \(search.engine.name) for “\(search.query)”",
                                        subtitle: "Site search · \(search.engine.keyword)", symbol: "magnifyingglass.circle", shortcut: "↵",
                                        target: .siteSearch(search.engine, search.query))
            } else if let engine = SiteSearch.keyword(text, engines: context.engines) {
                siteSearchMatch = .init(id: "sitesearch-start:\(engine.keyword)", title: "Search \(engine.name)",
                                        subtitle: "Press Tab, then type what to search for", symbol: "magnifyingglass.circle", shortcut: "⇥",
                                        target: .beginSiteSearch(engine))
            }

            var open: [(Int, TabItem, String)] = []
            var kept: [(Int, TabItem, String)] = []
            let groups: [(String, [TabItem], [TabItem])] =
                context.workspace.spaces.map { ($0.name, $0.tabs, $0.pinned) }
            for (group, tabs, pinned) in groups {
                for tab in tabs { if let s = score(fields(tab, group)) { open.append((s, tab, group)) } }
                for tab in pinned { if let s = score(fields(tab, group)) { kept.append((s, tab, group)) } }
            }
            for tab in context.workspace.favorites { if let s = score(fields(tab, "Favorites")) { kept.append((s, tab, "Favorites")) } }
            func order(_ lhs: (Int, TabItem, String), _ rhs: (Int, TabItem, String)) -> Bool {
                lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1.lastActiveAt > rhs.1.lastActiveAt
            }
            // The current tab is not a useful destination.
            for entry in open.sorted(by: order) + kept.sorted(by: order) where entry.1.id != context.selectedTabID || context.mode != .navigate {
                let tab = entry.1
                if let url = tab.url { shownURLs.insert(url.absoluteString) }
                results.append(.init(id: "tab:\(tab.id)", title: tab.displayTitle, subtitle: entry.2 + " · " + (tab.url?.host ?? "New Tab"),
                                     symbol: "rectangle.on.rectangle", shortcut: nil, target: .tab(tab.id)))
            }
            if !needle.isEmpty { results += historyMatches(words: words, context: context, shown: shownURLs) }
        }

        var actions: [CommandBarMatch] = []
        for command in context.commands where score([command.title, command.subtitle ?? ""] + command.keywords) != nil {
            actions.append(.init(id: "command:\(command.id)", title: command.title, subtitle: command.subtitle ?? "Command",
                                 symbol: command.symbol ?? "command", shortcut: command.shortcut, target: .command(command.id)))
        }
        actions += parameterized(context: context).filter { score([$0.title]) != nil }
        results += actions

        guard !text.isEmpty, !commandOnly else { return Array(results.prefix(resultLimit)) }
        results = Array(results.prefix(resultLimit - 1))
        let fallback = fallbackMatch(text, context: context)
        let direct = isDirectAddress(text, searchTemplate: context.searchTemplate)
        if let siteSearchMatch { results.insert(siteSearchMatch, at: 0) }
        if direct { results.insert(fallback, at: 0) } else { results.append(fallback) }
        return results
    }

    /// Where Enter lands before the user presses an arrow key.
    public static func defaultSelection(_ matches: [CommandBarMatch], mode: CommandBarMode) -> Int {
        if mode == .navigate, let index = matches.firstIndex(where: { if case .navigation = $0.target { return true } else { return false } }) {
            return index
        }
        return 0
    }

    public static func isDirectAddress(_ text: String, searchTemplate: String) -> Bool {
        let sentinel = "https://cairn-search.invalid/?q=%s"
        guard let url = URLResolver.resolve(text, searchTemplate: sentinel) else { return false }
        return url.host != "cairn-search.invalid"
    }

    private static func fields(_ tab: TabItem, _ group: String) -> [String] {
        [tab.displayTitle, tab.title, tab.url?.absoluteString ?? "", group]
    }

    private static func fallbackMatch(_ text: String, context: CommandBarContext) -> CommandBarMatch {
        let inPlace = context.mode == .navigate && context.selectedTabID != nil
        return .init(id: "navigate", title: "Go to “\(text)”",
                     subtitle: inPlace ? "Open in the current tab" : "Open a website or search in a new tab",
                     symbol: "arrow.up.right", shortcut: "↵", target: .navigation(text))
    }

    /// Recency × frequency, de-duplicated by URL.
    private static func historyMatches(words: [String], context: CommandBarContext, shown: Set<String>) -> [CommandBarMatch] {
        var frequency: [String: Int] = [:]
        var latest: [String: HistoryEntry] = [:]
        for entry in context.history {
            let key = entry.url.absoluteString
            frequency[key, default: 0] += 1
            if latest[key].map({ entry.visitedAt > $0.visitedAt }) ?? true { latest[key] = entry }
        }
        func relevance(_ entry: HistoryEntry) -> Double {
            let age = max(context.now.timeIntervalSince(entry.visitedAt), 0) / 86_400
            return log2(1 + Double(frequency[entry.url.absoluteString] ?? 1)) * pow(0.5, age / 7)
        }
        return latest.values
            .filter { !shown.contains($0.url.absoluteString) }
            .filter { entry in words.allSatisfy { entry.title.localizedCaseInsensitiveContains($0) || entry.url.absoluteString.localizedCaseInsensitiveContains($0) } }
            .sorted { relevance($0) != relevance($1) ? relevance($0) > relevance($1) : $0.url.absoluteString < $1.url.absoluteString }
            .prefix(historyLimit)
            .map { entry in
                .init(id: "history:\(entry.url.absoluteString)", title: entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title,
                      subtitle: "History · " + (entry.url.host ?? "") + entry.url.path, symbol: "clock",
                      shortcut: nil, target: .history(entry.url))
            }
    }

    /// Actions with an argument, one row per Space. Hidden when there is nothing to act on.
    private static func parameterized(context: CommandBarContext) -> [CommandBarMatch] {
        guard let tabID = context.selectedTabID,
              let current = context.workspace.spaces.first(where: { ($0.pinned + $0.tabs).contains { $0.id == tabID } })
                ?? context.workspace.spaces.first(where: { $0.id == context.workspace.selectedSpaceID }) else { return [] }
        var rows: [CommandBarMatch] = []
        for space in context.workspace.spaces where space.id != current.id {
            rows.append(.init(id: "action:move:\(space.id)", title: "Move to \(space.name)", subtitle: "Move this tab to another Space",
                              symbol: "arrow.right.square", shortcut: nil, target: .action(.moveToSpace(space.id))))
            rows.append(.init(id: "action:pin:\(space.id)", title: "Pin to \(space.name)", subtitle: "Pin this tab in another Space",
                              symbol: "pin", shortcut: nil, target: .action(.pinToSpace(space.id))))
        }
        return rows
    }
}

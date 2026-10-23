import Foundation
import Observation
import CairnCore
import CairnModules

/// State and behavior of the command bar. Views only render it, so key handling stays testable.
@MainActor @Observable
public final class CommandBarModel {
    public let mode: CommandBarMode
    public var query: String { didSet { if query != oldValue { refresh() } } }
    public private(set) var matches: [CommandBarMatch] = []
    public var selection = 0
    /// Set after Tab on a keyword: the bar searches that site until the chip is removed.
    public private(set) var activeEngine: SiteSearchEngine?

    @ObservationIgnored private let browser: BrowserModel
    @ObservationIgnored private let history: HistoryStore?
    @ObservationIgnored private let commands: [Command]
    @ObservationIgnored private let engines: () -> [SiteSearchEngine]
    @ObservationIgnored private let report: (String, String) -> Void
    @ObservationIgnored private var historyFailed = false
    @ObservationIgnored private let initialQuery: String

    public init(mode: CommandBarMode, browser: BrowserModel, history: HistoryStore?, commands: [Command],
                engines: @escaping () -> [SiteSearchEngine] = { [] }, report: @escaping (String, String) -> Void = { _, _ in }) {
        self.mode = mode
        self.browser = browser
        self.history = history
        self.commands = commands
        self.engines = engines
        self.report = report
        let prefill = mode == .navigate ? (browser.selectedTab?.url?.absoluteString ?? "") : ""
        initialQuery = prefill
        query = prefill
        refresh()
    }

    public var placeholder: String {
        if let activeEngine { return "Search \(activeEngine.name)" }
        switch mode {
        case .navigate: return "Edit the address or search"
        case .newTab: return "Search tabs, commands, or open a new tab"
        case .search: return "Search tabs, commands, or the web"
        }
    }

    /// True while the field still holds the prefilled address, so it should be fully selected.
    public var startsSelected: Bool { mode == .navigate && !initialQuery.isEmpty }

    public func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let engine = activeEngine {
            matches = trimmed.isEmpty ? [] : [.init(id: "sitesearch:\(engine.keyword)", title: "Search \(engine.name) for “\(trimmed)”",
                subtitle: "Site search · \(engine.keyword)", symbol: "magnifyingglass.circle", shortcut: "↵", target: .siteSearch(engine, trimmed))]
            selection = 0
            return
        }
        var entries: [HistoryEntry] = []
        if let history, !trimmed.isEmpty, !trimmed.hasPrefix(">") {
            do { entries = try history.search(trimmed.split(separator: " ").first.map(String.init) ?? trimmed, limit: 100) }
            catch {
                if !historyFailed { historyFailed = true; report("History suggestions are unavailable", error.localizedDescription) }
            }
        }
        let context = CommandBarContext(workspace: browser.workspace, selectedTabID: browser.selectedTabID, commands: commands,
                                        history: entries, engines: engines(), searchTemplate: browser.searchTemplate, mode: mode)
        matches = CommandBarRanking.rank(query: trimmed, context: context)
        selection = CommandBarRanking.defaultSelection(matches, mode: mode)
    }

    public func moveSelection(_ delta: Int) { selection = CommandBarSearch.nextSelection(selection, delta: delta, count: matches.count) }

    /// Tab on a known keyword starts a site search. Returns true when the key was used.
    public func handleTab() -> Bool {
        guard activeEngine == nil, let engine = SiteSearch.keyword(query, engines: engines()) else { return false }
        activeEngine = engine
        query = ""
        refresh()
        return true
    }

    /// Delete on an empty field removes the site-search chip. Returns true when the key was used.
    public func handleDeleteOnEmpty() -> Bool {
        guard activeEngine != nil, query.isEmpty else { return false }
        activeEngine = nil
        refresh()
        return true
    }

    /// Runs the selected row. The caller dismisses the bar first.
    public func activateSelected() {
        guard matches.indices.contains(selection) else { return }
        activate(matches[selection])
    }

    public func activate(_ match: CommandBarMatch) {
        switch match.target {
        case .tab(let id): browser.select(id)
        case .command(let id): commands.first { $0.id == id }?.perform(browser)
        case .history(let url): open(url)
        case .navigation(let text): openText(text)
        case .siteSearch(let engine, let text): openSiteSearch(engine, text)
        case .beginSiteSearch(let engine):
            activeEngine = engine
            query = ""
            refresh()
        case .action(let action): perform(action)
        }
    }

    private func openText(_ text: String) {
        switch mode {
        case .navigate: browser.navigate(text)
        case .newTab, .search:
            guard let url = URLResolver.resolve(text, searchTemplate: browser.searchTemplate) else {
                report("The address or search is invalid", "Check the address or the search template in Settings.")
                return
            }
            browser.newTab(url: url)
        }
    }

    private func open(_ url: URL) {
        if mode == .navigate, let id = browser.selectedTabID { browser.load(url, in: id) } else { browser.newTab(url: url) }
    }

    private func openSiteSearch(_ engine: SiteSearchEngine, _ text: String) {
        guard let url = engine.url(for: text) else {
            report("Site search could not be opened", "“\(engine.name)” does not have a valid search address.")
            return
        }
        open(url)
    }

    private func perform(_ action: CommandBarAction) {
        guard let id = browser.selectedTabID else { return }
        switch action {
        case .moveToSpace(let space): browser.moveTab(id, to: .today, in: space)
        case .pinToSpace(let space): browser.moveTab(id, to: .pinned, in: space)
        }
    }
}

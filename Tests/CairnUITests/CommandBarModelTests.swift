import AppKit
import Foundation
import Testing
import CairnCore
import CairnEngineKit
import CairnModules
@testable import CairnUI

@MainActor
private final class Engine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = Tab()
        tab.state.url = initialURL
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class Tab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    func load(_ url: URL) { state.url = url }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() {}
}

private let wiki = SiteSearchEngine(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s")

@Suite @MainActor struct CommandBarRankingTests {
    private func context(_ mode: CommandBarMode = .search, engines: [SiteSearchEngine] = [], history: [HistoryEntry] = [],
                         commands: [Command] = [], tabs: [TabItem] = []) -> CommandBarContext {
        var context = CommandBarContext(workspace: Workspace(spaces: [Space(name: "Home", tabs: tabs)]),
                                        selectedTabID: tabs.first?.id, commands: commands, history: history, engines: engines)
        context.mode = mode
        return context
    }

    @Test func aDirectAddressComesFirst() {
        let matches = CommandBarRanking.rank(query: "example.com", context: context())
        guard case .navigation = matches.first?.target else { Issue.record("expected navigation first"); return }
    }

    @Test func plainSearchTextEndsWithTheSearchFallback() {
        let tab = TabItem(url: URL(string: "https://swift.org"), title: "Swift language")
        let matches = CommandBarRanking.rank(query: "swift", context: context(tabs: [tab]))
        guard case .tab = matches.first?.target else { Issue.record("expected the tab first"); return }
        guard case .navigation = matches.last?.target else { Issue.record("expected search fallback last"); return }
    }

    @Test func openTabsRankAboveCommands() {
        let tab = TabItem(url: URL(string: "https://example.com"), title: "Settings guide")
        let command = Command(id: "x", title: "Settings", perform: { _ in })
        let matches = CommandBarRanking.rank(query: "settings", context: context(commands: [command], tabs: [tab]))
        let tabIndex = matches.firstIndex { if case .tab = $0.target { return true } else { return false } }
        let commandIndex = matches.firstIndex { if case .command = $0.target { return true } else { return false } }
        #expect(tabIndex != nil && commandIndex != nil && tabIndex! < commandIndex!)
    }

    @Test func siteSearchParsesKeywordAndQuery() {
        let matches = CommandBarRanking.rank(query: "w swift language", context: context(engines: [wiki]))
        guard case .siteSearch(let engine, let text) = matches.first?.target else { Issue.record("expected site search first"); return }
        #expect(engine == wiki && text == "swift language")
        let start = CommandBarRanking.rank(query: "w", context: context(engines: [wiki]))
        guard case .beginSiteSearch = start.first?.target else { Issue.record("expected chip row"); return }
    }

    @Test func siteSearchBuildsAnEscapedURL() {
        #expect(wiki.url(for: "a&b c")?.absoluteString == "https://en.wikipedia.org/w/index.php?search=a%26b%20c")
        #expect(SiteSearch.parse("zzz hello", engines: [wiki]) == nil)
    }

    @Test func navigateModeSelectsTheTypedAddressByDefault() {
        let tab = TabItem(url: URL(string: "https://swift.org"), title: "Swift")
        let matches = CommandBarRanking.rank(query: "swift", context: context(.navigate, tabs: [tab, TabItem(title: "Swift two")]))
        let index = CommandBarRanking.defaultSelection(matches, mode: .navigate)
        guard case .navigation = matches[index].target else { Issue.record("expected navigation row"); return }
        #expect(CommandBarRanking.defaultSelection(matches, mode: .search) == 0)
    }

    @Test func theCurrentTabIsHiddenWhenNavigating() {
        let tab = TabItem(url: URL(string: "https://swift.org"), title: "Swift")
        let matches = CommandBarRanking.rank(query: "swift", context: context(.navigate, tabs: [tab]))
        #expect(!matches.contains { if case .tab = $0.target { return true } else { return false } })
    }

    @Test func parameterizedActionsOfferSpaces() {
        let tab = TabItem(url: URL(string: "https://swift.org"), title: "Swift")
        var context = context(tabs: [tab])
        context.workspace.spaces.append(Space(name: "Work"))
        let matches = CommandBarRanking.rank(query: "work", context: context)
        #expect(matches.contains { if case .action = $0.target { return true } else { return false } })
    }

    @Test func historyIsDeduplicatedAgainstOpenTabsAndCapped() {
        let tab = TabItem(url: URL(string: "https://swift.org/a"), title: "Swift a")
        var history = (0..<30).map { HistoryEntry(url: URL(string: "https://swift.org/h\($0)")!, title: "Swift history \($0)") }
        history.append(HistoryEntry(url: URL(string: "https://swift.org/a")!, title: "Swift a"))
        let matches = CommandBarRanking.rank(query: "swift", context: context(history: history, tabs: [tab]))
        let urls = matches.compactMap { match -> URL? in if case .history(let url) = match.target { return url } else { return nil } }
        #expect(urls.count <= CommandBarRanking.historyLimit)
        #expect(!urls.contains(URL(string: "https://swift.org/a")!))
    }
}

@Suite @MainActor struct CommandBarModelTests {
    private func make(url: String = "https://swift.org") -> (BrowserModel, CommandBarModel.Type) {
        let tab = TabItem(url: URL(string: url), title: "Swift")
        let model = BrowserModel(engine: Engine(), workspace: Workspace(spaces: [Space(name: "Home", tabs: [tab], selectedTabID: tab.id)]))
        return (model, CommandBarModel.self)
    }

    @Test func navigateModeLoadsTheTypedAddressInTheCurrentTab() {
        let (model, _) = make()
        let before = model.selectedSpace.tabs.count
        let bar = CommandBarModel(mode: .navigate, browser: model, history: nil, commands: [])
        #expect(bar.query == "https://swift.org")
        bar.query = "example.org"
        bar.selection = CommandBarRanking.defaultSelection(bar.matches, mode: .navigate)
        bar.activateSelected()
        #expect(model.selectedSpace.tabs.count == before)
        #expect(model.selectedTab?.url?.host == "example.org")
    }

    @Test func newTabModeOpensANewTab() {
        let (model, _) = make()
        let bar = CommandBarModel(mode: .newTab, browser: model, history: nil, commands: [])
        bar.query = "example.org"
        bar.selection = CommandBarRanking.defaultSelection(bar.matches, mode: .newTab)
        bar.activateSelected()
        #expect(model.selectedSpace.tabs.count == 2)
        #expect(model.selectedTab?.url?.host == "example.org")
    }

    @Test func tabOnAKeywordStartsASiteSearchAndDeleteRemovesTheChip() {
        let (model, _) = make()
        let bar = CommandBarModel(mode: .search, browser: model, history: nil, commands: [], engines: { [wiki] })
        bar.query = "w"
        #expect(bar.handleTab())
        #expect(bar.activeEngine == wiki && bar.query.isEmpty)
        bar.query = "swift"
        bar.selection = 0
        bar.activateSelected()
        #expect(model.selectedTab?.url?.host == "en.wikipedia.org")
        let second = CommandBarModel(mode: .search, browser: model, history: nil, commands: [], engines: { [wiki] })
        second.query = "w"
        _ = second.handleTab()
        #expect(second.handleDeleteOnEmpty())
        #expect(second.activeEngine == nil)
        #expect(!second.handleTab() || second.activeEngine != nil)
    }

    @Test func keywordSearchInSearchModeOpensANewTab() {
        let (model, _) = make()
        let bar = CommandBarModel(mode: .search, browser: model, history: nil, commands: [], engines: { [wiki] })
        bar.query = "w swift"
        bar.activateSelected()
        #expect(model.selectedSpace.tabs.count == 2)
    }
}

@MainActor enum NullEngine {
    static func make() -> BrowserEngine { Engine() }
}

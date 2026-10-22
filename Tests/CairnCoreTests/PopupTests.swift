import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class PopupEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [PopupTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = PopupTab()
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class PopupTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate? { didSet { delegate?.engineTab(self, didChange: state) } }
    var zoom: Double = 1
    var scripts: [EngineUserScript] = []
    var closed = false
    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) { self.scripts = scripts }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { closed = true }
}

@Suite @MainActor struct PopupTests {
    private func makeModel() throws -> (BrowserModel, PopupEngine, EngineTab, Space) {
        let a = TabItem(url: URL(string: "https://opener.example/")!)
        let space = Space(name: "One", profileID: "first", tabs: [a], selectedTabID: a.id)
        let other = Space(name: "Two", profileID: "second")
        let engine = PopupEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [space, other]))
        return (model, engine, try #require(model.liveTab(for: a.id)), space)
    }

    @Test func hostedPopupBecomesASelectedTabInTheOpenersSpace() throws {
        let (model, _, opener, space) = try makeModel()
        model.selectSpace(model.workspace.spaces[1].id)
        let popup = PopupTab()
        popup.state.url = URL(string: "https://idp.example/auth")
        #expect(model.engineTab(opener, hostsPopup: popup, activate: true))
        #expect(model.selectedSpace.id == space.id)
        let added = try #require(model.workspace.spaces[0].tabs.last)
        #expect(added.url?.absoluteString == "https://idp.example/auth")
        #expect(model.selectedTabID == added.id)
        #expect(model.liveTab(for: added.id) === popup)
        #expect(popup.delegate === model)
        #expect(model.workspace.spaces[1].tabs.isEmpty)
        try model.workspace.validate()
    }

    @Test func emptyPopupGetsABlankPageSoItsViewIsMounted() throws {
        let (model, _, opener, _) = try makeModel()
        let popup = PopupTab()
        #expect(model.engineTab(opener, hostsPopup: popup, activate: true))
        #expect(model.selectedTab?.url?.absoluteString == "about:blank")
    }

    @Test func popupClosingItselfRemovesTheTabAndClosesTheEngineTab() throws {
        let (model, _, opener, _) = try makeModel()
        let popup = PopupTab()
        #expect(model.engineTab(opener, hostsPopup: popup, activate: true))
        let id = try #require(model.selectedTabID)
        model.engineTabDidRequestClose(popup)
        #expect(model.item(id) == nil)
        #expect(popup.closed)
        #expect(model.liveTabs[id] == nil)
        #expect(model.selectedTabID != id)
        try model.workspace.validate()
    }

    @Test func popupFromAnUnknownTabIsRefused() throws {
        let (model, _, _, _) = try makeModel()
        let stranger = PopupTab()
        let before = model.workspace.spaces.map(\.tabs.count)
        #expect(!model.engineTab(stranger, hostsPopup: PopupTab(), activate: true))
        #expect(model.workspace.spaces.map(\.tabs.count) == before)
    }

    @Test func popupsReceiveTheUserScriptsForTheirURL() throws {
        let (model, _, opener, _) = try makeModel()
        model.userScriptProvider = { url in [EngineUserScript(id: url?.host ?? "none", source: "1")] }
        let popup = PopupTab()
        popup.state.url = URL(string: "https://idp.example/auth")
        #expect(model.engineTab(opener, hostsPopup: popup, activate: false))
        #expect(popup.scripts.map(\.id) == ["idp.example"])
        #expect(model.selectedTabID != model.workspace.spaces[0].tabs.last?.id)
    }

    @Test func blockedPopupsAreCountedPerTabAndDismissible() throws {
        let (model, _, opener, space) = try makeModel()
        let id = try #require(space.tabs.first?.id)
        model.engineTab(opener, blockedPopup: nil, reason: .noUserGesture)
        model.engineTab(opener, blockedPopup: URL(string: "https://ad.example/"), reason: .rateLimited)
        #expect(model.blockedPopups[id] == 2)
        model.dismissBlockedPopups(id)
        #expect(model.blockedPopups[id] == nil)
        model.engineTab(opener, blockedPopup: nil, reason: .noUserGesture)
        model.unloadTab(id)
        #expect(model.blockedPopups[id] == nil)
    }
}

@Suite struct PopupPolicyTests {
    private func decide(_ url: String, _ disposition: PopupDisposition = .foreground, gesture: Bool = true,
                        budget: inout PopupBudget, at now: Date = Date(timeIntervalSince1970: 1000)) -> PopupDecision {
        PopupPolicy.decide(url: url, disposition: disposition, userGesture: gesture, budget: &budget, now: now)
    }

    @Test func gesturePopupsAreAdoptedIncludingEmptyOnes() {
        var budget = PopupBudget()
        #expect(decide("https://idp.example/auth", budget: &budget) == .adopt)
        #expect(decide("", budget: &budget) == .adopt)
        #expect(decide("about:blank", budget: &budget) == .adopt)
    }

    @Test func popupsWithoutAGestureAreBlockedAndCostNoBudget() {
        var budget = PopupBudget(limit: 1)
        #expect(decide("https://a.example/", gesture: false, budget: &budget) == .block(.noUserGesture))
        #expect(decide("https://a.example/", budget: &budget) == .adopt)
    }

    @Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "view-source:https://a.example/",
                      "cairn://x", "not a url"])
    func unsupportedSchemesAreBlocked(_ url: String) {
        var budget = PopupBudget()
        #expect(decide(url, budget: &budget) == .block(.unsupportedScheme))
    }

    @Test func backgroundLinksOpenAsPlainTabsAndUnsupportedDispositionsAreIgnored() {
        var budget = PopupBudget()
        #expect(decide("https://a.example/", .background, budget: &budget) == .openInTab(activate: false))
        #expect(decide("https://a.example/", .unsupported, budget: &budget) == .cancel)
        #expect(decide("https://a.example/", .unsupported, gesture: false, budget: &budget) == .cancel)
    }

    @Test func budgetAllowsThreePerTenSecondsThenRecovers() {
        var budget = PopupBudget()
        let start = Date(timeIntervalSince1970: 1000)
        for i in 0..<3 { #expect(decide("https://a.example/\(i)", budget: &budget, at: start) == .adopt) }
        #expect(decide("https://a.example/x", budget: &budget, at: start.addingTimeInterval(9)) == .block(.rateLimited))
        #expect(decide("https://a.example/x", budget: &budget, at: start.addingTimeInterval(10)) == .adopt)
    }
}

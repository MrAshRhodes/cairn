import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class StubTab: EngineTab {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    func load(_ url: URL) {}
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

@MainActor
private final class StubEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Stub"
    let versionDescription = "Test"
    var tabs: [StubTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = StubTab()
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@Suite @MainActor struct ContextMenuEventsTests {
    @Test(arguments: ["mailto:a@b.c", "tel:+15555550100", "slack://open", "zoommtg://x"])
    func allowsMailAndAppSchemes(_ link: String) {
        #expect(ExternalURLLauncher.decision(for: URL(string: link)!) == .allow)
    }

    @Test(arguments: ["file:///etc/passwd", "ssh://host", "smb://host/share", "javascript:alert(1)",
                      "x-apple.systempreferences:com.apple.preference.security", "https://example.com", "data:text/html,x"])
    func deniesDangerousSchemes(_ link: String) {
        guard case .deny = ExternalURLLauncher.decision(for: URL(string: link)!) else {
            Issue.record("\(link) was allowed"); return
        }
    }

    @Test func confirmedLinkOpensOnceAndIsRateLimited() {
        let launcher = ExternalURLLauncher()
        var opened: [URL] = []
        var prompts = 0
        var clock = ContinuousClock.now
        launcher.now = { clock }
        launcher.applicationName = { _ in "Mail" }
        launcher.confirm = { _, _ in prompts += 1; return true }
        launcher.open = { opened.append($0) }
        let url = URL(string: "mailto:a@b.c")!

        #expect(launcher.handle(url) == nil)
        #expect(launcher.handle(url) == nil)
        #expect(opened == [url] && prompts == 1)
        clock = clock.advanced(by: .seconds(2))
        #expect(launcher.handle(url) == nil)
        #expect(opened.count == 2 && prompts == 2)
    }

    @Test func declinedLinkIsNotOpenedAndNoHandlerReportsAnError() {
        let launcher = ExternalURLLauncher()
        var opened = 0
        var clock = ContinuousClock.now
        launcher.now = { clock }
        launcher.applicationName = { _ in "Mail" }
        launcher.confirm = { _, _ in false }
        launcher.open = { _ in opened += 1 }
        #expect(launcher.handle(URL(string: "mailto:a@b.c")!) == nil)
        #expect(opened == 0)

        clock = clock.advanced(by: .seconds(2))
        launcher.applicationName = { _ in nil }
        #expect(launcher.handle(URL(string: "nosuchscheme://x")!) != nil)
        #expect(opened == 0)
    }

    @Test func searchTextIsNeverInterpretedAsAScheme() throws {
        let url = try #require(BrowserModel.searchURL(for: " javascript:alert(1) & more ", template: "https://s.test/?q=%s"))
        #expect(url.absoluteString == "https://s.test/?q=javascript%3Aalert%281%29%20%26%20more")
        #expect(BrowserModel.searchURL(for: "   ", template: "https://s.test/?q=%s") == nil)
        #expect(BrowserModel.searchURL(for: "x", template: "file:///%s") == nil)
    }

    @Test func searchSelectionOpensATabInTheOriginatingSpace() throws {
        let engine = StubEngine()
        let model = BrowserModel(engine: engine)
        model.searchTemplate = "https://s.test/?q=%s"
        let origin = model.newTab(url: URL(string: "https://example.com")!)
        let tab = try #require(model.liveTabs[origin])
        let before = model.selectedSpace.tabs.count

        model.engineTab(tab, requestsSearchFor: "cairn browser", activate: false)

        #expect(model.selectedSpace.tabs.count == before + 1)
        #expect(model.selectedSpace.tabs.last?.url?.absoluteString == "https://s.test/?q=cairn%20browser")
        #expect(model.selectedTabID == origin)
    }

    @Test func eventsFromUnknownTabsAreIgnored() {
        let model = BrowserModel(engine: StubEngine())
        let count = model.selectedSpace.tabs.count
        model.engineTab(StubTab(), requestsSearchFor: "x", activate: true)
        model.engineTab(StubTab(), requestsExternalURL: URL(string: "mailto:a@b.c")!)
        #expect(model.selectedSpace.tabs.count == count)
    }
}

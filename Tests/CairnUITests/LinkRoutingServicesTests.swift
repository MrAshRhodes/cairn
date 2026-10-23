import AppKit
import Testing
import CairnCore
import CairnEngineKit
@testable import CairnUI

@MainActor
private final class RoutingEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Routing test engine"
    let versionDescription = "Test"
    var profiles: [String] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        profiles.append(configuration.profileID)
        return RoutingTab()
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class RoutingTab: EngineTab {
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

@Suite(.serialized) @MainActor
struct LinkRoutingServicesTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [false, true])
    func externalAndEngineLinksShareOrderedRulesWithoutMovingLiveViews(activate: Bool) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Space(name: "Personal", profileID: "personal")
        let target = Space(name: "Work", profileID: "work")
        let engine = RoutingEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [source, target]))
        let services = BrowserServices(model: model, directory: directory)
        let original = model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(model.liveTab(for: original))
        let url = try #require(URL(string: "https://target.test/page"))
        try services.linkRules.update(rules: [
            LinkRule(text: "target.test", destination: .space(target.id)),
            LinkRule(text: "target", destination: .space(source.id)),
        ], defaultDestination: .space(source.id), peekEnabled: false)

        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: activate)
        let routed = try #require(model.workspace.spaces[1].tabs.first)
        #expect(model.workspace.spaces.map(\.tabs.count) == [1, 1])
        #expect(routed.url == url)
        #expect(model.selectedSpace.id == (activate ? target.id : source.id))
        #expect(model.selectedTabID == (activate ? routed.id : original))
        #expect(model.liveTabs[original] === opener)
        #expect(engine.profiles == (activate ? ["personal", "work"] : ["personal"]))
        if !activate {
            #expect(model.liveTabs[routed.id] == nil)
            model.select(routed.id)
            #expect(engine.profiles == ["personal", "work"])
        }
        #expect(model.liveTabs[routed.id] !== opener)

        services.openExternalLink(url)
        #expect(model.workspace.spaces.map(\.tabs.count) == [1, 2])
        #expect(model.selectedSpace.id == target.id)
        #expect(model.selectedTab?.url == url)
        #expect(engine.profiles == ["personal", "work", "work"])
        #expect(services.issues.isEmpty)
    }

    @Test func sameTabExplicitDestinationsAndOpenerPopupsDoNotUseRules() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Space(name: "Personal", profileID: "personal")
        let target = Space(name: "Work", profileID: "work")
        let engine = RoutingEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [source, target]))
        let services = BrowserServices(model: model, directory: directory)
        try services.linkRules.update(rules: [], defaultDestination: .space(target.id), peekEnabled: true)
        let url = try #require(URL(string: "https://target.test"))
        let original = model.newTab(url: url, in: source.id)
        let opener = try #require(model.liveTab(for: original))
        model.load(url.appendingPathComponent("same-tab"), in: original)
        model.navigate("https://target.test/address-bar")
        #expect(model.workspace.spaces.map(\.tabs.count) == [1, 0])
        #expect(model.selectedSpace.id == source.id)
        #expect(opener.state.url?.path == "/address-bar")

        let popup = RoutingTab()
        popup.state.url = url.appendingPathComponent("oauth")
        #expect(model.engineTab(opener, hostsPopup: popup, activate: true))
        #expect(model.workspace.spaces.map(\.tabs.count) == [2, 0])
        #expect(model.selectedSpace.id == source.id)
        #expect(model.selectedTabID.flatMap { model.liveTabs[$0] } === popup)
        #expect(engine.profiles == ["personal"])
    }

    @Test func editsApplyImmediatelyAndNonWebNewTabsKeepTheirOrigin() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Space(name: "Source", profileID: "source")
        let target = Space(name: "Target", profileID: "target")
        let model = BrowserModel(engine: RoutingEngine(), workspace: Workspace(spaces: [source, target]))
        let services = BrowserServices(model: model, directory: directory)
        let original = model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(model.liveTab(for: original))
        let url = try #require(URL(string: "https://target.test"))
        try services.linkRules.update(rules: [], defaultDestination: .space(target.id), peekEnabled: false)
        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: true)
        let foreground = model.selectedTabID
        try services.linkRules.update(rules: [], defaultDestination: .space(source.id), peekEnabled: false)
        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: false)
        #expect(model.workspace.spaces.map(\.tabs.count) == [2, 1])
        #expect(model.selectedSpace.id == target.id && model.selectedTabID == foreground)
        try services.linkRules.update(rules: [], defaultDestination: .space(target.id), peekEnabled: false)
        opener.delegate?.engineTab(opener, requestsNewTab: try #require(URL(string: "about:blank")), activate: false)
        #expect(model.workspace.spaces.map(\.tabs.count) == [3, 1])
        #expect(model.workspace.spaces[0].tabs.last?.url?.absoluteString == "about:blank")
        #expect(model.selectedTabID == foreground)
    }

    @Test func noServiceProviderKeepsNewTabInTheOriginatingSpace() throws {
        let source = Space(name: "Source", profileID: "source")
        let other = Space(name: "Other", profileID: "other")
        let model = BrowserModel(engine: RoutingEngine(), workspace: Workspace(spaces: [source, other]))
        let original = model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(model.liveTab(for: original))
        model.selectSpace(other.id)
        model.engineTab(opener, requestsNewTab: try #require(URL(string: "https://target.test")), activate: false)
        #expect(model.workspace.spaces.map(\.tabs.count) == [2, 0])
        #expect(model.selectedSpace.id == other.id)
    }

    @Test func staleOpenerAndDeletedProviderDestinationCannotCreateMisplacedTabs() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(engine: RoutingEngine())
        let services = BrowserServices(model: model, directory: directory)
        let original = model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(model.liveTab(for: original))
        let url = try #require(URL(string: "https://target.test"))
        try services.linkRules.update(rules: [], defaultDestination: .space(UUID()), peekEnabled: false)
        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: false)
        #expect(model.selectedSpace.tabs.count == 2)
        #expect(model.selectedTabID == original)
        #expect(services.issues.contains { $0.title == "Link destination is unavailable" })
        model.unloadTab(original)
        model.engineTab(opener, requestsNewTab: url, activate: true)
        #expect(model.selectedSpace.tabs.count == 2)
    }

    @Test(arguments: [false, true])
    func quickWindowRoutePresentsExactlyOnceWithoutPersistentTab(activate: Bool) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(engine: RoutingEngine())
        let services = BrowserServices(model: model, directory: directory)
        var presented: [(UUID, Bool)] = []
        services.presentQuickWindow = { presented.append(($0, $1)) }
        let original = model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(model.liveTab(for: original))
        try services.linkRules.update(rules: [], defaultDestination: .quickWindow, peekEnabled: true)
        let url = try #require(URL(string: "https://target.test"))
        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: activate)
        #expect(model.selectedSpace.tabs.count == 1)
        #expect(model.selectedTabID == original)
        #expect(presented.count == 1 && presented.first?.1 == activate)
        let page = try #require(model.transientPages[presented[0].0])
        #expect(page.kind == .quickWindow && page.profileID == model.selectedSpace.profileID)
        #expect(model.liveTabs[page.id]?.state.url == url)
        #expect(services.issues.isEmpty)
        services.shutdown()
    }

    @Test func externalQuickRouteAndRemappedCommandUseExplicitProfilesWithoutSessionRecords() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = RoutingEngine()
        let model = BrowserModel(engine: engine)
        let services = BrowserServices(model: model, directory: directory)
        var presented: [UUID] = []
        services.presentQuickWindow = { id, _ in presented.append(id) }
        try services.linkRules.update(rules: [], defaultDestination: .quickWindow, peekEnabled: false)
        services.openExternalLink(try #require(URL(string: "https://quick.test")))
        #expect(model.selectedSpace.tabs.isEmpty && presented.count == 1)
        #expect(engine.profiles == [model.selectedSpace.profileID])
        try services.assignShortcut(KeyChord("n", command: true, shift: true, option: true), to: "ui.quick-window")
        #expect(services.shortcuts.chord(for: "ui.quick-window")?.display == "⌥⇧⌘N")
        #expect(services.commands().first { $0.id == "ui.quick-window" }?.shortcut == "⌥⇧⌘N")
        services.perform(action: "ui.quick-window")
        #expect(presented.count == 2 && model.selectedSpace.tabs.isEmpty)
        try services.flush()
        let loaded = try WorkspaceStore(directory: directory).load()
        let restored = try #require(loaded)
        #expect(restored.spaces.allSatisfy { $0.tabs.isEmpty })
        services.shutdown()
        #expect(model.transientPages.isEmpty && model.liveTabs.isEmpty)
    }

    @Test func nativeQuickWindowHasVisibleChromeAndNoRestorationIdentifier() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(engine: RoutingEngine())
        let services = BrowserServices(model: model, directory: directory)
        // Build the actual window off screen: no global key-window/UI automation in unit tests.
        services.presentQuickWindow = { [weak services] id, _ in
            guard let services else { return }
            services.quickWindows[id] = QuickWindowController(services: services, tabID: id)
        }
        let id = try #require(model.openQuickPage(url: URL(string: "https://quick.test"), in: model.selectedSpace.id))
        let controller = try #require(services.quickWindows[id])
        #expect(controller.window.styleMask.contains([.titled, .closable, .resizable]))
        #expect(!controller.window.isRestorable && controller.window.frameAutosaveName.isEmpty)
        #expect(controller.window.title.contains("Quick Window") && controller.window.contentView != nil)
        #expect(!controller.windowShouldClose(controller.window))
        #expect(model.transientPages[id] == nil && services.quickWindows[id] == nil)
        #expect(controller.window.contentView == nil)
    }

    @Test func persistedRulesAndSelectionsSurviveRelaunchAndDeletedSpacesAreReported() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(.chromium) { RoutingEngine() }
        let first = try BrowserServices.bootstrap(registry: registry, directory: directory)
        let sourceID = first.model.selectedSpace.id
        let targetID = first.model.addSpace(name: "Work")
        first.model.updateSpace(targetID) { $0.profileID = "work" }
        let missingID = UUID()
        try first.linkRules.update(rules: [
            LinkRule(text: "deleted.test", destination: .space(missingID)),
            LinkRule(text: "target.test", destination: .space(targetID)),
        ], defaultDestination: .space(sourceID), peekEnabled: false)
        first.model.selectSpace(sourceID)
        let original = first.model.newTab(url: URL(string: "https://source.test"))
        let opener = try #require(first.model.liveTab(for: original))
        let url = try #require(URL(string: "https://target.test"))
        opener.delegate?.engineTab(opener, requestsNewTab: url, activate: false)
        let routedID = try #require(first.model.workspace.spaces[1].tabs.first?.id)
        try first.flush()
        first.shutdown()

        let second = try BrowserServices.bootstrap(registry: registry, directory: directory)
        defer { second.shutdown() }
        #expect(second.model.selectedSpace.id == sourceID)
        #expect(second.model.selectedTabID == original)
        #expect(second.model.item(routedID)?.url == url)
        #expect(second.linkRules.rules.map(\.text) == ["target.test"])
        #expect(!second.linkRules.peekEnabled)
        #expect(second.issues.contains { $0.title == "Link destinations were removed" })
        let restoredOpener = try #require(second.model.liveTab(for: original))
        restoredOpener.delegate?.engineTab(restoredOpener, requestsNewTab: url, activate: true)
        #expect(second.model.selectedSpace.id == targetID)
        #expect(second.model.workspace.spaces[1].tabs.count == 2)
        second.openExternalLink(url)
        #expect(second.model.workspace.spaces[1].tabs.count == 3)
    }
}

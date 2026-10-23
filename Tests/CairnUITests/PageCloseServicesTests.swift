import AppKit
import CairnCore
import CairnEngineKit
import Testing
@testable import CairnUI

@MainActor
private final class CloseServicesEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Close services test"
    let versionDescription = "Test"
    let tab = CloseServicesTab()
    var shutdowns = 0
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { tab }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() { shutdowns += 1 }
}

@MainActor
private final class CloseServicesTab: EngineTab, EngineTabCloseControlling {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom = 1.0
    var decide: (@MainActor (Bool) -> Void)?
    var requests = 0
    var forces = 0
    var approved = false
    func load(_ url: URL) { state.url = url }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {}
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { requestClose { _ in } }
    func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        if approved { completion(true); return }
        requests += 1
        decide = completion
    }
    func forceClose() { forces += 1; answer(true) }
    func answer(_ approved: Bool) {
        self.approved = approved
        let callback = decide
        decide = nil
        callback?(approved)
    }
}

@Suite @MainActor
struct PageCloseServicesTests {
    @Test func shutdownDoesNotDisconnectServicesUntilEveryPageApproves() {
        let engine = CloseServicesEngine()
        let model = BrowserModel(engine: engine)
        let id = model.newTab()
        let services = BrowserServices(model: model)
        model.onNavigationCommitted = { _, _ in }
        services.shutdown()
        services.shutdown()
        #expect(engine.tab.requests == 1)
        #expect(engine.shutdowns == 0)
        #expect(model.onNavigationCommitted != nil)
        #expect(engine.tab.delegate === model)
        engine.tab.answer(false)
        #expect(engine.shutdowns == 0)
        #expect(model.liveTabs[id] === engine.tab)
        #expect(model.onNavigationCommitted != nil)
        services.shutdown()
        engine.tab.answer(true)
        #expect(engine.shutdowns == 1)
        #expect(model.onNavigationCommitted == nil)
        #expect(model.liveTabs.isEmpty)
        #expect(model.item(id) != nil)
        services.shutdown()
        #expect(engine.shutdowns == 1)
    }

    @Test func explicitForcePropagatesButOrdinaryPageApprovalDoesNotForce() {
        let engine = CloseServicesEngine()
        let model = BrowserModel(engine: engine)
        let id = model.newTab()
        let services = BrowserServices(model: model)
        services.commandBarPresented = true
        services.sheet = .history
        var results: [Bool] = []
        services.requestPageCloseApproval { results.append($0) }
        #expect(!services.commandBarPresented)
        #expect(services.sheet == nil)
        #expect(engine.tab.forces == 0)
        services.requestPageCloseApproval(force: true) { results.append($0) }
        #expect(results == [true, true])
        #expect(engine.tab.forces == 1)
        #expect(model.item(id) != nil)
        #expect(model.isWorkspaceSuspended)
        #expect(engine.shutdowns == 0)
    }
}

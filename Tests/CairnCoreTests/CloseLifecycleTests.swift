import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class ClosingEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Close test"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { ClosingTab() }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class ClosingTab: EngineTab, EngineTabCloseControlling {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom = 1.0
    var requests = 0
    var forced = 0
    var approved = false
    var decision: (@MainActor (Bool) -> Void)?
    func load(_ url: URL) { state.url = url }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(42)) }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { requestClose { _ in } }
    func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        if approved { completion(true); return }
        requests += 1
        decision = completion
    }
    func answer(_ leave: Bool) {
        approved = leave
        let callback = decision
        decision = nil
        callback?(leave)
    }
    func forceClose() { forced += 1; answer(true) }
}

@Suite @MainActor
struct CloseLifecycleTests {
    private func snapshot(_ model: BrowserModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(model.workspace)
    }
    private func make(_ count: Int = 1) throws -> (BrowserModel, [UUID], [ClosingTab]) {
        let model = BrowserModel(engine: ClosingEngine())
        let ids = (0..<count).map { model.newTab(url: URL(string: "https://example.com/\($0)")!) }
            .sorted { $0.uuidString < $1.uuidString }
        let tabs = try ids.map { try #require(model.liveTabs[$0] as? ClosingTab) }
        return (model, ids, tabs)
    }

    @Test func stayPreservesTheTabSelectionDelegateAndWorkspace() throws {
        let (model, ids, tabs) = try make()
        let before = try snapshot(model)
        var changes = 0
        model.onChange = { changes += 1 }
        model.closeTab(ids[0])
        model.closeTab(ids[0])
        #expect(tabs[0].requests == 1)
        #expect(try snapshot(model) == before)
        #expect(tabs[0].delegate === model)
        #expect(model.closingTabID == ids[0])
        tabs[0].answer(false)
        #expect(try snapshot(model) == before)
        #expect(model.liveTabs[ids[0]] === tabs[0])
        #expect(model.closingTabID == nil)
        #expect(model.closedTabs.count == 0)
        #expect(changes == 0)
        #expect(tabs[0].forced == 0)
    }

    @Test func leaveRemovesOnlyAfterApprovalAndIgnoresStaleAnswers() throws {
        let (model, ids, tabs) = try make()
        model.closeTab(ids[0])
        let stale = try #require(tabs[0].decision)
        #expect(model.item(ids[0]) != nil)
        tabs[0].answer(true)
        #expect(model.item(ids[0]) == nil)
        #expect(model.liveTabs[ids[0]] == nil)
        #expect(model.closedTabs.count == 1)
        stale(false)
        stale(true)
        #expect(model.closedTabs.count == 1)
    }

    @Test func laterStayNeverDeletesWorkspaceRecordsOrChangesSelection() throws {
        let (model, ids, tabs) = try make(3)
        model.select(ids[1])
        let before = try snapshot(model)
        var results: [Bool] = []
        model.requestCloseAll { results.append($0) }
        model.requestCloseAll { results.append($0) }
        #expect(tabs[0].requests == 1)
        #expect(tabs[1].requests == 0)
        tabs[0].answer(true)
        #expect(try snapshot(model) == before)
        #expect(model.isClosingWorkspace)
        tabs[1].answer(false)
        #expect(results == [false, false])
        #expect(try snapshot(model) == before)
        #expect(model.liveTabs[ids[0]] == nil)
        #expect(model.liveTabs[ids[1]] === tabs[1])
        #expect(model.liveTabs[ids[2]] === tabs[2])
        #expect(model.closedTabs.count == 0)
        #expect(!model.isClosingWorkspace)
        #expect(tabs.allSatisfy { $0.forced == 0 })
    }

    @Test func successfulWindowCloseRetainsWorkspaceForReopen() throws {
        let (model, _, tabs) = try make(2)
        let before = try snapshot(model)
        var results: [Bool] = []
        model.requestCloseAll { results.append($0) }
        tabs[0].answer(true)
        tabs[1].answer(true)
        #expect(results == [true])
        #expect(try snapshot(model) == before)
        #expect(model.liveTabs.isEmpty)
        #expect(model.closedTabs.count == 0)
        #expect(model.isWorkspaceSuspended)
        #expect(model.liveTab(for: try #require(model.selectedTabID)) == nil)
        model.resumeWorkspace()
        #expect(model.liveTab(for: try #require(model.selectedTabID)) != nil)
    }

    @Test func forcedCloseIsAnExplicitOverrideAndSettlesThePendingRequestOnce() throws {
        let (model, ids, tabs) = try make(2)
        var results: [Bool] = []
        model.requestCloseAll { results.append($0) }
        #expect(tabs.allSatisfy { $0.forced == 0 })
        model.requestCloseAll(force: true) { results.append($0) }
        #expect(results == [true, true])
        #expect(tabs.allSatisfy { $0.forced == 1 })
        #expect(model.liveTabs.isEmpty)
        #expect(ids.allSatisfy { model.item($0) != nil })
    }

    @Test func rendererOrDocumentInvalidationCannotAuthorizeALaterAttempt() throws {
        let (model, ids, tabs) = try make()
        model.closeTab(ids[0])
        let stale = try #require(tabs[0].decision)
        tabs[0].answer(false)
        model.closeTab(ids[0])
        stale(true)
        #expect(model.item(ids[0]) != nil)
        #expect(model.closingTabID == ids[0])
        tabs[0].answer(false)
        #expect(model.liveTabs[ids[0]] === tabs[0])
    }

    @Test func removeSpaceWaitsForAllPagesAndStayPreservesTheWholeSpace() throws {
        let (model, _, tabs) = try make(2)
        let space = model.selectedSpace.id
        _ = model.addSpace(name: "Other")
        let before = try snapshot(model)
        model.removeSpace(space)
        #expect(try snapshot(model) == before)
        tabs[0].answer(true)
        tabs[1].answer(false)
        #expect(try snapshot(model) == before)
        #expect(model.workspace.spaces.count == 2)
    }

    @Test func pendingPopupJoinsWorkspaceApprovalWithoutChangingSelection() throws {
        let (model, _, tabs) = try make()
        var results: [Bool] = []
        model.requestCloseAll { results.append($0) }
        let popup = ClosingTab()
        #expect(model.engineTab(tabs[0], hostsPopup: popup, activate: false))
        tabs[0].answer(true)
        #expect(popup.requests == 1)
        #expect(results.isEmpty)
        popup.answer(false)
        #expect(results == [false])
        #expect(model.liveTabs.values.contains { $0 === popup })
    }
}

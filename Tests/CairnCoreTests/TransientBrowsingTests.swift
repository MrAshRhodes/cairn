import AppKit
import Testing
import CairnEngineKit
@testable import CairnCore

@MainActor
private final class TransientEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Transient test"
    let versionDescription = "Test"
    var configurations: [EngineConfiguration] = []
    var made: [TransientTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        #expect(initialURL == nil)
        configurations.append(configuration)
        let tab = TransientTab()
        made.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class TransientTab: EngineTab, EngineTabCloseControlling, EngineTabPromptResponding {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom = 1.0
    var loads: [URL] = []
    var scripts: [EngineUserScript] = []
    var editedPageState = ""
    var closeRequests = 0
    var forced = 0
    var automaticDecision: Bool? = true
    var decision: (@MainActor (Bool) -> Void)?
    var jsAnswers: [Bool] = []
    func load(_ url: URL) {
        #expect(delegate != nil)
        loads.append(url); state.url = url
        delegate?.engineTab(self, didChange: state)
    }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) { completion?(.success(nil)) }
    func setUserScripts(_ scripts: [EngineUserScript]) { self.scripts = scripts }
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() { requestClose { _ in } }
    func requestClose(completion: @escaping @MainActor (Bool) -> Void) {
        closeRequests += 1
        decision = completion
        if let automaticDecision { answer(automaticDecision) }
    }
    func answer(_ approved: Bool) {
        let callback = decision; decision = nil; callback?(approved)
    }
    func forceClose() { forced += 1; automaticDecision = true; answer(true) }
    func resolvePermission(id: String, allow: Bool) {}
    func resolveJSDialog(id: String, accept: Bool, text: String?, suppressFurther: Bool) { jsAnswers.append(accept) }
    func resolveAuthentication(id: String, username: String?, password: String?) {}
}

@Suite @MainActor
struct TransientBrowsingTests {
    private let sourceURL = URL(string: "https://source.example")!
    private let targetURL = URL(string: "https://target.example/page")!
    private func snapshot(_ model: BrowserModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(model.workspace)
    }

    private func pinned() throws -> (BrowserModel, TransientEngine, UUID, TransientTab) {
        let item = TabItem(url: sourceURL)
        let space = Space(name: "Source", profileID: "source", pinned: [item], selectedTabID: item.id)
        let other = Space(name: "Other", profileID: "other")
        let engine = TransientEngine()
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [space, other]))
        model.peekEnabled = { true }
        let tab = try #require(model.liveTab(for: item.id) as? TransientTab)
        return (model, engine, item.id, tab)
    }

    private func openPeek(_ model: BrowserModel, from source: TransientTab) throws -> (UUID, TransientTab) {
        #expect(model.engineTab(source, interceptsUserNavigation: targetURL))
        let id = try #require(model.peek.tabID)
        return (id, try #require(model.liveTabs[id] as? TransientTab))
    }

    @Test func peekUsesSourceProfileWithoutPersistentRecordOrDuplicateLoad() throws {
        let (model, engine, owner, source) = try pinned()
        let before = try snapshot(model)
        var persisted = 0
        model.onChange = { persisted += 1 }
        let (id, peek) = try openPeek(model, from: source)
        #expect(try snapshot(model) == before)
        #expect(persisted == 0 && model.locate(id) == nil)
        #expect(model.peek.ownerTabID == owner)
        #expect(model.transientPages[id]?.profileID == "source")
        #expect(engine.configurations.map(\.profileID) == ["source", "source"])
        #expect(engine.configurations.allSatisfy { !$0.isEphemeral })
        #expect(source.loads == [sourceURL] && peek.loads == [targetURL])
        model.repairReferences()
        #expect(model.liveTab(for: id) === peek && peek.closeRequests == 0)
        #expect(!model.engineTab(source, interceptsUserNavigation: URL(string: "https://third.example")!))
        #expect(engine.made.count == 2)
    }

    @Test(arguments: [
        "https://docs.source.example", "https://accounts.google.com/signin",
        "https://target.example/oauth/authorize", "https://checkout.stripe.com/pay", "mailto:person@example.com",
        "https://identity.example/session?client_id=public&redirect_uri=https%3A%2F%2Fsource.example",
        "https://source.example/callback?code=test", "https://target.example/login",
    ])
    func sameSiteAndAuthenticationExceptionsNeverCreateAPeek(address: String) throws {
        let (model, engine, _, source) = try pinned()
        #expect(!model.engineTab(source, interceptsUserNavigation: try #require(URL(string: address))))
        #expect(!model.peek.isOpen && engine.made.count == 1)
    }

    @Test func disabledTodayStaleAndAuthSourceBypass() throws {
        let (model, engine, _, source) = try pinned()
        model.peekEnabled = { false }
        #expect(!model.engineTab(source, interceptsUserNavigation: targetURL))
        model.peekEnabled = { true }
        let today = model.newTab(url: sourceURL)
        let todayTab = try #require(model.liveTabs[today] as? TransientTab)
        #expect(!model.engineTab(todayTab, interceptsUserNavigation: targetURL))
        source.state.url = URL(string: "https://accounts.google.com/signin")
        #expect(!model.engineTab(source, interceptsUserNavigation: targetURL))
        #expect(!model.engineTab(TransientTab(), interceptsUserNavigation: targetURL))
        #expect(engine.made.count == 2)
    }

    @Test func favoritePeekKeepsItsOriginatingProfile() throws {
        let (model, _, owner, _) = try pinned()
        model.favorite(owner)
        let source = try #require(model.liveTab(for: owner) as? TransientTab)
        let (id, peek) = try openPeek(model, from: source)
        #expect(model.transientPages[id]?.profileID == "source")
        model.selectSpace(model.workspace.spaces[1].id)
        // Switching a global favorite's profile first closes its dependent Peek.
        #expect(model.liveTabs[id] == nil && peek.closeRequests == 1)
        #expect(!model.peek.isOpen)
    }

    @Test func expandMovesTheSameLivePageAndPreservesItsState() throws {
        let (model, engine, _, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        peek.editedPageState = "unsaved form, history, scroll, playback"
        peek.state.title = "Current title"
        peek.delegate?.engineTab(peek, didChange: peek.state)
        model.expandPeek()
        #expect(!model.peek.isOpen && model.transientPages[id] == nil)
        #expect(model.selectedTabID == id && model.locate(id)?.list == .today)
        #expect(model.liveTabs[id] === peek)
        #expect(model.item(id)?.title == "Current title")
        #expect(peek.editedPageState == "unsaved form, history, scroll, playback")
        #expect(peek.loads == [targetURL] && engine.made.count == 2 && peek.closeRequests == 0)
        model.expandPeek()
        #expect(model.selectedSpace.tabs.count == 1)
    }

    @Test func dismissHonorsStayThenLeaveAndRejectsStaleCallbacks() throws {
        let (model, _, _, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        peek.automaticDecision = nil
        model.dismissTransient(id)
        let stale = try #require(peek.decision)
        #expect(model.peek.isOpen)
        peek.answer(false)
        #expect(model.liveTabs[id] === peek && model.peek.isOpen)
        model.dismissTransient(id)
        stale(true)
        #expect(model.peek.isOpen)
        peek.answer(true)
        #expect(model.liveTabs[id] == nil && !model.peek.isOpen && peek.delegate == nil)
        #expect(model.closedTabs.count == 0)
    }

    @Test func ownerCloseWaitsForPeekAndStayNeverClosesOwner() throws {
        let (model, _, owner, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        peek.automaticDecision = nil
        model.closeTab(owner)
        model.closeTab(owner)
        #expect(peek.closeRequests == 1 && source.closeRequests == 0)
        #expect(model.closingTabID == id)
        peek.answer(false)
        #expect(source.closeRequests == 0 && model.liveTabs[owner] === source)
        #expect(model.liveTabs[id] === peek)
        model.closeTab(owner)
        peek.answer(true)
        #expect(source.closeRequests == 1 && model.liveTabs[owner] == nil)
        #expect(!model.peek.isOpen && model.liveTabs[id] == nil)
    }

    @Test func forceOwnerFirstSettlesItsDependentPeekThenOwner() throws {
        let (model, _, owner, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        peek.automaticDecision = nil; source.automaticDecision = nil
        model.closeTab(owner)
        model.forceCloseTab(owner)
        #expect(peek.forced == 1 && source.forced == 1)
        #expect(peek.closeRequests == 1 && source.closeRequests == 1)
        #expect(model.liveTabs[id] == nil && model.liveTabs[owner] == nil)
        #expect(model.closingTabID == nil)
    }

    @Test func forceOwnerWithoutPriorRequestDoesNotAskEitherPageToVeto() throws {
        let (model, _, owner, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        source.automaticDecision = false; peek.automaticDecision = false
        model.forceCloseTab(owner)
        #expect(peek.forced == 1 && source.forced == 1)
        #expect(model.liveTabs[id] == nil && model.liveTabs[owner] == nil)
    }

    @Test func quickWindowNeverRestoresOrArchivesUntilPromoted() throws {
        let (model, engine, owner, _) = try pinned()
        let before = try snapshot(model)
        let id = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        #expect(try snapshot(model) == before && model.selectedTabID == owner)
        #expect(model.transientPages[id]?.kind == .quickWindow)
        let original = try #require(model.liveTabs[id])
        #expect(engine.configurations.last?.profileID == "source")
        model.archiveStaleTabs(olderThan: 1, now: Date.distantFuture)
        #expect(model.liveTabs[id] != nil && model.selectedSpace.archive.isEmpty)
        model.promoteTransient(id, to: model.selectedSpace.id)
        #expect(model.liveTabs[id] === original)
        #expect(model.selectedTabID == id && model.locate(id)?.list == .today)
        #expect(model.transientPages.isEmpty && engine.made.count == 2)
        model.requestCloseAll { #expect($0) }
        #expect(model.item(id)?.url == targetURL && model.liveTabs.isEmpty)
    }

    @Test func crossProfilePromotionWaitsAndCreatesOnlyAFreshTargetEngine() throws {
        let (model, engine, _, _) = try pinned()
        let id = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        let page = try #require(model.liveTabs[id] as? TransientTab)
        page.automaticDecision = nil
        page.editedPageState = "source secrets"
        let destination = model.workspace.spaces[1].id
        var promoted: UUID?
        model.promoteTransient(id, to: destination) { promoted = $0 }
        #expect(engine.made.count == 2 && model.workspace.spaces[1].tabs.isEmpty)
        page.answer(false)
        #expect(promoted == nil && model.liveTabs[id] === page)
        model.promoteTransient(id, to: destination) { promoted = $0 }
        page.answer(true)
        let target = try #require(promoted)
        let targetTab = try #require(model.liveTabs[target] as? TransientTab)
        #expect(target != id && targetTab !== page && targetTab.editedPageState.isEmpty)
        #expect(engine.configurations.map(\.profileID) == ["source", "source", "other"])
        #expect(targetTab.loads == [targetURL] && model.workspace.spaces[1].tabs.count == 1)
        #expect(model.transientPages.isEmpty && model.liveTabs[id] == nil)
    }

    @Test func spaceProfilesCannotBeAliasedToTransferAnAuthenticatedView() throws {
        let (model, engine, _, _) = try pinned()
        let target = model.workspace.spaces[1].id
        model.updateSpace(target) { $0.profileID = "source" }
        #expect(model.workspace.spaces[1].profileID == "other")
        let id = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        let page = try #require(model.liveTabs[id])
        var promoted: UUID?
        model.promoteTransient(id, to: target) { promoted = $0 }
        let replacement = try #require(promoted)
        #expect(model.liveTabs[id] == nil && model.liveTabs[replacement] !== page && engine.made.count == 3)
        #expect(model.selectedSpace.id == target && model.liveSpaceIDs[replacement] == target)
    }

    @Test func popupFromPeekIsAdoptedWithOpenerProfileNotReplayedOrPersisted() throws {
        let (model, engine, _, source) = try pinned()
        let (peekID, peek) = try openPeek(model, from: source)
        var shown: [UUID] = []
        model.onQuickPageCreated = { id, _ in shown.append(id) }
        let popup = TransientTab()
        popup.state.url = URL(string: "https://accounts.google.com/oauth")
        #expect(model.engineTab(peek, hostsPopup: popup, activate: true))
        let id = try #require(shown.first)
        #expect(model.liveTabs[id] === popup && popup.loads.isEmpty)
        #expect(model.transientPages[id]?.ownerTabID == peekID && model.liveProfileIDs[id] == "source")
        #expect(model.selectedSpace.tabs.isEmpty && engine.made.count == 2)
        model.dismissTransient(peekID)
        #expect(popup.closeRequests == 1 && peek.closeRequests == 1)
        #expect(model.transientPages.isEmpty)
    }

    @Test func pinningAnAdoptedPopupDoesNotLoseItsOpenerThroughPeek() throws {
        let (model, _, _, source) = try pinned()
        let popup = TransientTab()
        popup.state.url = sourceURL
        #expect(model.engineTab(source, hostsPopup: popup, activate: true))
        let id = try #require(model.selectedTabID)
        model.pin(id)
        #expect(model.liveTabs[id] === popup && model.locate(id)?.list == .pinned)
        #expect(!model.engineTab(popup, interceptsUserNavigation: targetURL))
        #expect(model.peek.tabID == nil && model.openerBoundTabIDs.contains(id))
        model.unloadTab(id)
        #expect(!model.openerBoundTabIDs.contains(id))
    }

    @Test func spaceAndWindowClosureIncludeTransientsAndCancelPendingPrompts() throws {
        let (model, _, _, _) = try pinned()
        let id = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        let tab = try #require(model.liveTabs[id] as? TransientTab)
        model.engineTab(tab, requestsJSDialog: .init(id: "transient-dialog", kind: .confirm, message: "Waiting"))
        model.removeSpace(model.selectedSpace.id)
        #expect(model.transientPages.isEmpty && model.liveTabs[id] == nil)
        #expect(tab.jsAnswers == [false] && model.prompts.front(id) == nil)
        #expect(model.workspace.spaces.count == 1)
        let second = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        model.requestCloseAll { #expect($0) }
        #expect(model.isWorkspaceSuspended && model.liveTabs[second] == nil && model.transientPages.isEmpty)
        #expect(model.openQuickPage(url: targetURL, in: model.selectedSpace.id) == nil)
    }

    @Test func transientVetoStopsWorkspaceCloseBeforeOrdinaryPages() throws {
        let (model, _, owner, source) = try pinned()
        let id = try #require(model.openQuickPage(url: targetURL, in: model.selectedSpace.id))
        let quick = try #require(model.liveTabs[id] as? TransientTab)
        quick.automaticDecision = nil
        var result: Bool?
        model.requestCloseAll { result = $0 }
        #expect(quick.closeRequests == 1 && source.closeRequests == 0 && result == nil)
        quick.answer(false)
        #expect(result == false && model.liveTabs[id] === quick && model.liveTabs[owner] === source)
        #expect(!model.isWorkspaceSuspended && !model.isClosingWorkspace)
    }

    @Test func promotionWaitsWhilePageCloseIsPendingAndStateChangesStayTransient() throws {
        let (model, _, _, source) = try pinned()
        let (id, peek) = try openPeek(model, from: source)
        peek.state = .init(url: targetURL, title: "Loading", isLoading: true, progress: 0.4)
        model.engineTab(peek, didChange: peek.state)
        #expect(model.tabStates[id]?.isLoading == true && model.selectedSpace.tabs.isEmpty)
        peek.state = .init(url: targetURL, title: "Failed", errorMessage: "Offline")
        model.engineTab(peek, didChange: peek.state)
        #expect(model.tabStates[id]?.errorMessage == "Offline")
        peek.automaticDecision = nil
        model.dismissTransient(id)
        model.expandPeek()
        #expect(model.selectedSpace.tabs.isEmpty && model.peek.tabID == id)
        peek.answer(false)
        model.expandPeek()
        #expect(model.item(id)?.title == "Failed" && model.liveTabs[id] === peek)
    }
}

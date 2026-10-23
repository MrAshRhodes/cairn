import AppKit
import CairnEngineKit
import Foundation
import Testing
@testable import CairnCore

@MainActor
private final class Engine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [Tab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = Tab()
        tabs.append(tab)
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
    var closed = false
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
    func close() { closed = true }
}

@Suite @MainActor struct SplitModelTests {
    private func make(_ count: Int = 5) -> (BrowserModel, [UUID], Space) {
        let tabs = (0..<count).map { _ in TabItem(url: URL(string: "https://example.com")) }
        let space = Space(name: "One", tabs: tabs, selectedTabID: tabs[0].id)
        let model = BrowserModel(engine: Engine(), workspace: Workspace(spaces: [space, Space(name: "Two")]))
        return (model, tabs.map(\.id), space)
    }

    @Test func buildsUpToFourPanesAndRefusesAFifthWithAVisibleError() {
        let (model, ids, _) = make()
        var errors: [Error] = []
        model.onError = { errors.append($0) }
        #expect(model.addToSplit(ids[1], edge: .right))
        #expect(model.addToSplit(ids[2], edge: .bottom, beside: ids[1]))
        #expect(model.addToSplit(ids[3], edge: .bottom, beside: ids[0]))
        #expect(model.splitTabIDs.count == 4)
        #expect(!model.addToSplit(ids[4], edge: .left))
        #expect(errors.count == 1)
        #expect(model.splitTabIDs.count == 4)
    }

    @Test func groupPersistsWhileAnotherTabIsSelectedAndReturnsWithAnyMember() {
        let (model, ids, _) = make()
        model.splitSelected(with: ids[1])
        model.select(ids[3])
        #expect(model.splitTabIDs.isEmpty)
        #expect(model.splitGroups.count == 1)
        model.select(ids[1])
        #expect(model.splitTabIDs == [ids[0], ids[1]])
    }

    @Test func removingAPaneKeepsTheTabAndDissolvesTinyGroups() {
        let (model, ids, space) = make()
        model.splitSelected(with: ids[1])
        model.addToSplit(ids[2], edge: .right, beside: ids[1])
        model.removeFromSplit(ids[1])
        #expect(model.splitTabIDs == [ids[0], ids[2]])
        #expect(model.locate(ids[1]) != nil)
        model.removeFromSplit(ids[2])
        #expect(model.splitGroups.isEmpty)
        #expect(model.selectedSpace.id == space.id)
    }

    @Test func closingATabShrinksItsSplit() {
        let (model, ids, _) = make()
        model.splitSelected(with: ids[1])
        model.addToSplit(ids[2], edge: .bottom)
        model.removeTab(ids[2])
        #expect(model.splitTabIDs == [ids[0], ids[1]])
        model.removeTab(ids[1])
        #expect(model.splitGroups.isEmpty)
    }

    @Test func separateAllDissolvesOnlyTheActiveGroup() {
        let (model, ids, _) = make()
        model.splitSelected(with: ids[1])
        model.select(ids[2])
        model.splitSelected(with: ids[3])
        #expect(model.splitGroups.count == 2)
        model.closeSplit()
        #expect(model.splitGroups.count == 1)
        #expect(model.splitGroup(containing: ids[0]) != nil)
    }

    @Test func aTabMovesBetweenGroupsInsteadOfBelongingToTwo() {
        let (model, ids, _) = make()
        model.splitSelected(with: ids[1])
        model.addToSplit(ids[2], edge: .right, beside: ids[1])
        model.select(ids[3])
        model.splitSelected(with: ids[2])
        #expect(model.splitGroup(containing: ids[2])?.layout.tabIDs == [ids[3], ids[2]])
        #expect(model.splitGroup(containing: ids[0])?.layout.tabIDs == [ids[0], ids[1]])
    }

    @Test func movingAMemberToAnotherSpaceDropsItAndProfilesStayIsolated() {
        let (model, ids, _) = make()
        let other = model.workspace.spaces[1].id
        model.splitSelected(with: ids[1])
        model.moveTab(ids[1], to: .today, in: other)
        #expect(model.splitGroups.isEmpty)
        #expect(!model.addToSplit(ids[0], edge: .right, beside: ids[1]))
    }

    @Test func focusPaneSelectsByReadingOrder() {
        let (model, ids, _) = make()
        model.splitSelected(with: ids[1])
        model.addToSplit(ids[2], edge: .left)
        #expect(model.splitTabIDs == [ids[2], ids[0], ids[1]])
        model.focusPane(2)
        #expect(model.selectedTabID == ids[1])
        model.focusPane(9)
        #expect(model.selectedTabID == ids[1])
        model.focusPane(0)
        #expect(model.selectedTabID == ids[2])
    }

    @Test func switchingSpacesKeepsGroupsButHidesThem() {
        let (model, ids, space) = make()
        model.splitSelected(with: ids[1])
        model.selectSpace(model.workspace.spaces[1].id)
        #expect(model.splitTabIDs.isEmpty)
        model.selectSpace(space.id)
        #expect(model.splitTabIDs == [ids[0], ids[1]])
    }

    @Test func restoreRepairsInvalidGroupsAndPaneDoesNotRecreateLiveTabs() throws {
        let (model, ids, space) = make()
        let engine = try #require(model.engine as? Engine)
        let missing = UUID()
        let good = SplitGroup(spaceID: space.id, layout: SplitLayout(tab: ids[0]).adding(ids[1], beside: ids[0], edge: .right)!)
        let stale = SplitGroup(spaceID: space.id, layout: SplitLayout(tab: ids[2]).adding(missing, beside: ids[2], edge: .right)!)
        let orphan = SplitGroup(spaceID: UUID(), layout: SplitLayout(tab: ids[3]).adding(ids[4], beside: ids[3], edge: .right)!)
        model.restoreSplits([good, stale, orphan])
        #expect(model.splitGroups == [good])
        let created = engine.tabs.count
        let divider = try #require(good.layout.dividers(in: CGRect(x: 0, y: 0, width: 800, height: 600)).first)
        model.moveSplitDivider(group: good.id, path: divider.path, index: 0, to: 0.7, minimumFraction: 0.1)
        #expect(engine.tabs.count == created)
        #expect(abs((model.splitGroups[0].layout.ratios.first ?? 0) - 0.7) < 1e-9)
    }

    @Test func splitPanesAreNotArchived() {
        let old = Date(timeIntervalSince1970: 0)
        let tabs = (0..<3).map { _ in TabItem(lastActiveAt: old) }
        let model = BrowserModel(engine: Engine(), workspace: Workspace(spaces: [Space(name: "S", tabs: tabs, selectedTabID: tabs[0].id)]))
        model.splitSelected(with: tabs[1].id)
        model.select(tabs[2].id)
        model.archiveStaleTabs(olderThan: 10)
        #expect(model.locate(tabs[1].id)?.list == .today)
    }
}

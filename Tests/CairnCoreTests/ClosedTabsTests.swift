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

@Suite @MainActor struct ClosedTabsTests {
    private func make(_ count: Int = 4) -> (BrowserModel, [UUID]) {
        let tabs = (0..<count).map { TabItem(url: URL(string: "https://example.com/\($0)")) }
        let space = Space(name: "One", tabs: tabs, selectedTabID: tabs[0].id)
        return (BrowserModel(engine: Engine(), workspace: Workspace(spaces: [space, Space(name: "Two")])), tabs.map(\.id))
    }

    @Test func reopensToTheOriginalPositionAndSelectsIt() {
        let (model, ids) = make()
        model.closeTab(ids[1])
        #expect(model.canReopenClosedTab)
        let restored = model.reopenClosedTab()
        #expect(restored == [ids[1]])
        #expect(model.selectedSpace.tabs.map(\.id) == ids)
        #expect(model.selectedTabID == ids[1])
        #expect(!model.canReopenClosedTab)
    }

    @Test func reopensToTheSpaceItWasClosedIn() {
        let (model, ids) = make()
        model.closeTab(ids[2])
        model.selectSpace(model.workspace.spaces[1].id)
        model.reopenClosedTab()
        #expect(model.workspace.spaces[0].tabs.contains { $0.id == ids[2] })
        #expect(model.workspace.spaces[1].tabs.isEmpty)
    }

    @Test func reopensNewestFirst() {
        let (model, ids) = make()
        model.closeTab(ids[1])
        model.closeTab(ids[2])
        #expect(model.reopenClosedTab() == [ids[2]])
        #expect(model.reopenClosedTab() == [ids[1]])
        #expect(model.reopenClosedTab().isEmpty)
    }

    @Test func stackKeepsTwentyFiveNewest() {
        var stack = ClosedTabsStack()
        for index in 0..<30 {
            stack.push(ClosedTab(item: TabItem(title: "\(index)"), spaceID: nil, list: .today, index: 0, batch: nil))
        }
        #expect(stack.count == 25)
        #expect(stack.entries.first?.item.title == "5")
        #expect(stack.pop().first?.item.title == "29")
    }

    @Test func aBatchLargerThanTheCapacityStaysWhole() {
        var stack = ClosedTabsStack(capacity: 3)
        let batch = UUID()
        for index in 0..<5 {
            stack.push(ClosedTab(item: TabItem(title: "\(index)"), spaceID: nil, list: .today, index: index, batch: batch))
        }
        #expect(stack.count == 5)
        #expect(stack.pop().count == 5)
    }

    @Test func clearTodayIsOneUndoableBatchThatKeepsPinnedTabs() {
        let (model, ids) = make()
        model.pin(ids[0])
        model.clearToday()
        #expect(model.selectedSpace.tabs.isEmpty)
        #expect(model.selectedSpace.pinned.map(\.id) == [ids[0]])
        let restored = Set(model.reopenClosedTab())
        #expect(restored == Set(ids[1...]))
        #expect(model.selectedSpace.tabs.map(\.id) == Array(ids[1...]))
    }

    @Test func recentTabsTrackSelectionOrder() {
        let (model, ids) = make()
        model.select(ids[1]); model.select(ids[3])
        #expect(model.recentTabs.candidates(valid: Set(ids)).prefix(2) == [ids[3], ids[1]])
        model.closeTab(ids[3])
        #expect(!model.recentTabs.ids.contains(ids[3]))
    }

    @Test func recentTrackerIsCappedAndDeduplicated() {
        var tracker = RecentTabsTracker(capacity: 3)
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach { tracker.touch($0) }
        tracker.touch(ids[3])
        #expect(tracker.ids == [ids[3], ids[4], ids[2]])
    }
}

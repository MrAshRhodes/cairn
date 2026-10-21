import Foundation
import Testing
import CairnCore
import CairnModules
@testable import CairnUI

@Suite struct CommandBarTests {
    @Test func searchesTitlesHostsSpacesAndFavorites() {
        let tab = TabItem(url: URL(string: "https://swift.org/documentation"), title: "The Swift Book")
        let favorite = TabItem(url: URL(string: "https://example.com"), title: "Reference")
        let archived = TabItem(title: "Hidden archive")
        let workspace = Workspace(spaces: [Space(name: "Learning", tabs: [tab], archive: [archived])], favorites: [favorite])
        for query in ["swift", "SWIFT.ORG", "Learning Swift"] {
            let matches = CommandBarSearch.matches(query: query, workspace: workspace, commands: [])
            #expect(matches.contains { $0.id == "tab:\(tab.id)" })
        }
        #expect(CommandBarSearch.matches(query: "Reference", workspace: workspace, commands: []).first?.id == "tab:\(favorite.id)")
        #expect(!CommandBarSearch.matches(query: "", workspace: workspace, commands: []).contains { $0.id == "tab:\(archived.id)" })
    }

    @Test func commandPrefixExcludesTabsAndNavigation() {
        let workspace = Workspace(spaces: [Space(name: "Home", tabs: [TabItem(title: "Zoom article")])])
        let commands = [Command(id: "zoom", title: "Zoom In", keywords: ["enlarge", "bigger"], perform: { _ in })]
        let matches = CommandBarSearch.matches(query: "> enlarge", workspace: workspace, commands: commands)
        #expect(matches.count == 1)
        #expect(matches.first?.id == "command:zoom")
    }

    @Test func navigationAlwaysRemainsReachableAfterResultLimit() {
        let tabs = (0..<100).map { TabItem(title: "Swift \($0)") }
        let workspace = Workspace(spaces: [Space(name: "Home", tabs: tabs)])
        let matches = CommandBarSearch.matches(query: "Swift", workspace: workspace, commands: [])
        #expect(matches.count == 60)
        #expect(matches.last?.id == "navigate")
        let empty = CommandBarSearch.matches(query: "   ", workspace: .makeDefault(), commands: [])
        #expect(empty.isEmpty)
    }

    @Test func keyboardSelectionWrapsAndHandlesEmptyResults() {
        #expect(CommandBarSearch.nextSelection(0, delta: -1, count: 3) == 2)
        #expect(CommandBarSearch.nextSelection(2, delta: 1, count: 3) == 0)
        #expect(CommandBarSearch.nextSelection(0, delta: 1, count: 0) == 0)
        #expect(CommandBarSearch.nextSelection(0, delta: -10, count: 3) == 2)
    }
}

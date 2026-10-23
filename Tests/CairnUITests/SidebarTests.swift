import SwiftUI
import Testing
import CairnCore
@testable import CairnUI

@Suite @MainActor struct SidebarTests {
    @Test func themeColoursRoundTripThroughHex() {
        for hex in ["#527B72", "#000000", "#FFFFFF", "#7C5CFF"] {
            #expect(Color(cairnHex: hex).cairnHexString == hex)
        }
    }

    @Test func accessoryRegistryOrdersReplacesAndFilters() {
        let registry = TabRowAccessoryRegistry()
        let tab = TabItem(url: URL(string: "https://example.com"))
        registry.register(id: "a", placement: .trailing) { _ in AnyView(Text("a")) }
        registry.register(id: "b", placement: .leading) { _ in AnyView(Text("b")) }
        registry.register(id: "c", placement: .trailing) { _ in nil }
        #expect(registry.accessories(for: tab, placement: .trailing).count == 1)
        #expect(registry.accessories(for: tab, placement: .leading).count == 1)
        registry.register(id: "c", placement: .trailing) { _ in AnyView(Text("c")) }
        #expect(registry.accessories(for: tab, placement: .trailing).count == 2)
        registry.unregister(id: "a")
        #expect(registry.accessories(for: tab, placement: .trailing).count == 1)
    }

    @Test func dropIndexAdjustsForSameListMoves() {
        let a = TabLocation(list: .pinned, spaceIndex: 0, index: 1)
        let b = TabLocation(list: .pinned, spaceIndex: 0, index: 3)
        #expect(TabDrop.insertionIndex(source: a, target: b) == 2)
        #expect(TabDrop.insertionIndex(source: b, target: a) == 1)
    }
}

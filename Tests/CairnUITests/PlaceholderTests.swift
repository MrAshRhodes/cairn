import Testing
@testable import CairnUI

@Suite struct UIPlaceholderTests {
    @Test func typesExist() {
        _ = PreferencesView.self
        _ = SidebarView.self
        _ = CommandBarView.self
    }
}

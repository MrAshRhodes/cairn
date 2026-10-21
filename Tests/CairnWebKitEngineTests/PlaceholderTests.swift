import Testing
@testable import CairnWebKitEngine
import CairnEngineKit

@Suite struct WebKitEnginePlaceholderTests {
    @Test func kindIsWebKit() {
        #expect(WebKitEngineModule.kind == .webkit)
    }
}

import Testing
@testable import CairnModules

@Suite struct ModuleRegistryPlaceholderTests {
    @Test @MainActor func registryStartsEmpty() {
        #expect(ModuleRegistry().modules.isEmpty)
    }
}

import Testing
import Foundation
@testable import CairnCore

@Suite struct URLResolverTests {
    @Test func resolvesExplicitURL() {
        #expect(URLResolver.resolve("https://example.com/a")?.absoluteString == "https://example.com/a")
    }
    @Test func resolvesBareHost() {
        #expect(URLResolver.resolve("example.com")?.absoluteString == "https://example.com")
    }
    @Test func fallsBackToSearch() {
        let url = URLResolver.resolve("swift concurrency")
        #expect(url?.host == "duckduckgo.com")
        #expect(url?.absoluteString.contains("swift%20concurrency") == true)
    }
    @Test func emptyInputIsNil() {
        #expect(URLResolver.resolve("   ") == nil)
    }
}

@Suite struct WorkspaceTests {
    @Test func defaultWorkspaceHasOneSpace() {
        let ws = Workspace.makeDefault()
        #expect(ws.spaces.count == 1)
        #expect(ws.selectedSpaceID == ws.spaces[0].id)
    }
    @Test func workspaceRoundTripsThroughJSON() throws {
        let ws = Workspace.makeDefault()
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back.spaces == ws.spaces)
    }
}

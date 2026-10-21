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
    @Test(arguments: ["cats & dogs", "tag #swift", "a+b", "100% good", "你好 & cafés"])
    func preservesLiteralSearchQuery(input: String) throws {
        let url = try #require(URLResolver.resolve(input))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == input)
        #expect(components.fragment == nil)
        #expect(url.absoluteString.contains("+") == false)
    }
    @Test(arguments: ["javascript:alert(1)", "data:text/html,hello", "https:///missing", "https://bad..host/",
                      "https://-bad.example/", "https://example.com:99999/", "https://user:secret@example.com/",
                      "about:config", "ftp://example.com/file", "https://[bad", "https://999.999.999.999"])
    func rejectsUnsafeOrMalformedNavigation(input: String) {
        #expect(URLResolver.resolve(input) == nil)
    }
    @Test func supportsLocalDevelopmentAndBlankPage() {
        #expect(URLResolver.resolve("localhost:8080/test")?.absoluteString == "http://localhost:8080/test")
        #expect(URLResolver.resolve("example.com:8080")?.host == "example.com")
        #expect(URLResolver.resolve("about:blank")?.absoluteString == "about:blank")
        #expect(URLResolver.resolve("file:///Users/example/readme.txt")?.isFileURL == true)
        #expect(URLResolver.resolve("localhost evil")?.host == "duckduckgo.com")
        #expect(URLResolver.resolve("https://bücher.de")?.host == "xn--bcher-kva.de")
        #expect(URLResolver.resolve("bücher.de")?.host == "xn--bcher-kva.de")
        #expect(URLResolver.resolve("https://[::1]:8080")?.host == "::1")
    }
    @Test(arguments: ["https://example.com/", "https://%s.example.com/?q=test", "https://example.com/%s",
                      "https://example.com/?q=%s#fragment", "https://example.com/?a=%s&b=%s", "javascript:%s"])
    func rejectsInvalidSearchTemplates(template: String) {
        #expect(!URLResolver.isValidSearchTemplate(template))
        #expect(URLResolver.resolve("search words", searchTemplate: template) == nil)
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

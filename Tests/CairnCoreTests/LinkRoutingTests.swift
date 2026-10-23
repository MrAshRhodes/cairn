import Foundation
import Testing
@testable import CairnCore

@Suite struct LinkRoutingTests {
    let a = UUID(), b = UUID()

    @Test func firstMatchWinsAndDefaultApplies() throws {
        let rules = [LinkRule(match: .contains, text: "github.com", destination: .space(a)),
                     LinkRule(match: .contains, text: "github", destination: .space(b))]
        let url = try #require(URL(string: "https://GitHub.com/x"))
        #expect(LinkRouter.destination(for: url, rules: rules, default: .mostRecent) == .space(a))
        let other = try #require(URL(string: "https://example.com"))
        #expect(LinkRouter.destination(for: other, rules: rules, default: .quickWindow) == .quickWindow)
    }

    @Test func equalsMatchesWholeURLAndEmptyTextNeverMatches() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(LinkRule(match: .equals, text: "https://example.com/a", destination: .mostRecent).matches(url))
        #expect(!LinkRule(match: .equals, text: "example.com", destination: .mostRecent).matches(url))
        #expect(!LinkRule(text: "  ", destination: .mostRecent).matches(url))
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "about:blank", "ftp://example.com"])
    func nonWebURLsAreNotRouted(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(LinkRouter.destination(for: url, rules: [], default: .mostRecent) == nil)
    }

    @Test func pruningRemovesDeletedSpaces() {
        let rules = [LinkRule(text: "x", destination: .space(a)), LinkRule(text: "y", destination: .space(b)), LinkRule(text: "z", destination: .quickWindow)]
        let result = LinkRouter.pruned(rules: rules, default: .space(a), spaceIDs: [b])
        #expect(result.rules.map(\.text) == ["y", "z"])
        #expect(result.default == .mostRecent)
    }

    @Test func explicitDecisionsNameUnavailableDestinationsWithoutSkippingTheFirstRule() throws {
        let url = try #require(URL(string: "https://example.com"))
        let rules = [LinkRule(text: "example", destination: .space(b)),
                     LinkRule(text: "example", destination: .space(a))]
        let missing = try #require(LinkRouter.decision(for: url, rules: rules, default: .mostRecent,
                                                      spaceIDs: [a], mostRecentSpaceID: a))
        #expect(missing.spaceID == a && missing.fallback == .deletedSpace(b))
        let quick = try #require(LinkRouter.decision(for: url, rules: [], default: .quickWindow,
                                                    spaceIDs: [a, b], mostRecentSpaceID: b))
        #expect(quick.spaceID == b && quick.fallback == nil && quick.opensQuickWindow)
        #expect(LinkRouter.decision(for: url, rules: [], default: .mostRecent,
                                   spaceIDs: [a], mostRecentSpaceID: b) == nil)
    }

    @Test func peekPolicy() throws {
        func decide(_ from: String, _ to: String, pinned: Bool = true, enabled: Bool = true) throws -> PeekPolicy.Decision {
            PeekPolicy.decide(from: URL(string: from), to: try #require(URL(string: to)), sourceIsPinnedOrFavorite: pinned, enabled: enabled)
        }
        #expect(try decide("https://example.com", "https://other.test/x") == .peek)
        #expect(try decide("https://www.example.com", "https://docs.example.com") == .navigateNormally)
        #expect(try decide("https://a.example.co.uk", "https://b.example.co.uk") == .navigateNormally)
        #expect(try decide("https://example.co.uk", "https://other.co.uk") == .peek)
        #expect(try decide("https://example.com", "https://other.test", pinned: false) == .navigateNormally)
        #expect(try decide("https://example.com", "https://other.test", enabled: false) == .navigateNormally)
        #expect(try decide("https://example.com", "https://accounts.google.com/signin") == .navigateNormally)
        #expect(try decide("https://example.com", "https://other.test/oauth/authorize?x=1") == .navigateNormally)
        #expect(try decide("https://example.com", "https://checkout.stripe.com/pay") == .navigateNormally)
        #expect(try decide("https://example.com", "mailto:a@b.c") == .navigateNormally)
    }

    @MainActor @Test func unattachedPeekStateCannotPretendToTransferAPage() throws {
        let model = BrowserModel(engine: StubEngine())
        var state = PeekState()
        let url = try #require(URL(string: "https://other.test"))
        state.open(url, in: model.selectedSpace.id)
        #expect(state.isOpen)
        #expect(state.expand(in: model) == nil)
        #expect(model.selectedSpace.tabs.isEmpty)
        state.close()
        let again = state.expand(in: model)
        #expect(again == nil)
    }
}

@Suite struct LinkRuleStoreTests {
    @Test func roundTripAndPrune() throws {
        let dir = try TestDirectory()
        let file = dir.url.appendingPathComponent("link-rules.json")
        let a = UUID()
        let store = LinkRuleStore(url: file)
        store.load()
        try store.update(rules: [LinkRule(text: "x", destination: .space(a))], defaultDestination: .space(a), peekEnabled: false)
        let reloaded = LinkRuleStore(url: file); reloaded.load()
        #expect(reloaded.rules.count == 1 && reloaded.defaultDestination == .space(a) && !reloaded.peekEnabled)
        try reloaded.prune(validSpaceIDs: [])
        #expect(reloaded.rules.isEmpty && reloaded.defaultDestination == .mostRecent)
    }

    @Test func corruptFileIsMovedAsideWithANotice() throws {
        let dir = try TestDirectory()
        let file = dir.url.appendingPathComponent("link-rules.json")
        try Data("{nope".utf8).write(to: file)
        let store = LinkRuleStore(url: file); store.load()
        #expect(store.notice != nil && store.isWritable && store.rules.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names.contains { $0.hasPrefix("link-rules.corrupt-") } && !names.contains("link-rules.json"))
    }

    @Test func newerSchemaIsPreservedAndReadOnly() throws {
        let dir = try TestDirectory()
        let file = dir.url.appendingPathComponent("link-rules.json")
        let original = Data(#"{"schemaVersion":9,"defaultDestination":{"mostRecent":{}},"rules":[]}"#.utf8)
        try original.write(to: file)
        let store = LinkRuleStore(url: file); store.load()
        #expect(store.loadError != nil && !store.isWritable)
        #expect(throws: ServiceError.self) { try store.update(rules: [], defaultDestination: .mostRecent, peekEnabled: true) }
        #expect(try Data(contentsOf: file) == original)
    }
}

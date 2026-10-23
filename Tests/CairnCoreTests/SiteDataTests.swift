import Foundation
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class SiteDataEngine: BrowserEngine, EngineSiteDataManaging {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var deleted: [String] = []
    var blockedRequestCount = 0
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { preconditionFailure("no tabs expected") }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
    func clearSiteData(profileID: String, site: String?, kinds: SiteDataKinds) async -> SiteDataClearResult { .init() }
    func deleteProfileData(profileID: String) async { deleted.append(profileID) }
    func removeOrphanProfiles(keeping profileIDs: Set<String>) -> [String] { [] }
    func configureContentBlocking(_ configuration: ContentBlockingConfiguration) {}
}

@Suite @MainActor struct SiteDataTests {
    @Test func removingASpaceDeletesItsProfile() async throws {
        let engine = SiteDataEngine()
        let keep = Space(name: "Keep", profileID: "keep")
        let drop = Space(name: "Drop", profileID: "drop")
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [keep, drop]))
        model.removeSpace(drop.id)
        try await eventually { engine.deleted == ["drop"] }
    }

    @Test func aSharedProfileSurvivesRemovingOneSpace() async throws {
        let engine = SiteDataEngine()
        let first = Space(name: "One", profileID: "shared")
        let second = Space(name: "Two", profileID: "shared")
        let model = BrowserModel(engine: engine, workspace: Workspace(spaces: [first, second]))
        model.removeSpace(second.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.deleted.isEmpty)
    }

    @Test func blocklistParsingAcceptsHostsFilesAndDomainRulesOnly() {
        let text = """
        # comment
        ! comment
        [Adblock Plus 2.0]
        0.0.0.0 Tracker.Example.com
        127.0.0.1 localhost
        0.0.0.0 0.0.0.0
        ||ads.example.net^
        ||ads.example.net^$third-party
        ||example.org/banner^
        @@||allowed.example.com^
        ##.banner
        plain.example.io # trailing comment
        10.0.0.1
        bad host.com
        tracker.example.com
        com
        """
        #expect(ContentBlocklist.parse(text) == ["tracker.example.com", "ads.example.net", "plain.example.io"])
    }

    @Test func storeRoundTripsAndKeepsUnreadableFiles() throws {
        let directory = try TestDirectory()
        let url = directory.file("content-blocking.json")
        let store = ContentBlockingStore()
        #expect(try store.importList("0.0.0.0 a.example.com\nb.example.com\n", name: "list.txt") == 2)
        store.setEnabled(true)
        store.setBlocking(false, on: "News.Example.com")
        try store.save(to: url)
        let loaded = try ContentBlockingStore.load(from: url)
        #expect(loaded.configuration == ContentBlockingConfiguration(
            isEnabled: true, blockedHosts: ["a.example.com", "b.example.com"], exemptSites: ["news.example.com"]))
        #expect(!loaded.isBlocking(on: "news.example.com"))
        #expect(loaded.isBlocking(on: "other.example.com"))
        loaded.setBlocking(true, on: "news.example.com")
        #expect(loaded.exemptSites.isEmpty)

        try Data("{\"schemaVersion\": 99}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.save(to: url) }
        #expect(throws: (any Error).self) { _ = try ContentBlockingStore.load(from: url) }
    }

    @Test func importingAnEmptyListKeepsTheCurrentOne() throws {
        let store = ContentBlockingStore()
        try store.importList("a.example.com", name: "a.txt")
        #expect(throws: (any Error).self) { try store.importList("# nothing", name: "b.txt") }
        #expect(store.blockedHosts == ["a.example.com"] && store.listName == "a.txt")
    }
}

import Foundation
import Testing
@testable import CairnCore

@Suite @MainActor struct ImportSupportTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func importedSpaceGetsItsOwnProfileFoldersAndNoLiveTabs() throws {
        let m = BrowserModel(engine: StubEngine())
        let home = m.selectedSpace
        try m.importSpaces([.init(name: "Imported from Chrome", pins: [
            .init(title: "A", url: url("https://a.example/"), folderPath: ["Work", "Docs"]),
            .init(title: "B", url: url("https://b.example/"), folderPath: ["Work"]),
            .init(title: "C", url: url("https://c.example/")),
        ])])
        let space = try #require(m.workspace.spaces.first { $0.name == "Imported from Chrome" })
        #expect(space.profileID != home.profileID)
        #expect(space.pinned.count == 3 && space.folders?.count == 2)
        #expect(m.folderDepth(try #require(space.folders?.last?.id)) == 2)
        #expect(space.pinned.allSatisfy { $0.homeURL == $0.url })
        #expect(m.liveTabs.isEmpty)
        #expect(m.workspace.spaces.first { $0.id == home.id } == home)
        #expect(m.pinnedIdentities(inSpaceNamed: space.name) { "\($0.joined(separator: "/"))|\($1.host ?? "")" }
                == ["Work/Docs|a.example", "Work|b.example", "|c.example"])
    }

    @Test func appendingToAnExistingSpaceReusesFoldersAndKeepsOldPins() throws {
        let m = BrowserModel(engine: StubEngine())
        let first = BrowserModel.SpaceImport(name: "Imp", pins: [.init(title: "A", url: url("https://a.example/"), folderPath: ["F"])])
        try m.importSpaces([first])
        var second = BrowserModel.SpaceImport(name: "Imp", pins: [.init(title: "B", url: url("https://b.example/"), folderPath: ["F"])])
        second.appendToExisting = true
        try m.importSpaces([second])
        let space = try #require(m.workspace.spaces.first { $0.name == "Imp" })
        #expect(m.workspace.spaces.filter { $0.name == "Imp" }.count == 1)
        #expect(space.pinned.map(\.title) == ["A", "B"] && space.folders?.count == 1)
    }

    @Test func aFailedImportChangesNothing() {
        let m = BrowserModel(engine: StubEngine())
        let before = m.workspace.spaces
        #expect(throws: (any Error).self) {
            try m.importSpaces([.init(name: "Fine", pins: []), .init(name: "   ", pins: [])])
        }
        #expect(m.workspace.spaces == before)
    }

    @Test func historyBatchIsTransactionalDeduplicatedAndCapped() throws {
        let directory = try TestDirectory()
        let store = try HistoryStore(url: directory.file("h.sqlite"), maximumEntries: 3)
        func entry(_ s: String, _ t: Double) -> HistoryEntry { HistoryEntry(url: url(s), title: s, visitedAt: Date(timeIntervalSince1970: t)) }
        let batch = [entry("https://a.example/", 1), entry("https://b.example/", 2), entry("https://c.example/", 3),
                     entry("https://d.example/", 4), entry("javascript:alert(1)".isEmpty ? "" : "ftp://x.example/", 5)]
        #expect(try store.missing(batch).count == 5)
        #expect(try store.recordBatch(batch) == 3)
        #expect(try store.recent().map(\.title) == ["https://d.example/", "https://c.example/", "https://b.example/"])
        #expect(try store.recordBatch(batch) == 0)
        #expect(try store.recordBatch([]) == 0)
    }
}

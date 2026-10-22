import Foundation
import Testing
@testable import CairnCore

@Suite @MainActor struct SplitStoreTests {
    private func group() -> SplitGroup {
        let a = UUID(), b = UUID()
        return SplitGroup(spaceID: UUID(), layout: SplitLayout(tab: a).adding(b, beside: a, edge: .bottom)!)
    }

    @Test func roundTrips() throws {
        let directory = try TestDirectory()
        let store = SplitStore(directory: directory.url)
        let saved = [group()]
        try store.saveNow(saved)
        let loaded = store.load()
        #expect(loaded.groups == saved && loaded.error == nil)
    }

    @Test func missingFileIsEmptyAndNothingIsWrittenForNoGroups() throws {
        let directory = try TestDirectory()
        let store = SplitStore(directory: directory.url)
        #expect(store.load().groups.isEmpty)
        try store.saveNow([])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test(arguments: ["{ not json", #"{"schemaVersion":99,"groups":[]}"#])
    func corruptOrNewerFilesAreMovedAsideNotOverwritten(contents: String) throws {
        let directory = try TestDirectory()
        let store = SplitStore(directory: directory.url)
        try Data(contents.utf8).write(to: store.fileURL)
        let loaded = store.load()
        #expect(loaded.groups.isEmpty && loaded.error != nil)
        let moved = try #require(loaded.quarantinedTo)
        #expect(try String(contentsOf: moved, encoding: .utf8) == contents)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func debouncedSaveIsFlushed() async throws {
        let directory = try TestDirectory()
        let store = SplitStore(directory: directory.url, debounce: .seconds(60))
        let saved = [group()]
        store.scheduleSave(saved)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.flush()
        #expect(store.load().groups == saved)
    }
}

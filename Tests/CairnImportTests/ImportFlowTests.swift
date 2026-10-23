import Foundation
import Testing
import CairnCore
@testable import CairnImport

@Suite @MainActor struct ImportFlowTests {
    private func plan(_ spaces: [PlannedSpace], history: [ImportedHistoryEntry] = []) -> ImportPlan {
        ImportPlan(sourceName: "T", spaces: spaces, history: history, skipped: [:])
    }
    private func bookmark(_ title: String, _ url: String, _ path: [String] = []) -> ImportedBookmark {
        ImportedBookmark(title: title, url: URL(string: url)!, folderPath: path)
    }

    @Test func nothingIsReadBeforeConsent() throws {
        let scratch = try ImportScratch()
        _ = try scratch.write("{}", as: "Google/Chrome/Default/Bookmarks")
        let fs = RecordingFileSystem()
        let sources = ImportSourceDiscovery.discover(fileSystem: fs, applicationSupport: scratch.url)
        #expect(sources.map(\.name) == ["Google Chrome — Default"])
        #expect(fs.reads.isEmpty)
        #expect(fs.all.allSatisfy { $0.hasPrefix("exists") })
        _ = try ImportSourceDiscovery.chosen(scratch.file("x.html"), fileSystem: fs)
        #expect(fs.reads.isEmpty)
        #expect(throws: ImportError.self) { try ImportSourceDiscovery.chosen(scratch.file("x.txt"), fileSystem: fs) }
    }

    @Test func scanningOnlyOpensAllowListedFilesOfTheConsentedSource() async throws {
        let scratch = try ImportScratch()
        _ = try scratch.write(#"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"A","url":"https://a.example/"}]}}}"#,
                              as: "Default/Bookmarks")
        _ = try scratch.write("secret", as: "Default/Login Data")
        _ = try scratch.write("secret", as: "Default/Cookies")
        let fs = RecordingFileSystem()
        let source = ImportSource(id: "t", name: "T", browser: "Chrome", format: .chromiumProfile, location: scratch.file("Default"))
        let scanner = ImportScanner(fileSystem: fs, staging: ImportStaging(root: scratch.file("Staging"), fileSystem: fs))
        let plan = try await scanner.scan(ImportConsent(source: source, options: ImportOptions()))
        #expect(plan.spaces.first?.bookmarks.count == 1)
        #expect(fs.reads == ["read \(scratch.file("Default/Bookmarks").path)"])
        #expect(!fs.all.contains { $0.contains("Login Data") || $0.contains("Cookies") || $0.contains("Local State") })
    }

    @Test func netscapeAndJSONSourcesScanThroughTheFileSystem() async throws {
        let scratch = try ImportScratch()
        let html = try scratch.write(#"<DL><DT><A HREF="https://a.example/">A</A></DL>"#, as: "b.html")
        let json = try scratch.write(#"{"spaces":[{"name":"S","pinned":[{"title":"X","url":"https://x.example/"}]}],"history":[{"url":"https://x.example/","title":"X","lastVisit":1700000000}]}"#,
                                     as: "c.json")
        let scanner = ImportScanner(staging: ImportStaging(root: scratch.file("Staging")))
        let htmlPlan = try await scanner.scan(ImportConsent(source: ImportSourceDiscovery.chosen(html), options: ImportOptions()))
        #expect(htmlPlan.spaces.first?.name == "Imported from Bookmarks file")
        let jsonPlan = try await scanner.scan(ImportConsent(source: ImportSourceDiscovery.chosen(json), options: ImportOptions(bookmarks: true, history: true)))
        #expect(jsonPlan.spaces.first?.name == "S" && jsonPlan.history.count == 1)
    }

    @Test func dryRunCountsEqualAppliedCountsAndReimportIsIdempotent() throws {
        let sink = FakeSink()
        let entries = [ImportedHistoryEntry(url: URL(string: "https://h.example/")!, title: "H", lastVisit: Date(timeIntervalSince1970: 1_700_000_000))]
        let p = plan([PlannedSpace(name: "Imported from Chrome", bookmarks: [
            bookmark("A", "https://a.example/", ["F"]), bookmark("A again", "https://A.example", ["F"]),
            bookmark("B", "https://b.example/", ["F", "G"]), bookmark("C", "https://c.example/"),
        ])], history: entries)
        let preview = try ImportApplier.preview(p, sink: sink)
        #expect(preview.bookmarkCount == 3 && preview.folderCount == 2 && preview.historyCount == 1)
        #expect(preview.skipped[.duplicate] == 1)
        #expect(sink.committed.isEmpty && sink.history.isEmpty)

        let result = try ImportApplier.apply(preview, to: sink)
        #expect(result.bookmarksAdded == preview.bookmarkCount && result.foldersAdded == preview.folderCount)
        #expect(result.historyAdded == preview.historyCount)
        #expect(sink.committed.flatMap(\.pins).count == 3)

        let again = try ImportApplier.preview(p, sink: sink)
        #expect(again.bookmarkCount == 0 && again.historyCount == 0 && again.isEmpty)
        #expect(again.skipped[.duplicate] == 5)
        let second = try ImportApplier.apply(again, to: sink)
        #expect(second.bookmarksAdded == 0 && sink.committed.flatMap(\.pins).count == 3 && sink.history.count == 1)
    }

    @Test func cancellationLeavesNothingBehind() throws {
        let sink = FakeSink()
        let preview = try ImportApplier.preview(plan([PlannedSpace(name: "S", bookmarks: [bookmark("A", "https://a.example/")])]), sink: sink)
        #expect(throws: CancellationError.self) { try ImportApplier.apply(preview, to: sink, isCancelled: { true }) }
        #expect(sink.commitCalls == 0 && sink.spaces.isEmpty && sink.history.isEmpty)
    }

    @Test func newPinsInExistingFoldersDoNotCountAsNewFolders() throws {
        let sink = FakeSink()
        let first = plan([PlannedSpace(name: "Imported from Firefox", bookmarks: [bookmark("A", "https://a.example/", ["F"])])])
        _ = try ImportApplier.apply(ImportApplier.preview(first, sink: sink), to: sink)
        let second = plan([PlannedSpace(name: "Imported from Firefox", bookmarks: [bookmark("B", "https://b.example/", ["F"])])])
        let preview = try ImportApplier.preview(second, sink: sink)
        #expect(preview.bookmarkCount == 1 && preview.folderCount == 0)
    }

    @Test func cancelledScanThrowsCancellationAndCleansStaging() async throws {
        let scratch = try ImportScratch()
        try FileManager.default.createDirectory(at: scratch.file("Default"), withIntermediateDirectories: true)
        _ = try makeHistoryDatabase(at: scratch.file("Default/History"), rows: [("https://e.example/", "E", chromiumTime(1_700_000_000), 0)], keepOpen: false)
        let source = ImportSource(id: "t", name: "T", browser: "Chrome", format: .chromiumProfile, location: scratch.file("Default"))
        let scanner = ImportScanner(staging: ImportStaging(root: scratch.file("Staging")))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scanner.scan(ImportConsent(source: source, options: ImportOptions(bookmarks: false, history: true)))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func stagingIsPrivateAllowListedAndSweepable() throws {
        let scratch = try ImportScratch()
        _ = try scratch.write("db", as: "Profile/History")
        _ = try scratch.write("secret", as: "Profile/Cookies")
        let staging = ImportStaging(root: scratch.file("Staging"))
        let directory = try staging.stage(["History", "History-wal"], from: scratch.file("Profile"))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["History"])
        #expect(throws: ImportError.self) { try staging.stage(["Cookies"], from: scratch.file("Profile")) }
        try staging.sweep()
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func capabilityCheckFlattensFoldersWhenUnsupported() throws {
        let sink = FakeSink()
        sink.supportsFolders = false
        let preview = try ImportApplier.preview(plan([PlannedSpace(name: "S", bookmarks: [bookmark("A", "https://a.example/", ["F", "G"])])]), sink: sink)
        #expect(preview.spaces[0].pins[0].title == "F / G / A" && preview.spaces[0].pins[0].folderPath.isEmpty)
        #expect(preview.folderCount == 0)
    }

    @Test func deepFolderPathsFoldIntoTheDepthLimit() throws {
        let sink = FakeSink()
        let preview = try ImportApplier.preview(plan([PlannedSpace(name: "S", bookmarks: [
            bookmark("A", "https://a.example/", ["1", "2", "3", "4", "5"])])]), sink: sink)
        #expect(preview.spaces[0].pins[0].folderPath == ["1", "2", "3 / 4 / 5"])
    }
}

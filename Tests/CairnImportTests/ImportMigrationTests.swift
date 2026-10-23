import Foundation
import Testing
@testable import CairnImport

@Suite struct ImportMigrationTests {
    @Test @MainActor func HTMLFoldersMapIntoMultipleSpacesAndReuseDedupe() async throws {
        let scratch = try ImportScratch()
        let plan = try await scannedHTML(scratch)
        let groups = ImportMigration.groups(in: plan)
        #expect(groups.map(\.topLevelFolder) == ["Work", "Personal", nil])
        var mappings = groups.map { MigrationMapping(group: $0) }
        mappings[2].destinationName = "Work"
        let mapped = try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: [])
        #expect(mapped.spaces.map(\.name) == ["Work", "Personal"])
        #expect(mapped.spaces[0].bookmarks.map(\.folderPath) == [["Reference"], ["Reference"], []])
        let sink = FakeSink()
        let preview = try ImportApplier.preview(mapped, sink: sink)
        #expect(preview.bookmarkCount == 3 && preview.folderCount == 1 && preview.skipped[.duplicate] == 1)
        #expect(sink.committed.isEmpty)
        #expect(throws: CancellationError.self) { try ImportApplier.apply(preview, to: sink, isCancelled: { true }) }
        sink.failCommit = true
        #expect(throws: ImportError.self) { try ImportApplier.apply(preview, to: sink) }
        #expect(sink.committed.isEmpty && sink.history.isEmpty)
        sink.failCommit = false
        _ = try ImportApplier.apply(preview, to: sink)
        for index in mappings.indices { mappings[index].conflict = .append }
        let repeated = try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: ["Work", "Personal"])
        #expect(try ImportApplier.preview(repeated, sink: sink).isEmpty)
    }

    @Test func existingDestinationsRequireExplicitUnambiguousAppend() async throws {
        let scratch = try ImportScratch()
        let plan = try await scannedHTML(scratch)
        var mappings = ImportMigration.groups(in: plan).map { MigrationMapping(group: $0) }
        #expect(throws: ImportError.self) {
            try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: ["Work"])
        }
        mappings[0].conflict = .append
        #expect(throws: ImportError.self) {
            try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: [])
        }
        #expect(throws: ImportError.self) {
            try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: ["Work", "Work"])
        }
        _ = try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: ["Work"])
    }

    @Test func skippedGroupsAndFolderRetentionArePreviewed() async throws {
        let scratch = try ImportScratch()
        let plan = try await scannedHTML(scratch)
        var mappings = ImportMigration.groups(in: plan).map { MigrationMapping(group: $0) }
        mappings[0].keepTopLevelFolder = true
        mappings[1].conflict = .skip
        mappings[2].conflict = .skip
        let result = try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: [])
        #expect(result.spaces.count == 1 && result.spaces[0].bookmarks[0].folderPath == ["Work", "Reference"])
        #expect(result.skipped[.userExcluded] == 2)
    }

    @Test func portableNamesThemesAndHistoryRoundTripThroughSchema() throws {
        let parsed = try CairnImportV1.parse(Data("""
            {"format":"cairn-import-v1","spaces":[
              {"name":"研究","icon":"book","colorHex":"#527B72","pinned":[
                {"title":"資料","url":"https://example.org/","folder":["Team","Reference"]}]},
              {"name":"Personal","pinned":[{"url":"https://example.com/","title":"Home"}]}],
             "history":[{"url":"https://example.org/","title":"Visited","lastVisit":1700000000.25}]}
            """.utf8))
        let plan = ImportPlan(sourceName: "Portable", spaces: parsed.spaces.map {
            PlannedSpace(name: $0.name, icon: $0.icon, colorHex: $0.colorHex, bookmarks: $0.bookmarks)
        }, history: parsed.history, skipped: parsed.skipped)
        let mappings = ImportMigration.groups(in: plan).map { MigrationMapping(group: $0, preserveSourceSpace: true) }
        let result = try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: [])
        #expect(result.spaces.map(\.name) == ["研究", "Personal"])
        #expect(result.spaces[0].icon == "book" && result.spaces[0].colorHex == "#527B72")
        #expect(result.spaces[0].bookmarks[0].folderPath == ["Team", "Reference"])
        #expect(result.history == plan.history)
    }

    @Test func invalidOrMissingMappingsAndCancellationFailBeforeApply() async throws {
        let scratch = try ImportScratch()
        let plan = try await scannedHTML(scratch)
        var mappings = ImportMigration.groups(in: plan).map { MigrationMapping(group: $0) }
        #expect(throws: ImportError.self) { try ImportMigration.plan(from: plan, mappings: [], existingSpaceNames: []) }
        var duplicate = mappings
        duplicate[1] = duplicate[0]
        #expect(throws: ImportError.self) { try ImportMigration.plan(from: plan, mappings: duplicate, existingSpaceNames: []) }
        for invalid in [" ", String(repeating: "x", count: 257), "Name\u{1F}"] {
            mappings[0].destinationName = invalid
            #expect(throws: ImportError.self) { try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: []) }
        }
        #expect(throws: CancellationError.self) {
            try ImportMigration.plan(from: plan, mappings: mappings, existingSpaceNames: [], isCancelled: { true })
        }
    }

    @Test func unknownExportFolderIsNotSilentlyTreatedAsEmptyChromium() throws {
        let scratch = try ImportScratch()
        _ = try scratch.write("not opened", as: "Passwords.csv")
        let fs = RecordingFileSystem()
        #expect(throws: ImportError.self) { try ImportSourceDiscovery.chosen(scratch.url, fileSystem: fs) }
        #expect(fs.reads.isEmpty)
    }

    private func scannedHTML(_ scratch: ImportScratch) async throws -> ImportPlan {
        let url = try scratch.write("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <DL><DT><H3>Work</H3><DL><DT><H3>Reference</H3><DL>
              <DT><A HREF="https://docs.example/">Docs</A>
              <DT><A HREF="https://docs.example/">Duplicate</A>
            </DL></DL><DT><H3>Personal</H3><DL><DT><A HREF="https://home.example/">Home</A></DL>
              <DT><A HREF="https://unfiled.example/">Unfiled</A>
            </DL>
            """, as: "portable.html")
        return try await ImportScanner(staging: ImportStaging(root: scratch.file("Staging")))
            .scan(ImportConsent(source: ImportSourceDiscovery.chosen(url), options: ImportOptions()))
    }
}

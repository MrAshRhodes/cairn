import Foundation
import SQLite3
import Testing
@testable import CairnImport

@Suite struct ImportParsingTests {
    @Test func chromiumBookmarksKeepNestedUnicodeFoldersAndCountSkips() throws {
        let json = """
        {"roots":{
          "bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
            {"type":"url","name":"Swift","url":"https://swift.org/"},
            {"type":"folder","name":"Работа 📁","children":[
              {"type":"url","name":"日本語","url":"https://example.jp/パス"},
              {"type":"folder","name":"Deep","children":[{"type":"url","name":"Deeper","url":"http://example.com/a"}]}
            ]},
            {"type":"url","name":"Bookmarklet","url":"javascript:alert(1)"},
            {"type":"url","name":"Chrome page","url":"chrome://settings"},
            {"type":"url","name":"Local","url":"file:///etc/passwd"},
            {"type":"url","name":"Creds","url":"https://user:pw@example.com/"}
          ]},
          "other":{"type":"folder","name":"Other bookmarks","children":[{"type":"url","name":"","url":"https://example.org/x"}]},
          "synced":{"type":"folder","name":"Mobile bookmarks","children":[]}
        }}
        """
        let result = try ChromiumBookmarks.parse(Data(json.utf8))
        #expect(result.bookmarks.count == 4)
        #expect(result.bookmarks[0].folderPath == [])
        #expect(result.bookmarks[1].folderPath == ["Работа 📁"] && result.bookmarks[1].title == "日本語")
        #expect(result.bookmarks[2].folderPath == ["Работа 📁", "Deep"])
        #expect(result.bookmarks[3].folderPath == ["Other Bookmarks"] && result.bookmarks[3].title == "example.org")
        #expect(result.skipped[.unsupportedScheme] == 3)
        #expect(result.skipped[.invalidURL] == 1)
    }

    @Test(arguments: ["", "[]", "{\"roots\": 5}", "not json"])
    func malformedChromiumBookmarksAreRejected(text: String) {
        #expect(throws: ImportError.self) { try ChromiumBookmarks.parse(Data(text.utf8)) }
    }

    @Test func netscapeHTMLFromSeveralBrowsers() throws {
        let firefox = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
        <DT><H3 ADD_DATE="1" LAST_MODIFIED="2">Mozilla &amp; Friends</H3>
        <DL><p>
            <DT><A HREF="https://www.mozilla.org/" ADD_DATE="3" ICON="data:image/png;base64,AAAA">Mozilla &quot;Home&quot;</A>
            <DT><H3>Sub</H3>
            <DL><p><DT><A HREF="https://example.com/?a=1&amp;b=2">Query</A></DL><p>
        </DL><p>
        <DT><A HREF="javascript:void(0)">Bookmarklet</A>
        <DT><A HREF='https://single.example/'>Single &#x41; quoted</A>
        </DL><p>
        """
        let result = try NetscapeHTML.parse(Data(firefox.utf8))
        #expect(result.bookmarks.map(\.title) == ["Mozilla \"Home\"", "Query", "Single A quoted"])
        #expect(result.bookmarks[0].folderPath == ["Mozilla & Friends"])
        #expect(result.bookmarks[1].folderPath == ["Mozilla & Friends", "Sub"])
        #expect(result.bookmarks[1].url.absoluteString == "https://example.com/?a=1&b=2")
        #expect(result.bookmarks[2].folderPath == [])
        #expect(result.skipped[.unsupportedScheme] == 1)

        let safari = "<html><body><dl><dt><h3>Favorites</h3><dl><dt><a href=\"https://apple.com\">Apple</a></dl></dl></body></html>"
        let parsed = try NetscapeHTML.parse(Data(safari.utf8))
        #expect(parsed.bookmarks.first?.folderPath == ["Favorites"])
        #expect(throws: ImportError.self) { try NetscapeHTML.parse(Data("<html>hello</html>".utf8)) }
    }

    @Test func cairnImportV1ParsesAndRejectsBadInput() throws {
        let json = """
        {"format":"cairn-import-v1","spaces":[{"name":"Work","icon":"briefcase","colorHex":"#112233",
          "pinned":[{"title":"Docs","url":"https://example.com/docs","folder":["Team","Docs"]},{"title":"Bad","url":"data:text/html,x"}]}],
         "history":[{"url":"https://example.com/","title":"Home","lastVisit":1700000000},
                    {"url":"https://example.org/","title":"ISO","lastVisit":"2024-01-02T03:04:05Z"},
                    {"url":"ftp://example.org/","title":"Nope","lastVisit":1700000000}]}
        """
        let result = try CairnImportV1.parse(Data(json.utf8))
        #expect(result.spaces.count == 1 && result.spaces[0].colorHex == "#112233")
        #expect(result.spaces[0].bookmarks.count == 1 && result.spaces[0].bookmarks[0].folderPath == ["Team", "Docs"])
        #expect(result.history.count == 2)
        #expect(result.skipped[.unsupportedScheme] == 2)
        for bad in ["{}", "[]", "{\"format\":\"other\",\"spaces\":[]}", "{\"spaces\":[{\"pinned\":[]}]}"] {
            #expect(throws: ImportError.self) { try CairnImportV1.parse(Data(bad.utf8)) }
        }
    }

    @Test func chromiumTimeConversion() throws {
        #expect(ChromiumHistory.date(fromChromiumMicroseconds: chromiumTime(1_700_000_000)) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(ChromiumHistory.date(fromChromiumMicroseconds: 0) == nil)
        #expect(ChromiumHistory.date(fromChromiumMicroseconds: -5) == nil)
    }

    @Test func historyIsReadFromAStagedCopyIncludingTheWAL() async throws {
        let scratch = try ImportScratch()
        let profile = scratch.file("Profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let now = 1_700_000_000.0
        let db = try makeHistoryDatabase(at: profile.appendingPathComponent("History"), rows: [
            ("https://example.com/old", "Old", chromiumTime(now - 100), 0),
            ("https://example.com/new", "New", chromiumTime(now), 0),
            ("https://example.com/hidden", "Hidden", chromiumTime(now - 5), 1),
            ("chrome://history", "Internal", chromiumTime(now - 6), 0),
            ("https://example.com/it's", "Apostrophe", chromiumTime(now - 7), 0),
        ], keepOpen: true)
        defer { sqlite3_close(db) }
        #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("History-wal").path))

        let staging = ImportStaging(root: scratch.file("Staging"))
        let source = ImportSource(id: "t", name: "T", browser: "Test", format: .chromiumProfile, location: profile)
        let plan = try await ImportScanner(staging: staging)
            .scan(ImportConsent(source: source, options: ImportOptions(bookmarks: false, history: true)))
        #expect(plan.history.map(\.title) == ["New", "Apostrophe", "Old"])
        #expect(plan.history.first?.lastVisit == Date(timeIntervalSince1970: now))
        #expect(plan.skipped[.hidden] == 1 && plan.skipped[.unsupportedScheme] == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.file("Staging").path).isEmpty)
    }

    @Test func historyRowCapStopsTheScan() async throws {
        let scratch = try ImportScratch()
        let rows = (0..<10).map { ("https://example.com/\($0)", "T\($0)", chromiumTime(1_700_000_000 + Double($0)), Int32(0)) }
        _ = try makeHistoryDatabase(at: scratch.file("History"), rows: rows, keepOpen: false)
        let result = try ChromiumHistory.read(databaseAt: scratch.file("History"), limit: 3)
        #expect(result.entries.map(\.title) == ["T9", "T8", "T7"])
    }

    @Test func oversizedFilesAreRefused() throws {
        let scratch = try ImportScratch()
        let file = try scratch.write(String(repeating: "x", count: 64), as: "big.html")
        #expect(throws: ImportError.tooLarge("big.html")) { try LocalImportFileSystem().read(file, maximumBytes: 16) }
        let link = scratch.file("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: ImportError.self) { try LocalImportFileSystem().read(link, maximumBytes: 1_000) }
    }

    @Test func importerContainsNoNetworkCode() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CairnImport")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 8)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in ["URLSession", "URLRequest", "NWConnection", "Network", "WebKit", "CFNetwork", "Keychain", "SecItem"] {
                #expect(!text.contains(token), "\(file.lastPathComponent) mentions \(token)")
            }
        }
    }
}

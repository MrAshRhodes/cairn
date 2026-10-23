import Foundation
import Testing
import CairnEngineKit
@testable import CairnCore

@Suite struct PagePreferencesTests {
    @Test(arguments: [
        ("de-DE, de;q=0.9", "de-DE,de"), ("en-US,en", "en-US,en"), ("fr", "fr"), ("EN-us,en-US", "EN-us"),
        ("zh-Hant-TW,zh", "zh-Hant-TW,zh"),
    ])
    func normalizesLanguageLists(input: String, expected: String) {
        #expect(PagePreferences.normalizedLanguages(input) == expected)
    }

    @Test(arguments: ["", " ", "e", "en_US", "en-US\r\nX: y", "12", "en-", "toolongsubtag-xx"])
    func rejectsInvalidLanguageLists(input: String) {
        #expect(PagePreferences.normalizedLanguages(input) == nil)
    }

    @Test func systemLanguagesAddBaseLanguages() {
        #expect(PagePreferences.systemLanguages(["de-DE", "en-US", "fr"]) == "de-DE,de,en-US,en,fr")
        #expect(PagePreferences.systemLanguages(["en_GB", "bad tag", "en"]) == "en-GB,en")
        #expect(PagePreferences.systemLanguages([]) == "")
    }

    @Test func userAgentMustBePrintableAsciiAndBounded() {
        #expect(PagePreferences.isValidUserAgent(""))
        #expect(PagePreferences.isValidUserAgent("Mozilla/5.0 (Macintosh) Custom/1.0"))
        #expect(!PagePreferences.isValidUserAgent("Mozilla\nHeader: x"))
        #expect(!PagePreferences.isValidUserAgent("Mozilla é"))
        #expect(!PagePreferences.isValidUserAgent(String(repeating: "a", count: 513)))
    }
}

@Suite struct ViewSourceTests {
    @Test func buildsOnlyForLoadablePages() {
        #expect(ViewSource.url(for: URL(string: "https://example.com/a?b=1")!)?.absoluteString == "view-source:https://example.com/a?b=1")
        #expect(ViewSource.url(for: URL(string: "file:///tmp/a.html")!) != nil)
        #expect(ViewSource.url(for: URL(string: "about:blank")!) == nil)
        #expect(ViewSource.url(for: URL(string: "view-source:https://example.com")!) == nil)
        #expect(ViewSource.url(for: URL(string: "javascript:alert(1)")!) == nil)
    }

    @Test func navigableOnlyWhenInnerPageIs() {
        #expect(URLResolver.isNavigable(URL(string: "view-source:https://example.com/")!))
        #expect(!URLResolver.isNavigable(URL(string: "view-source:javascript:alert(1)")!))
        #expect(!URLResolver.isNavigable(URL(string: "view-source:data:text/html,hi")!))
        #expect(!URLResolver.isNavigable(URL(string: "view-source:https://user:pw@example.com/")!))
    }

    @Test func typedAddressesCannotOpenViewSource() {
        #expect(URLResolver.resolve("view-source:https://example.com", searchTemplate: URLResolver.defaultSearchTemplate) == nil)
    }
}

@Suite @MainActor struct SiteZoomStoreTests {
    private let page = URL(string: "https://Example.com/path")!

    @Test func remembersPerProfileAndHost() throws {
        let store = try SiteZoomStore()
        #expect(store.zoom(profileID: "a", url: page) == nil)
        #expect(store.setZoom(1.5, profileID: "a", url: page))
        #expect(store.zoom(profileID: "a", url: URL(string: "https://example.com/other")) == 1.5)
        #expect(store.zoom(profileID: "b", url: page) == nil)
        #expect(store.zoom(profileID: "a", url: URL(string: "https://sub.example.com/")) == nil)
    }

    @Test func defaultZoomRemovesTheEntryAndNoOpsReportNoChange() throws {
        let store = try SiteZoomStore()
        #expect(!store.setZoom(1, profileID: "a", url: page))
        store.setZoom(2, profileID: "a", url: page)
        #expect(!store.setZoom(2, profileID: "a", url: page))
        #expect(store.setZoom(1, profileID: "a", url: page))
        #expect(store.count == 0)
    }

    @Test func clampsAndIgnoresPagesWithoutAWebHost() throws {
        let store = try SiteZoomStore()
        store.setZoom(100, profileID: "a", url: page)
        #expect(store.zoom(profileID: "a", url: page) == 5)
        #expect(!store.setZoom(2, profileID: "a", url: URL(string: "file:///tmp/a.html")))
        #expect(!store.setZoom(2, profileID: "a", url: URL(string: "about:blank")))
        #expect(!store.setZoom(.nan, profileID: "a", url: page))
    }

    @Test func persistsAcrossRelaunch() throws {
        let directory = try TestDirectory()
        let file = directory.file("site-zoom.json")
        let first = try SiteZoomStore(url: file)
        first.setZoom(1.25, profileID: "a", url: page)
        let second = try SiteZoomStore(url: file)
        #expect(second.zoom(profileID: "a", url: page) == 1.25)
    }

    @Test func damagedFileIsPreserved() throws {
        let directory = try TestDirectory()
        let file = directory.file("site-zoom.json")
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try SiteZoomStore(url: file) }
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
    }

    @Test func invalidStoredEntriesAreDropped() throws {
        let directory = try TestDirectory()
        let file = directory.file("site-zoom.json")
        try Data(#"{"schemaVersion":1,"levels":{"a\u001Fexample.com":99,"nokey":2,"a\u001Fok.com":1.5}}"#.utf8).write(to: file)
        let store = try SiteZoomStore(url: file)
        #expect(store.count == 1)
        #expect(store.zoom(profileID: "a", url: URL(string: "https://ok.com")) == 1.5)
    }
}

@Suite @MainActor struct PageSettingsTests {
    @Test func languageAndUserAgentRoundTripAndOldFilesStillLoad() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let old = #"{"schemaVersion":1,"searchTemplate":"https://duckduckgo.com/?q=%s","autoArchiveAfterHours":12,"restoreSessionOnLaunch":true,"sidebarWidth":260}"#
        try Data(old.utf8).write(to: file)
        let settings = try Settings.load(from: file)
        #expect(settings.acceptLanguages.isEmpty && settings.userAgent.isEmpty)
        #expect(!settings.pagePreferences.acceptLanguages.isEmpty || Locale.preferredLanguages.isEmpty)
        #expect(settings.pagePreferences.userAgent.isEmpty)
        settings.acceptLanguages = "de-DE,de"
        settings.userAgent = "Custom/1.0"
        try settings.save(to: file)
        let loaded = try Settings.load(from: file)
        #expect(loaded.pagePreferences == PagePreferences(acceptLanguages: "de-DE,de", userAgent: "Custom/1.0"))
    }

    @Test func invalidValuesAreNotSaved() throws {
        let directory = try TestDirectory()
        let file = directory.file("settings.json")
        let settings = Settings()
        settings.acceptLanguages = "en-US\nX: y"
        #expect(throws: (any Error).self) { try settings.save(to: file) }
        settings.acceptLanguages = ""
        settings.userAgent = "bad\nagent"
        #expect(throws: (any Error).self) { try settings.save(to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

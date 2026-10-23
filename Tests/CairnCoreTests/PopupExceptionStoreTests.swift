import Foundation
import Testing
@testable import CairnCore

@Suite @MainActor
struct PopupExceptionStoreTests {
    @Test func persistsExactOriginsAndRevocationAcrossRelaunch() throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        let space = UUID()
        let first = PopupExceptionStore()
        try first.load(from: url)
        #expect(first.allow(spaceID: space, profileID: "one", origin: "HTTPS://Example.com:443/path"))
        let second = PopupExceptionStore()
        try second.load(from: url)
        #expect(second.entries.map(\.origin) == ["https://example.com"])
        #expect(second.allows(spaceID: space, profileID: "one", origin: "https://example.com/another"))
        #expect(!second.allows(spaceID: UUID(), profileID: "one", origin: "https://example.com"))
        #expect(!second.allows(spaceID: space, profileID: "two", origin: "https://example.com"))
        for origin in ["http://example.com", "https://sub.example.com", "https://example.com:444", "https://example.com.evil"] {
            #expect(!second.allows(spaceID: space, profileID: "one", origin: origin))
        }
        #expect(second.revoke(try #require(second.entries.first).id))
        let third = PopupExceptionStore()
        try third.load(from: url)
        #expect(third.entries.isEmpty)
    }

    @Test func defaultPortsAndIPv6RemainCanonical() throws {
        let directory = try TestDirectory()
        let store = PopupExceptionStore()
        try store.load(from: directory.file("popups.json"))
        let space = UUID()
        #expect(store.allow(spaceID: space, profileID: "one", origin: "http://[::1]:80/path"))
        #expect(store.entries.first?.origin == "http://[::1]")
        #expect(store.allows(spaceID: space, profileID: "one", origin: "http://[::1]/other"))
        #expect(!store.allows(spaceID: space, profileID: "one", origin: "http://[::1]:8080"))
        let reloaded = PopupExceptionStore()
        try reloaded.load(from: directory.file("popups.json"))
        #expect(reloaded.entries == store.entries)
    }

    @Test(arguments: ["{ broken", #"{"schemaVersion":2,"entries":[]}"#,
                      #"{"schemaVersion":1,"entries":[{"spaceID":"bad","profileID":"one","origin":"https://example.com","allowedAt":0}]}"#])
    func unreadableDocumentsArePreservedAndCannotGrant(_ source: String) throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        try Data(source.utf8).write(to: url)
        let store = PopupExceptionStore()
        #expect(throws: (any Error).self) { try store.load(from: url) }
        #expect(!store.isWritable)
        #expect(store.errorMessage != nil)
        #expect(store.entries.isEmpty)
        #expect(!store.allow(spaceID: UUID(), profileID: "one", origin: "https://example.com"))
        #expect(try String(contentsOf: url, encoding: .utf8) == source)
    }

    @Test(arguments: ["https://example.com/path", "https://*.example.com", "file:///x", "HTTPS://example.com"])
    func invalidStoredOriginsAreNotSilentlyBroadened(_ origin: String) throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "entries": [
                ["spaceID": UUID().uuidString, "profileID": "one", "origin": origin, "allowedAt": 0]
            ]
        ])
        try data.write(to: url)
        let store = PopupExceptionStore()
        #expect(throws: (any Error).self) { try store.load(from: url) }
        #expect(store.entries.isEmpty)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func failedSaveNeverActivatesAGrant() throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        let store = PopupExceptionStore()
        try store.load(from: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var errors = 0
        store.onError = { _ in errors += 1 }
        let space = UUID()
        #expect(!store.allow(spaceID: space, profileID: "one", origin: "https://example.com"))
        #expect(!store.allows(spaceID: space, profileID: "one", origin: "https://example.com"))
        #expect(store.entries.isEmpty)
        #expect(!store.isWritable)
        #expect(store.errorMessage?.contains("not allowed") == true)
        #expect(errors == 1)
    }

    @Test func failedRevokeSaveStillRevokesImmediatelyAndWarnsAboutRestart() throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        let store = PopupExceptionStore()
        try store.load(from: url)
        let space = UUID()
        #expect(store.allow(spaceID: space, profileID: "one", origin: "https://example.com"))
        try FileManager.default.moveItem(at: url, to: directory.file("preserved.json"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(!store.revoke(try #require(store.entries.first).id))
        #expect(!store.allows(spaceID: space, profileID: "one", origin: "https://example.com"))
        #expect(store.errorMessage?.contains("may return after restarting") == true)
        #expect(FileManager.default.fileExists(atPath: directory.file("preserved.json").path))
    }

    @Test func removedSpacesAndChangedProfilesArePrunedWithoutBroadeningOtherGrants() throws {
        let directory = try TestDirectory()
        let url = directory.file("popups.json")
        let store = PopupExceptionStore()
        try store.load(from: url)
        var first = Space(name: "One", profileID: "one")
        let second = Space(name: "Two", profileID: "two")
        for space in [first, second] {
            #expect(store.allow(spaceID: space.id, profileID: space.profileID, origin: "https://example.com"))
        }
        #expect(store.removeAll(spaceID: second.id))
        #expect(store.entries.count == 1)
        first.profileID = "replacement"
        #expect(store.retain(spaces: [first]))
        #expect(store.entries.isEmpty)
        let reloaded = PopupExceptionStore()
        try reloaded.load(from: url)
        #expect(reloaded.entries.isEmpty)
    }

    @Test func unconfiguredStoreAndUnsafeOriginsCannotGrant() throws {
        let directory = try TestDirectory()
        let store = PopupExceptionStore()
        let space = UUID()
        #expect(!store.allow(spaceID: space, profileID: "one", origin: "https://example.com"))
        try store.load(from: directory.file("popups.json"))
        for origin in ["about:blank", "file:///x", "data:text/html,hi", "https://*.example.com"] {
            #expect(!store.allow(spaceID: space, profileID: "one", origin: origin))
        }
        #expect(store.entries.isEmpty)
    }
}

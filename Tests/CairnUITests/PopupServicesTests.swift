import AppKit
import CairnCore
import CairnEngineKit
import Testing
@testable import CairnUI

@MainActor
private final class PopupServicesEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Popup services test"
    let versionDescription = "Test"
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { fatalError("No live tabs needed") }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@Suite @MainActor
struct PopupServicesTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".popup-services-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func serviceRelaunchRetainsOnlyTheSameSpaceAndProfile() throws {
        try withDirectory { directory in
            let workspace = Workspace.makeDefault()
            let first = BrowserServices(model: BrowserModel(engine: PopupServicesEngine(), workspace: workspace), directory: directory)
            first.loadPopupExceptions()
            let space = first.model.selectedSpace
            #expect(first.model.popupExceptions.allow(spaceID: space.id, profileID: space.profileID, origin: "https://example.com"))
            let second = BrowserServices(model: BrowserModel(engine: PopupServicesEngine(), workspace: workspace), directory: directory)
            second.loadPopupExceptions()
            #expect(second.model.popupExceptions.allows(spaceID: space.id, profileID: space.profileID, origin: "https://example.com"))
            var changed = workspace
            changed.spaces[0].profileID = "different-profile"
            let third = BrowserServices(model: BrowserModel(engine: PopupServicesEngine(), workspace: changed), directory: directory)
            third.loadPopupExceptions()
            #expect(third.model.popupExceptions.entries.isEmpty)
        }
    }

    @Test func corruptAndNewerStoresProduceVisibleIssuesAndKeepOriginalBytes() throws {
        for source in ["{broken", #"{"schemaVersion":2,"entries":[]}"#] {
            try withDirectory { directory in
                let url = directory.appendingPathComponent("popup-exceptions.json")
                try Data(source.utf8).write(to: url)
                let services = BrowserServices(model: BrowserModel(engine: PopupServicesEngine()), directory: directory)
                services.loadPopupExceptions()
                #expect(!services.model.popupExceptions.isWritable)
                #expect(services.issues.contains { $0.title == "Popup exceptions could not be loaded" })
                #expect(services.model.popupExceptions.errorMessage?.contains("preserved") == true)
                #expect(try String(contentsOf: url, encoding: .utf8) == source)
            }
        }
    }

    @Test func failedGrantSaveSurfacesAnIssueAndLeavesThePolicyRestrictive() throws {
        try withDirectory { directory in
            let services = BrowserServices(model: BrowserModel(engine: PopupServicesEngine()), directory: directory)
            services.loadPopupExceptions()
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("popup-exceptions.json"),
                                                    withIntermediateDirectories: false)
            let space = services.model.selectedSpace
            #expect(!services.model.popupExceptions.allow(spaceID: space.id, profileID: space.profileID, origin: "https://example.com"))
            #expect(services.issues.contains { $0.title == "Popup exceptions could not be saved" })
            #expect(services.model.popupExceptions.entries.isEmpty)
        }
    }
}

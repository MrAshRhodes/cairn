import Foundation
import Testing
import CairnCore
import CairnEngineKit
@testable import CairnUI

@MainActor
private final class NativeDownloadEngine: BrowserEngine, EngineDownloadControlling {
    let kind = EngineKind.chromium
    let displayName = "Test"
    let versionDescription = "1"
    weak var downloadDelegate: EngineDownloadDelegate?
    var actions: [(EngineDownloadAction, UInt32)] = []

    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { fatalError("unused") }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
    func performDownloadAction(_ action: EngineDownloadAction, id: UInt32) { actions.append((action, id)) }
}

@Suite(.serialized) @MainActor
struct NativeDownloadServicesTests {
    private func make() throws -> (BrowserServices, NativeDownloadEngine, URL) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-native-download-\(UUID().uuidString)")
        let engine = NativeDownloadEngine()
        let registry = EngineRegistry()
        registry.register(.chromium) { engine }
        return (try BrowserServices.bootstrap(registry: registry, directory: directory), engine, directory)
    }

    @Test(arguments: ["https://signed-in.example/private/image.png", "blob:https://signed-in.example/image"])
    func nativeSaveRequestsKeepTheEngineTransferAndControls(source: String) throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let delegate = try #require(engine.downloadDelegate)
        #expect(delegate === services.model)
        var legacyRequests = 0
        services.model.downloadHandler = { _, _ in legacyRequests += 1 }
        let destination = directory.appendingPathComponent("saved.png")
        services.downloads.destinationChooser = { filename, decide in
            #expect(filename == "image.png")
            decide(destination)
        }
        var chosen: URL??
        delegate.engineWillStartDownload(.init(id: 42, url: URL(string: source), suggestedFilename: "image.png",
                                              mimeType: "image/png", profileID: "signed-in")) { chosen = .some($0) }
        #expect(chosen == .some(destination))
        #expect(services.sheet == .downloads)
        let item = try #require(services.downloads.items.first)
        #expect(item.engineID == 42 && item.url.absoluteString == source)
        #expect(legacyRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        delegate.engineDownloadDidUpdate(.init(id: 42, state: .inProgress, receivedBytes: 5, totalBytes: 10, percentComplete: 50))
        #expect(services.downloads.items[0].progress == 0.5)
        services.downloads.pause(item.id)
        services.downloads.resume(item.id)
        services.downloads.cancel(item.id)
        #expect(engine.actions.map(\.0) == [.pause, .resume, .cancel])
        #expect(engine.actions.map(\.1) == [42, 42, 42])
        #expect(services.downloads.items[0].status == .cancelled)
        #expect(services.issues.isEmpty)
    }

    @Test func cancelledAndInvalidNativeSaveDestinationsNeverUseTheURLDownloader() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let delegate = try #require(engine.downloadDelegate)
        var legacyRequests = 0
        services.model.downloadHandler = { _, _ in legacyRequests += 1 }
        let request = EngineDownloadRequest(id: 42, url: URL(string: "https://signed-in.example/file"),
                                            suggestedFilename: "file", profileID: "signed-in")
        var chosen: URL??
        services.downloads.destinationChooser = { _, decide in decide(nil) }
        delegate.engineWillStartDownload(request) { chosen = .some($0) }
        #expect(chosen == .some(nil) && services.downloads.items.isEmpty)
        #expect(services.sheet == nil && services.issues.isEmpty)

        services.downloads.destinationChooser = { _, decide in decide(directory.appendingPathComponent("missing/file")) }
        chosen = nil
        delegate.engineWillStartDownload(request) { chosen = .some($0) }
        #expect(chosen == .some(nil) && legacyRequests == 0)
        #expect(services.downloads.items.allSatisfy { $0.engineID == nil })
        #expect(services.issues.contains { $0.title == "Download could not finish" && $0.detail.contains("folder does not exist") })
    }

    @Test func failedRetryRoutesBackToTheOriginalEngineWithoutAnotherSavePanel() throws {
        let (services, engine, directory) = try make()
        defer { services.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let delegate = try #require(engine.downloadDelegate)
        var choices = 0
        services.downloads.destinationChooser = { _, decide in
            choices += 1
            decide(directory.appendingPathComponent("retry.bin"))
        }
        services.model.downloadHandler = { _, _ in Issue.record("A failed native download must not replay a URL.") }
        delegate.engineWillStartDownload(.init(id: 17, url: URL(string: "https://signed-in.example/file"),
                                              suggestedFilename: "retry.bin", profileID: "original-space")) { _ in }
        let id = try #require(services.downloads.items.first?.id)
        delegate.engineDownloadDidUpdate(.init(id: 17, state: .failed("Connection lost"), retry: .available))
        services.downloads.retry(id)
        services.downloads.retry(id)
        #expect(engine.actions.map(\.0) == [.retry(attempt: 1)] && engine.actions.map(\.1) == [17])
        #expect(choices == 1 && services.downloads.items.count == 1)
        delegate.engineDownloadDidUpdate(.init(id: 17, state: .failed("Still offline"), retry: .available, attempt: 1))
        delegate.engineDownloadDidUpdate(.init(id: 17, state: .failed("Still offline"),
                                               retry: .unavailable("The original Space was removed."), attempt: 1))
        services.downloads.retry(id)
        #expect(engine.actions.count == 1)
        #expect(services.downloads.items[0].retry == .unavailable("The original Space was removed."))
    }
}

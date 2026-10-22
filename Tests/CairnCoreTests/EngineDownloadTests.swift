import AppKit
import Foundation
import Testing
import CairnEngineKit
@testable import CairnCore

@MainActor
private final class DownloadEngine: BrowserEngine, EngineDownloadControlling {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "0"
    weak var downloadDelegate: EngineDownloadDelegate?
    var actions: [(EngineDownloadAction, UInt32)] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab { fatalError("unused") }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
    func performDownloadAction(_ action: EngineDownloadAction, id: UInt32) { actions.append((action, id)) }
}

@Suite @MainActor struct EngineDownloadTests {
    private let source = URL(string: "https://files.test/report.pdf")!

    private func request(_ id: UInt32 = 7, name: String = "report.pdf") -> EngineDownloadRequest {
        EngineDownloadRequest(id: id, url: source, suggestedFilename: name, totalBytes: 1000, profileID: "space")
    }

    private func started(_ manager: DownloadsManager, destination: URL?, id: UInt32 = 7) -> URL?? {
        var chosen: URL??
        manager.destinationChooser = { _, completion in completion(destination) }
        manager.beginEngineDownload(request(id)) { chosen = .some($0) }
        return chosen
    }

    @Test func modelInstallsItselfAndRoutesEngineEvents() throws {
        let engine = DownloadEngine()
        let model = BrowserModel(engine: engine)
        #expect(engine.downloadDelegate === model)
        var decided: URL??
        model.engineDownloadHandler = { _, decide in decide(URL(fileURLWithPath: "/tmp/x")) }
        model.engineWillStartDownload(request()) { decided = .some($0) }
        #expect(decided == .some(URL(fileURLWithPath: "/tmp/x")))
        var update: EngineDownloadUpdate?
        model.engineDownloadUpdateHandler = { update = $0 }
        model.engineDownloadDidUpdate(.init(id: 7, state: .paused))
        #expect(update?.state == .paused)
        model.performEngineDownloadAction(.pause, id: 7)
        #expect(engine.actions.first?.0 == .pause && engine.actions.first?.1 == 7)
    }

    @Test func modelCancelsAndReportsWhenNoHandlerIsConfigured() {
        let model = BrowserModel(engine: DownloadEngine())
        var reported = false
        model.onError = { _ in reported = true }
        var decided: URL??
        model.engineWillStartDownload(request()) { decided = .some($0) }
        #expect(decided == .some(nil))
        #expect(reported)
    }

    @Test func userCancellationOfThePanelCancelsTheEngineDownloadWithoutAnItem() throws {
        let manager = DownloadsManager()
        let result = started(manager, destination: nil)
        #expect(result == .some(nil))
        #expect(manager.items.isEmpty)
    }

    @Test func chosenDestinationCreatesAnEngineItemAndReportsProgressToCompletion() throws {
        let directory = try TestDirectory()
        let destination = directory.file("saved.pdf")
        let manager = DownloadsManager()
        #expect(started(manager, destination: destination) == .some(destination))
        var item = try #require(manager.items.first)
        #expect(item.engineID == 7 && item.status == .downloading && item.filename == "saved.pdf")

        manager.applyEngineUpdate(.init(id: 7, state: .inProgress, receivedBytes: 250, totalBytes: 1000, percentComplete: 25, bytesPerSecond: 50))
        item = manager.items[0]
        #expect(item.progress == 0.25 && item.receivedBytes == 250 && item.bytesPerSecond == 50)

        manager.applyEngineUpdate(.init(id: 7, state: .paused, receivedBytes: 300, totalBytes: 1000, percentComplete: 30))
        #expect(manager.items[0].status == .paused)
        #expect(manager.items[0].status.isActive)
        manager.clearFinished()
        #expect(manager.items.count == 1)

        try Data("done".utf8).write(to: destination)
        manager.applyEngineUpdate(.init(id: 7, state: .completed, receivedBytes: 1000, totalBytes: 1000, percentComplete: 100, path: destination.path))
        #expect(manager.items[0].status == .completed && manager.items[0].progress == 1)
        #expect(manager.items[0].destination == destination)
        #expect(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
        manager.applyEngineUpdate(.init(id: 7, state: .inProgress, percentComplete: 10))
        #expect(manager.items[0].status == .completed)
    }

    @Test func cancellationIsNotAFailure() throws {
        let directory = try TestDirectory()
        let manager = DownloadsManager()
        var errors = 0
        manager.onError = { _ in errors += 1 }
        var sent: [(EngineDownloadAction, UInt32)] = []
        manager.engineControl = { sent.append(($0, $1)) }
        _ = started(manager, destination: directory.file("a.bin"))
        manager.cancel(manager.items[0].id)
        #expect(sent.count == 1 && sent[0].0 == .cancel && sent[0].1 == 7)
        #expect(manager.items[0].status == .cancelled)
        manager.applyEngineUpdate(.init(id: 7, state: .cancelled))
        #expect(manager.items[0].status == .cancelled && manager.items[0].errorMessage == nil)
        #expect(errors == 0)
    }

    @Test func pauseAndResumeAreForwardedOnlyForActiveEngineItems() throws {
        let directory = try TestDirectory()
        let manager = DownloadsManager()
        var sent: [EngineDownloadAction] = []
        manager.engineControl = { action, _ in sent.append(action) }
        _ = started(manager, destination: directory.file("p.bin"))
        let id = manager.items[0].id
        manager.pause(id)
        manager.resume(id)
        #expect(sent == [.pause, .resume])
        manager.applyEngineUpdate(.init(id: 7, state: .completed))
        manager.pause(id)
        #expect(sent.count == 2)
    }

    @Test func failureIsReportedWithAReadableReason() throws {
        let directory = try TestDirectory()
        let manager = DownloadsManager()
        var reported: Error?
        manager.onError = { reported = $0 }
        _ = started(manager, destination: directory.file("f.bin"))
        manager.applyEngineUpdate(.init(id: 7, state: EngineDownloadFailure.state(forInterruptReason: 22)))
        #expect(manager.items[0].status == .failed)
        #expect(manager.items[0].errorMessage == "The network connection was lost.")
        #expect(reported != nil)
        #expect(manager.items[0].engineID == 7)
    }

    @Test func interruptReasonsDistinguishUserCancellationFromFailure() {
        #expect(EngineDownloadFailure.state(forInterruptReason: 40) == .cancelled)
        #expect(EngineDownloadFailure.state(forInterruptReason: 41) == .cancelled)
        #expect(EngineDownloadFailure.state(forInterruptReason: 3) == .failed("There is not enough disk space."))
        #expect(EngineDownloadState.failed("x").isTerminal && !EngineDownloadState.paused.isTerminal)
    }

    @Test func unsafeDestinationsAreRefusedAndCancelTheEngineDownload() throws {
        let directory = try TestDirectory()
        let real = directory.file("real.bin")
        try Data("x".utf8).write(to: real)
        let link = directory.file("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let manager = DownloadsManager()
        var errors = 0
        manager.onError = { _ in errors += 1 }
        for bad in [link, directory.url.appendingPathComponent("missing/dir/file.bin"),
                    URL(fileURLWithPath: directory.url.path + "/.hidden"), directory.url] {
            #expect(started(manager, destination: bad) == .some(nil))
        }
        #expect(errors == 4)
        #expect(manager.items.allSatisfy { $0.engineID == nil })
    }

    @Test func overwritingARegularFileTheUserConfirmedIsAllowed() throws {
        let directory = try TestDirectory()
        let existing = directory.file("same.bin")
        try Data("old".utf8).write(to: existing)
        let manager = DownloadsManager()
        #expect(started(manager, destination: existing) == .some(existing))
    }

    @Test func serverFilenamesNeverEscapeTheChosenName() {
        #expect(DownloadsManager.safeFilename("../../etc/passwd") == "passwd")
        #expect(DownloadsManager.safeFilename("") == "Download")
    }

    @Test func updatesForUnknownDownloadsAreIgnored() {
        let manager = DownloadsManager()
        manager.applyEngineUpdate(.init(id: 99, state: .completed))
        #expect(manager.items.isEmpty)
    }
}

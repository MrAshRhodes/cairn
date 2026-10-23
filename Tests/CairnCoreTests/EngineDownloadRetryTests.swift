import Foundation
import Testing
import CairnEngineKit
@testable import CairnCore

@Suite @MainActor
struct EngineDownloadRetryTests {
    private func failed(_ directory: TestDirectory, retry: EngineDownloadRetry = .available)
        -> (DownloadsManager, UUID) {
        let manager = DownloadsManager()
        manager.destinationChooser = { _, decide in decide(directory.file("download.bin")) }
        manager.beginEngineDownload(.init(id: 9, url: URL(string: "https://signed-in.test/file"),
                                          suggestedFilename: "download.bin", profileID: "space-a")) { _ in }
        manager.applyEngineUpdate(.init(id: 9, state: .failed("Connection lost"), receivedBytes: 25,
                                        totalBytes: 100, percentComplete: 25, retry: retry))
        return (manager, manager.items[0].id)
    }

    @Test func retryKeepsTheEngineItemAndRejectsDoubleClicksAndStaleUpdates() throws {
        let directory = try TestDirectory()
        let (manager, id) = failed(directory)
        var actions: [EngineDownloadAction] = []
        manager.engineControl = { action, engineID in
            #expect(engineID == 9)
            actions.append(action)
        }
        manager.retry(id)
        manager.retry(id)
        #expect(actions == [.retry(attempt: 1)])
        #expect(manager.items.count == 1 && manager.items[0].id == id)
        #expect(manager.items[0].status == .downloading && manager.items[0].attempt == 1)
        manager.applyEngineUpdate(.init(id: 9, state: .completed, attempt: 0))
        manager.applyEngineUpdate(.init(id: 9, state: .failed("old failure"), attempt: 0))
        #expect(manager.items[0].status == .downloading)
        manager.applyEngineUpdate(.init(id: 9, state: .inProgress, receivedBytes: 60, percentComplete: 60, attempt: 1))
        #expect(manager.items[0].receivedBytes == 60)
        try Data("complete".utf8).write(to: directory.file("download.bin"))
        manager.applyEngineUpdate(.init(id: 9, state: .completed, path: directory.file("download.bin").path, attempt: 1))
        #expect(manager.items[0].status == .completed)
        #expect(getxattr(directory.file("download.bin").path, "com.apple.quarantine", nil, 0, 0, 0) >= 0)
        manager.retry(id)
        #expect(actions.count == 1)
    }

    @Test func retryRefusalAndRemovedContextStayVisibleWithoutReplayingAURL() throws {
        let directory = try TestDirectory()
        for reason in ["POST must start from its page.", "Blob has expired.", "Space was removed."] {
            let (manager, id) = failed(directory, retry: .unavailable(reason))
            var actions = 0
            manager.engineControl = { _, _ in actions += 1 }
            manager.destinationChooser = { _, _ in Issue.record("Retry must not create a new URL download.") }
            manager.retry(id)
            #expect(actions == 0 && manager.items[0].status == .failed)
            #expect(manager.items[0].retry == .unavailable(reason))
        }
        let (manager, id) = failed(directory)
        manager.engineControl = { _, _ in }
        manager.applyEngineUpdate(.init(id: 9, state: .failed("Connection lost"),
                                        retry: .unavailable("The original tab was closed.")))
        manager.retry(id)
        #expect(manager.items[0].status == .failed && manager.items[0].attempt == 0)
    }

    @Test func cancellationAndClearingCannotReviveRetainedCallbacks() throws {
        let directory = try TestDirectory()
        let (manager, id) = failed(directory)
        var actions: [EngineDownloadAction] = []
        manager.engineControl = { action, _ in actions.append(action) }
        manager.retry(id)
        manager.cancel(id)
        manager.applyEngineUpdate(.init(id: 9, state: .inProgress, attempt: 1))
        manager.applyEngineUpdate(.init(id: 9, state: .completed, attempt: 1))
        manager.retry(id)
        #expect(manager.items[0].status == .cancelled)
        #expect(actions == [.retry(attempt: 1), .cancel])
        manager.clearFinished()
        manager.applyEngineUpdate(.init(id: 9, state: .failed("late"), retry: .available, attempt: 1))
        #expect(manager.items.isEmpty)
    }

    @Test func failedRetryMayFailAgainWithoutCreatingASecondJob() throws {
        let directory = try TestDirectory()
        let (manager, id) = failed(directory)
        var actions: [EngineDownloadAction] = []
        manager.engineControl = { action, _ in actions.append(action) }
        manager.retry(id)
        manager.applyEngineUpdate(.init(id: 9, state: .failed("Still offline"), retry: .available, attempt: 1))
        manager.retry(id)
        #expect(actions == [.retry(attempt: 1), .retry(attempt: 2)])
        #expect(manager.items.count == 1 && manager.items[0].id == id)
    }

    @Test func changedDestinationAndMissingControllerRefuseRetry() throws {
        let directory = try TestDirectory()
        let (manager, id) = failed(directory)
        manager.retry(id)
        #expect(manager.items[0].status == .failed)
        var actions = 0
        manager.engineControl = { _, _ in actions += 1 }
        let unrelated = directory.file("unrelated")
        try Data("keep me".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: directory.file("download.bin"), withDestinationURL: unrelated)
        manager.retry(id)
        #expect(actions == 0)
        #expect(manager.items[0].status == .failed)
        if case .available = manager.items[0].retry { Issue.record("Unsafe destination remained retryable.") }
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep me")
    }

    @Test func pausedTransfersUseResumeNotRetry() throws {
        let directory = try TestDirectory()
        let (manager, id) = failed(directory)
        manager.engineControl = { _, _ in }
        manager.retry(id)
        manager.applyEngineUpdate(.init(id: 9, state: .paused, attempt: 1))
        var actions: [EngineDownloadAction] = []
        manager.engineControl = { action, _ in actions.append(action) }
        manager.retry(id)
        manager.resume(id)
        #expect(actions == [.resume])
    }
}

import AppKit
import Testing
@testable import CairnUI

@Suite(.serialized) @MainActor
struct ApplicationTerminationTests {
    @Test func cancellingQuitLeavesTheEngineRunning() {
        var engineClosed = false
        var terminationReplied = false
        let termination = ApplicationTerminationCoordinator { completion in
            engineClosed = true
            completion()
        }

        let decision = termination.request(approval: { false }) { _ in terminationReplied = true }

        #expect(decision == .terminateCancel)
        #expect(!engineClosed)
        #expect(!terminationReplied)
    }

    @Test func approvedQuitWaitsForEngineCloseBeforeReplying() async throws {
        let started = AsyncStream<Void>.makeStream()
        var finishClosing: (@MainActor () -> Void)?
        var events: [String] = []
        let termination = ApplicationTerminationCoordinator { completion in
            events.append("close")
            finishClosing = completion
            started.continuation.yield(())
        }

        let decision = termination.request(approval: {
            events.append("approval")
            return true
        }) { approved in events.append("reply:\(approved)") }

        try #require(decision == .terminateLater)
        #expect(events == ["approval"])
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        #expect(events == ["approval", "close"])
        finishClosing?()
        #expect(events == ["approval", "close", "reply:true"])
        started.continuation.finish()
    }

    @Test func repeatedQuitAndCompletionOnlyCloseAndReplyOnce() async throws {
        let started = AsyncStream<Void>.makeStream()
        var finishClosing: (@MainActor () -> Void)?
        var approvals = 0
        var closes = 0
        var replies = 0
        let termination = ApplicationTerminationCoordinator { completion in
            closes += 1
            finishClosing = completion
            started.continuation.yield(())
        }
        for _ in 0..<2 {
            let decision = termination.request(approval: {
                approvals += 1
                return true
            }) { _ in replies += 1 }
            #expect(decision == .terminateLater)
        }
        #expect(approvals == 1)
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        #expect(closes == 1)
        finishClosing?()
        finishClosing?()
        #expect(replies == 1)
        started.continuation.finish()
    }

    @Test func reentrantQuitDuringApprovalCannotBypassCancellation() {
        let termination = ApplicationTerminationCoordinator()
        var nestedApprovalRan = false
        var nestedDecision = NSApplication.TerminateReply.terminateNow
        let decision = termination.request(approval: {
            nestedDecision = termination.request(approval: {
                nestedApprovalRan = true
                return true
            }) { _ in Issue.record("No asynchronous reply expected") }
            return false
        }) { _ in Issue.record("Cancelled quit must not reply") }

        #expect(decision == .terminateCancel)
        #expect(nestedDecision == .terminateCancel)
        #expect(!nestedApprovalRan)
        var checkedAgain = false
        #expect(termination.request(approval: {
            checkedAgain = true
            return false
        }) { _ in } == .terminateCancel)
        #expect(checkedAgain)
        #expect(termination.request(approval: { true }) { _ in } == .terminateNow)
    }
}

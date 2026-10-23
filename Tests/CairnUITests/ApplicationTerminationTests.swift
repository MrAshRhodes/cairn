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

    @Test func stuckPreparationReportsFailureInsteadOfSuccessfulTermination() async throws {
        let replies = AsyncStream<Bool>.makeStream()
        let termination = ApplicationTerminationCoordinator(prepare: { _ in }, deadline: .milliseconds(30))
        var failures = 0

        #expect(termination.request(approval: { true }, failed: { failures += 1 }) { replies.continuation.yield($0) } == .terminateLater)
        #expect(termination.request(approval: { true }) { _ in } == .terminateLater)
        var iterator = replies.stream.makeAsyncIterator()
        #expect(await iterator.next() == false)
        #expect(failures == 1)
        #expect(termination.request(approval: { true }) { _ in } == .terminateCancel)
        replies.continuation.finish()
    }

    @Test func completingBeforeTheDeadlineRepliesOnlyOnce() async throws {
        var replies = 0
        let termination = ApplicationTerminationCoordinator(prepare: { $0() }, deadline: .milliseconds(30))
        _ = termination.request(approval: { true }) { _ in replies += 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(replies == 1)
    }

    @Test func humanDecisionHasNoTeardownDeadlineAndStayCanBeRetried() async throws {
        var decide: (@MainActor (Bool) -> Void)?
        var prepares = 0
        var replies: [Bool] = []
        var flushes = 0
        let termination = ApplicationTerminationCoordinator(prepare: { done in prepares += 1; done() },
                                                             deadline: .milliseconds(20))
        let pages: CairnApp.PageCloseApproval = { decide = $0 }
        #expect(termination.request(approval: { true }, pageApproval: pages,
                                    commitApproval: { flushes += 1; return true }) { replies.append($0) } == .terminateLater)
        try await Task.sleep(for: .milliseconds(80))
        #expect(prepares == 0)
        #expect(replies.isEmpty)
        #expect(flushes == 0)
        let stale = try #require(decide)
        stale(false)
        #expect(replies == [false])
        #expect(termination.request(approval: { true }, pageApproval: pages) { replies.append($0) } == .terminateLater)
        await Task.yield()
        stale(true)
        #expect(prepares == 0)
        decide?(true)
        #expect(prepares == 1)
        #expect(replies == [false, true])
    }

    @Test func repeatedQuitDoesNotRepeatPageOrPersistencePrompts() async throws {
        var decide: (@MainActor (Bool) -> Void)?
        var decisions = 0
        var flushes = 0
        var replies: [Bool] = []
        let termination = ApplicationTerminationCoordinator(prepare: { $0() })
        let pages: CairnApp.PageCloseApproval = { decisions += 1; decide = $0 }
        for _ in 0..<3 {
            #expect(termination.request(approval: { true }, pageApproval: pages,
                                        commitApproval: { flushes += 1; return true }) { replies.append($0) } == .terminateLater)
        }
        await Task.yield()
        #expect(decisions == 1)
        decide?(true)
        decide?(false)
        #expect(flushes == 1)
        #expect(replies == [true])
    }

    @Test func persistenceVetoAfterPageApprovalDoesNotStartEngineTeardown() async {
        var preparations = 0
        var replies: [Bool] = []
        let termination = ApplicationTerminationCoordinator { _ in preparations += 1 }
        #expect(termination.request(approval: { true }, pageApproval: { $0(true) },
                                    commitApproval: { false }) { replies.append($0) } == .terminateLater)
        await Task.yield()
        #expect(preparations == 0)
        #expect(replies == [false])
    }
}

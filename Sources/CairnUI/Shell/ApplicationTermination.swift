import AppKit

extension CairnApp {
    public typealias TerminationPreparation = @MainActor (@escaping @MainActor () -> Void) -> Void
    public typealias PageCloseApproval = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
}

@MainActor
final class ApplicationTerminationCoordinator {
    private enum State { case idle, checking, deciding, tearingDown, completed, failed }
    private var state = State.idle
    private var generation = 0
    private let prepare: CairnApp.TerminationPreparation?
    private let deadline: Duration
    var isInProgress: Bool { state == .checking || state == .deciding || state == .tearingDown }

    /// Bounds approved teardown only. Human decisions never have a shutdown deadline.
    init(prepare: CairnApp.TerminationPreparation? = nil, deadline: Duration = .seconds(12)) {
        self.prepare = prepare
        self.deadline = deadline
    }

    func request(approval: () -> Bool,
                 pageApproval: CairnApp.PageCloseApproval? = nil,
                 commitApproval: @escaping @MainActor () -> Bool = { true },
                 failed: @escaping @MainActor () -> Void = { NSLog("Cairn: approved engine teardown timed out; quit did not complete.") },
                 reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if state == .deciding || state == .tearingDown { return .terminateLater }
        if state == .completed { return .terminateNow }
        if state == .checking || state == .failed { return .terminateCancel }
        state = .checking
        guard approval() else {
            state = .idle
            return .terminateCancel
        }
        guard pageApproval != nil || prepare != nil else {
            guard commitApproval() else { state = .idle; return .terminateCancel }
            state = .completed
            return .terminateNow
        }
        generation += 1
        let token = generation
        state = .deciding
        // Return terminateLater before any synchronous engine decision can reply to AppKit.
        Task { @MainActor in
            let decided: @MainActor (Bool) -> Void = { approved in
                guard self.generation == token, self.state == .deciding else { return }
                self.state = .checking
                guard approved && commitApproval() else {
                    self.state = .idle
                    reply(false)
                    return
                }
                self.beginTeardown(token: token, failed: failed, reply: reply)
            }
            if let pageApproval { pageApproval(decided) } else { decided(true) }
        }
        return .terminateLater
    }

    private func beginTeardown(token: Int, failed: @escaping @MainActor () -> Void,
                               reply: @escaping @MainActor (Bool) -> Void) {
        guard let prepare else { state = .completed; reply(true); return }
        state = .tearingDown
        prepare {
            guard self.generation == token, self.state == .tearingDown else { return }
            self.state = .completed
            reply(true)
        }
        Task { @MainActor in
            try? await Task.sleep(for: deadline)
            guard self.generation == token, self.state == .tearingDown else { return }
            self.state = .failed
            failed()
            // A watchdog is not evidence that CEF flushed its data. The native hard watchdog exits
            // with failure if Chromium itself is stuck; never fabricate successful termination.
            reply(false)
        }
    }
}

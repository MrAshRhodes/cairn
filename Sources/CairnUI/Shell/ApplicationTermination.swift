import AppKit

extension CairnApp {
    public typealias TerminationPreparation = @MainActor (@escaping @MainActor () -> Void) -> Void
}

@MainActor
final class ApplicationTerminationCoordinator {
    private enum State { case idle, checking, waiting, completed }
    private var state = State.idle
    private let prepare: CairnApp.TerminationPreparation?
    private let deadline: Duration

    /// `deadline` bounds how long quitting may wait for `prepare`; the engine has its own, shorter limits,
    /// so this is the last resort that keeps a stuck shutdown from trapping the user in a window-less app.
    init(prepare: CairnApp.TerminationPreparation? = nil, deadline: Duration = .seconds(12)) {
        self.prepare = prepare
        self.deadline = deadline
    }

    func request(approval: () -> Bool,
                 reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if state == .waiting { return .terminateLater }
        if state == .completed { return .terminateNow }
        if state == .checking { return .terminateCancel }
        state = .checking
        guard approval() else {
            state = .idle
            return .terminateCancel
        }
        guard let prepare else {
            state = .completed
            return .terminateNow
        }
        state = .waiting
        // AppKit must receive terminateLater before even an immediate completion
        // can reply. Approval dialogs and persistence checks have already passed.
        Task { @MainActor in
            prepare {
                guard self.state == .waiting else { return }
                self.state = .completed
                reply(true)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: deadline)
            guard self.state == .waiting else { return }
            self.state = .completed
            reply(true)
        }
        return .terminateLater
    }
}

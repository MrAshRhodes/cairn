import Foundation
import CairnEngineKit

@MainActor
final class TabCloseRequest {
    let tab: EngineTab
    var force = false
    var nativeStarted = false
    var completions: [@MainActor (Bool) -> Void] = []
    init(tab: EngineTab) { self.tab = tab }
}

@MainActor
final class WorkspaceCloseRequest {
    var approved: Set<UUID> = []
    var targets: Set<UUID>?
    var force = false
    var completions: [@MainActor (Bool) -> Void] = []
}

extension BrowserModel {
    func requestTabClose(_ id: UUID, force: Bool = false, completion: @escaping @MainActor (Bool) -> Void) {
        if let request = closeRequests[id] {
            request.completions.append(completion)
            if force { forcePendingClose(id, request: request) }
            return
        }
        guard let tab = liveTabs[id] else { completion(true); return }
        let request = TabCloseRequest(tab: tab)
        request.force = force
        request.completions.append(completion)
        closeRequests[id] = request
        closingTabID = id
        let decided: @MainActor (Bool) -> Void = { [weak self, weak request] approved in
            guard let self, let request, self.closeRequests[id] === request else { return }
            self.closeRequests[id] = nil
            if self.closingTabID == id { self.closingTabID = self.closeRequests.keys.first }
            // A superseded engine view cannot approve deleting its replacement.
            let current = self.liveTabs[id] === request.tab
            for callback in request.completions { callback(approved && current) }
        }
        requestCloseOwnedTransients(id, force: force) { [weak self, weak request] approved in
            guard let self, let request, self.closeRequests[id] === request, !request.nativeStarted else { return }
            guard approved else { decided(false); return }
            request.nativeStarted = true
            self.closingTabID = id
            if let closing = tab as? EngineTabCloseControlling {
                if request.force { closing.forceClose() }
                guard self.closeRequests[id] === request else { return }
                closing.requestClose(completion: decided)
            } else {
                tab.close()
                decided(true)
            }
        }
    }

    private func forcePendingClose(_ id: UUID, request: TabCloseRequest) {
        request.force = true
        // Dependents must be approved before their owner, even under an explicit force request.
        let children = transientPages.values.filter { $0.ownerTabID == id }.map(\.id)
        for child in children { requestTabClose(child, force: true) { _ in } }
        if request.nativeStarted, closeRequests[id] === request {
            (request.tab as? EngineTabCloseControlling)?.forceClose()
        }
    }

    /// Keeps every workspace record and selection intact, including when a later page chooses Stay.
    /// Pages already approved by the user finish closing; their retained records can be loaded again.
    public func requestCloseAll(force: Bool = false, completion: @escaping @MainActor (Bool) -> Void) {
        if let request = workspaceClose {
            guard request.targets == nil else { completion(false); return }
            request.completions.append(completion)
            if force {
                request.force = true
                for (id, pending) in Array(closeRequests) {
                    if closeRequests[id] === pending { forcePendingClose(id, request: pending) }
                }
            }
            return
        }
        let request = WorkspaceCloseRequest()
        request.force = force
        request.completions.append(completion)
        workspaceClose = request
        isClosingWorkspace = true
        advanceWorkspaceClose(request)
    }

    func requestCloseGroup(_ ids: [UUID], completion: @escaping @MainActor (Bool) -> Void) {
        guard workspaceClose == nil else { completion(false); return }
        let request = WorkspaceCloseRequest()
        request.targets = Set(ids)
        request.completions = [completion]
        workspaceClose = request
        isClosingWorkspace = true
        advanceWorkspaceClose(request)
    }

    private func advanceWorkspaceClose(_ request: WorkspaceCloseRequest) {
        guard workspaceClose === request else { return }
        // Include popups/tabs created while a decision was pending, not only an initial snapshot.
        let remaining = liveTabs.keys.filter {
            !request.approved.contains($0) && (request.targets?.contains($0) ?? true)
        }.sorted {
            if (transientPages[$0] != nil) != (transientPages[$1] != nil) { return transientPages[$0] != nil }
            return $0.uuidString < $1.uuidString
        }
        guard let id = remaining.first else { finishWorkspaceClose(request, approved: true); return }
        requestTabClose(id, force: request.force) { [weak self, weak request] approved in
            guard let self, let request, self.workspaceClose === request else { return }
            guard approved else { self.finishWorkspaceClose(request, approved: false); return }
            request.approved.insert(id)
            self.advanceWorkspaceClose(request)
        }
    }

    private func finishWorkspaceClose(_ request: WorkspaceCloseRequest, approved: Bool) {
        guard workspaceClose === request else { return }
        // CEF DoClose is not a reversible preflight. Never leave approved browsers half-closed.
        // Drop their live handles, not their workspace records, even when another page vetoes.
        if approved && request.targets == nil { isWorkspaceSuspended = true }
        for id in request.approved { discardClosedTab(id) }
        workspaceClose = nil
        isClosingWorkspace = false
        closingTabID = closeRequests.keys.first
        if !approved, let selectedTabID { _ = liveTab(for: selectedTabID) }
        for callback in request.completions { callback(approved) }
    }

    /// Explicit user override, also usable while Chromium is not producing a beforeunload dialog.
    public func forceCloseTab(_ id: UUID) {
        guard !isClosingWorkspace else { return }
        requestTabClose(id, force: true) { [weak self] approved in
            if approved { self?.commitTabClose(id) }
        }
    }

    /// A retained SwiftUI window must not recreate browsers while it is closed or quitting.
    public func resumeWorkspace() {
        guard !isClosingWorkspace else { return }
        isWorkspaceSuspended = false
        if let selectedTabID { _ = liveTab(for: selectedTabID) }
    }
}

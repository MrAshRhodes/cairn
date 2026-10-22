import Foundation
import Observation
import CairnEngineKit

/// What a tab is waiting on the user for. Shown one at a time, oldest first, on the tab that raised it.
public enum TabPrompt: Identifiable, Equatable, Sendable {
    case permission(EnginePermissionRequest)
    case jsDialog(EngineJSDialogRequest)
    case authentication(EngineAuthRequest)

    public var id: String {
        switch self {
        case .permission(let request): request.id
        case .jsDialog(let request): request.id
        case .authentication(let request): request.id
        }
    }
}

/// Pending prompts and blocked-certificate notices per live tab. Mutated only by `BrowserModel`.
@MainActor @Observable
public final class TabPromptCenter {
    public private(set) var queues: [UUID: [TabPrompt]] = [:]
    public private(set) var certificateErrors: [UUID: EngineCertificateError] = [:]
    /// JavaScript dialogs shown since the tab last navigated; the third and later offer to silence the page.
    public private(set) var dialogsShown: [UUID: Int] = [:]

    public static let dialogsBeforeSuppressOffer = 2

    public func front(_ tab: UUID) -> TabPrompt? { queues[tab]?.first }
    /// Tabs with something waiting, so a background tab can be marked as needing attention.
    public var tabsNeedingAttention: Set<UUID> { Set(queues.compactMap { $0.value.isEmpty ? nil : $0.key }) }
    public func offersSuppression(_ tab: UUID) -> Bool { (dialogsShown[tab] ?? 0) > Self.dialogsBeforeSuppressOffer - 1 }

    func enqueue(_ prompt: TabPrompt, tab: UUID) {
        if case .jsDialog = prompt { dialogsShown[tab, default: 0] += 1 }
        queues[tab, default: []].append(prompt)
    }
    @discardableResult
    func remove(_ id: String, tab: UUID) -> TabPrompt? {
        guard let index = queues[tab]?.firstIndex(where: { $0.id == id }) else { return nil }
        let prompt = queues[tab]?.remove(at: index)
        if queues[tab]?.isEmpty == true { queues[tab] = nil }
        return prompt
    }
    func setCertificateError(_ error: EngineCertificateError?, tab: UUID) { certificateErrors[tab] = error }
    func resetDialogCount(_ tab: UUID) { dialogsShown[tab] = nil }
    func removeTab(_ tab: UUID) {
        queues[tab] = nil; certificateErrors[tab] = nil; dialogsShown[tab] = nil
    }
}

extension BrowserModel: EngineTabPromptEvents {
    private func itemID(forPromptTab tab: EngineTab) -> UUID? { liveTabs.first { $0.value === tab }?.key }
    private func responder(_ id: UUID) -> EngineTabPromptResponding? { liveTabs[id] as? EngineTabPromptResponding }

    // MARK: Site permissions
    public func engineTab(_ tab: EngineTab, requestsPermission request: EnginePermissionRequest) {
        guard let id = itemID(forPromptTab: tab), let profile = liveProfileIDs[id] else {
            (tab as? EngineTabPromptResponding)?.resolvePermission(id: request.id, allow: false); return
        }
        switch permissionVerdict(for: request, profileID: profile) {
        case .allow: (tab as? EngineTabPromptResponding)?.resolvePermission(id: request.id, allow: true)
        case .block: (tab as? EngineTabPromptResponding)?.resolvePermission(id: request.id, allow: false)
        case nil: prompts.enqueue(.permission(request), tab: id)
        }
    }

    /// Stored decisions answer without asking; a single blocked kind blocks the request; a secure-context
    /// failure blocks without being remembered. `nil` means the user must be asked.
    public func permissionVerdict(for request: EnginePermissionRequest, profileID: String) -> SitePermissionDecision? {
        guard let origin = SiteOrigin.normalize(request.origin), SiteOrigin.isSecureContext(origin) else { return .block }
        let stored = request.kinds.map { sitePermissions.decision(profileID: profileID, origin: origin, kind: $0) }
        if stored.contains(.block) { return .block }
        return stored.allSatisfy { $0 == .allow } ? .allow : nil
    }

    public func engineTab(_ tab: EngineTab, dismissesPermission requestID: String) {
        if let id = itemID(forPromptTab: tab) { prompts.remove(requestID, tab: id) }
    }

    /// Answers the permission prompt at the front of a tab. `remember` stores the choice for the site in this
    /// Space; without it the answer applies to this request only.
    public func answerPermission(_ requestID: String, tab id: UUID, allow: Bool, remember: Bool) {
        guard case .permission(let request)? = prompts.remove(requestID, tab: id) else { return }
        if remember, let profile = liveProfileIDs[id] {
            for kind in request.kinds {
                sitePermissions.set(allow ? .allow : .block, profileID: profile, origin: request.origin, kind: kind)
            }
        }
        responder(id)?.resolvePermission(id: requestID, allow: allow)
    }

    // MARK: JavaScript dialogs
    public func engineTab(_ tab: EngineTab, requestsJSDialog request: EngineJSDialogRequest) {
        guard let id = itemID(forPromptTab: tab) else {
            (tab as? EngineTabPromptResponding)?.resolveJSDialog(id: request.id, accept: false, text: nil, suppressFurther: false)
            return
        }
        prompts.enqueue(.jsDialog(request), tab: id)
    }
    public func engineTab(_ tab: EngineTab, dismissesJSDialog requestID: String) {
        if let id = itemID(forPromptTab: tab) { prompts.remove(requestID, tab: id) }
    }
    public func answerJSDialog(_ requestID: String, tab id: UUID, accept: Bool, text: String? = nil, suppressFurther: Bool = false) {
        guard prompts.remove(requestID, tab: id) != nil else { return }
        responder(id)?.resolveJSDialog(id: requestID, accept: accept, text: text, suppressFurther: suppressFurther)
    }

    // MARK: HTTP authentication
    public func engineTab(_ tab: EngineTab, requestsAuthentication request: EngineAuthRequest) {
        guard let id = itemID(forPromptTab: tab) else {
            (tab as? EngineTabPromptResponding)?.resolveAuthentication(id: request.id, username: nil, password: nil)
            return
        }
        prompts.enqueue(.authentication(request), tab: id)
    }
    /// Credentials go to the engine for this request only and are never stored. `nil` cancels.
    public func answerAuthentication(_ requestID: String, tab id: UUID, username: String?, password: String?) {
        guard prompts.remove(requestID, tab: id) != nil else { return }
        responder(id)?.resolveAuthentication(id: requestID, username: username, password: password)
    }

    // MARK: Blocked certificates
    public func engineTab(_ tab: EngineTab, blockedCertificate error: EngineCertificateError) {
        guard let id = itemID(forPromptTab: tab) else { return }
        // A failed subresource is not worth interrupting for: only the page the tab is on gets a notice.
        let page = tabStates[id]?.url ?? item(id)?.url
        guard page?.host?.lowercased() == error.url.host?.lowercased() else { return }
        prompts.setCertificateError(error, tab: id)
    }
    public func dismissCertificateError(tab id: UUID) { prompts.setCertificateError(nil, tab: id) }

    // MARK: Lifecycle hooks (called from BrowserModel.swift)
    func promptsTabStateChanged(_ id: UUID, previous: EngineTabState?, state: EngineTabState) {
        if previous?.url != state.url { prompts.resetDialogCount(id) }
        guard let error = prompts.certificateErrors[id] else { return }
        let sameHost = state.url?.host?.lowercased() == error.url.host?.lowercased()
        if !sameHost || (!state.isLoading && state.errorMessage == nil) { prompts.setCertificateError(nil, tab: id) }
    }

    func cancelPrompts(for id: UUID) {
        for prompt in prompts.queues[id] ?? [] {
            switch prompt {
            case .permission(let request): responder(id)?.resolvePermission(id: request.id, allow: false)
            case .jsDialog(let request):
                responder(id)?.resolveJSDialog(id: request.id, accept: false, text: nil, suppressFurther: false)
            case .authentication(let request):
                responder(id)?.resolveAuthentication(id: request.id, username: nil, password: nil)
            }
        }
        prompts.removeTab(id)
    }
}

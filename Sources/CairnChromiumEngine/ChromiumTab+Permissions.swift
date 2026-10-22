import Foundation
import CairnEngineKit
import CairnChromiumBridge

// Prompts raised by the page: site permissions, JavaScript dialogs, HTTP authentication, blocked certificates.
// Events are delivered to a delegate that adopted `EngineTabPromptEvents`; answers come back through
// `EngineTabPromptResponding`.

extension ChromiumTab: EngineTabPromptResponding {
    func resolvePermission(id: String, allow: Bool) { bridge.resolvePermission(id, allow: allow) }
    func resolveJSDialog(id: String, accept: Bool, text: String?, suppressFurther: Bool) {
        bridge.resolveJSDialog(id, accept: accept, text: text, suppressFurther: suppressFurther)
    }
    func resolveAuthentication(id: String, username: String?, password: String?) {
        bridge.resolveAuthentication(id, username: username, password: password)
    }
}

private extension ChromiumTab {
    var promptEvents: EngineTabPromptEvents? { delegate as? EngineTabPromptEvents }
}

extension ChromiumTab: @preconcurrency CCChromiumTabPermissionDelegate {
    func chromiumTab(_ tab: CCChromiumTab, requestsPermission requestID: String, origin: String,
                     topLevel: String, kinds: [String]) {
        let parsed = kinds.compactMap(SitePermissionKind.init(rawValue:))
        guard !closed, let events = promptEvents, !parsed.isEmpty, parsed.count == kinds.count else {
            bridge.resolvePermission(requestID, allow: false); return
        }
        events.engineTab(self, requestsPermission: EnginePermissionRequest(
            id: requestID, origin: origin, topLevelURL: URL(string: topLevel), kinds: parsed))
    }
    func chromiumTab(_ tab: CCChromiumTab, dismissesPermission requestID: String) {
        promptEvents?.engineTab(self, dismissesPermission: requestID)
    }
}

extension ChromiumTab: @preconcurrency CCChromiumTabJSDialogDelegate {
    func chromiumTab(_ tab: CCChromiumTab, requestsJSDialog requestID: String, type: String, message: String,
                     defaultText: String, origin: String, isReload: Bool) {
        guard !closed, let events = promptEvents, let kind = EngineJSDialogKind(rawValue: type) else {
            bridge.resolveJSDialog(requestID, accept: false, text: nil, suppressFurther: false); return
        }
        events.engineTab(self, requestsJSDialog: EngineJSDialogRequest(
            id: requestID, kind: kind, message: message, defaultText: defaultText, origin: origin, isReload: isReload))
    }
    func chromiumTab(_ tab: CCChromiumTab, dismissesJSDialog requestID: String) {
        promptEvents?.engineTab(self, dismissesJSDialog: requestID)
    }
}

extension ChromiumTab: @preconcurrency CCChromiumTabRequestDelegate {
    func chromiumTab(_ tab: CCChromiumTab, requestsAuthentication requestID: String, url: String, host: String,
                     port: Int, realm: String, scheme: String, isProxy: Bool) {
        guard !closed, let events = promptEvents else {
            bridge.resolveAuthentication(requestID, username: nil, password: nil); return
        }
        events.engineTab(self, requestsAuthentication: EngineAuthRequest(
            id: requestID, host: host, port: port, realm: realm, scheme: scheme, isProxy: isProxy, url: URL(string: url)))
    }
    func chromiumTab(_ tab: CCChromiumTab, blockedCertificate url: String, code: Int, subject: String,
                     issuer: String, validFrom: Double, validUntil: Double) {
        guard !closed, let parsed = URL(string: url) else { return }
        func date(_ seconds: Double) -> Date? { seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil }
        promptEvents?.engineTab(self, blockedCertificate: EngineCertificateError(
            url: parsed, code: code, subject: subject.isEmpty ? nil : subject, issuer: issuer.isEmpty ? nil : issuer,
            validFrom: date(validFrom), validUntil: date(validUntil)))
    }
    func chromiumTab(_ tab: CCChromiumTab, dismissesAuthentication requestID: String) {
        promptEvents?.engineTab(self, dismissesAuthentication: requestID)
    }
}

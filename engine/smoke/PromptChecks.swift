import AppKit
import CairnEngineKit
import CairnChromiumEngine

// Smoke checks for the prompts a page can raise (permissions, JS dialogs, HTTP auth, blocked certificates).
// The Smoke object forwards the engine's prompt events to `PromptHarness`, which answers them from a script.

@MainActor final class PromptHarness {
    static let shared = PromptHarness()
    var permission: (EnginePermissionRequest) -> Bool = { _ in false }
    var dialog: (EngineJSDialogRequest) -> (accept: Bool, text: String?, suppress: Bool) = { _ in (false, nil, false) }
    var credentials: (EngineAuthRequest) -> (String, String)? = { _ in nil }
    var permissions: [EnginePermissionRequest] = []
    var dialogs: [EngineJSDialogRequest] = []
    var authRequests: [EngineAuthRequest] = []
    var certificateErrors: [EngineCertificateError] = []
}

extension Smoke: EngineTabPromptEvents {
    func engineTab(_ tab: EngineTab, requestsPermission request: EnginePermissionRequest) {
        let harness = PromptHarness.shared
        harness.permissions.append(request)
        (tab as? EngineTabPromptResponding)?.resolvePermission(id: request.id, allow: harness.permission(request))
    }
    func engineTab(_ tab: EngineTab, requestsJSDialog request: EngineJSDialogRequest) {
        let harness = PromptHarness.shared
        harness.dialogs.append(request)
        let answer = harness.dialog(request)
        (tab as? EngineTabPromptResponding)?.resolveJSDialog(id: request.id, accept: answer.accept, text: answer.text,
                                                              suppressFurther: answer.suppress)
    }
    func engineTab(_ tab: EngineTab, requestsAuthentication request: EngineAuthRequest) {
        let harness = PromptHarness.shared
        harness.authRequests.append(request)
        let pair = harness.credentials(request)
        (tab as? EngineTabPromptResponding)?.resolveAuthentication(id: request.id, username: pair?.0, password: pair?.1)
    }
    func engineTab(_ tab: EngineTab, blockedCertificate error: EngineCertificateError) {
        PromptHarness.shared.certificateErrors.append(error)
    }
}

extension Smoke {
    func checkPrompts() async throws {
        let harness = PromptHarness.shared
        let tab = make("prompts")
        try await load(tab, path: "prompts/page")

        // Permissions: denied by default, allowed only when the harness says so, never silently.
        harness.permission = { _ in false }
        let denied = try await js(tab, """
            new Promise(r => navigator.geolocation.getCurrentPosition(() => r('granted'), e => r('error:' + e.code)))
            """) as? String
        try require(denied == "error:1", "geolocation request reaches the client and a denial is delivered to the page")
        try require(harness.permissions.last?.kinds == [.geolocation], "geolocation request names its kind")
        let media = try await js(tab, """
            navigator.mediaDevices.getUserMedia({audio: true}).then(() => 'granted', e => e.name)
            """) as? String
        try require(media == "NotAllowedError", "microphone request is denied through the media callback")
        try require(harness.permissions.last?.kinds == [.microphone], "microphone request names its kind")
        harness.permission = { $0.kinds == [.notifications] }
        let notification = try await js(tab, "Notification.requestPermission()") as? String
        try require(notification == "granted", "an allowed notification request is delivered to the page")

        // JavaScript dialogs
        harness.dialog = { request in
            switch request.kind {
            case .confirm: (true, nil, false)
            case .prompt: (true, "Ada", false)
            default: (true, nil, false)
            }
        }
        try require(try await js(tab, "confirm('Proceed?')") as? Bool == true, "confirm() is answered by the client")
        try require(try await js(tab, "prompt('Name?', 'x')") as? String == "Ada", "prompt() returns the client's text")
        harness.dialog = { _ in (false, nil, false) }
        try require(try await js(tab, "confirm('No?')") as? Bool == false, "cancelled confirm() returns false")
        let before = harness.dialogs.count
        harness.dialog = { _ in (true, nil, true) }
        _ = try await js(tab, "alert('one'); true")
        _ = try await js(tab, "alert('two'); alert('three'); alert('four'); true")
        try require(harness.dialogs.count == before + 1, "suppressing further dialogs silences the page until it navigates")
        try await load(tab, path: "prompts/page2")
        harness.dialog = { _ in (true, nil, false) }
        let again = harness.dialogs.count
        _ = try await js(tab, "alert('after navigation'); true")
        try require(harness.dialogs.count == again + 1, "dialogs work again after navigation")

        // HTTP authentication
        harness.credentials = { _ in ("ada", "secret") }
        let auth = make("prompts-auth")
        try await load(auth, path: "prompts/auth")
        try require(harness.authRequests.last?.realm == "Cairn Smoke", "basic auth challenge reaches the client with its realm")
        try require(auth.state.title == "authed", "credentials from the client authenticate the request")
        harness.credentials = { _ in nil }
        let cancelled = make("prompts-auth-cancel")
        cancelled.load(base.appendingPathComponent("prompts/auth"))
        try await wait { !cancelled.state.isLoading && cancelled.state.progress >= 1 || cancelled.state.errorMessage != nil }
        try require(cancelled.state.title != "authed", "cancelling the auth prompt does not authenticate")

        // Certificate errors are reported and never bypassed.
        guard let tls = ProcessInfo.processInfo.environment["CAIRN_SMOKE_TLS_URL"].flatMap(URL.init(string:)) else {
            throw SmokeError.failed("Missing CAIRN_SMOKE_TLS_URL")
        }
        let secure = make("prompts-tls")
        secure.load(tls)
        try await wait { !harness.certificateErrors.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        try require(harness.certificateErrors.first?.code == -202, "self-signed certificate is reported as untrusted")
        try require(secure.state.title != "TLS fixture reached" && secure.state.isSecure == false,
                    "the page behind a certificate error is never loaded")
        let leaked = try? await js(secure, "document.body ? document.body.innerText : ''") as? String
        try require(leaked?.contains("TLS fixture reached") != true, "certificate error is not silently bypassed")
        for tab in [tab, auth, cancelled, secure] { tab.close() }
    }
}

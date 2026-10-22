import AppKit
import CairnEngineKit
import Foundation
import Testing
@testable import CairnCore

@MainActor
private final class PromptEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [PromptTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = PromptTab()
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class PromptTab: EngineTab, EngineTabPromptResponding {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom = 1.0
    var permissions: [String: Bool] = [:]
    var dialogs: [String: (accept: Bool, text: String?, suppress: Bool)] = [:]
    var auth: [String: String?] = [:]
    func load(_ url: URL) { state.url = url; delegate?.engineTab(self, didChange: state) }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {}
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() {}
    func resolvePermission(id: String, allow: Bool) { permissions[id] = allow }
    func resolveJSDialog(id: String, accept: Bool, text: String?, suppressFurther: Bool) {
        dialogs[id] = (accept, text, suppressFurther)
    }
    func resolveAuthentication(id: String, username: String?, password: String?) { auth[id] = username }
}

@MainActor
private func makeModel() -> (BrowserModel, PromptEngine, PromptTab, UUID) {
    let engine = PromptEngine()
    let model = BrowserModel(engine: engine)
    let id = model.newTab(url: URL(string: "https://example.com/page")!)
    return (model, engine, engine.tabs[0], id)
}

private func request(_ id: String, origin: String = "https://example.com",
                     kinds: [SitePermissionKind] = [.camera]) -> EnginePermissionRequest {
    EnginePermissionRequest(id: id, origin: origin, topLevelURL: URL(string: origin), kinds: kinds)
}

@MainActor
@Suite struct SitePermissionStoreTests {
    @Test func normalizesOriginsAndRejectsOthers() {
        #expect(SiteOrigin.normalize("HTTPS://Example.com:443/path?q=1") == "https://example.com")
        #expect(SiteOrigin.normalize("http://localhost:3000/") == "http://localhost:3000")
        #expect(SiteOrigin.normalize("file:///etc/hosts") == nil)
        #expect(SiteOrigin.normalize("not a url") == nil)
        #expect(SiteOrigin.isSecureContext("https://example.com"))
        #expect(SiteOrigin.isSecureContext("http://localhost:8080"))
        #expect(SiteOrigin.isSecureContext("http://127.0.0.1"))
        #expect(!SiteOrigin.isSecureContext("http://example.com"))
        #expect(!SiteOrigin.isSecureContext("http://localhost.evil.com"))
    }

    @Test func decisionsAreIsolatedPerProfileAndOrigin() {
        let store = SitePermissionStore()
        store.set(.allow, profileID: "a", origin: "https://example.com/x", kind: .camera)
        #expect(store.decision(profileID: "a", origin: "https://example.com", kind: .camera) == .allow)
        #expect(store.decision(profileID: "b", origin: "https://example.com", kind: .camera) == nil)
        #expect(store.decision(profileID: "a", origin: "https://other.com", kind: .camera) == nil)
        #expect(store.decision(profileID: "a", origin: "https://example.com", kind: .microphone) == nil)
        store.set(.block, profileID: "a", origin: "https://example.com", kind: .camera)
        #expect(store.entries.count == 1)
        #expect(!store.set(.allow, profileID: "a", origin: "file:///x", kind: .camera))
    }

    @Test func persistsAndReloads() throws {
        let directory = try TestDirectory()
        let url = directory.file("permissions.json")
        let first = SitePermissionStore()
        try first.load(from: url)
        first.set(.block, profileID: "p", origin: "https://example.com", kind: .geolocation)
        let second = SitePermissionStore()
        try second.load(from: url)
        #expect(second.decision(profileID: "p", origin: "https://example.com", kind: .geolocation) == .block)
        second.remove(second.entries[0].id)
        let third = SitePermissionStore()
        try third.load(from: url)
        #expect(third.entries.isEmpty)
    }

    @Test func corruptFileIsPreservedAndNeverOverwritten() throws {
        let directory = try TestDirectory()
        let url = directory.file("permissions.json")
        try Data("{ broken".utf8).write(to: url)
        let store = SitePermissionStore()
        #expect(throws: (any Error).self) { try store.load(from: url) }
        #expect(!store.isWritable)
        store.set(.allow, profileID: "p", origin: "https://example.com", kind: .camera)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ broken")
    }
}

@MainActor
@Suite struct TabPromptTests {
    @Test func unknownSiteAsksAndNothingIsAnsweredUntilTheUserDecides() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("m1"))
        #expect(model.prompts.front(id) == .permission(request("m1")))
        #expect(tab.permissions.isEmpty)
        #expect(model.prompts.tabsNeedingAttention == [id])
    }

    @Test func allowRememberedAnswersLaterRequestsWithoutAsking() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("m1"))
        model.answerPermission("m1", tab: id, allow: true, remember: true)
        #expect(tab.permissions["m1"] == true)
        model.engineTab(tab, requestsPermission: request("m2"))
        #expect(tab.permissions["m2"] == true)
        #expect(model.prompts.front(id) == nil)
    }

    @Test func answeringWithoutRememberStoresNothing() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("p1", kinds: [.geolocation]))
        model.answerPermission("p1", tab: id, allow: true, remember: false)
        #expect(tab.permissions["p1"] == true)
        #expect(model.sitePermissions.entries.isEmpty)
    }

    @Test func blockedKindBlocksTheWholeRequest() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("m1", kinds: [.microphone]))
        model.answerPermission("m1", tab: id, allow: false, remember: true)
        model.sitePermissions.set(.allow, profileID: model.selectedSpace.profileID, origin: "https://example.com", kind: .camera)
        model.engineTab(tab, requestsPermission: request("m2", kinds: [.camera, .microphone]))
        #expect(tab.permissions["m2"] == false)
        #expect(model.prompts.front(id) == nil)
    }

    @Test func insecureOriginsAreBlockedWithoutPromptOrMemory() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("p1", origin: "http://example.com", kinds: [.geolocation]))
        #expect(tab.permissions["p1"] == false)
        #expect(model.prompts.front(id) == nil)
        #expect(model.sitePermissions.entries.isEmpty)
        model.engineTab(tab, requestsPermission: request("p2", origin: "http://localhost:3000", kinds: [.geolocation]))
        #expect(model.prompts.front(id) != nil)
    }

    @Test func dismissRemovesThePrompt() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("p1"))
        model.engineTab(tab, dismissesPermission: "p1")
        #expect(model.prompts.front(id) == nil)
    }

    @Test func decisionsAreKeptPerSpace() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("m1"))
        model.answerPermission("m1", tab: id, allow: true, remember: true)
        let first = model.selectedSpace.profileID
        #expect(model.sitePermissions.decision(profileID: first, origin: "https://example.com", kind: .camera) == .allow)
        #expect(model.sitePermissions.decision(profileID: "other-space", origin: "https://example.com", kind: .camera) == nil)
    }

    @Test func dialogsQueueInOrderAndAnswerThroughTheEngine() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsJSDialog: .init(id: "js1", kind: .prompt, message: "Name?", defaultText: "x"))
        model.engineTab(tab, requestsJSDialog: .init(id: "js2", kind: .confirm, message: "Sure?"))
        #expect(model.prompts.front(id)?.id == "js1")
        model.answerJSDialog("js1", tab: id, accept: true, text: "Ada")
        #expect(tab.dialogs["js1"]?.text == "Ada")
        #expect(model.prompts.front(id)?.id == "js2")
        model.answerJSDialog("js2", tab: id, accept: false, suppressFurther: true)
        #expect(tab.dialogs["js2"]?.accept == false)
        #expect(tab.dialogs["js2"]?.suppress == true)
        #expect(model.prompts.front(id) == nil)
    }

    @Test func suppressionIsOfferedFromTheSecondDialogUntilNavigation() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsJSDialog: .init(id: "js1", kind: .alert, message: "a"))
        #expect(!model.prompts.offersSuppression(id))
        model.engineTab(tab, requestsJSDialog: .init(id: "js2", kind: .alert, message: "b"))
        #expect(model.prompts.offersSuppression(id))
        var state = EngineTabState(url: URL(string: "https://example.com/next")!)
        state.isLoading = true
        model.engineTab(tab, didChange: state)
        #expect(!model.prompts.offersSuppression(id))
    }

    @Test func authenticationCancelsOrSendsCredentials() {
        let (model, _, tab, id) = makeModel()
        let auth = EngineAuthRequest(id: "a1", host: "example.com", port: 443, realm: "Admin", scheme: "basic",
                                     isProxy: false, url: URL(string: "https://example.com/"))
        model.engineTab(tab, requestsAuthentication: auth)
        model.answerAuthentication("a1", tab: id, username: "ada", password: "pw")
        #expect(tab.auth["a1"] == .some("ada"))
        model.engineTab(tab, requestsAuthentication: .init(id: "a2", host: "example.com", port: 443, realm: "", scheme: "basic",
                                                           isProxy: false, url: nil))
        model.answerAuthentication("a2", tab: id, username: nil, password: nil)
        #expect(tab.auth["a2"] == .some(nil))
    }

    @Test func closingATabCancelsEverythingItWasWaitingOn() {
        let (model, _, tab, id) = makeModel()
        model.engineTab(tab, requestsPermission: request("m1"))
        model.engineTab(tab, requestsJSDialog: .init(id: "js1", kind: .confirm, message: "x"))
        model.engineTab(tab, requestsAuthentication: .init(id: "a1", host: "h", port: 1, realm: "", scheme: "basic",
                                                           isProxy: false, url: nil))
        model.unloadTab(id)
        #expect(tab.permissions["m1"] == false)
        #expect(tab.dialogs["js1"]?.accept == false)
        #expect(tab.auth["a1"] == .some(nil))
        #expect(model.prompts.front(id) == nil)
    }

    @Test func certificateNoticeIsOnlyForThePageAndClearsOnSuccess() {
        let (model, _, tab, id) = makeModel()
        let url = URL(string: "https://example.com/page")!
        model.engineTab(tab, blockedCertificate: .init(url: URL(string: "https://cdn.other.com/a.js")!, code: -202))
        #expect(model.prompts.certificateErrors[id] == nil)
        model.engineTab(tab, blockedCertificate: .init(url: url, code: -202))
        #expect(model.prompts.certificateErrors[id]?.code == -202)
        model.engineTab(tab, didChange: EngineTabState(url: url, isLoading: false, errorMessage: "Failed"))
        #expect(model.prompts.certificateErrors[id] != nil)
        model.engineTab(tab, didChange: EngineTabState(url: url, isLoading: false))
        #expect(model.prompts.certificateErrors[id] == nil)
    }

    @Test func certificateExplanationsNameTheProblem() {
        let url = URL(string: "https://expired.example/")!
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        let expired = CertificateErrorInfo.describe(.init(url: url, code: -201, validUntil: past))
        #expect(expired.name == "ERR_CERT_DATE_INVALID")
        #expect(expired.reason.contains("expired"))
        #expect(CertificateErrorInfo.describe(.init(url: url, code: -200)).reason.contains("expired.example"))
        #expect(CertificateErrorInfo.describe(.init(url: url, code: -999)).name.contains("-999"))
    }
}

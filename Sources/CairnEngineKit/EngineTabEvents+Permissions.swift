import Foundation

// Engine → app events for the prompts a page can raise: site permissions, JavaScript dialogs, HTTP
// authentication and blocked certificates. Additive: `EngineTabDelegate` is untouched. The app adopts
// `EngineTabPromptEvents` (BrowserModel+Permissions.swift) and answers through `EngineTabPromptResponding`,
// which the Chromium tab adopts. A request that is never answered is cancelled when the tab closes.

public enum SitePermissionKind: String, Codable, CaseIterable, Sendable, Hashable {
    case camera, microphone, geolocation, notifications, clipboard, multipleDownloads, storageAccess
    case localNetwork, keyboardLock, pointerLock, midiSysex, windowManagement, localFonts, idleDetection

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .geolocation: "Location"
        case .notifications: "Notifications"
        case .clipboard: "Clipboard"
        case .multipleDownloads: "Multiple downloads"
        case .storageAccess: "Cross-site cookies and storage"
        case .localNetwork: "Devices on your local network"
        case .keyboardLock: "Keyboard lock"
        case .pointerLock: "Pointer lock"
        case .midiSysex: "MIDI devices"
        case .windowManagement: "Window management"
        case .localFonts: "Local fonts"
        case .idleDetection: "Idle detection"
        }
    }

    /// Phrase completing "wants to …" in a prompt.
    public var action: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .geolocation: "know your location"
        case .notifications: "show notifications"
        case .clipboard: "see text and images you copy"
        case .multipleDownloads: "download multiple files"
        case .storageAccess: "use its cookies and data while embedded in another site"
        case .localNetwork: "connect to devices on your local network"
        case .keyboardLock: "capture your keyboard"
        case .pointerLock: "hide and capture your pointer"
        case .midiSysex: "use your MIDI devices"
        case .windowManagement: "manage windows on your displays"
        case .localFonts: "see the fonts installed on this Mac"
        case .idleDetection: "know when you are idle"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .geolocation: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        case .multipleDownloads: "arrow.down.circle"
        case .storageAccess: "externaldrive"
        case .localNetwork: "network"
        case .keyboardLock: "keyboard"
        case .pointerLock: "cursorarrow"
        case .midiSysex: "pianokeys"
        case .windowManagement: "macwindow.on.rectangle"
        case .localFonts: "textformat"
        case .idleDetection: "moon"
        }
    }
}

public struct EnginePermissionRequest: Identifiable, Equatable, Sendable {
    public var id: String
    /// Origin asking, e.g. `https://example.com`.
    public var origin: String
    /// URL of the page the user is looking at; differs from `origin` for embedded frames.
    public var topLevelURL: URL?
    public var kinds: [SitePermissionKind]
    public init(id: String, origin: String, topLevelURL: URL?, kinds: [SitePermissionKind]) {
        self.id = id; self.origin = origin; self.topLevelURL = topLevelURL; self.kinds = kinds
    }
}

public enum EngineJSDialogKind: String, Sendable {
    case alert, confirm, prompt, beforeUnload
}

public struct EngineJSDialogRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: EngineJSDialogKind
    public var message: String
    public var defaultText: String
    public var origin: String
    /// A `beforeunload` raised by a reload rather than by leaving the page.
    public var isReload: Bool
    public init(id: String, kind: EngineJSDialogKind, message: String, defaultText: String = "",
                origin: String = "", isReload: Bool = false) {
        self.id = id; self.kind = kind; self.message = message; self.defaultText = defaultText
        self.origin = origin; self.isReload = isReload
    }
}

public struct EngineAuthRequest: Identifiable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var port: Int
    public var realm: String
    public var scheme: String
    public var isProxy: Bool
    /// The URL that asked; its scheme tells whether the credentials would cross the network unencrypted.
    public var url: URL?
    public init(id: String, host: String, port: Int, realm: String, scheme: String, isProxy: Bool, url: URL?) {
        self.id = id; self.host = host; self.port = port; self.realm = realm
        self.scheme = scheme; self.isProxy = isProxy; self.url = url
    }
}

/// A TLS failure the engine refused. The engine never continues past one, so there is no "proceed" response.
public struct EngineCertificateError: Equatable, Sendable {
    public var url: URL
    /// Chromium `net::Error` value, e.g. -201 (`ERR_CERT_DATE_INVALID`).
    public var code: Int
    public var subject: String?
    public var issuer: String?
    public var validFrom: Date?
    public var validUntil: Date?
    public init(url: URL, code: Int, subject: String? = nil, issuer: String? = nil,
                validFrom: Date? = nil, validUntil: Date? = nil) {
        self.url = url; self.code = code; self.subject = subject; self.issuer = issuer
        self.validFrom = validFrom; self.validUntil = validUntil
    }
}

@MainActor
public protocol EngineTabPromptEvents: EngineTabEvents {
    func engineTab(_ tab: EngineTab, requestsPermission request: EnginePermissionRequest)
    func engineTab(_ tab: EngineTab, dismissesPermission id: String)
    func engineTab(_ tab: EngineTab, requestsJSDialog request: EngineJSDialogRequest)
    func engineTab(_ tab: EngineTab, dismissesJSDialog id: String)
    func engineTab(_ tab: EngineTab, requestsAuthentication request: EngineAuthRequest)
    func engineTab(_ tab: EngineTab, dismissesAuthentication id: String)
    func engineTab(_ tab: EngineTab, blockedCertificate error: EngineCertificateError)
}

public extension EngineTabPromptEvents {
    func engineTab(_ tab: EngineTab, requestsPermission request: EnginePermissionRequest) {}
    func engineTab(_ tab: EngineTab, dismissesPermission id: String) {}
    func engineTab(_ tab: EngineTab, requestsJSDialog request: EngineJSDialogRequest) {}
    func engineTab(_ tab: EngineTab, dismissesJSDialog id: String) {}
    func engineTab(_ tab: EngineTab, requestsAuthentication request: EngineAuthRequest) {}
    func engineTab(_ tab: EngineTab, dismissesAuthentication id: String) {}
    func engineTab(_ tab: EngineTab, blockedCertificate error: EngineCertificateError) {}
}

/// Answers to the requests above. Implemented by the engine tab.
@MainActor
public protocol EngineTabPromptResponding: EngineTab {
    func resolvePermission(id: String, allow: Bool)
    /// `text` is the prompt() answer; `suppressFurther` silences further dialogs until the next navigation.
    func resolveJSDialog(id: String, accept: Bool, text: String?, suppressFurther: Bool)
    /// `nil` credentials cancel the request.
    func resolveAuthentication(id: String, username: String?, password: String?)
}

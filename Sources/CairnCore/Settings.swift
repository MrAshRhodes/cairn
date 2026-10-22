import Foundation
import Observation
import CairnEngineKit

@MainActor @Observable
public final class Settings {
    public var searchTemplate = URLResolver.defaultSearchTemplate
    /// Zero disables automatic archiving.
    public var autoArchiveAfterHours: Double = 12
    public var restoreSessionOnLaunch = true
    public var sidebarWidth: Double = 260
    /// Comma-separated language tags; empty follows the system language list.
    public var acceptLanguages = ""
    /// Complete user agent string; empty keeps Chromium's own identity.
    public var userAgent = ""
    public init() {}

    /// What the engine applies: the user's choice, else the system languages, plus the optional user agent override.
    public var pagePreferences: PagePreferences {
        PagePreferences(acceptLanguages: PagePreferences.normalizedLanguages(acceptLanguages) ?? PagePreferences.systemLanguages(),
                        userAgent: userAgent)
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var searchTemplate: String
        /// Legacy key: v0.1.0 requires it, so it is still written. Chromium is the only engine, so a value
        /// stored by older builds and the old `engineKindIsExplicit` flag are ignored on load.
        var engineKind: String? = "chromium"
        var autoArchiveAfterHours: Double
        var restoreSessionOnLaunch: Bool
        var sidebarWidth: Double
        var acceptLanguages: String?
        var userAgent: String?

        func validate() throws {
            guard URLResolver.isValidSearchTemplate(searchTemplate) else {
                throw ServiceError.invalidData("Search template must be an HTTP(S) URL with one %s query placeholder.")
            }
            guard (acceptLanguages ?? "").isEmpty || PagePreferences.normalizedLanguages(acceptLanguages ?? "") != nil,
                  PagePreferences.isValidUserAgent(userAgent ?? "") else {
                throw ServiceError.invalidData("Language or user agent setting is not valid.")
            }
            guard autoArchiveAfterHours.isFinite, (0...8_760).contains(autoArchiveAfterHours),
                  sidebarWidth.isFinite, (180...600).contains(sidebarWidth) else {
                throw ServiceError.invalidData("Settings values are outside their supported ranges.")
            }
        }
    }

    public static func load(from url: URL) throws -> Settings {
        let settings = Settings()
        guard let data = try JSONStorage.read(url) else { return settings }
        let document = try decode(data)
        settings.searchTemplate = document.searchTemplate
        settings.autoArchiveAfterHours = document.autoArchiveAfterHours
        settings.restoreSessionOnLaunch = document.restoreSessionOnLaunch
        settings.sidebarWidth = document.sidebarWidth
        settings.acceptLanguages = document.acceptLanguages ?? ""
        settings.userAgent = document.userAgent ?? ""
        return settings
    }

    /// Existing invalid/newer data is preserved, even if the caller skipped `load`.
    public func save(to url: URL) throws {
        let document = Document(searchTemplate: searchTemplate,
                                autoArchiveAfterHours: autoArchiveAfterHours,
                                restoreSessionOnLaunch: restoreSessionOnLaunch, sidebarWidth: sidebarWidth,
                                acceptLanguages: acceptLanguages.isEmpty ? nil : acceptLanguages,
                                userAgent: userAgent.isEmpty ? nil : userAgent)
        try document.validate()
        if let existing = try JSONStorage.read(url) { _ = try Self.decode(existing) }
        try JSONStorage.write(document, to: url)
    }

    private static func decode(_ data: Data) throws -> Document {
        let document = try JSONStorage.decode(Document.self, from: data, schema: 1)
        try document.validate()
        return document
    }
}

import Foundation
import Observation
import CairnEngineKit

@MainActor @Observable
public final class Settings {
    public var searchTemplate = URLResolver.defaultSearchTemplate
    public var engineKind: EngineKind
    /// Zero disables automatic archiving.
    public var autoArchiveAfterHours: Double = 12
    public var restoreSessionOnLaunch = true
    public var sidebarWidth: Double = 260
    public init(engineKind: EngineKind = .webkit) {
        self.engineKind = engineKind
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var searchTemplate: String
        var engineKind: EngineKind
        var autoArchiveAfterHours: Double
        var restoreSessionOnLaunch: Bool
        var sidebarWidth: Double

        func validate() throws {
            guard URLResolver.isValidSearchTemplate(searchTemplate) else {
                throw ServiceError.invalidData("Search template must be an HTTP(S) URL with one %s query placeholder.")
            }
            guard autoArchiveAfterHours.isFinite, (0...8_760).contains(autoArchiveAfterHours),
                  sidebarWidth.isFinite, (180...600).contains(sidebarWidth) else {
                throw ServiceError.invalidData("Settings values are outside their supported ranges.")
            }
        }
    }

    public static func load(from url: URL, defaultEngineKind: EngineKind = .webkit) throws -> Settings {
        let settings = Settings(engineKind: defaultEngineKind)
        guard let data = try JSONStorage.read(url) else { return settings }
        let document = try decode(data)
        settings.searchTemplate = document.searchTemplate
        settings.engineKind = document.engineKind
        settings.autoArchiveAfterHours = document.autoArchiveAfterHours
        settings.restoreSessionOnLaunch = document.restoreSessionOnLaunch
        settings.sidebarWidth = document.sidebarWidth
        return settings
    }

    /// Existing invalid/newer data is preserved, even if the caller skipped `load`.
    public func save(to url: URL) throws {
        let document = Document(searchTemplate: searchTemplate, engineKind: engineKind,
                                autoArchiveAfterHours: autoArchiveAfterHours,
                                restoreSessionOnLaunch: restoreSessionOnLaunch, sidebarWidth: sidebarWidth)
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

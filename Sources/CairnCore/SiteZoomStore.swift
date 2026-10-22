import Foundation

/// Zoom factor remembered per (profile, host). Only non-default factors are kept; a Space's profile keeps its
/// sites' zoom private to it. Unreadable data is never overwritten.
@MainActor
public final class SiteZoomStore {
    public static let range: ClosedRange<Double> = 0.25...5
    private struct Document: Codable {
        var schemaVersion = 1
        var levels: [String: Double]
    }

    private var levels: [String: Double] = [:]
    private let url: URL?
    public private(set) var isWritable = true
    public var onError: ((Error) -> Void)?

    public init(url: URL? = nil) throws {
        self.url = url
        guard let url else { return }
        do {
            if let data = try JSONStorage.read(url) {
                let document = try JSONStorage.decode(Document.self, from: data, schema: 1)
                levels = document.levels.filter { Self.isValid(key: $0.key, zoom: $0.value) }
            }
        } catch {
            isWritable = false
            throw error
        }
    }

    public static func key(profileID: String, url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return profileID + "\u{1F}" + host
    }

    public func zoom(profileID: String, url: URL?) -> Double? {
        Self.key(profileID: profileID, url: url).flatMap { levels[$0] }
    }

    /// A factor of 1 removes the entry. Returns false when nothing changed.
    @discardableResult
    public func setZoom(_ zoom: Double, profileID: String, url: URL?) -> Bool {
        guard let key = Self.key(profileID: profileID, url: url), zoom.isFinite else { return false }
        let clamped = min(max(zoom, Self.range.lowerBound), Self.range.upperBound)
        let isDefault = abs(clamped - 1) < 0.0005
        if isDefault { guard levels.removeValue(forKey: key) != nil else { return false } }
        else {
            if let old = levels[key], abs(old - clamped) < 0.0005 { return false }
            levels[key] = clamped
        }
        save()
        return true
    }

    public func removeAll() { levels.removeAll(); save() }
    public var count: Int { levels.count }

    private static func isValid(key: String, zoom: Double) -> Bool {
        zoom.isFinite && range.contains(zoom) && key.contains("\u{1F}")
    }

    private func save() {
        guard isWritable, let url else { return }
        do { try JSONStorage.write(Document(levels: levels), to: url) }
        catch { onError?(error) }
    }
}

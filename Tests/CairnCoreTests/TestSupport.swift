import Foundation
import Testing

final class TestDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".core-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Unable to clean test directory: \(error)") }
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

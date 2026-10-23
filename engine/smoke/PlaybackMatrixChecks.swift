import CairnEngineKit
import Foundation

extension Smoke {
    func checkPlaybackMatrix() async throws {
        let tab = make("playback-matrix")
        defer { tab.close() }
        try await load(tab, path: "playback-matrix.html")
        try await click(tab, elementID: "run")
        var finished = false
        for _ in 0..<400 {
            if try await js(tab, "window.matrix.done") as? Bool == true {
                finished = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(finished, "local playback matrix settles")
        guard let report = try await js(tab, "JSON.stringify(window.matrix)") as? String else {
            throw SmokeError.failed("Missing playback matrix")
        }
        print("PLAYBACK_MATRIX: \(report)")
        try require(try await js(tab, """
            matrix.playback.length === 3 &&
            matrix.playback[0].status === 'passed' &&
            matrix.playback.every(row => row.status === 'passed' || row.status === 'not-tested')
            """) as? Bool == true, "synthetic PCM and available WebM encoders produce playable local media")
    }
}

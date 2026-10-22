import AppKit
import CryptoKit
import CairnEngineKit
import CairnChromiumEngine

// Site-data clearing, content blocking, Space deletion and orphan GC against the real engine.
extension Smoke {
    private static let seedScript = """
        (async () => {
          localStorage.setItem('k', 'v');
          await new Promise((resolve, reject) => {
            const open = indexedDB.open('cairn-smoke', 1);
            open.onupgradeneeded = () => open.result.createObjectStore('s');
            open.onerror = () => reject(open.error);
            open.onsuccess = () => {
              const tx = open.result.transaction('s', 'readwrite');
              tx.objectStore('s').put(1, 'a');
              tx.oncomplete = () => { open.result.close(); resolve(); };
              tx.onerror = () => reject(tx.error);
            };
          });
          const cache = await caches.open('cairn-smoke');
          await cache.put('/x', new Response('x'));
          document.cookie = 'sess=1; path=/';
          return true;
        })()
        """
    private static let probeScript = """
        (async () => [
          localStorage.getItem('k') === 'v',
          (await indexedDB.databases()).some(d => d.name === 'cairn-smoke'),
          await caches.has('cairn-smoke'),
          document.cookie.includes('sess=1')
        ])()
        """

    private func present(_ tab: EngineTab) async throws -> [Bool] {
        (try await js(tab, Self.probeScript) as? [Bool]) ?? []
    }

    private func seeded(_ profile: String) async throws -> EngineTab {
        let tab = make(profile)
        try await load(tab)
        try require(try await js(tab, Self.seedScript) as? Bool == true, "\(profile): cookie, localStorage, IndexedDB and Cache Storage seeded")
        try require(try await present(tab) == [true, true, true, true], "\(profile): seeded data is visible")
        return tab
    }

    private func profileDirectory(_ profile: String) -> URL {
        root.appendingPathComponent(ChromiumEngine.profileDirectory(profile))
    }

    func siteDataScenario() async throws {
        let a = try await seeded("sitedata-a")
        let b = try await seeded("sitedata-b")

        // Live tab: per-site clear of one Space leaves the other Space alone.
        let host = base.host() ?? "127.0.0.1"
        let live = await engine.clearSiteData(profileID: "sitedata-a", site: host, kinds: [.cookies, .storage])
        try require(live.isComplete, "per-site clear reports no failures: \(live.failures)")
        try await load(a)
        try require(try await present(a) == [false, false, false, false], "per-site clear removes cookie, localStorage, IndexedDB and Cache Storage")
        try require(try await present(b) == [true, true, true, true], "clearing one Space leaves another Space's data")
        try require(engine.lastDataRemovalError == nil && a.state.errorMessage == nil, "clearing raises no per-tab error")

        // No open tab: a hidden browser reaches the profile's storage.
        _ = try await js(a, Self.seedScript)
        a.close()
        try await Task.sleep(for: .milliseconds(500))
        let closed = await engine.clearSiteData(profileID: "sitedata-a", site: nil, kinds: .all)
        try require(closed.isComplete, "whole-profile clear without open tabs reports no failures: \(closed.failures)")
        let reopened = make("sitedata-a")
        try await load(reopened)
        try require(try await present(reopened) == [false, false, false, false], "whole-profile clear works with zero open tabs")

        // Content blocking: third-party only, per-site exemption, off switch.
        let port = base.port ?? 80
        let thirdParty = "fetch('http://localhost:\(port)/probe.json', {mode: 'no-cors'}).then(() => 'ok', () => 'blocked')"
        try require(try await js(b, thirdParty) as? String == "ok", "third-party request loads while blocking is off")
        let blockedBefore = engine.blockedRequestCount
        engine.configureContentBlocking(.init(isEnabled: true, blockedHosts: ["localhost"]))
        try require(try await js(b, thirdParty) as? String == "blocked", "listed third-party host is blocked")
        try require(engine.blockedRequestCount > blockedBefore, "blocked requests are counted")
        try require(try await js(b, "fetch('/probe.json').then(() => 'ok', () => 'blocked')") as? String == "ok", "first-party requests are never blocked")
        engine.configureContentBlocking(.init(isEnabled: true, blockedHosts: ["localhost"], exemptSites: [host]))
        try require(try await js(b, thirdParty) as? String == "ok", "per-site exemption disables blocking")
        engine.configureContentBlocking(.init(isEnabled: false, blockedHosts: ["localhost"]))
        try require(try await js(b, thirdParty) as? String == "ok", "blocking can be switched off")

        // Deleting a Space removes its profile directory.
        let c = try await seeded("sitedata-c")
        try await Task.sleep(for: .seconds(2)) // let Chromium create the profile files
        try require(FileManager.default.fileExists(atPath: profileDirectory("sitedata-c").path), "profile directory exists before deletion")
        c.close()
        await engine.deleteProfileData(profileID: "sitedata-c")
        try require(!FileManager.default.fileExists(atPath: profileDirectory("sitedata-c").path), "deleting a Space removes its profile directory")
        try require(!FileManager.default.fileExists(atPath: profileDirectory("sitedata-c").path + ".delete"), "deletion marker is cleaned up")

        // Orphan GC removes only unreferenced profile directories.
        let orphan = ChromiumEngine.profileDirectory("removed-long-ago")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(orphan), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent(orphan).appendingPathComponent("Cookies"))
        let keep: Set<String> = ["first", "second", "sitedata-a", "sitedata-b"]
        let removed = engine.removeOrphanProfiles(keeping: keep)
        try require(removed.contains(orphan), "orphan profile directory is collected")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan).path), "orphan directory is gone")
        try require(keep.allSatisfy { FileManager.default.fileExists(atPath: profileDirectory($0).path) }, "referenced profile directories are kept")
    }
}

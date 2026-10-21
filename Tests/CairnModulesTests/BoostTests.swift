import Foundation
import JavaScriptCore
import Testing
@testable import CairnBoosts
import CairnEngineKit

@Suite @MainActor struct BoostTests {
    @Test(arguments: [
        ("https://example.com", true), ("http://www.example.com/path", true),
        ("https://a.b.example.com:8443", true), ("https://EXAMPLE.COM./", true),
        ("https://evilexample.com", false), ("https://example.com.evil.test", false),
        ("https://example.com@evil.test", false), ("https://example.com.evil.test/?example.com", false),
        ("file://example.com/index.html", false), ("ftp://example.com", false),
        ("data:text/html,example.com", false), ("about:blank", false),
    ])
    func hostMatchingRespectsBoundariesAndSchemes(address: String, expected: Bool) throws {
        let boost = Boost(name: "Example", hostPatterns: ["example.com"], css: "body {}")
        #expect(boost.matches(try #require(URL(string: address))) == expected)
    }

    @Test func explicitWildcardsAndNormalizedHosts() throws {
        let any = Boost(name: "Any", hostPatterns: ["*"], css: "body {}")
        let subdomains = Boost(name: "Subdomains", hostPatterns: ["*.EXAMPLE.com."], css: "body {}")
        try subdomains.validate()
        #expect(!subdomains.matches(URL(string: "https://example.com")!))
        #expect(subdomains.matches(URL(string: "https://www.example.com")!))
        #expect(!subdomains.matches(URL(string: "https://evilexample.com")!))
        #expect(any.matches(URL(string: "http://localhost:8000")!))
        #expect(any.matches(URL(string: "https://[::1]/")!))
        #expect(!any.matches(URL(string: "file:///example.com")!))
        let local = Boost(name: "Local", hostPatterns: ["localhost", "127.0.0.1"])
        try local.validate()
        #expect(local.matches(URL(string: "http://127.0.0.1:8080/")!))
    }

    @Test(arguments: [
        "", " ", "https://example.com", ".example.com", "example..com", "example.com..",
        "evil*example.com", "*example.com", "example.*", "example.com/path",
        "example.com:443", "example.com@evil.test", "example.com?x", "example.com#x",
        "example.com\n", "example.com\\evil", "example%2ecom", "-example.com",
        "example-.com", "example_com", "example.com\";globalThis.pwned=true;//", "éxample.com", "K.example.com",
    ])
    func malformedPatternsAreRejected(pattern: String) {
        let boost = Boost(name: "Bad", hostPatterns: [pattern], css: "body {}")
        #expect(throws: BoostError.self) { try boost.validate() }
        #expect(!boost.matches(URL(string: "https://example.com")!))
    }

    @Test func crudRoundTripAndDirectoryIsolation() throws {
        let first = try ModuleFixture()
        let second = try ModuleFixture()
        defer { first.remove(); second.remove() }
        let store = BoostStore(directory: first.directory.appendingPathComponent("Boosts"))
        try store.load()
        #expect(store.boosts.isEmpty)
        let original = Boost(name: "Readable", hostPatterns: ["example.com"], css: "body { color: red; }")
        try store.add(original)
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("boosts.json").path))
        let other = BoostStore(directory: second.directory)
        try other.load()
        #expect(other.boosts.isEmpty)
        let reloaded = BoostStore(directory: store.directory)
        try reloaded.load()
        #expect(reloaded.boosts == [original])
        var changed = original
        changed.name = "Edited"
        changed.css = "body { color: blue; }"
        try reloaded.update(changed)
        try reloaded.setEnabled(false, for: original.id)
        try store.load()
        #expect(store.boosts[0].name == "Edited")
        #expect(store.boosts[0].css == changed.css)
        #expect(!store.boosts[0].isEnabled)
        #expect(store.scripts(for: URL(string: "https://example.com")).isEmpty)
        try store.save()
        try store.remove(original.id)
        try reloaded.load()
        #expect(reloaded.boosts.isEmpty)
    }

    @Test func mutationsLoadExistingStoreAndRejectDuplicateOrMissingIDs() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let original = Boost(name: "Original", hostPatterns: ["example.com"])
        let store = BoostStore(directory: fixture.directory)
        try store.add(original)
        let reopened = BoostStore(directory: fixture.directory)
        let extra = Boost(name: "Second", hostPatterns: ["example.org"])
        try reopened.add(extra)
        #expect(reopened.boosts == [original, extra])
        #expect(throws: BoostError.self) { try reopened.add(original) }
        let missing = Boost(name: "Missing", hostPatterns: ["example.com"])
        #expect(throws: BoostError.self) { try reopened.update(missing) }
        #expect(throws: BoostError.self) { try reopened.remove(missing.id) }
        #expect(throws: BoostError.self) { try reopened.setEnabled(false, for: missing.id) }
        #expect(throws: BoostError.self) { try reopened.setJavaScriptTrusted(true, for: missing.id) }
        #expect(throws: BoostError.self) { try reopened.add(Boost(name: "", hostPatterns: ["*"])) }
        #expect(throws: BoostError.self) { try reopened.add(Boost(name: "No scope", hostPatterns: [])) }
        #expect(throws: BoostError.self) { try reopened.add(Boost(name: "Too large", hostPatterns: ["*"], css: String(repeating: "x", count: 256 * 1024 + 1))) }
        #expect(reopened.boosts == [original, extra])
    }

    @Test(arguments: [
        "{invalid",
        #"{"schemaVersion":9,"boosts":[]}"#,
        #"{"schemaVersion":1,"boosts":[{}]}"#,
        #"{"schemaVersion":1,"boosts":"not an array"}"#,
        #"[]"#,
    ])
    func invalidDocumentsDoNotReplaceMemoryOrGetSilentlyOverwritten(document: String) throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let store = BoostStore(directory: fixture.directory)
        let boost = Boost(name: "Original", hostPatterns: ["example.com"], css: "body {}")
        try store.add(boost)
        let data = Data(document.utf8)
        let file = fixture.directory.appendingPathComponent("boosts.json")
        try data.write(to: file)
        #expect(throws: BoostError.self) { try store.load() }
        #expect(store.boosts == [boost])
        #expect(try Data(contentsOf: file) == data)
        let fresh = BoostStore(directory: fixture.directory)
        #expect(throws: BoostError.self) { try fresh.add(boost) }
        #expect(fresh.boosts.isEmpty)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func duplicateStoredIDsAndInvalidPatternsAreRejected() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let boost = Boost(name: "Example", hostPatterns: ["example.com"])
        let encoded = try JSONEncoder().encode([boost, boost])
        let array = try JSONSerialization.jsonObject(with: encoded)
        let file = fixture.directory.appendingPathComponent("boosts.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "boosts": array]).write(to: file)
        let store = BoostStore(directory: fixture.directory)
        #expect(throws: BoostError.self) { try store.load() }
        let invalid = Boost(name: "Invalid", hostPatterns: ["https://example.com"])
        let invalidArray = try JSONSerialization.jsonObject(with: JSONEncoder().encode([invalid]))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "boosts": invalidArray]).write(to: file)
        #expect(throws: BoostError.self) { try store.load() }
        #expect(store.boosts.isEmpty)
    }

    @Test func filesystemErrorsPreservePublishedState() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let directory = fixture.directory.appendingPathComponent("store")
        let savedDirectory = fixture.directory.appendingPathComponent("saved-store")
        let store = BoostStore(directory: directory)
        let boost = Boost(name: "Original", hostPatterns: ["example.com"])
        try store.add(boost)
        let persisted = try Data(contentsOf: directory.appendingPathComponent("boosts.json"))
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try Data("Not a directory".utf8).write(to: directory)
        #expect(throws: BoostError.self) { try store.add(Boost(name: "New", hostPatterns: ["example.com"])) }
        var edited = boost
        edited.name = "Changed"
        #expect(throws: BoostError.self) { try store.update(edited) }
        #expect(throws: BoostError.self) { try store.remove(boost.id) }
        #expect(store.boosts == [boost])
        #expect(try Data(contentsOf: savedDirectory.appendingPathComponent("boosts.json")) == persisted)
        #expect(throws: BoostError.self) { try BoostStore(directory: URL(string: "https://example.com")!).load() }
    }

    @Test func failedAtomicReplacementDoesNotPublishMutation() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let store = BoostStore(directory: fixture.directory)
        let boost = Boost(name: "Original", hostPatterns: ["example.com"])
        try store.add(boost)
        let file = fixture.directory.appendingPathComponent("boosts.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("Keep".utf8).write(to: file.appendingPathComponent("sentinel"))
        #expect(throws: (any Error).self) { try store.remove(boost.id) }
        #expect(store.boosts == [boost])
        #expect(FileManager.default.fileExists(atPath: file.appendingPathComponent("sentinel").path))
    }

    @Test func storedSymlinksAreRejected() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("target.json")
        try Data(#"{"schemaVersion":1,"boosts":[]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("boosts.json"), withDestinationURL: target)
        #expect(throws: BoostError.self) { try BoostStore(directory: fixture.directory).load() }
        try FileManager.default.removeItem(at: target)
        #expect(throws: BoostError.self) { try BoostStore(directory: fixture.directory).load() }
    }

    @Test func shippedExampleIsCSSOnlyAndValid() throws {
        let store = BoostStore(directory: ModuleFixture.repositoryRoot.appendingPathComponent("examples/boosts"))
        try store.load()
        #expect(store.boosts.count == 1)
        #expect(store.boosts.allSatisfy { $0.js.isEmpty })
        #expect(store.trustedJavaScriptIDs.isEmpty)
        #expect(store.scripts(for: nil).count == 1)
    }

    @Test func cssIsEncodedAsDataNotExecutableJavaScriptAndIsIdempotent() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let css = "body::before { content: \"` ${globalThis.pwned = true} \\\\ ' </script>\"; }\n\u{2028}\u{2029}\u{0000}\n\"; globalThis.pwned = true; //"
        let store = BoostStore(directory: fixture.directory)
        let boost = Boost(name: "Escaped", hostPatterns: ["example.com"], css: css)
        try store.add(boost)
        let script = try #require(store.scripts(for: nil).first)
        #expect(script.injection == .documentEnd)
        let context = try makeContext(url: "https://example.com/")
        context.evaluateScript(script.source)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("globalThis.pwned")?.isUndefined == true)
        #expect(context.evaluateScript("Object.values(styles)[0].textContent")?.toString() == css)
        context.evaluateScript(script.source)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.keys(styles).length")?.toInt32() == 1)
    }

    @Test func guardedScriptsSurviveCrossSiteNavigationInOneTab() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let store = BoostStore(directory: fixture.directory)
        try store.add(Boost(name: "Example", hostPatterns: ["example.com"], css: "body {color: red}"))
        try store.add(Boost(name: "Other", hostPatterns: ["other.test"], css: "body {color: blue}"))
        let scripts = store.scripts(for: URL(string: "https://unmatched.test"))
        #expect(scripts.count == 2)
        #expect(store.scripts(for: nil) == scripts)
        #expect(store.scripts(for: URL(string: "about:blank")) == scripts)
        for _ in 0..<20 { #expect(store.scripts(for: nil) == scripts) }
        for (url, expected) in [
            ("https://example.com", "body {color: red}"),
            ("http://sub.example.com", "body {color: red}"),
            ("https://other.test", "body {color: blue}"),
            ("https://evilexample.com", ""),
            ("https://example.com.evil.test", ""),
            ("file://example.com/test", ""),
            ("about:blank", ""),
        ] {
            let context = try makeContext(url: url)
            for script in scripts { context.evaluateScript(script.source) }
            #expect(context.exception == nil)
            #expect(context.evaluateScript("Object.values(styles).map(s => s.textContent).join('')")?.toString() == expected)
        }
    }

    @Test func wildcardRuntimeMatchesSwiftSemantics() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let store = BoostStore(directory: fixture.directory)
        for pattern in ["*.example.com", "*", "EXAMPLE.COM."] {
            let boost = Boost(name: "Scope", hostPatterns: [pattern], css: "body {}")
            try store.add(boost)
            let script = try #require(store.scripts(for: nil).first)
            for url in ["https://example.com", "https://sub.example.com", "https://evilexample.com", "https://example.com.", "file://example.com/a", "https://[::1]/"] {
                let context = try makeContext(url: url)
                context.evaluateScript(script.source)
                #expect(context.exception == nil)
                #expect((context.evaluateScript("Object.keys(styles).length")?.toInt32() == 1) == boost.matches(URL(string: url)!))
            }
            try store.remove(boost.id)
        }
    }

    @Test func javaScriptIsOffByDefaultAndTrustIsRevokedOnSourceOrScopeChanges() throws {
        let fixture = try ModuleFixture()
        defer { fixture.remove() }
        let store = BoostStore(directory: fixture.directory)
        var boost = Boost(name: "Local Script", hostPatterns: ["example.com"], js: "globalThis.ran = true;")
        try store.add(boost)
        #expect(store.scripts(for: nil).isEmpty)
        try store.setJavaScriptTrusted(true, for: boost.id)
        let script = try #require(store.scripts(for: nil).first)
        for (url, expected) in [("https://example.com", true), ("https://evilexample.com", false), ("file://example.com/test", false)] {
            let context = try makeContext(url: url)
            context.evaluateScript(script.source)
            #expect(context.exception == nil)
            #expect(context.evaluateScript("globalThis.ran === true")?.toBool() == expected)
        }
        try store.setEnabled(false, for: boost.id)
        #expect(store.scripts(for: nil).isEmpty)
        try store.setEnabled(true, for: boost.id)
        #expect(!store.scripts(for: nil).isEmpty)
        boost.js = "globalThis.changed = true;"
        try store.update(boost)
        #expect(store.scripts(for: nil).isEmpty)
        try store.setJavaScriptTrusted(true, for: boost.id)
        boost.hostPatterns = ["*"]
        try store.update(boost)
        #expect(store.scripts(for: nil).isEmpty)
        try store.setJavaScriptTrusted(true, for: boost.id)
        try store.load()
        #expect(store.trustedJavaScriptIDs.isEmpty)
        #expect(store.scripts(for: nil).isEmpty)
        let newStore = BoostStore(directory: fixture.directory)
        try newStore.load()
        #expect(newStore.scripts(for: nil).isEmpty)
    }

    private func makeContext(url text: String) throws -> JSContext {
        let url = try #require(URL(string: text))
        let location = try JSONSerialization.data(withJSONObject: [
            "protocol": (url.scheme ?? "") + ":", "hostname": url.host ?? "",
        ])
        let context = try #require(JSContext())
        context.evaluateScript("""
        var location = \(String(decoding: location, as: UTF8.self));
        var styles = {};
        var document = {
            getElementById: function (id) { return styles[id]; },
            createElement: function () { return {}; },
            head: { appendChild: function (style) { styles[style.id] = style; } }
        };
        """)
        return context
    }
}

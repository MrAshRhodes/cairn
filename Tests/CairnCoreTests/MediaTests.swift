import AppKit
import CairnEngineKit
import Testing
@testable import CairnCore

@MainActor
private final class MediaEngine: BrowserEngine {
    let kind = EngineKind.chromium
    let displayName = "Fake"
    let versionDescription = "Test"
    var tabs: [MediaTab] = []
    func makeTab(configuration: EngineConfiguration, initialURL: URL?) -> EngineTab {
        let tab = MediaTab()
        tabs.append(tab)
        return tab
    }
    func clearBrowsingData(profileID: String, kinds: Set<BrowsingDataKind>) async {}
    func shutdown() {}
}

@MainActor
private final class MediaTab: EngineTabAudioControl {
    let id = UUID()
    let view = NSView()
    var state = EngineTabState()
    weak var delegate: EngineTabDelegate?
    var zoom: Double = 1
    var isAudioMuted = false
    var evaluated: [String] = []
    func load(_ url: URL) { state.url = url }
    func goBack() {}
    func goForward() {}
    func reload(ignoringCache: Bool) {}
    func stopLoading() {}
    func find(_ query: String, forward: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func clearFind() {}
    func evaluateJavaScript(_ source: String, completion: ((Result<Any?, Error>) -> Void)?) {
        evaluated.append(source)
        completion?(.success("paused"))
    }
    func setUserScripts(_ scripts: [EngineUserScript]) {}
    func takeSnapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func close() {}
    func audio(_ playing: Bool) { (delegate as? EngineTabMediaEvents)?.engineTab(self, audioPlayingDidChange: playing) }
}

private func icon(_ color: NSColor = .red) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill(); image.unlockFocus()
    return image
}

private func png(_ image: NSImage) -> Data {
    NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

@Suite @MainActor struct MediaTests {
    @Test func audibleStateAndMuteFollowTheTab() throws {
        let engine = MediaEngine()
        let model = BrowserModel(engine: engine)
        let id = model.newTab(url: URL(string: "https://a.example")!)
        let tab = try #require(engine.tabs.first)

        tab.audio(true)
        #expect(model.mediaStates[id] == EngineTabMediaState(isAudible: true))
        #expect(model.isAnyTabAudible)

        model.toggleMute(id)
        #expect(tab.isAudioMuted)
        #expect(model.mediaStates[id] == EngineTabMediaState(isAudible: true, isMuted: true))
        #expect(!model.isAnyTabAudible)

        tab.audio(false)
        #expect(model.mediaStates[id] == EngineTabMediaState(isAudible: false, isMuted: true))
        model.toggleMute(id)
        #expect(!tab.isAudioMuted)
        #expect(model.mediaStates[id] == nil)
    }

    @Test func muteOtherTabsLeavesTheKeptAndSilentTabsAlone() throws {
        let engine = MediaEngine()
        let model = BrowserModel(engine: engine)
        let a = model.newTab(url: URL(string: "https://a.example")!)
        let b = model.newTab(url: URL(string: "https://b.example")!)
        let c = model.newTab(url: URL(string: "https://c.example")!)
        engine.tabs[0].audio(true); engine.tabs[1].audio(true)

        model.muteOtherTabs(except: b)

        #expect(model.isMuted(a))
        #expect(!model.isMuted(b))
        #expect(!model.isMuted(c))
        #expect(!engine.tabs[1].isAudioMuted && !engine.tabs[2].isAudioMuted)
    }

    @Test func mediaKeysTargetTheAudibleTabAndClearOnUnload() async throws {
        let engine = MediaEngine()
        let model = BrowserModel(engine: engine)
        let a = model.newTab(url: URL(string: "https://a.example")!)
        let b = model.newTab(url: URL(string: "https://b.example")!)
        engine.tabs[0].audio(true)
        #expect(model.selectedTabID == b)
        #expect(model.mediaTargetTabID == a)

        var result: String?
        model.toggleMediaPlayback { result = $0 }
        #expect(result == "paused")
        #expect(engine.tabs[0].evaluated.count == 1 && engine.tabs[1].evaluated.isEmpty)

        model.unloadTab(a)
        #expect(model.mediaStates[a] == nil)
        #expect(model.mediaTargetTabID == b)
    }

    @Test func faviconsAreCachedPerProfileAndResolveWithoutALiveTab() throws {
        let directory = try TestDirectory()
        let engine = MediaEngine()
        let workspace = Workspace(spaces: [Space(name: "One", profileID: "one"), Space(name: "Two", profileID: "two")])
        let model = BrowserModel(engine: engine, workspace: workspace)
        model.faviconStore = FaviconStore(directory: directory.url)
        let url = URL(string: "https://news.example/story")!
        let id = model.newTab(url: url)

        engine.tabs[0].state.url = url
        model.engineTab(engine.tabs[0], didReceiveFavicon: icon())
        #expect(model.favicons[id] != nil)

        model.unloadTab(id)
        let item = try #require(model.item(id))
        #expect(model.favicon(for: item) != nil)

        model.selectSpace(workspace.spaces[1].id)
        let second = model.newTab(url: url)
        #expect(model.favicon(for: try #require(model.item(second))) == nil)
        let reopened = FaviconStore(directory: directory.url)
        #expect(reopened.image(profileID: "one", host: "news.example") != nil)
        #expect(reopened.image(profileID: "two", host: "news.example") == nil)
    }

    @Test func faviconStorePersistsPrunesAndKeepsPrivateDataOffDisk() throws {
        let directory = try TestDirectory()
        let data = png(icon())
        let store = FaviconStore(directory: directory.url, limit: 2)
        for host in ["a.example", "b.example", "c.example"] {
            store.store(data, profileID: "p", host: host)
            Thread.sleep(forTimeInterval: 0.02)
        }
        store.prune()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(files.count == 2)
        #expect(FaviconStore(directory: directory.url).data(profileID: "p", host: "a.example") == nil)
        #expect(FaviconStore(directory: directory.url).data(profileID: "p", host: "C.example") != nil)

        let privateStore = FaviconStore(directory: nil)
        privateStore.store(data, profileID: "p", host: "x.example")
        #expect(privateStore.image(profileID: "p", host: "x.example") != nil)
        #expect(FaviconStore(directory: nil).image(profileID: "p", host: "x.example") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).count == 2)
    }

    @Test func corruptCachedIconsAreIgnored() throws {
        let directory = try TestDirectory()
        let store = FaviconStore(directory: directory.url)
        store.store(Data("not an image".utf8), profileID: "p", host: "bad.example")
        #expect(FaviconStore(directory: directory.url).image(profileID: "p", host: "bad.example") == nil)
    }
}

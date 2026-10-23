import AppKit
import Foundation
import Testing
import CairnCore
import CairnModules
@testable import CairnUI

@Suite @MainActor struct ShortcutTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [("⇧⌘D", "d", true, true, false, false), ("⌥⌘↓", "down", true, false, true, false),
                      ("⌃⇥", "tab", false, false, false, true), ("⌘,", ",", true, false, false, false)])
    func parsesAndDisplaysChords(text: String, key: String, command: Bool, shift: Bool, option: Bool, control: Bool) throws {
        let chord = try #require(KeyChord.parse(text))
        #expect(chord == KeyChord(key, command: command, shift: shift, option: option, control: control))
        #expect(chord.display == text)
    }

    @Test func rejectsTextThatIsNotAChord() {
        #expect(KeyChord.parse("T") == nil)
        #expect(KeyChord.parse("⇧T") == nil)
        #expect(KeyChord.parse("") == nil)
    }

    @Test func conflictsAreRefusedAndNamed() throws {
        var map = ShortcutMap()
        #expect(throws: ShortcutError.self) { try map.assign(KeyChord("t", command: true), to: "ui.history") }
        do { try map.assign(KeyChord("t", command: true), to: "ui.history") }
        catch { #expect(error.localizedDescription.contains("New Tab")) }
        #expect(map.chord(for: "ui.history") == KeyChord("y", command: true))
        #expect(throws: ShortcutError.self) { try map.assign(KeyChord("q", command: true), to: "ui.history") }
        #expect(throws: ShortcutError.self) { try map.assign(KeyChord("h", command: true), to: "system.quit") }
    }

    @Test func assignClearAndReset() throws {
        var map = ShortcutMap()
        try map.assign(KeyChord("u", command: true, shift: true, option: true), to: "ui.history")
        #expect(map.chord(for: "ui.history")?.display == "⌥⇧⌘U")
        try map.assign(nil, to: "ui.history")
        #expect(map.chord(for: "ui.history") == nil)
        map.reset("ui.history")
        #expect(map.chord(for: "ui.history") == KeyChord("y", command: true))
        #expect(throws: ShortcutError.self) { try map.assign(KeyChord("u"), to: "ui.history") }
    }

    @Test func noTwoActionsShareAChordInEitherPreset() {
        for preset in KeymapPreset.allCases {
            let map = ShortcutMap(preset: preset)
            let chords = map.bindings.values.map(\.display)
            #expect(Set(chords).count == chords.count, "duplicate chord in \(preset.title)")
        }
    }

    @Test func theArcPresetCoversTheArcTableRows() throws {
        let map = ShortcutMap(preset: .arc)
        let expected: [String: String] = [
            "ui.new-tab": "⌘T", "ui.command-bar": "⌘K", "ui.address": "⌘L", "ui.close-tab": "⌘W", "ui.reopen-closed-tab": "⇧⌘T",
            "ui.copy-url": "⇧⌘C", "ui.copy-markdown-link": "⌥⇧⌘C", "ui.sidebar": "⌘S", "ui.pin-tab": "⌘D", "ui.clear-today": "⇧⌘K",
            "ui.reload": "⌘R", "ui.find": "⌘F", "ui.split": "⇧⌘D", "ui.split-add-right": "⌃⇧+", "ui.split-remove-pane": "⌃⇧-",
            "ui.recent-tabs": "⌃⇥", "ui.next-space": "⌥⌘→", "ui.previous-space": "⌥⌘←", "ui.next-tab": "⌥⌘↓", "ui.previous-tab": "⌥⌘↑",
            "ui.select-tab-1": "⌘1", "ui.select-tab-9": "⌘9", "ui.select-space-1": "⌃1", "ui.split-focus-1": "⌃⇧1",
            "ui.quick-window": "⌥⌘N",
        ]
        for (id, display) in expected { #expect(map.chord(for: id)?.display == display, "\(id)") }
        #expect(ShortcutCatalog.unmappedArcRows.count == 3)
    }

    @Test func everyDefaultActionHasAnIdTheServicesCanRun() {
        let services = BrowserServices(model: BrowserModel(engine: NullEngine.make(), workspace: Workspace(spaces: [Space(name: "H")])),
                                       directory: URL(fileURLWithPath: "/nonexistent-cairn"))
        for action in ShortcutCatalog.actions where !action.id.hasPrefix("system.") {
            _ = services.isEnabled(action: action.id)
        }
        #expect(ShortcutCatalog.actions.filter { !$0.id.hasPrefix("system.") && $0.menu == .tools }.map(\.id).contains("ui.shortcuts"))
    }

    @Test func storeRoundTripsPresetAndCustomChords() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShortcutStore(directory: dir)
        var map = ShortcutMap(preset: .arc)
        try map.assign(KeyChord("u", command: true, shift: true, option: true), to: "ui.history")
        try map.assign(nil, to: "ui.find")
        try store.save(map)
        let loaded = store.load()
        #expect(loaded.error == nil)
        #expect(loaded.map.preset == .arc)
        #expect(loaded.map.chord(for: "ui.history")?.display == "⌥⇧⌘U")
        #expect(loaded.map.chord(for: "ui.find") == nil)
    }

    @Test(arguments: ["ui.print", "ui.devtools", "ui.view-source"])
    func newPageToolDefaultsDoNotStealPreviouslySavedRemaps(id: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShortcutStore(directory: dir)
        let chord = try #require(ShortcutMap().chord(for: id))
        var legacy = ShortcutMap(actions: ShortcutCatalog.actions.filter { $0.id != id })
        try legacy.assign(chord, to: "ui.history")
        try store.save(legacy)
        let loaded = store.load()
        #expect(loaded.error == nil)
        #expect(loaded.map.chord(for: "ui.history") == chord)
        #expect(loaded.map.chord(for: id) == nil)
        let bindings = Array(loaded.map.bindings.values)
        #expect(Set(bindings).count == bindings.count)
    }

    @Test func conflictingSavedRemapsCannotStealSystemKeysOrOtherCustomBindings() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShortcutStore(directory: dir)
        let map = ShortcutMap(assigned: [
            "ui.print": KeyChord("q", command: true),
            "ui.history": KeyChord("p", command: true),
        ])
        try store.save(map)
        let loaded = store.load().map
        #expect(loaded.chord(for: "system.quit") == KeyChord("q", command: true))
        #expect(loaded.chord(for: "ui.history") == KeyChord("p", command: true))
        #expect(loaded.chord(for: "ui.print") == nil)
        let bindings = Array(loaded.bindings.values)
        #expect(Set(bindings).count == bindings.count)
    }

    @Test(arguments: ["{ nope", #"{"schemaVersion":99}"#])
    func corruptShortcutFilesAreMovedAside(contents: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shortcuts.json")
        try Data(contents.utf8).write(to: file)
        let loaded = ShortcutStore(directory: dir).load()
        #expect(loaded.error != nil)
        let moved = try #require(loaded.quarantinedTo)
        #expect(try String(contentsOf: moved, encoding: .utf8) == contents)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(loaded.map.chord(for: "ui.new-tab") == KeyChord("t", command: true))
    }

    @Test func discoveredModuleShortcutsDoNotStealBoundKeys() {
        let free = Command(id: "mod.free", title: "Free", shortcut: "⌥⇧⌘U", perform: { _ in })
        let taken = Command(id: "mod.taken", title: "Taken", shortcut: "⌘T", perform: { _ in })
        let map = ShortcutMap().adding(discovered: [free, taken])
        #expect(map.chord(for: "mod.free")?.display == "⌥⇧⌘U")
        #expect(map.chord(for: "mod.taken") == nil)
        #expect(map.chord(for: "ui.new-tab") == KeyChord("t", command: true))
    }

    @Test func menuItemsCarryKeyEquivalentsMasksAndActionIDs() throws {
        let target = NSObject()
        let menu = MenuBuilder.menu(.file, map: ShortcutMap(), target: target, action: #selector(NSObject.description))
        let newTab = try #require(menu.items.first { $0.representedObject as? String == "ui.new-tab" })
        #expect(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == .command)
        let reopen = try #require(menu.items.first { $0.representedObject as? String == "ui.reopen-closed-tab" })
        #expect(reopen.keyEquivalent == "t" && reopen.keyEquivalentModifierMask == [.command, .shift])
        let tabs = MenuBuilder.menu(.tabs, map: ShortcutMap(), target: target, action: #selector(NSObject.description))
        let select = try #require(tabs.items.first { $0.title == "Select Tab" }?.submenu)
        #expect(select.items.count == 9)
        #expect(select.items[8].keyEquivalent == "9")
        let arc = MenuBuilder.menu(.tabs, map: ShortcutMap(preset: .arc), target: target, action: #selector(NSObject.description))
        let pin = try #require(arc.items.first { $0.representedObject as? String == "ui.pin-tab" })
        #expect(pin.keyEquivalent == "d" && pin.keyEquivalentModifierMask == .command)
        let everything = ShortcutMenu.allCases.flatMap { MenuBuilder.menu($0, map: ShortcutMap(), target: target, action: #selector(NSObject.description)).items }
        #expect(!everything.contains { ($0.representedObject as? String)?.hasPrefix("system.") == true })
    }

    @Test func pageToolsHaveRemappableMenuEntriesInBothPresets() throws {
        let expected: [(String, ShortcutMenu, String?)] = [
            ("ui.devtools", .tools, "⌥⌘I"), ("ui.view-source", .tools, "⌥⌘U"),
            ("ui.print", .file, "⌘P"), ("ui.save-pdf", .file, nil),
            ("ui.zoom-in", .view, "⌘+"), ("ui.zoom-out", .view, "⌘-"),
            ("ui.zoom-reset", .view, "⌘0"), ("ui.reset-site-zoom", .view, nil),
        ]
        let target = NSObject()
        let custom = KeyChord("p", command: true, shift: true, control: true)
        for preset in KeymapPreset.allCases {
            for (id, home, display) in expected {
                var map = ShortcutMap(preset: preset)
                let action = try #require(map.action(id))
                #expect(action.remappable && action.menu == home)
                #expect(map.chord(for: id)?.display == display)
                try map.assign(custom, to: id)
                let menu = MenuBuilder.menu(home, map: map, target: target, action: #selector(NSObject.description))
                let item = try #require(menu.items.first { $0.representedObject as? String == id })
                #expect(item.keyEquivalent == custom.keyEquivalent)
                #expect(item.keyEquivalentModifierMask == custom.modifierMask)
                #expect(item.target === target)
                try map.assign(nil, to: id)
                let cleared = MenuBuilder.item(action, map: map, target: target, action: #selector(NSObject.description))
                #expect(cleared.keyEquivalent.isEmpty && cleared.keyEquivalentModifierMask.isEmpty)
            }
        }
    }

    @Test func tabSwitcherWrapsInBothDirections() {
        #expect(TabSwitcher.nextIndex(0, count: 3, forward: true) == 1)
        #expect(TabSwitcher.nextIndex(2, count: 3, forward: true) == 0)
        #expect(TabSwitcher.nextIndex(0, count: 3, forward: false) == 2)
        #expect(TabSwitcher.nextIndex(0, count: 0, forward: true) == 0)
    }
}

@Suite @MainActor struct SiteSearchStoreTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-sitesearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private let engine = SiteSearchEngine(keyword: "g", name: "GitHub", template: "https://github.com/search?q=%s")

    @Test func persistsEnginesAndDefault() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SiteSearchStore(directory: dir)
        try store.add(engine)
        try store.setDefault(keyword: "g")
        let reloaded = SiteSearchStore(directory: dir)
        reloaded.load()
        #expect(reloaded.engines == [engine] && reloaded.defaultEngine == engine)
        try reloaded.remove(keyword: "g")
        #expect(reloaded.defaultEngine == nil && reloaded.engines.isEmpty)
    }

    @Test func rejectsUnsafeTemplatesAndDuplicateKeywords() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SiteSearchStore(directory: dir)
        #expect(throws: (any Error).self) { try store.add(SiteSearchEngine(keyword: "x", name: "X", template: "javascript:alert(%s)")) }
        #expect(throws: (any Error).self) { try store.add(SiteSearchEngine(keyword: "x", name: "X", template: "https://a.test/?q=%s&r=%s")) }
        #expect(throws: (any Error).self) { try store.add(SiteSearchEngine(keyword: "bad key", name: "X", template: "https://a.test/?q=%s")) }
        try store.add(engine)
        try store.add(SiteSearchEngine(keyword: "G", name: "Again", template: "https://a.test/?q=%s"))
        #expect(store.engines.count == 1 && store.engines[0].name == "Again")
    }

    @Test func corruptFileIsMovedAsideAndReported() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("site-search.json")
        try Data("{ broken".utf8).write(to: file)
        let store = SiteSearchStore(directory: dir)
        var reported: String?
        store.onError = { title, _ in reported = title }
        store.load()
        #expect(reported != nil && store.engines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("site-search.json.corrupt") }
        #expect(kept.count == 1)
        try store.add(engine)
    }
}

@Suite @MainActor struct ShortcutActionTests {
    private func make() -> BrowserServices {
        let tabs = (0..<5).map { TabItem(url: URL(string: "https://example.com/\($0)")) }
        let space = Space(name: "One", tabs: tabs, selectedTabID: tabs[0].id)
        return BrowserServices(model: BrowserModel(engine: NullEngine.make(), workspace: Workspace(spaces: [space, Space(name: "Two")])),
                               directory: URL(fileURLWithPath: "/nonexistent-cairn"))
    }

    @Test func numberedTabsAndSpacesAreSelectable() {
        let services = make()
        let ids = services.model.selectedSpace.tabs.map(\.id)
        services.perform(action: "ui.select-tab-3")
        #expect(services.model.selectedTabID == ids[2])
        services.perform(action: "ui.select-tab-9")
        #expect(services.model.selectedTabID == ids[4])
        services.perform(action: "ui.select-space-2")
        #expect(services.model.selectedSpace.name == "Two")
        services.perform(action: "ui.previous-space")
        #expect(services.model.selectedSpace.name == "One")
    }

    @Test func splitActionsGrowToFourPanesAndStop() {
        let services = make()
        services.perform(action: "ui.split-add-right")
        services.perform(action: "ui.split-add-bottom")
        services.perform(action: "ui.split-add-left")
        #expect(services.model.splitTabIDs.count == 4)
        #expect(!services.isEnabled(action: "ui.split-add-top"))
        services.perform(action: "ui.split-focus-2")
        #expect(services.model.selectedTabID == services.model.splitTabIDs[1])
        services.perform(action: "ui.split-remove-pane")
        #expect(services.model.splitGroups.first?.layout.paneCount == 3)
        #expect(services.model.splitTabIDs.isEmpty)
        services.perform(action: "ui.split-focus-1")
        services.model.focusPane(0)
        services.perform(action: "ui.split-separate")
        #expect(services.model.splitTabIDs.isEmpty)
    }

    @Test func closeAndReopenRoundTrip() {
        let services = make()
        let id = services.model.selectedTabID
        services.perform(action: "ui.close-tab")
        #expect(services.model.selectedSpace.tabs.count == 4)
        services.perform(action: "ui.reopen-closed-tab")
        #expect(services.model.selectedTabID == id)
        #expect(!services.isEnabled(action: "ui.reopen-closed-tab"))
    }

    @Test func commandsShowTheCurrentChord() throws {
        let services = make()
        let command = try #require(services.commands().first { $0.id == "ui.new-tab" })
        #expect(command.shortcut == "⌘T")
    }
}

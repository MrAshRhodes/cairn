import AppKit
import CairnCore
import CairnEngineKit
import CairnModules

// Registry-driven actions: menus, the shortcuts pane and the command bar all dispatch through `perform(action:)`.
extension BrowserServices {
    public func showCommandBar(mode: CommandBarMode) {
        commandBarMode = mode
        commandBarPresented = true
    }

    public func editAddress() { showCommandBar(mode: .navigate) }

    /// Tabs reachable with ⌘1-9 and ⌘⌥↑↓: favorites, then the Space's pinned and ordinary tabs.
    var orderedTabs: [TabItem] {
        model.workspace.favorites + model.selectedSpace.pinned + model.selectedSpace.tabs
    }

    func stepTab(_ delta: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == model.selectedTabID } ?? (delta > 0 ? -1 : 0)
        selectTab(tabs[(current + delta + tabs.count) % tabs.count].id)
    }

    func stepSpace(_ delta: Int) {
        let spaces = model.workspace.spaces
        guard spaces.count > 1 else { return }
        selectSpace(at: (model.selectedSpaceIndex + delta + spaces.count) % spaces.count)
    }

    func selectSpace(at index: Int) {
        guard model.workspace.spaces.indices.contains(index) else { return }
        model.selectSpace(model.workspace.spaces[index].id)
        zoom = activeEngineTab?.zoom ?? 1
        findResult = nil
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func copyCurrentURL() {
        guard let url = model.selectedTab?.url else { return }
        copyToPasteboard(url.absoluteString)
    }

    public func copyMarkdownLink() {
        guard let tab = model.selectedTab, let url = tab.url else { return }
        let escaped = tab.displayTitle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        copyToPasteboard("[\(escaped)](\(url.absoluteString))")
    }

    public func togglePin() {
        guard let id = model.selectedTabID, let list = model.locate(id)?.list else { return }
        if list == .pinned { model.unpin(id) } else if list == .today { model.pin(id) }
    }

    /// Adds a tab beside the focused pane: the next free tab of the Space, or a new blank one.
    public func addSplit(edge: SplitEdge) {
        guard let current = model.selectedTabID else { newTab(); return }
        let inSplit = Set(model.activeSplit?.layout.tabIDs ?? [current])
        let free = (model.selectedSpace.tabs + model.selectedSpace.pinned + model.workspace.favorites).first {
            !inSplit.contains($0.id) && model.splitGroup(containing: $0.id) == nil
        }
        let other = free?.id ?? model.newTab(activate: false)
        model.addToSplit(other, edge: edge)
    }

    /// True when the action can run now; menus use this to disable items.
    public func isEnabled(action id: String) -> Bool {
        if activeTransientID != nil {
            let supported: Set<String> = ["ui.quick-window", "ui.close-tab", "ui.close-window", "ui.address", "ui.command-bar",
                                           "ui.reload", "ui.hard-reload", "ui.stop", "ui.back", "ui.forward",
                                           "ui.zoom-in", "ui.zoom-out", "ui.zoom-reset", "ui.copy-url"]
            guard supported.contains(id) else { return false }
        }
        let hasTab = activeTransientID != nil || model.selectedTabID != nil
        let panes = model.splitTabIDs.count
        switch id {
        case "ui.close-tab", "ui.reload", "ui.hard-reload", "ui.stop", "ui.find", "ui.find-next", "ui.find-previous",
             "ui.copy-url", "ui.copy-markdown-link":
            return hasTab && (!id.hasPrefix("ui.copy") || activeEngineTab?.state.url != nil || model.selectedTab?.url != nil)
        case "ui.zoom-in", "ui.zoom-out", "ui.zoom-reset": return activeEngineTab != nil
        case "ui.devtools", "ui.print", "ui.save-pdf": return activePageTools != nil
        case "ui.view-source": return model.viewSourceURLForSelectedTab != nil
        case "ui.pin-tab": return model.selectedTabID.flatMap { model.locate($0)?.list }.map { $0 == .pinned || $0 == .today } ?? false
        case "ui.reopen-closed-tab": return model.canReopenClosedTab
        case "ui.clear-today": return !model.selectedSpace.tabs.isEmpty
        case "ui.back": return activeEngineTab?.state.canGoBack == true
        case "ui.forward": return activeEngineTab?.state.canGoForward == true
        case "ui.next-tab", "ui.previous-tab", "ui.recent-tabs", "ui.recent-tabs-previous": return orderedTabs.count > 1
        case "ui.next-space", "ui.previous-space": return model.workspace.spaces.count > 1
        case "ui.split-add-right", "ui.split-add-left", "ui.split-add-top", "ui.split-add-bottom":
            return hasTab && panes < SplitLayout.maximumPanes
        case "ui.split-remove-pane", "ui.split-separate": return panes > 0
        default:
            if id.hasPrefix("ui.select-tab-"), let number = Int(id.dropFirst("ui.select-tab-".count)) { return orderedTabs.count >= 1 && number >= 1 }
            if id.hasPrefix("ui.select-space-"), let number = Int(id.dropFirst("ui.select-space-".count)) { return model.workspace.spaces.count >= number }
            if id.hasPrefix("ui.split-focus-"), let number = Int(id.dropFirst("ui.split-focus-".count)) { return panes >= number }
            return true
        }
    }

    /// Runs a registered action. Unknown ids fall through to registered commands (modules, other features).
    public func perform(action id: String) {
        guard isEnabled(action: id) else { return }
        if performTransientAction(id) { return }
        switch id {
        case "ui.quick-window": newQuickWindow()
        case "ui.new-tab": showCommandBar(mode: .newTab)
        case "ui.command-bar": showCommandBar(mode: .search)
        case "ui.address": editAddress()
        case "ui.close-tab": closeTab()
        case "ui.reopen-closed-tab": model.reopenClosedTab()
        case "ui.copy-url": copyCurrentURL()
        case "ui.copy-markdown-link": copyMarkdownLink()
        case "ui.find": findPresented = true
        case "ui.find-next": find()
        case "ui.find-previous": find(forward: false)
        case "ui.sidebar": sidebarVisible.toggle()
        case "ui.reload": activeEngineTab?.reload(ignoringCache: false)
        case "ui.hard-reload": activeEngineTab?.reload(ignoringCache: true)
        case "ui.stop": activeEngineTab?.stopLoading()
        case "ui.zoom-in": setZoom((activeEngineTab?.zoom ?? 1) + 0.1)
        case "ui.zoom-out": setZoom((activeEngineTab?.zoom ?? 1) - 0.1)
        case "ui.zoom-reset": setZoom(1)
        case "ui.reset-site-zoom": resetSiteZoom()
        case "ui.devtools": toggleDevTools()
        case "ui.view-source": viewSource()
        case "ui.print": printPage()
        case "ui.save-pdf": savePageAsPDF()
        case "ui.back": activeEngineTab?.goBack()
        case "ui.forward": activeEngineTab?.goForward()
        case "ui.history": sheet = .history
        case "ui.archive": sheet = .archive
        case "ui.downloads": sheet = .downloads
        case "ui.boosts": sheet = .boosts
        case "ui.settings": sheet = .preferences
        case "ui.shortcuts": sheet = .shortcuts
        case "ui.pin-tab": togglePin()
        case "ui.clear-today": model.clearToday()
        case "ui.next-tab": stepTab(1)
        case "ui.previous-tab": stepTab(-1)
        case "ui.recent-tabs": tabSwitcher.advance(model: model, forward: true)
        case "ui.recent-tabs-previous": tabSwitcher.advance(model: model, forward: false)
        case "ui.next-space": stepSpace(1)
        case "ui.previous-space": stepSpace(-1)
        case "ui.split": toggleSplit()
        case "ui.split-add-right": addSplit(edge: .right)
        case "ui.split-add-left": addSplit(edge: .left)
        case "ui.split-add-top": addSplit(edge: .top)
        case "ui.split-add-bottom": addSplit(edge: .bottom)
        case "ui.split-remove-pane": if let id = model.selectedTabID { model.removeFromSplit(id) }
        case "ui.split-separate": model.closeSplit()
        default:
            if id.hasPrefix("ui.select-tab-"), let number = Int(id.dropFirst("ui.select-tab-".count)) {
                let tabs = orderedTabs
                guard !tabs.isEmpty else { return }
                // ⌘9 is the last tab, as in other browsers.
                selectTab(number == 9 ? tabs[tabs.count - 1].id : tabs[min(number, tabs.count) - 1].id)
            } else if id.hasPrefix("ui.select-space-"), let number = Int(id.dropFirst("ui.select-space-".count)) {
                selectSpace(at: number - 1)
            } else if id.hasPrefix("ui.split-focus-"), let number = Int(id.dropFirst("ui.split-focus-".count)) {
                model.focusPane(number - 1)
                zoom = activeEngineTab?.zoom ?? 1
            } else if let command = commands().first(where: { $0.id == id }) {
                command.perform(model)
            }
        }
    }

    // MARK: Keymap

    /// The user-editable keymap including actions discovered from registered commands.
    func loadShortcuts() {
        let base = ShortcutMap().adding(discovered: moduleCommandsForShortcuts())
        let loaded = shortcutStore.load(base: base)
        shortcuts = loaded.map
        if let error = loaded.error {
            shortcutsWritable = loaded.quarantinedTo != nil
            report("Keyboard shortcuts could not be read",
                   detail: "\(error.localizedDescription)\n" + (loaded.quarantinedTo.map { "The file was moved to \($0.lastPathComponent) and the default keymap is active." }
                        ?? "The original file is preserved. Changes will not be saved this session."))
        }
    }

    private func moduleCommandsForShortcuts() -> [Command] { modules.allCommands(for: model) }

    public func assignShortcut(_ chord: KeyChord?, to id: String) throws {
        guard shortcutsWritable else { throw ShortcutError(message: "Shortcuts are read-only because the saved file could not be set aside.") }
        var updated = shortcuts
        try updated.assign(chord, to: id)
        try commitShortcuts(updated)
    }

    public func resetShortcut(_ id: String) throws {
        var updated = shortcuts
        updated.reset(id)
        try commitShortcuts(updated)
    }

    public func setKeymapPreset(_ preset: KeymapPreset) throws {
        var updated = shortcuts
        updated.preset = preset
        updated.resetAll()
        try commitShortcuts(updated)
    }

    private func commitShortcuts(_ updated: ShortcutMap) throws {
        guard shortcutsWritable else { throw ShortcutError(message: "Shortcuts are read-only because the saved file could not be set aside.") }
        try shortcutStore.save(updated)
        shortcuts = updated
        onShortcutsChanged?()
    }
}

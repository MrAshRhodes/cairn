import AppKit
import CairnCore
import CairnEngineKit
import CairnModules

// Page tools: DevTools, view-source, print / Save as PDF, per-site zoom, language and user agent.
// Menus and command-bar rows share ShortcutCatalog entries and perform(action:) dispatch.
extension BrowserServices {
    var activePageTools: EngineTabPageTools? { activeEngineTab as? EngineTabPageTools }

    func installPageTools() {
        do { siteZoom = try SiteZoomStore(url: directory.appendingPathComponent("site-zoom.json")) }
        catch {
            // The unreadable file stays untouched; zoom is simply not remembered this session.
            siteZoom = try? SiteZoomStore()
            report("Site zoom could not be read", detail: "\(error.localizedDescription)\nZoom levels will not be remembered this session.")
        }
        siteZoom?.onError = { [weak self] error in self?.report("Site zoom could not be saved", error: error) }
        model.onTabHostChanged = { [weak self] id, tab, url in
            guard let self, let profile = self.model.profileID(forLiveTab: id) else { return }
            let wanted = self.siteZoom?.zoom(profileID: profile, url: url) ?? 1
            if abs(tab.zoom - wanted) > 0.0005 { tab.zoom = wanted }
            if id == self.model.selectedTabID { self.zoom = tab.zoom }
        }
        model.onTabZoomChanged = { [weak self] id, _, zoom in
            guard let self, let profile = self.model.profileID(forLiveTab: id) else { return }
            self.siteZoom?.setZoom(zoom, profileID: profile, url: self.model.tabStates[id]?.url)
            if id == self.model.selectedTabID { self.zoom = zoom }
        }
    }

    func applyPageSettings() {
        (model.engine as? EnginePagePreferences)?.pagePreferences = settings.pagePreferences
    }

    public func toggleDevTools() {
        guard let tab = activePageTools else { return }
        if tab.hasDevTools { tab.closeDevTools() } else { tab.showDevTools(inspectingAt: nil) }
    }

    /// For a context-menu "Inspect"; the point is in the page view's coordinates.
    public func inspectElement(at point: CGPoint) { activePageTools?.showDevTools(inspectingAt: point) }

    public func viewSource() {
        guard let url = model.viewSourceURLForSelectedTab else {
            report("View Source is unavailable", detail: "Only web and local file pages can be viewed as source.")
            return
        }
        model.newTab(url: url)
    }

    public func printPage() { activePageTools?.printPage() }

    public func exportPDF(to url: URL) {
        guard let tab = activePageTools else { return }
        exportPDF(to: url, from: tab)
    }

    private func exportPDF(to url: URL, from tab: EngineTabPageTools) {
        tab.printToPDF(at: url) { [weak self] result in
            if case .failure(let error) = result { self?.report("The page could not be saved as PDF", error: error) }
        }
    }

    public func savePageAsPDF() {
        guard let tab = activePageTools else { return }
        let title = model.selectedTab?.title ?? ""
        let filename = (title.isEmpty ? "Page" : title.replacingOccurrences(of: "/", with: "-")) + ".pdf"
        guard let url = pdfDestinationChooser(filename) else { return }
        // The save panel runs a nested event loop; selection may have changed while it was open.
        exportPDF(to: url, from: tab)
    }

    public func resetSiteZoom() {
        siteZoom?.removeAll()
        setZoom(1)
    }

    func pageToolCommands() -> [Command] {
        let entries: [(id: String, keywords: [String])] = [
            ("ui.devtools", ["inspect", "console", "devtools"]),
            ("ui.view-source", ["source"]),
            ("ui.print", ["print"]),
            ("ui.save-pdf", ["export", "pdf"]),
            ("ui.zoom-in", ["zoom"]),
            ("ui.zoom-out", ["zoom"]),
            ("ui.zoom-reset", ["zoom", "reset"]),
            ("ui.reset-site-zoom", ["zoom", "reset", "sites"]),
        ]
        return entries.compactMap { entry in
            guard isEnabled(action: entry.id), let action = shortcuts.action(entry.id) else { return nil }
            return Command(id: action.id, title: action.title, symbol: action.symbol ?? "command", keywords: entry.keywords,
                           shortcut: shortcuts.chord(for: action.id)?.display,
                           perform: { [weak self] _ in self?.perform(action: action.id) })
        }
    }
}

import AppKit
import CairnCore
import CairnEngineKit
import CairnModules

// Page tools: DevTools, view-source, print / Save as PDF, per-site zoom, language and user agent.
// Menus are owned elsewhere; everything here is reachable as a Command (see `pageToolCommands`) or a method.
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
        tab.printToPDF(at: url) { [weak self] result in
            if case .failure(let error) = result { self?.report("The page could not be saved as PDF", error: error) }
        }
    }

    public func savePageAsPDF() {
        guard activePageTools != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let title = model.selectedTab?.title ?? ""
        panel.nameFieldStringValue = (title.isEmpty ? "Page" : title.replacingOccurrences(of: "/", with: "-")) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPDF(to: url)
    }

    public func resetSiteZoom() {
        siteZoom?.removeAll()
        activeEngineTab?.zoom = 1
    }

    func pageToolCommands() -> [Command] {
        [
            .init(id: "ui.devtools", title: "Toggle Developer Tools", symbol: "hammer",
                  keywords: ["inspect", "console", "devtools"], shortcut: "⌥⌘I", perform: { [weak self] _ in self?.toggleDevTools() }),
            .init(id: "ui.view-source", title: "View Page Source", symbol: "chevron.left.forwardslash.chevron.right", shortcut: "⌥⌘U",
                  perform: { [weak self] _ in self?.viewSource() }),
            .init(id: "ui.print", title: "Print…", symbol: "printer", shortcut: "⌘P", perform: { [weak self] _ in self?.printPage() }),
            .init(id: "ui.save-pdf", title: "Save Page as PDF…", symbol: "doc.richtext", keywords: ["export", "pdf"],
                  perform: { [weak self] _ in self?.savePageAsPDF() }),
            .init(id: "ui.reset-site-zoom", title: "Reset Zoom for All Sites", symbol: "1.magnifyingglass",
                  perform: { [weak self] _ in self?.resetSiteZoom() }),
        ]
    }
}

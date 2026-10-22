import CairnChromiumBridge
import CairnEngineKit
import Foundation

extension ChromiumTab: @preconcurrency CCChromiumTabContextMenuDelegate {
    func chromiumTab(_ tab: CCChromiumTab, searchFor query: String, activate: Bool) {
        guard !closed else { return }
        (delegate as? EngineTabContextMenuEvents)?.engineTab(self, requestsSearchFor: query, activate: activate)
    }

    func chromiumTab(_ tab: CCChromiumTab, openExternalURL url: String) {
        guard !closed, let url = URL(string: url) else { return }
        (delegate as? EngineTabContextMenuEvents)?.engineTab(self, requestsExternalURL: url)
    }
}

extension ChromiumTab: EngineTabContentFocus {
    func focusContent() { if !closed { bridge.focusContent() } }
}

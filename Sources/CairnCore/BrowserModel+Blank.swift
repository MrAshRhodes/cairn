import Foundation
import CairnEngineKit

extension BrowserModel {
    /// Chromium's bootstrap `about:blank` document must not replace the URL and title the tab already has:
    /// a quit or crash before the real navigation commits would otherwise persist a blank tab.
    static func isBootstrapBlank(_ state: EngineTabState, over current: TabItem) -> Bool {
        guard let existing = current.url, existing.absoluteString != "about:blank" else { return false }
        return state.url?.absoluteString == "about:blank"
            || (state.url == nil && state.title == "about:blank")
    }
}

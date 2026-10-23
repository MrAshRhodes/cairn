import Foundation
import CairnEngineKit
import CairnChromiumBridge

extension ChromiumTab: @preconcurrency CCChromiumTabNavigationDelegate {
    func chromiumTab(_ tab: CCChromiumTab, interceptUserNavigation url: String) -> Bool {
        guard !closed, let url = URL(string: url),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return (delegate as? EngineTabNavigationEvents)?.engineTab(self, interceptsUserNavigation: url) ?? false
    }
}

import AppKit
import CairnEngineKit
import CairnChromiumBridge

extension ChromiumTab: @preconcurrency CCChromiumTabLifeSpanDelegate {
    func chromiumTab(_ tab: CCChromiumTab, hostsPopup url: String, disposition: CCPopupDisposition,
                     userGesture: Bool) -> CCChromiumTab? {
        chromiumTab(tab, hostsPopup: url, disposition: disposition, userGesture: userGesture, requestingURL: "")
    }

    func chromiumTab(_ tab: CCChromiumTab, hostsPopup url: String, disposition: CCPopupDisposition,
                     userGesture: Bool, requestingURL: String) -> CCChromiumTab? {
        guard !closed else { return nil }
        let kind: PopupDisposition
        switch disposition {
        case .foreground: kind = .foreground
        case .background: kind = .background
        default: kind = .unsupported
        }
        let target = url.isEmpty ? nil : URL(string: url)
        let requester = requestingURL.isEmpty ? nil : URL(string: requestingURL)
        let events = delegate as? EngineTabPopupEvents
        let allowed = requester.map { events?.engineTab(self, allowsPopupsFrom: $0) == true } ?? false
        switch PopupPolicy.decide(url: url, disposition: kind, userGesture: userGesture, budget: &popupBudget,
                                  allowsWithoutGesture: allowed) {
        case .cancel:
            return nil
        case .block(let reason):
            events?.engineTab(self, blockedPopup: target, reason: reason, requestingURL: requester)
            return nil
        case .openInTab(let activate):
            chromiumTab(tab, popup: url, activate: activate)
            return nil
        case .adopt:
            let popup = ChromiumTab(popupOf: self)
            if let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") { popup.state.url = target }
            engine?.track(popup)
            guard (delegate as? EngineTabPopupEvents)?.engineTab(self, hostsPopup: popup, activate: true) == true else {
                popup.close()
                return nil
            }
            return popup.bridge
        }
    }
}

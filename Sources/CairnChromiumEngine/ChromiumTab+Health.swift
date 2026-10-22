import CairnEngineKit
import CairnChromiumBridge

extension ChromiumTab: @preconcurrency CCChromiumTabHealthDelegate {
    func chromiumTab(_ tab: CCChromiumTab, health kind: String, detail: String, code: Int) {
        guard !closed else { return }
        let health: EngineTabHealth
        switch kind {
        case "unresponsive": health = .unresponsive
        case "crashed": health = .crashed(reason: detail, code: code)
        case "navigationStalled": health = .navigationStalled(hint: detail)
        case "automationUnavailable": health = .automationUnavailable
        default: health = .healthy
        }
        guard let events = delegate as? EngineTabHealthEvents else {
            if case .crashed(let reason, _) = health { report("The page \(reason).") }
            return
        }
        events.engineTab(self, healthDidChange: health)
    }
}

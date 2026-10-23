import Foundation
import CairnCore

extension BrowserServices {
    public func requestPageCloseApproval(force: Bool = false, completion: @escaping @MainActor (Bool) -> Void) {
        commandBarPresented = false
        tabSwitcher.cancel()
        sheet = nil
        model.requestCloseAll(force: force, completion: completion)
    }
}

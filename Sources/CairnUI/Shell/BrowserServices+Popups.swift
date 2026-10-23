import Foundation
import CairnCore

extension BrowserServices {
    func loadPopupExceptions() {
        let store = model.popupExceptions
        store.onError = { [weak self, weak store] error in
            self?.report("Popup exceptions could not be saved", detail: store?.errorMessage ?? error.localizedDescription)
        }
        do {
            try store.load(from: directory.appendingPathComponent("popup-exceptions.json"))
            if workspaceWritable { store.retain(spaces: model.workspace.spaces) }
        } catch {
            report("Popup exceptions could not be loaded", detail: store.errorMessage ?? error.localizedDescription)
        }
    }
}

import Foundation
import CairnEngineKit

extension BrowserModel: EngineDownloadDelegate {
    public func engineWillStartDownload(_ request: EngineDownloadRequest, decide: @escaping @MainActor (URL?) -> Void) {
        guard let engineDownloadHandler else {
            onError?(ServiceError.invalidDownload("No download handler is configured."))
            decide(nil)
            return
        }
        engineDownloadHandler(request, decide)
    }

    public func engineDownloadDidUpdate(_ update: EngineDownloadUpdate) {
        engineDownloadUpdateHandler?(update)
    }

    /// Control or retry the original engine download by its per-launch id.
    public func performEngineDownloadAction(_ action: EngineDownloadAction, id: UInt32) {
        (engine as? EngineDownloadControlling)?.performDownloadAction(action, id: id)
    }
}

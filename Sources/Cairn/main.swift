import CairnUI
import CairnEngineKit
import CairnChromiumEngine

MainActor.assumeIsolated {
    ChromiumEngineModule.prepareApplication()
    ChromiumEngineModule.register(in: .shared)
    CairnApp.run(prepareForTermination: ChromiumEngineModule.prepareForTermination)
}

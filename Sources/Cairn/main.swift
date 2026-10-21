import CairnUI
import CairnEngineKit
import CairnWebKitEngine
#if CAIRN_CHROMIUM
import CairnChromiumEngine
#endif

MainActor.assumeIsolated {
    var prepareForTermination: CairnApp.TerminationPreparation?
    #if CAIRN_CHROMIUM
    ChromiumEngineModule.prepareApplication()
    ChromiumEngineModule.register(in: .shared)
    prepareForTermination = ChromiumEngineModule.prepareForTermination
    #endif
    WebKitEngineModule.register(in: .shared)
    CairnApp.run(prepareForTermination: prepareForTermination)
}

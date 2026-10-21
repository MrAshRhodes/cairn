import CairnUI
import CairnEngineKit
import CairnWebKitEngine
#if CAIRN_CHROMIUM
import CairnChromiumEngine
#endif

MainActor.assumeIsolated {
    #if CAIRN_CHROMIUM
    ChromiumEngineModule.prepareApplication()
    ChromiumEngineModule.register(in: .shared)
    #endif
    WebKitEngineModule.register(in: .shared)
    CairnApp.run()
}

import AppKit
import CairnBoosts
import CairnEngineKit

extension Smoke {
    func checkPopupBoosts() async throws {
        var firstDocumentFailures: [String] = []
        func checkFirstDocument(_ tab: any EngineTab, _ expression: String, _ message: String) async throws {
            if try await js(tab, expression) as? Bool == true {
                try require(true, message)
            } else {
                firstDocumentFailures.append(message)
                print("GATE FAILED (#24): \(message)")
                let evidence = try await js(tab, """
                    JSON.stringify({
                        url: location.href,
                        firstStart: window.firstStart,
                        firstEnd: window.firstEnd,
                        count: window.__popupEnd,
                        endTiming: window.__endTiming,
                        css: getComputedStyle(document.body).getPropertyValue('--cairn-popup-boost').trim(),
                        messages: window.messages
                    })
                    """)
                print("POPUP BOOST EVIDENCE: \(String(describing: evidence))")
            }
        }
        let store = BoostStore(directory: root.appendingPathComponent("popup-boosts"))
        let trusted = Boost(name: "First popup document", hostPatterns: ["127.0.0.1"],
                            css: "body { --cairn-popup-boost: applied; }",
                            js: "window.__popupEnd = (window.__popupEnd || 0) + 1; window.__endTiming = document.readyState;")
        let untrusted = Boost(name: "Untrusted", hostPatterns: ["*"], js: "window.__untrustedRan = true;")
        try store.add(trusted)
        try store.add(untrusted)
        try store.setJavaScriptTrusted(true, for: trusted.id)
        let start = EngineUserScript(id: "popup-start", source: """
            if (location.protocol === 'http:' && location.hostname === '127.0.0.1') {
                window.__popupStart = document.readyState === 'loading';
            }
            """, injection: .documentStart)
        let opener = make("popup-boosts")
        popupScripts[opener.id] = [start] + store.scripts(for: nil)
        defer { popupScripts.removeValue(forKey: opener.id) }
        try await loadPage(opener, "popup-boost/opener")
        try await closePopups()

        for button in ["direct", "redirect"] {
            let before = popupTabs.count
            try await click(opener, button)
            try await wait { self.popupTabs.count == before + 1 }
            let popup = popupTabs[before]
            try await wait { popup.state.title == "Boost child" && !popup.state.isLoading }
            try require(try await js(popup, """
                typeof __untrustedRan === 'undefined' && window.opener !== null
                """) as? Bool == true, "\(button): untrusted JavaScript stays blocked and opener is retained")
            try await checkFirstDocument(popup, """
                firstStart && !firstEnd && __popupEnd === 1 && __endTiming === 'interactive' &&
                getComputedStyle(document.body).getPropertyValue('--cairn-popup-boost').trim() === 'applied'
                """, "\(button): first popup document gets start/end scripts and trusted CSS/JS once")
            try require(try await js(opener, """
                messages.some(m => m.fromPopup && m.data.cookie.includes('popupBoost=shared'))
                """) as? Bool == true, "\(button): postMessage and shared cookies survive")
            try await checkFirstDocument(opener, """
                messages.some(m => m.fromPopup && m.data.firstStart && !m.data.firstEnd &&
                                  m.data.count === 1 && m.data.cookie.includes('popupBoost=shared'))
                """, "\(button): postMessage observes first-document Boost execution")
        }
        let direct = popupTabs[0]
        let count = popupTabs.count
        try await click(opener, "named")
        try await wait { direct.state.url?.query == "named" && !direct.state.isLoading }
        let namedScripts = try await js(direct, "__popupEnd === 1 && firstStart") as? Bool == true
        try require(popupTabs.count == count && namedScripts,
                    "named target reuses its browser without duplicate scripts")

        try await click(opener, "cross")
        try await wait { self.popupTabs.count == count + 1 }
        let cross = popupTabs[count]
        try await wait { cross.state.url?.host == "localhost" && !cross.state.isLoading }
        try require(try await js(cross, """
            !firstStart && !firstEnd && typeof __popupEnd === 'undefined' &&
            typeof __untrustedRan === 'undefined' &&
            getComputedStyle(document.body).getPropertyValue('--cairn-popup-boost').trim() === ''
            """) as? Bool == true, "redirect host guard prevents stale and untrusted Boost execution")

        let writer = make("popup-boosts")
        popupScripts[writer.id] = popupScripts[opener.id]
        defer { popupScripts.removeValue(forKey: writer.id) }
        try await loadPage(writer, "popup-boost/opener?writer")
        try await click(writer, "blank")
        try await wait { self.popupTabs.count == count + 2 }
        let blank = popupTabs[count + 1]
        try await wait { blank.state.title == "Written blank" }
        try require(try await js(writer, """
            win.document.body.textContent === 'written by opener' &&
            typeof win.__popupStart === 'undefined' && typeof win.__popupEnd === 'undefined'
            """) as? Bool == true, "blank popup stays opener-written with no unintended Boost")
        _ = try await js(writer, "win.location = '/popup-boost/landing?after-blank'; true")
        try await wait { blank.state.title == "Boost child" && !blank.state.isLoading }
        try require(try await js(blank, "firstStart && __popupEnd === 1") as? Bool == true,
                    "blank popup receives Boosts on its first supported HTTP document")

        let prePost = popupTabs.count
        try await click(writer, "post")
        try await wait { self.popupTabs.count == prePost + 1 }
        let post = popupTabs[prePost]
        try await wait { post.state.title == "Boost child" && !post.state.isLoading }
        try require(try await js(post, """
            requestMethod === 'POST' && postBody === 'payload=cairn'
            """) as? Bool == true, "popup retains the original POST body")
        try await checkFirstDocument(post, "firstStart && __popupEnd === 1",
                                     "POST popup receives first-document Boosts once")

        let counts = try await js(opener, "fetch('/popup-boost/requests.json').then(r => r.json())") as? [String: Int]
        for path in ["landing?direct", "redirect", "landing?redirect", "cross-redirect", "landing?cross",
                     "landing?named", "landing?after-blank"] {
            try require(counts?["GET /popup-boost/\(path)"] == 1, "\(path): no duplicate popup navigation")
        }
        try require(counts?["POST /popup-boost/landing?post"] == 1 && counts?["GET /popup-boost/landing?post"] == nil,
                    "popup form submits once and is never reconstructed as GET")
        try await closePopups()
        if !firstDocumentFailures.isEmpty {
            throw SmokeError.failed("Issue #24 first-document Boost gate: " + firstDocumentFailures.joined(separator: "; "))
        }
        print("CAIRN_POPUP_BOOSTS_OK")
    }
}

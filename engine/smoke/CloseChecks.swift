import AppKit
import CairnEngineKit
import CairnChromiumEngine

extension Smoke {
    private func closeController(_ tab: EngineTab) throws -> EngineTabCloseControlling {
        guard let closing = tab as? EngineTabCloseControlling else {
            throw SmokeError.failed("Chromium must support cancellable close")
        }
        return closing
    }

    private func closeDecision(_ tab: EngineTab) async throws -> Bool {
        var result: Bool?
        try closeController(tab).requestClose { result = $0 }
        try await wait { result != nil }
        return result == true
    }

    private func editableCloseFixture(_ profile: String) async throws -> EngineTab {
        let tab = make(profile)
        try await load(tab, path: "beforeunload.html")
        try await click(tab, "edit")
        try require(try await js(tab, "navigator.userActivation.hasBeenActive && window.__dirty") as? Bool == true,
                    "beforeunload fixture has trusted activation and an unsaved edit")
        return tab
    }

    func checkCloseLifecycle() async throws {
        let harness = PromptHarness.shared
        defer {
            harness.deferDialogs = false
            harness.dialog = { _ in (true, nil, false) }
        }
        harness.dialog = { _ in (false, nil, false) }
        let clean = make("close-clean")
        try await load(clean, path: "beforeunload.html")
        let dialogsBeforeClean = harness.dialogs.count
        try require(try await closeDecision(clean), "clean page approves close without a dialog")
        try require(harness.dialogs.count == dialogsBeforeClean, "clean close does not fabricate a prompt")

        let stay = try await editableCloseFixture("close-stay")
        try require(try await closeDecision(stay) == false, "Stay cancels a real CEF tab close")
        try require(try await js(stay, "document.querySelector('#draft').value") as? String == "Unsaved Cairn fixture text",
                    "Stay leaves the renderer, delegate and unsaved DOM usable")
        try require(try await js(stay, "window.__beforeUnloadCount") as? Int == 1,
                    "one close request dispatches beforeunload once")
        guard let tools = stay as? EngineTabPageTools else { throw SmokeError.failed("Missing DevTools capability") }
        tools.showDevTools(inspectingAt: nil)
        try await wait { tools.hasDevTools }
        harness.dialog = { _ in (true, nil, false) }
        try require(try await closeDecision(stay), "Leave approves the supported CEF close lifecycle")
        try await wait { !tools.hasDevTools }
        try require(true, "approved page close also closes its DevTools window")

        let repeated = try await editableCloseFixture("close-repeat")
        harness.deferDialogs = true
        harness.deferredDialogs.removeAll()
        var repeatedAnswers: [Bool] = []
        let repeatClose = try closeController(repeated)
        repeatClose.requestClose { repeatedAnswers.append($0) }
        repeatClose.requestClose { repeatedAnswers.append($0) }
        try await wait { harness.deferredDialogs.count == 1 }
        let repeatedPrompt = harness.deferredDialogs[0].request
        try await Task.sleep(for: .milliseconds(150))
        try require(repeatedAnswers.isEmpty, "repeated close waits for a human decision without teardown")
        (repeated as? EngineTabPromptResponding)?.resolveJSDialog(id: repeatedPrompt.id, accept: false,
                                                                 text: nil, suppressFurther: false)
        harness.deferredDialogs.removeAll()
        try await wait { repeatedAnswers.count == 2 }
        try require(repeatedAnswers == [false, false], "repeated close shares one prompt and settles both requests once")

        var crashAnswer: Bool?
        repeatClose.requestClose { crashAnswer = $0 }
        do {
            try await wait { harness.deferredDialogs.count == 1 }
        } catch {
            print("CLOSE REENTRY: answer=\(String(describing: crashAnswer)) prompts=\(harness.deferredDialogs.count) state=\(repeated.state)")
            throw error
        }
        let stalePrompt = harness.deferredDialogs[0].request
        try require(ChromiumEngineModule.crashRendererForTesting(repeated),
                    "native task manager terminates only the selected tab's renderer while a dialog is pending")
        try await wait { crashAnswer != nil }
        try require(crashAnswer == false, "renderer loss invalidates a pending close prompt without authorizing teardown")
        (repeated as? EngineTabPromptResponding)?.resolveJSDialog(id: stalePrompt.id, accept: true,
                                                                 text: nil, suppressFurther: false)
        harness.deferDialogs = false
        harness.deferredDialogs.removeAll()
        let healthCount = healthEvents.count
        repeated.reload(ignoringCache: false)
        try await wait {
            self.healthEvents.dropFirst(healthCount).contains { $0.tab == repeated.id && $0.health == .healthy }
        }
        try require(try await js(repeated, "document.querySelector('#draft').value") as? String == "Original draft",
                    "stale Leave cannot close the recovered renderer")
        let dialogsBeforeRecoveredClose = harness.dialogs.count
        var recoveredAnswer: Bool?
        repeatClose.requestClose { recoveredAnswer = $0 }
        do {
            try await wait { recoveredAnswer != nil }
        } catch {
            print("RECOVERED CLOSE: dialogs=\(harness.dialogs.count - dialogsBeforeRecoveredClose) deferred=\(harness.deferredDialogs.count) state=\(repeated.state)")
            throw error
        }
        try require(recoveredAnswer == true, "recovered renderer can close normally")

        let first = try await editableCloseFixture("close-multiple-a")
        let second = try await editableCloseFixture("close-multiple-b")
        harness.deferDialogs = true
        var firstAnswer: Bool?, secondAnswer: Bool?
        try closeController(first).requestClose { firstAnswer = $0 }
        try closeController(second).requestClose { secondAnswer = $0 }
        try await wait { harness.deferredDialogs.count == 2 }
        for pending in harness.deferredDialogs {
            (pending.tab as? EngineTabPromptResponding)?.resolveJSDialog(id: pending.request.id,
                accept: pending.tab === first, text: nil, suppressFurther: false)
        }
        harness.deferredDialogs.removeAll()
        try await wait { firstAnswer != nil && secondAnswer != nil }
        try require(firstAnswer == true && secondAnswer == false, "two CEF tabs retain independent Leave and Stay decisions")
        try require(try await js(second, "window.__dirty") as? Bool == true, "a different tab's Leave does not discard the Stay tab")
        harness.deferDialogs = false
        try closeController(second).forceClose()

        let opener = make("close-popup")
        try await load(opener, path: "beforeunload.html")
        let popupCount = popupTabs.count
        try await click(opener, "popup")
        try await wait { self.popupTabs.count == popupCount + 1 }
        let popup = popupTabs[popupCount]
        try await wait { !popup.state.isLoading && popup.state.title == "Cairn unsaved-page fixture" }
        try await click(popup, "edit")
        harness.dialog = { _ in (false, nil, false) }
        try require(try await closeDecision(popup) == false, "an adopted popup can veto close")
        try require(try await js(opener, "window.child.closed") as? Bool == false, "popup Stay preserves its opener relationship")
        harness.dialog = { _ in (true, nil, false) }
        try require(try await closeDecision(popup), "popup Leave approves close")
        try await wait { popup.view.subviews.isEmpty }
        try require(try await js(opener, "window.child.closed") as? Bool == true, "popup Leave destroys only the popup browser")
        try require(try await closeDecision(opener), "opener remains independently closable")

        let forced = try await editableCloseFixture("close-force")
        harness.deferDialogs = true
        var forceAnswer: Bool?
        let forceControl = try closeController(forced)
        forceControl.requestClose { forceAnswer = $0 }
        try await wait { !harness.deferredDialogs.isEmpty }
        forceControl.forceClose()
        try await wait { forceAnswer != nil }
        try require(forceAnswer == true, "explicit forced close escapes a pending beforeunload prompt")
        harness.deferredDialogs.removeAll()
        print("CAIRN_CLOSE_LIFECYCLE_OK")
    }

    /// Invoke before the smoke runner's final pending-creation probe and runtime shutdown.
    /// Runtime shutdown is deliberately not an implicit authorization to discard live pages.
    func approveSmokeTabClosure() async throws {
        let harness = PromptHarness.shared
        harness.deferDialogs = false
        harness.dialog = { _ in (true, nil, false) }
        let deferred = harness.deferredDialogs
        harness.deferredDialogs.removeAll()
        for pending in deferred {
            (pending.tab as? EngineTabPromptResponding)?.resolveJSDialog(id: pending.request.id, accept: true,
                                                                        text: nil, suppressFurther: false)
        }
        var seen: Set<UUID> = []
        for tab in tabs + popupTabs where seen.insert(tab.id).inserted {
            guard try await closeDecision(tab) else { throw SmokeError.failed("Final smoke close was vetoed") }
        }
    }
}

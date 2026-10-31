import Testing
@testable import BoothCore

@Suite("Popover logic")
struct PopoverLogicTests {
    @Test func viewOnOpenPriorities() {
        // Each rule wins over everything below it, as in Main.dc.html.
        var c = PopoverContext(
            requested: .settings, setupIncomplete: true, hasError: true, hasActiveJob: true,
            hasFocus: true, unseen: true)
        #expect(PopoverLogic.viewOnOpen(c) == .firstrun)
        c.setupIncomplete = false
        #expect(PopoverLogic.viewOnOpen(c) == .error)
        c.hasError = false
        #expect(PopoverLogic.viewOnOpen(c) == .working)
        c.hasActiveJob = false
        #expect(PopoverLogic.viewOnOpen(c) == .done)
        c.unseen = false
        #expect(PopoverLogic.viewOnOpen(c) == .settings)
        c.requested = .done
        #expect(PopoverLogic.viewOnOpen(c) == .done)
        c.hasFocus = false
        #expect(PopoverLogic.viewOnOpen(c) == .idle)
        c.requested = .working
        #expect(PopoverLogic.viewOnOpen(c) == .idle)
    }

    @Test func settingsAlwaysShows() {
        let c = PopoverContext(requested: .settings, setupIncomplete: true, hasError: true)
        #expect(PopoverLogic.effectiveScreen(c) == .settings)
    }

    @Test func setupScreenOverridesEverythingButSettings() {
        for requested in PopoverScreen.allCases where requested != .settings {
            let c = PopoverContext(requested: requested, setupIncomplete: true, hasActiveJob: true)
            #expect(PopoverLogic.effectiveScreen(c) == .firstrun)
        }
    }

    @Test func errorNeedsAnError() {
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .error, hasError: true)) == .error)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .error)) == .idle)
        // An error alone does not take over another requested screen.
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .idle, hasError: true)) == .idle)
    }

    @Test func workingFallsBackToDoneThenIdle() {
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .working, hasActiveJob: true)) == .working)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .working, hasFocus: true, focusIsDone: true)) == .done)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .working, hasFocus: true)) == .idle)
        // A job that has just finished stays on Working for a moment before Done.
        #expect(PopoverLogic.effectiveScreen(
            PopoverContext(requested: .working, hasFocus: true, focusIsDone: true, focusIsFinishing: true)) == .working)
    }

    @Test func doneNeedsAFinishedFocus() {
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .done, hasFocus: true, focusIsDone: true)) == .done)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .done, hasActiveJob: true, hasFocus: true)) == .idle)
    }

    @Test func staleFirstrunRequestShowsIdle() {
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .firstrun)) == .idle)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(requested: .idle)) == .idle)
    }

    @Test func glyphModes() {
        #expect(PopoverLogic.glyphMode(PopoverContext()) == .idle)
        #expect(PopoverLogic.glyphMode(PopoverContext(hasActiveJob: true, iconTarget: true)) == .target)
        #expect(PopoverLogic.glyphMode(PopoverContext(isOpen: false, hasError: true, hasActiveJob: true)) == .attention)
        #expect(PopoverLogic.glyphMode(PopoverContext(isOpen: true, hasError: true, hasActiveJob: true)) == .working)
        #expect(PopoverLogic.glyphMode(PopoverContext(setupIncomplete: true)) == .working)
        #expect(PopoverLogic.glyphMode(PopoverContext(isOpen: false, setupIncomplete: true, setupFailed: true)) == .attention)
        #expect(PopoverLogic.glyphMode(PopoverContext(isOpen: true, setupIncomplete: true, setupFailed: true)) == .idle)
        #expect(PopoverLogic.glyphMode(PopoverContext(hasActiveJob: true, unseen: true)) == .working)
        #expect(PopoverLogic.glyphMode(PopoverContext(unseen: true)) == .done)
    }

    @Test func screenTraits() {
        #expect(PopoverScreen.allCases.filter { !$0.acceptsDrops } == [.settings])
        #expect(PopoverScreen.allCases.filter { !$0.showsGear } == [.working, .done, .settings, .error])
        #expect(PopoverScreen.allCases.filter(\.showsSignature) == [.firstrun, .idle])
        #expect(GlyphMode.allCases.filter { !$0.isTemplate } == [.working])
    }
}

@Suite("Setup state")
struct SetupStateTests {
    @Test func foldsSetupEvents() {
        var state = SetupState.checking
        #expect(!state.isReady && !state.showsSetupScreen)
        state.apply(.setup(SetupProgress(phase: "weights", label: "Downloading voice models", bytesDone: 412_000_000, bytesTotal: 1_130_000_000, eta: 110)))
        guard case .running(let info) = state else {
            Issue.record("expected running")
            return
        }
        #expect(info.label == "Downloading voice models")
        #expect(abs(state.fraction - 412.0 / 1130.0) < 1e-12)
        #expect(state.showsSetupScreen && state.isRunning)

        state.apply(.progress(EngineProgress(progress: 0.5)))
        #expect(state.isRunning)

        state.apply(.done(EngineDone()))
        #expect(state == .ready)
        #expect(state.fraction == 1)
    }

    @Test func failsWithTheMessage() {
        var state = SetupState.running(SetupProgressInfo())
        state.apply(.error(JobError(code: .setupFailed, message: "No space left.")))
        #expect(state == .failed(message: "No space left."))
        #expect(state.isFailed && state.showsSetupScreen && !state.isRunning)
    }

    @Test func statusCheckOnlyEverMakesItReady() {
        var state = SetupState.checking
        state.apply(.setupStatus(SetupStatus(ready: false)))
        #expect(state == .checking)
        state.apply(.setupStatus(SetupStatus(ready: true)))
        #expect(state == .ready)
    }

    @Test func waitingForTheEngineShowsTheSetupScreenWithoutRunning() {
        let state = SetupState.waitingForEngine(folder: "~/Documents/sv")
        #expect(state.showsSetupScreen && state.isWaitingForEngine)
        #expect(!state.isRunning && !state.isFailed && !state.isReady)
        #expect(state.fraction == 0)
        // The prototype's logic then shows First run and the working glyph.
        let context = PopoverContext(isOpen: false, requested: .idle, setupIncomplete: state.showsSetupScreen, setupFailed: state.isFailed)
        #expect(PopoverLogic.glyphMode(context) == .working)
        var open = context
        open.isOpen = true
        #expect(PopoverLogic.viewOnOpen(open) == .firstrun)
        #expect(PopoverLogic.effectiveScreen(PopoverContext(isOpen: true, requested: .idle, setupIncomplete: true)) == .firstrun)
    }

    @Test func fractionWithUnknownTotal() {
        #expect(SetupProgressInfo(bytesDone: 10, bytesTotal: 0).fraction == 0)
        #expect(SetupProgressInfo(bytesDone: 20, bytesTotal: 10).fraction == 1)
    }

    @Test func onlyTheDropZoneHasAnOutline() {
        for screen in PopoverScreen.allCases {
            #expect(PopoverLogic.frameStyle(screen: screen, dropHover: false) == (screen == .idle ? .dotted : FrameStyle.none))
        }
    }

    @Test func aFileOverAScreenThatTakesItShowsTheDropTarget() {
        for screen in PopoverScreen.allCases {
            let expected: FrameStyle = screen.acceptsDrops ? .dropTarget : .none
            #expect(PopoverLogic.frameStyle(screen: screen, dropHover: true) == expected)
        }
    }
}

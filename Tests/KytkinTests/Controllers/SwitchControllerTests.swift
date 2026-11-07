// P2-20: SwitchController with fakes: rules on context change (keepCurrent → no switch), learning from manual
// switches and its enable/disable matrix, Kytkin's own window (P2-39), Pin / Forget / Pause, and the one re-assert.

import XCTest

@MainActor
final class SwitchControllerTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var conflicts: FakeConflicts!
    private var store: PreferencesStore!
    private var sut: SwitchController!
    private let notes = "com.apple.Notes"
    private let terminal = "com.apple.Terminal"
    private let date = Date(timeIntervalSince1970: 5_000)

    private func make(_ prefs: Preferences = Preferences(), tap: Bool = true) {
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: IDs.abc)
        monitor = FakeContextMonitor()
        conflicts = FakeConflicts()
        store = makeStore(prefs, clock: clock)
        sut = SwitchController(switcher: switcher, context: monitor, store: store, conflicts: conflicts, clock: clock,
                               now: { [date] in date })
        sut.setKeyboardTapAvailable(tap)
        monitor.onChange = { [unowned self] c in self.sut.contextDidChange(c) }
    }

    private func prefs(rules: [Rule]) -> Preferences {
        var p = Preferences()
        p.rules = rules
        return p
    }

    /// The user presses Ctrl-Space at least 600 ms after the last context change.
    private func userSwitch(to id: InputSourceID) {
        clock.advance(byMilliseconds: 600)
        switcher.current = id
        sut.inputSourceDidChange(.external(id, atNanos: clock.nowNanos))
    }

    // MARK: - Flow (a)

    func testContextChangeAppliesTheAppRule() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        XCTAssertEqual(switcher.selects.first?.1, .rule)
        XCTAssertEqual(conflicts.ourSwitches, 1)
    }

    func testKeepCurrentDoesNotSwitch() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(terminal, pid: 11)
        XCTAssertTrue(switcher.selects.isEmpty)
        XCTAssertEqual(conflicts.ourSwitches, 0)
    }

    func testDefaultSwitchToApplies() {
        var p = Preferences()
        p.general.defaultBehavior = .switchTo(IDs.hebrew)
        make(p)
        monitor.activate(terminal, pid: 11)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testAlreadyCurrentDoesNotSelect() {
        make(prefs(rules: [.app(notes, IDs.abc)]))
        monitor.activate(notes, pid: 10)
        XCTAssertTrue(switcher.selects.isEmpty)
        XCTAssertEqual(conflicts.ourSwitches, 0)
    }

    func testFailedSelectIsNotCountedAsOurs() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        switcher.selectSucceeds = false
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(conflicts.ourSwitches, 0)
    }

    func testDisabledAppAndDisabledKytkinDoNotSwitch() {
        var p = prefs(rules: [.app(notes, IDs.hebrew)])
        p.apps[notes] = .init(disabled: true)
        make(p)
        monitor.activate(notes, pid: 10)
        XCTAssertTrue(switcher.selects.isEmpty)

        var q = prefs(rules: [.app(notes, IDs.hebrew)])
        q.general.enabled = false
        make(q)
        monitor.activate(notes, pid: 10)
        XCTAssertTrue(switcher.selects.isEmpty)
    }

    // MARK: - Flow (b): learning

    func testManualSwitchIsLearnedAfterTwoWords() {
        make()
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        XCTAssertEqual(conflicts.externalSwitches, 1)
        XCTAssertNotNil(sut.learner.pending)
        sut.wordBoundary()
        sut.wordBoundary()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: notes)])
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew)
        XCTAssertEqual(store.prefs.rules.first?.origin, .learned)
        XCTAssertEqual(sut.engine.resolve(monitor.current!).target, IDs.hebrew, "engine rebuilt at once")
    }

    func testLearnedRuleIsAppliedOnTheNextVisit() {
        make()
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        sut.wordBoundary(); sut.wordBoundary()
        switcher.current = IDs.abc
        monitor.activate(terminal, pid: 11)
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testDwellConfirmsWithoutATap() {
        make(tap: false)
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        XCTAssertTrue(sut.wantsTicks)
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertTrue(store.prefs.rules.isEmpty, "no words without a buffer")
        clock.advance(bySeconds: 4)
        sut.tick()
        XCTAssertEqual(store.prefs.rules.count, 1)
        XCTAssertFalse(sut.wantsTicks)
    }

    func testWantsTicksOnlyWithACandidateAndNoTap() {
        make(tap: true)
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        XCTAssertFalse(sut.wantsTicks)
        sut.setKeyboardTapAvailable(false)
        XCTAssertTrue(sut.wantsTicks)
    }

    func testLearningEnableMatrix() {
        // (learn setting, Kytkin enabled, paused, per-document input) → learningEnabled
        let cases: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, true, false, false, true),
            (false, true, false, false, false),
            (true, false, false, false, false),
            (true, true, true, false, false),
            (true, true, false, true, false),
            (false, false, true, true, false),
        ]
        for (learn, enabled, paused, perDoc, expected) in cases {
            var p = Preferences()
            p.general.learnFromManualSwitches = learn
            p.general.enabled = enabled
            make(p)
            conflicts.conflicts.perDocumentInputEnabled = perDoc
            sut.refreshLearning()
            sut.setPaused(paused)
            XCTAssertEqual(sut.learner.learningEnabled, expected, "\(learn) \(enabled) \(paused) \(perDoc)")
        }
    }

    func testPerDocumentPauseIsSessionOnlyAndRulesStillApply() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        conflicts.conflicts.perDocumentInputEnabled = true
        sut.refreshLearning()
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "rules still apply")
        monitor.activate(terminal, pid: 11)
        userSwitch(to: IDs.russian)
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertEqual(store.prefs.rules.count, 1, "nothing learned")
        XCTAssertTrue(store.prefs.general.learnFromManualSwitches, "the preference is never written")
        conflicts.conflicts.perDocumentInputEnabled = false
        sut.refreshLearning()
        XCTAssertTrue(sut.learner.learningEnabled)
    }

    func testOurSwitchIsNeverLearned() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertEqual(conflicts.externalSwitches, 0)
        XCTAssertEqual(store.prefs.rules.count, 1)
    }

    func testPinnedRuleIsNeverChangedByLearning() {
        make(prefs(rules: [.app(notes, IDs.hebrew, .pinned)]))
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.russian)
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew)
    }

    func testExternalSwitchInADisabledAppIsNotLearned() {
        var p = Preferences()
        p.apps[notes] = .init(disabled: true)
        make(p)
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        XCTAssertNil(sut.learner.pending)
        XCTAssertEqual(conflicts.externalSwitches, 1, "fights are still counted")
    }

    // MARK: - Kytkin's own window (P2-39)

    func testKytkinActiveCancelsTheCandidateAndIgnoresManualSwitches() {
        make()
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        XCTAssertNotNil(sut.learner.pending)
        sut.kytkinDidBecomeActive()
        XCTAssertNil(sut.learner.pending, "cancelled")
        userSwitch(to: IDs.russian)            // typed in Settings
        XCTAssertNil(sut.learner.pending, "not passed to the learner")
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertTrue(store.prefs.rules.isEmpty)
        XCTAssertEqual(conflicts.externalSwitches, 2)
    }

    func testResignToTheSameAppReappliesItsRuleAndRestartsTheSettle() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        sut.kytkinDidBecomeActive()
        switcher.current = IDs.abc                 // changed while Settings was open
        sut.kytkinDidResignActive(frontmostPID: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
        // The settle restarted: a switch 350 ms later (past the re-assert window) is still not a preference.
        clock.advance(byMilliseconds: 350)
        switcher.current = IDs.russian
        sut.inputSourceDidChange(.external(IDs.russian, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs.count, 2, "no re-assert after 300 ms")
        XCTAssertNil(sut.learner.pending)
    }

    func testResignToAnotherAppDoesNotApplyTheOldRule() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        sut.kytkinDidBecomeActive()
        switcher.current = IDs.abc
        sut.kytkinDidResignActive(frontmostPID: 99)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "only the first activation")
        sut.kytkinDidResignActive(frontmostPID: nil)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testAfterResignLearningWorksAgain() {
        make()
        monitor.activate(notes, pid: 10)
        sut.kytkinDidBecomeActive()
        sut.kytkinDidResignActive(frontmostPID: 10)
        userSwitch(to: IDs.hebrew)
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertEqual(store.prefs.rules.count, 1)
    }

    // MARK: - P2-41: the current app quit

    func testNothingIsLearnedForAnAppThatQuit() {
        make()
        monitor.activate(notes, pid: 10)
        monitor.currentAppIsGone = true
        userSwitch(to: IDs.hebrew)
        XCTAssertNil(sut.learner.pending)
        XCTAssertTrue(sut.learnerDebug.contains("app quit"))
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testAQuitAppsRuleIsNotReappliedButTheNextAppsIs() {
        make(prefs(rules: [.app(notes, IDs.hebrew), .app(terminal, IDs.russian)]))
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        switcher.current = IDs.abc
        monitor.currentAppIsGone = true
        sut.kytkinDidBecomeActive()
        sut.kytkinDidResignActive(frontmostPID: 10)
        sut.recheckAfterResign(frontmostPID: 10)
        sut.setPaused(true); sut.setPaused(false)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "no switch for a dead pid")
        monitor.activate(terminal, pid: 11)   // a new Context clears the flag
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian])
    }

    func testPinAndForgetStillWorkAfterTheAppQuit() {
        make(prefs(rules: [.app(notes, IDs.abc)]))
        monitor.activate(notes, pid: 10)
        monitor.currentAppIsGone = true
        switcher.current = IDs.hebrew
        XCTAssertEqual(sut.pinCurrent()?.inputSource, IDs.hebrew)
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    // MARK: - Pin / Forget / Pause

    func testPinWritesAPinnedRuleForTheCurrentAppAndSource() {
        make(prefs(rules: [.app(notes, IDs.abc)]))
        monitor.activate(notes, pid: 10)
        switcher.current = IDs.hebrew
        let pinned = sut.pinCurrent()
        XCTAssertEqual(pinned?.origin, .pinned)
        XCTAssertEqual(store.prefs.rules.count, 1)
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew)
        XCTAssertEqual(store.prefs.rules.first?.origin, .pinned)
        XCTAssertEqual(store.prefs.rules.first?.updatedAt, date)
    }

    func testPinWhileKytkinIsActiveTargetsThePreviousApp() {
        make()
        monitor.activate(notes, pid: 10)
        sut.kytkinDidBecomeActive()
        sut.pinCurrent()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: notes)])
    }

    func testPinWithoutAContextDoesNothing() {
        make()
        XCTAssertNil(sut.pinCurrent())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testPinnedRuleBlocksLaterLearning() {
        make()
        monitor.activate(notes, pid: 10)
        sut.pinCurrent()
        userSwitch(to: IDs.hebrew)
        sut.wordBoundary(); sut.wordBoundary()
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.abc)
    }

    func testForgetRemovesTheMatchedRule() {
        make(prefs(rules: [.app(notes, IDs.hebrew, .pinned), .app(terminal, IDs.abc)]))
        monitor.activate(notes, pid: 10)
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: terminal)])
        XCTAssertNil(sut.currentRule?.resolution.matched)
        XCTAssertFalse(sut.forgetCurrent(), "nothing left")
    }

    func testForgetDoesNotSwitch() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        sut.forgetCurrent()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testPauseStopsSwitchingAndLearningAndResumeReapplies() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        sut.setPaused(true)
        monitor.activate(notes, pid: 10)
        XCTAssertTrue(switcher.selects.isEmpty)
        userSwitch(to: IDs.russian)
        XCTAssertNil(sut.learner.pending)
        XCTAssertFalse(sut.learner.learningEnabled)
        switcher.current = IDs.abc
        sut.setPaused(false)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "resume applies the current app's rule")
        XCTAssertTrue(sut.learner.learningEnabled)
        XCTAssertEqual(store.prefs, prefs(rules: store.prefs.rules), "Pause writes nothing")
    }

    func testPauseCancelsACandidate() {
        make()
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.hebrew)
        sut.setPaused(true)
        XCTAssertNil(sut.learner.pending)
    }

    func testSelectFromMenuCountsAsOurs() {
        make()
        XCTAssertTrue(sut.selectFromMenu(IDs.hebrew))
        XCTAssertEqual(conflicts.ourSwitches, 1)
        XCTAssertTrue(sut.selectFromMenu(IDs.hebrew))
        XCTAssertEqual(conflicts.ourSwitches, 1, "already current: no switch")
    }

    // MARK: - Re-assert once

    func testExternalChangeRightAfterOurSwitchIsReassertedOnce() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        // macOS (per-document input) or another switcher puts ABC back 50 ms later.
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
        XCTAssertNil(sut.learner.pending)
        // It happens again: no loop.
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs.count, 2)
    }

    func testExternalChangeLaterIsNotReasserted() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        userSwitch(to: IDs.abc)   // 600 ms later: the user's own choice
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        XCTAssertNotNil(sut.learner.pending)
    }

    // MARK: - P2-20 QA

    func testNoReassertWhilePaused() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        sut.setPaused(true)
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "paused: no fight back")
    }

    /// The resign re-apply (P2-39) is a new rule switch in the same Context; together with the first one there is
    /// still at most one re-assert for that app change. A new app change gets its own single re-assert.
    func testAtMostOneReassertPerAppChangeAcrossResignReapply() {
        make(prefs(rules: [.app(notes, IDs.hebrew)]))
        monitor.activate(notes, pid: 10)
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))   // re-assert
        sut.kytkinDidBecomeActive()
        switcher.current = IDs.abc
        sut.kytkinDidResignActive(frontmostPID: 10)                              // re-apply
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew, IDs.hebrew], "no second re-assert")
        monitor.activate(terminal, pid: 11)
        monitor.activate(notes, pid: 10)
        clock.advance(byMilliseconds: 50)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs.count, 5)
    }

    /// Learning off (Settings) or Kytkin disabled: a manual switch never becomes a rule, by words or by dwell.
    func testNothingLearnedWhenLearningOrKytkinIsOff() {
        for setting in 0..<2 {
            var p = Preferences()
            if setting == 0 { p.general.learnFromManualSwitches = false } else { p.general.enabled = false }
            make(p, tap: false)
            monitor.activate(notes, pid: 10)
            userSwitch(to: IDs.hebrew)
            clock.advance(bySeconds: 5)
            sut.tick()
            sut.wordBoundary(); sut.wordBoundary()
            XCTAssertTrue(store.prefs.rules.isEmpty, "setting \(setting)")
            XCTAssertTrue(switcher.selects.isEmpty)
        }
    }

    /// A rule for a source that is no longer enabled: the switcher refuses, nothing counts as ours, and no re-assert
    /// follows (it is tried again only on the next app change).
    func testRuleForADisabledSourceIsTriedOncePerAppChange() {
        make(prefs(rules: [.app(notes, IDs.russian)]))
        switcher.selectSucceeds = false
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.russian])
        XCTAssertEqual(conflicts.ourSwitches, 0)
        clock.advance(byMilliseconds: 50)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs, [IDs.russian])
    }
}

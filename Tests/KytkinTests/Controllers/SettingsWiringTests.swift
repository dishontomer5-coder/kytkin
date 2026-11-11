// P2-23 / P2-52: the controller side of the Settings window.
// Item 3: turning `general.enabled` back on re-applies the current app's rule like resuming from Pause (at once, or at
//         the resign when Settings is in front); turning it off drops a learning candidate.
// Item 1: when Kytkin resigns and the frontmost app still reads as Kytkin (or unknown), AppController looks again
//         after 150 ms (up to 3 times, FakeClock-driven) and re-applies the rule if the previous app is in front.

import XCTest

@MainActor
final class SettingsWiringTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var permissions: FakePermissions!
    private var conflicts: FakeConflicts!
    private var watcher: FakeKeyWatcher!
    private var oneShot: FakeOneShot!
    private var store: PreferencesStore!
    private var sut: AppController!
    private var frontmost: Int32?
    private let notes = "com.apple.Notes"
    private let ownPID: Int32 = 4_242

    private func make(withScheduler: Bool = true) {
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: IDs.abc)
        monitor = FakeContextMonitor()
        permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .granted,
                                                                             inputMonitoring: .notDetermined))
        conflicts = FakeConflicts()
        watcher = FakeKeyWatcher()
        oneShot = FakeOneShot(clock: clock)
        var p = Preferences()
        p.rules = [.app(notes, IDs.hebrew)]
        store = makeStore(p, clock: clock)
        sut = AppController(switcher: switcher, context: monitor, store: store, permissions: permissions,
                            conflicts: conflicts, keyWatcher: watcher, ticker: FakeTicker(), clock: clock,
                            scheduler: withScheduler ? oneShot : nil, ownPID: ownPID,
                            frontmostPID: { [unowned self] in self.frontmost })
        switcher.onChange = { [unowned self] in self.sut.inputSourceDidChange($0) }
        monitor.onChange = { [unowned self] in self.sut.contextDidChange($0) }
        sut.start()
    }

    /// Notes is in front with its rule applied, then the user opens Settings and changes the language there.
    private func openSettingsOverNotes() {
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        sut.kytkinDidBecomeActive()
        switcher.current = IDs.abc
    }

    private func setEnabled(_ on: Bool) {
        store.update { $0.general.enabled = on }
        sut.preferencesDidChange()      // what the Observation hook calls
    }

    // MARK: - Item 1: the second look after a resign

    func testResignWhileFrontmostIsStillKytkinRechecksAndReapplies() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "Kytkin itself is not the app in front")
        XCTAssertTrue(oneShot.isScheduled)
        frontmost = 10
        oneShot.advance(byMilliseconds: 149)
        XCTAssertEqual(switcher.selectedIDs.count, 1, "not before 150 ms")
        oneShot.advance(byMilliseconds: 1)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew], "Notes' rule re-applied")
        XCTAssertFalse(oneShot.isScheduled)
    }

    func testUnknownFrontmostAlsoRechecks() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: nil)
        frontmost = 10
        oneShot.advance(byMilliseconds: 150)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
    }

    func testRecheckTriesThreeTimesThenGivesUp() {
        make()
        openSettingsOverNotes()
        frontmost = ownPID
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        oneShot.advance(byMilliseconds: 150)
        oneShot.advance(byMilliseconds: 150)
        XCTAssertTrue(oneShot.isScheduled, "third look still to come")
        oneShot.advance(byMilliseconds: 150)
        XCTAssertFalse(oneShot.isScheduled, "gives up after 3")
        XCTAssertEqual(oneShot.scheduleCount, 3)
        frontmost = 10
        oneShot.advance(byMilliseconds: 1_000)
        XCTAssertEqual(switcher.selectedIDs.count, 1)
    }

    func testRecheckFindingAnotherAppDoesNotApplyTheOldRule() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        frontmost = 77                    // ContextMonitor will report this app itself
        oneShot.advance(byMilliseconds: 150)
        XCTAssertEqual(switcher.selectedIDs.count, 1)
        XCTAssertFalse(oneShot.isScheduled)
    }

    func testKnownFrontmostAtResignNeedsNoRecheck() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: 10)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew], "applied at once, as before")
        XCTAssertFalse(oneShot.isScheduled)
    }

    func testReactivationOrAContextChangeCancelsTheRecheck() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        sut.kytkinDidBecomeActive()               // Settings clicked again
        XCTAssertFalse(oneShot.isScheduled)
        frontmost = 10
        oneShot.advance(byMilliseconds: 500)
        XCTAssertEqual(switcher.selectedIDs.count, 1)

        sut.kytkinDidResignActive(frontmostPID: nil)
        monitor.activate("com.apple.Terminal", pid: 20)
        XCTAssertFalse(oneShot.isScheduled, "the new app got its own context change")
    }

    func testRecheckDoesNothingWhileKytkinIsActiveOrAfterStop() {
        make()
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        sut.stop()
        XCTAssertFalse(oneShot.isScheduled)
        frontmost = 10
        oneShot.advance(byMilliseconds: 500)
        XCTAssertEqual(switcher.selectedIDs.count, 1)
    }

    func testWithoutASchedulerNothingIsScheduled() {
        make(withScheduler: false)
        openSettingsOverNotes()
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        XCTAssertEqual(oneShot.scheduleCount, 0)
        XCTAssertEqual(switcher.selectedIDs.count, 1)
    }

    // MARK: - Item 3: Kytkin back on re-applies the rule

    func testTurningKytkinBackOnReappliesTheCurrentRule() {
        make()
        monitor.activate(notes, pid: 10)
        setEnabled(false)
        switcher.current = IDs.abc
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "off: no switch")
        setEnabled(true)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew], "like unpause")
        setEnabled(true)
        sut.preferencesDidChange()
        XCTAssertEqual(switcher.selectedIDs.count, 2, "only on an off → on change")
    }

    func testTurningKytkinBackOnFromSettingsAppliesAtTheResign() {
        make()
        openSettingsOverNotes()
        setEnabled(false)
        setEnabled(true)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "Settings is in front: nothing yet")
        frontmost = 10
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        oneShot.advance(byMilliseconds: 150)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
    }

    func testTurningKytkinBackOnWhilePausedDoesNotSwitch() {
        make()
        monitor.activate(notes, pid: 10)
        sut.setPaused(true)
        setEnabled(false)
        switcher.current = IDs.abc
        setEnabled(true)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        sut.setPaused(false)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
    }

    func testTurningKytkinOffDropsTheCandidateAndStopsLearning() {
        make()
        monitor.activate(notes, pid: 10)
        clock.advance(byMilliseconds: 600)
        switcher.current = IDs.russian
        sut.inputSourceDidChange(.external(IDs.russian, atNanos: clock.nowNanos))
        XCTAssertNotNil(sut.switching.learner.pending)
        setEnabled(false)
        XCTAssertNil(sut.switching.learner.pending)
        XCTAssertFalse(sut.switching.learner.learningEnabled)
        setEnabled(true)
        XCTAssertTrue(sut.switching.learner.learningEnabled)
    }

    func testTurningKytkinOffAndOnTurnsTheTapOffAndOn() {
        make()
        XCTAssertEqual(watcher.starts, [.active])
        setEnabled(false)
        XCTAssertEqual(watcher.stops, 1)
        setEnabled(true)
        XCTAssertEqual(watcher.starts, [.active, .active])
    }

    func testTurningKytkinBackOnWithNoContextDoesNothing() {
        make()
        setEnabled(false)
        setEnabled(true)
        XCTAssertTrue(switcher.selects.isEmpty)
    }

    // MARK: - P2-55 QA: menu activations vs Settings with a lagging frontmost app

    private let textEdit = "com.apple.TextEdit"
    private var resets: Int { watcher.contextResets.count }   // P3-37

    /// TextEdit (no rule) in front and settled; frontmost reads TextEdit.
    private func textEditInFront() {
        monitor.activate(textEdit, pid: 20)
        frontmost = 20
        clock.advance(byMilliseconds: 1_000)
    }

    /// Settings comes forward with `NSApp.activate()`, but at didBecomeActive `frontmostApplication` still reads the
    /// previous app. The second look sees Kytkin in front: it is Kytkin's window, so a switch typed there is not
    /// learned for TextEdit (W2).
    func testSettingsOpeningWithALaggingFrontmostIsStillKytkinsWindow() {
        make()
        textEditInFront()
        sut.kytkinDidBecomeActive(isFrontmost: false)
        XCTAssertFalse(sut.switching.isOwnAppActive, "not decided yet")
        XCTAssertTrue(oneShot.isScheduled)
        frontmost = ownPID                                   // NSWorkspace caught up
        oneShot.advance(byMilliseconds: 150)
        XCTAssertTrue(sut.switching.isOwnAppActive, "Settings after all")
        XCTAssertFalse(oneShot.isScheduled)
        XCTAssertEqual(resets, 2, "context change + Kytkin's own window: the word buffer is reset")
        switcher.current = IDs.hebrew
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))   // typed in Settings
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertTrue(store.prefs.rules.allSatisfy { $0.scope != .app(bundleID: textEdit) }, "W2: not learned")
        XCTAssertNil(sut.switching.learner.pending)
    }

    /// The status-bar menu opens (didBecomeActive, TextEdit stays frontmost) and closes with an unpaired resign:
    /// the look finds TextEdit and stops; no reset, the candidate survives, learning works.
    func testMenuOpenWithNoRealActivationChangesNothing() {
        make()
        textEditInFront()
        switcher.current = IDs.hebrew
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        let resetsBefore = resets
        sut.kytkinDidBecomeActive(isFrontmost: false)
        oneShot.advance(byMilliseconds: 150)
        XCTAssertFalse(oneShot.isScheduled, "another app is frontmost: the look stops at once")
        XCTAssertFalse(sut.switching.isOwnAppActive)
        sut.kytkinDidResignActive(frontmostPID: 20)          // unpaired
        XCTAssertFalse(oneShot.isScheduled)
        XCTAssertEqual(resets, resetsBefore, "a menu is not Kytkin's window")
        XCTAssertEqual(switcher.selectedIDs, [], "no rule re-applied by the unpaired resign")
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.last?.scope, .app(bundleID: textEdit))
        XCTAssertEqual(store.prefs.rules.last?.inputSource, IDs.hebrew)
    }

    /// Menu opened and closed before the first look: the unpaired resign ends the look.
    func testResignBeforeTheLookEndsIt() {
        make()
        textEditInFront()
        sut.kytkinDidBecomeActive(isFrontmost: false)
        sut.kytkinDidResignActive(frontmostPID: 20)
        XCTAssertFalse(oneShot.isScheduled)
        frontmost = ownPID
        oneShot.advance(byMilliseconds: 500)
        XCTAssertFalse(sut.switching.isOwnAppActive)
    }

    /// A real activation then a resign (frontmost still Kytkin): the P2-23 look re-applies the rule; the resign was
    /// paired, so P2-55's "unpaired resign does nothing" doesn't apply.
    func testRealActivationThenResignStillRechecks() {
        make()
        monitor.activate(notes, pid: 10)
        frontmost = ownPID
        sut.kytkinDidBecomeActive(isFrontmost: true)
        XCTAssertTrue(sut.switching.isOwnAppActive)
        switcher.current = IDs.abc
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        XCTAssertFalse(sut.switching.isOwnAppActive)
        XCTAssertTrue(oneShot.isScheduled)
        frontmost = 10
        oneShot.advance(byMilliseconds: 150)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
    }

    /// A resign look is still running when the menu opens and closes: it keeps its job (re-apply Notes' rule).
    func testMenuOpenDuringAResignLookKeepsTheResignLook() {
        make()
        openSettingsOverNotes()
        frontmost = ownPID
        sut.kytkinDidResignActive(frontmostPID: ownPID)
        sut.kytkinDidBecomeActive(isFrontmost: false)        // menu, while frontmost still lags
        sut.kytkinDidResignActive(frontmostPID: ownPID)      // menu closed (unpaired)
        XCTAssertTrue(oneShot.isScheduled)
        frontmost = 10
        oneShot.advance(byMilliseconds: 150)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
        XCTAssertFalse(sut.switching.isOwnAppActive)
    }

    /// The flag can't stay stuck after a lost resign: the next external switch, with another app frontmost, ends it
    /// (without re-applying a rule over the user's switch) and is learned.
    func testAStaleOwnWindowFlagHealsOnTheNextSwitch() {
        make()
        textEditInFront()
        frontmost = ownPID
        sut.kytkinDidBecomeActive(isFrontmost: true)
        frontmost = 20                                       // Settings gone; resign never posted
        clock.advance(byMilliseconds: 1_000)
        switcher.current = IDs.hebrew
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        XCTAssertFalse(sut.switching.isOwnAppActive)
        XCTAssertEqual(switcher.selectedIDs, [], "no rule forced over the user's switch")
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.last?.scope, .app(bundleID: textEdit))
    }

    /// While Settings really is frontmost (or frontmost is unknown), words and switches never end the flag.
    func testOwnWindowFlagIsKeptWhileKytkinIsFrontmost() {
        make()
        textEditInFront()
        frontmost = ownPID
        sut.kytkinDidBecomeActive(isFrontmost: true)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        XCTAssertTrue(sut.switching.isOwnAppActive)
        frontmost = nil
        sut.keySignal(.wordBoundary)
        XCTAssertTrue(sut.switching.isOwnAppActive)
    }
}

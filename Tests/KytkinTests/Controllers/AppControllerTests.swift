// P2-20: AppController (the decisions behind AppEnvironment) with fakes for every adapter: the callback fan-out,
// tap-mode starts (§12 W7), config pushes (P2-50), Secure Input → dwell (P2-45), double-Shift generations always
// finished, Pause, the menu hooks (P2-48), and preferences observed through Observation.

import XCTest

@MainActor
final class AppControllerTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var permissions: FakePermissions!
    private var conflicts: FakeConflicts!
    private var watcher: FakeKeyWatcher!
    private var ticker: FakeTicker!
    private var convert: FakeConvert?
    private var store: PreferencesStore!
    private var sut: AppController!
    private var displayChanges = 0
    private let notes = "com.apple.Notes"
    private let snapshot = WordSnapshot(strokes: [], previousWords: [], renderedIn: nil, isValid: true)

    /// Wires the fakes the way AppEnvironment wires the real adapters.
    private func make(_ prefs: Preferences = Preferences(), accessibility: PermissionState = .granted,
                      inputMonitoring: PermissionState = .notDetermined, withConvert: Bool = false,
                      store customStore: PreferencesStore? = nil, start: Bool = true) {
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher()
        monitor = FakeContextMonitor()
        permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: accessibility,
                                                                             inputMonitoring: inputMonitoring))
        conflicts = FakeConflicts()
        watcher = FakeKeyWatcher()
        ticker = FakeTicker()
        convert = withConvert ? FakeConvert() : nil
        store = customStore ?? makeStore(prefs, clock: clock)
        sut = AppController(switcher: switcher, context: monitor, store: store, permissions: permissions,
                            conflicts: conflicts, keyWatcher: watcher, ticker: ticker, convert: convert, clock: clock)
        switcher.onChange = { [unowned self] in self.sut.inputSourceDidChange($0) }
        monitor.onChange = { [unowned self] in self.sut.contextDidChange($0) }
        permissions.onChange = { [unowned self] in self.sut.permissionsDidChange($0) }
        conflicts.onChange = { [unowned self] in self.sut.conflictsDidChange($0) }
        sut.onDisplayChange = { [unowned self] in self.displayChanges += 1 }
        if start { sut.start() }
    }

    // MARK: - P3-5: override hosts

    func testOverrideHostsFollowTheSiteHostRules() {
        let host = Rule(id: UUID(), scope: .siteHost(host: "Mail.Google.com."), inputSource: IDs.hebrew,
                        origin: .pinned, updatedAt: Date(timeIntervalSince1970: 1_000))
        var p = Preferences()
        p.rules = [.app(notes, IDs.hebrew), host]
        make(p)
        XCTAssertEqual(monitor.overrideHostsCalls, [["mail.google.com"]], "pushed once at start")
        store.update { $0.rules.append(.app("com.apple.Terminal", IDs.abc)) }
        sut.preferencesDidChange()
        XCTAssertEqual(monitor.overrideHostsCalls.count, 1, "unchanged hosts aren't pushed again")
        store.update { $0.rules.removeAll { if case .siteHost = $0.scope { true } else { false } } }
        sut.preferencesDidChange()
        XCTAssertEqual(monitor.overrideHostsCalls.last, [])
    }

    // MARK: - P3-40 (owner): no undo record, so nothing is dropped on a touch (replaces the P3-35 QA forgetUndo test)

    func testATouchFocusChangePauseOrSecureInputSendNothingToTheConvertController() {
        make(withConvert: true)
        let c = try! XCTUnwrap(convert)
        let requests = c.requests.count
        sut.keySignal(.bufferInvalidated)
        sut.keySignal(.wordBoundary)
        sut.contextDidChange(Context(bundleID: "com.apple.TextEdit", pid: 11, generation: 7))
        sut.setPaused(true)
        sut.setPaused(false)
        var status = KeyWatcherStatus()
        status.secureInputOn = true
        sut.keyWatcherStatusDidChange(status)
        XCTAssertEqual(c.requests.count, requests, "no convert request from any of these")
        XCTAssertEqual(c.anchors, [])
    }

    // MARK: - Start / stop

    func testStartStartsEverythingAndTheTapOnce() {
        make()
        XCTAssertEqual(conflicts.startCount, 1)
        XCTAssertEqual(permissions.startCount, 1)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(watcher.starts, [.active], "one start, never repeated")
        XCTAssertEqual(watcher.configs, [PreferencesMapping.processorConfig(Preferences())])
        XCTAssertTrue(sut.availability.doubleShiftConvert)
        sut.start()
        XCTAssertEqual(watcher.starts, [.active])
    }

    func testStartWithNoGrantsInstallsNoTap() {
        make(accessibility: .notDetermined)
        XCTAssertTrue(watcher.starts.isEmpty)
        XCTAssertEqual(watcher.stops, 0)
        XCTAssertTrue(sut.availability.appSwitching)
        XCTAssertTrue(sut.availability.learningByDwell)
    }

    func testInputMonitoringOnlyStartsListenOnly() {
        make(accessibility: .denied, inputMonitoring: .granted)
        XCTAssertEqual(watcher.starts, [.listenOnly])
        XCTAssertTrue(sut.availability.doubleShiftToggleOnly)
    }

    func testFrontmostAppRuleAppliesAtLaunch() {
        var p = Preferences()
        p.rules = [.app(notes, IDs.hebrew)]
        make(p, start: false)
        monitor.emitOnStart = Context(bundleID: notes, pid: 10, generation: 1)
        sut.start()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testStopStopsEverything() {
        make()
        sut.stop()
        XCTAssertEqual(watcher.stops, 1)
        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertEqual(permissions.stopCount, 1)
        XCTAssertEqual(conflicts.stopCount, 1)
        XCTAssertEqual(sut.policy.achieved, .off)
        sut.stop()
        XCTAssertEqual(watcher.stops, 1)
    }

    // MARK: - Fan-out

    func testContextChangeFansOut() {
        make()
        watcher.clear()
        monitor.activate(notes, pid: 10)
        // P3-37 (b): a context change is a reset that may park a terminal's buffer (Notes: not a terminal).
        XCTAssertEqual(watcher.calls, [.perform(.contextChanged(terminalPID: nil)), .checkSecureInput])
        XCTAssertGreaterThan(displayChanges, 0)
    }

    func testInputSourceChangesFanOut() {
        make()
        watcher.clear()
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        // P2-52 item 7: an `.ours` change that isn't our buffer-keeping after-convert switch resets the buffer too.
        XCTAssertEqual(watcher.calls, [.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false)),
                                       .perform(.inputSourceChanged(to: IDs.abc, isOurs: false))])
        XCTAssertEqual(conflicts.externalSwitches, 1)
    }

    func testRuleSwitchIsOursForTheLearnerButResetsTheBuffer() {
        var p = Preferences()
        p.rules = [.app(notes, IDs.hebrew)]
        make(p)
        monitor.activate(notes, pid: 10)
        sut.inputSourceDidChange(.ours(IDs.hebrew))   // the notification of our own select
        XCTAssertEqual(conflicts.ourSwitches, 1)
        XCTAssertEqual(conflicts.externalSwitches, 0)
        // P2-52 item 7: the strokes before a rule switch were typed in the old layout, so the tap drops them.
        XCTAssertTrue(watcher.calls.contains(.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false))))
        XCTAssertFalse(watcher.calls.contains(.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: true))))
    }

    func testWordBoundariesReachTheLearner() {
        make()
        monitor.activate(notes, pid: 10)
        clock.advance(byMilliseconds: 600)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.first?.scope, .app(bundleID: notes))
    }

    func testConflictsChangeUpdatesTheLearningFlag() {
        make()
        XCTAssertTrue(sut.switching.learner.learningEnabled)
        conflicts.setPerDocument(true)
        XCTAssertFalse(sut.switching.learner.learningEnabled)
        conflicts.setPerDocument(false)
        XCTAssertTrue(sut.switching.learner.learningEnabled)
    }

    // MARK: - Tap mode (§12 W7)

    func testGrantChangeRetriesOnlyWhenItCanHelp() {
        make(accessibility: .notDetermined)
        XCTAssertTrue(watcher.starts.isEmpty)
        permissions.grant(accessibility: .granted)
        XCTAssertEqual(watcher.starts, [.active])
        permissions.grant(accessibility: .granted, inputMonitoring: .granted)
        XCTAssertEqual(watcher.starts, [.active], "already active: no restart")
    }

    func testFailedStartIsRetriedOnTheNextGrantChangeOnly() {
        make(accessibility: .denied, inputMonitoring: .granted, start: false)
        watcher.startAnswer = .off       // Input Monitoring usually needs a relaunch
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .denied,
                                                                             inputMonitoring: .granted),
                                                     inputMonitoringNeedsRelaunch: true)
        sut.start()
        XCTAssertEqual(watcher.starts, [.listenOnly])
        XCTAssertTrue(sut.menuState.showsQuitAndReopen)
        sut.preferencesDidChange()
        sut.keyWatcherStatusDidChange(KeyWatcherStatus())
        XCTAssertEqual(watcher.starts, [.listenOnly], "no retry without a grant change")
        watcher.startAnswer = nil
        permissions.grant(accessibility: .granted, inputMonitoring: .granted)
        XCTAssertEqual(watcher.starts, [.listenOnly, .active])
        XCTAssertFalse(sut.menuState.showsQuitAndReopen)
    }

    func testRevokeStopsTheTap() {
        make()
        permissions.grant(accessibility: .denied)
        XCTAssertEqual(watcher.stops, 1)
        XCTAssertEqual(sut.policy.achieved, .off)
        XCTAssertFalse(sut.availability.doubleShiftConvert)
    }

    func testWatchdogDowngradeIsNotFoughtButShown() {
        make()
        var status = KeyWatcherStatus()
        status.health.mode = .listenOnly
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        XCTAssertEqual(watcher.starts, [.active])
        XCTAssertEqual(sut.menuState.tapMode, .listenOnly)
        XCTAssertTrue(sut.menuState.degradedByWatchdog)
        XCTAssertFalse(sut.availability.doubleShiftConvert)
    }

    func testTurningAllTypingFeaturesOffStopsTheTap() {
        make()
        store.update {
            $0.convert.doubleShiftEnabled = false
            $0.general.learnFromManualSwitches = false
        }
        sut.preferencesDidChange()
        XCTAssertEqual(watcher.stops, 1)
    }

    // MARK: - Secure Input (P2-45) → dwell

    func testSecureInputMakesLearningUseTheDwell() {
        make()
        XCTAssertTrue(sut.switching.learner.keyboardTapAvailable)
        var status = KeyWatcherStatus()
        status.health.mode = .active
        status.secureInputOn = true
        sut.keyWatcherStatusDidChange(status)
        XCTAssertFalse(sut.availability.learningWithWords)
        XCTAssertFalse(sut.switching.learner.keyboardTapAvailable)
        XCTAssertTrue(sut.menuState.secureInputOn)
        XCTAssertEqual(watcher.starts, [.active], "Secure Input never restarts the tap")
    }

    func testDwellTickerRunsOnlyWhileACandidateWaits() {
        make(accessibility: .notDetermined)
        monitor.activate(notes, pid: 10)
        XCTAssertFalse(ticker.isRunning)
        clock.advance(byMilliseconds: 600)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        XCTAssertTrue(ticker.isRunning)
        clock.advance(bySeconds: 4)
        ticker.fire()
        XCTAssertEqual(store.prefs.rules.count, 1)
        XCTAssertFalse(ticker.isRunning)
        XCTAssertEqual(ticker.startCount, 1)
    }

    // MARK: - Preferences → config (P2-50)

    func testConfigIsPushedOnlyWhenItChanges() {
        make()
        watcher.clear()
        store.update { $0.rules = [.app(self.notes, IDs.hebrew)] }
        sut.preferencesDidChange()
        XCTAssertTrue(watcher.configs.isEmpty, "rules don't touch the tap")
        store.update { $0.convert.doubleShiftWindowMs = 450 }
        sut.preferencesDidChange()
        sut.preferencesDidChange()
        XCTAssertEqual(watcher.configs.count, 1)
        XCTAssertEqual(watcher.configs.first?.doubleShift.windowNanos, 450_000_000)
        XCTAssertTrue(watcher.starts.isEmpty, "a config change never restarts the tap")
    }

    func testPreferencesAreObserved() async {
        make()
        watcher.clear()
        store.update { $0.convert.doubleShiftSides = .either }
        for _ in 0..<50 where watcher.configs.isEmpty { await Task.yield() }
        XCTAssertEqual(watcher.configs.map(\.doubleShift.sides), [.either])
        store.update { $0.convert.doubleShiftSides = .leftOnly }
        for _ in 0..<50 where watcher.configs.count < 2 { await Task.yield() }
        XCTAssertEqual(watcher.configs.map(\.doubleShift.sides), [.either, .leftOnly], "observation re-armed")
    }

    func testMethodHintsArePushedToTheConvertController() {
        var p = Preferences()
        p.apps["com.apple.Terminal"] = .init(replacementMethod: .terminal)
        make(p, withConvert: true)
        XCTAssertEqual(convert?.hints.last, ["com.apple.Terminal": .terminal])
        store.update { $0.apps[self.notes] = .init(convertEnabled: false) }
        sut.preferencesDidChange()
        XCTAssertEqual(convert?.hints.last, ["com.apple.Terminal": .terminal, notes: .disabled])
        XCTAssertEqual(convert?.hints.count, 2)
    }

    // MARK: - Double-Shift: every generation is finished

    func testPlaceholderFinishesEveryGenerationAtOnce() {
        make()
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 7))
        sut.keySignal(.wordEnded(snapshot, gen: 8))
        sut.keySignal(.undoCandidate(gen: 9))
        XCTAssertEqual(watcher.finishes, [7, 8, 9])
        XCTAssertEqual(sut.menuState.doubleShiftCount, 1)
    }

    func testDoubleShiftIsHandedToTheConvertControllerWithItsMode() {
        make(withConvert: true)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests, [ConvertRequest(snapshot: snapshot, gen: 1, bundleID: notes, mode: .convert,
                                                          useClipboard: true, processID: 10,
                                                          allowsChromiumAX: true)])   // P3-37, P3-41, P3-42
        XCTAssertTrue(watcher.finishes.isEmpty, "the convert controller finishes it")

        make(accessibility: .denied, inputMonitoring: .granted, withConvert: true)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 2))
        XCTAssertEqual(convert?.requests.map(\.mode), [.toggleOnly])
    }

    func testDoubleShiftIsFinishedWhenItMustNotRun() {
        var p = Preferences()
        p.apps[notes] = .init(convertEnabled: false)
        make(p, withConvert: true)
        sut.keySignal(.doubleShift(snapshot, gen: 1))            // no context yet
        monitor.activate(notes, pid: 10)
        p.apps["com.apple.TextEdit"] = .init(disabled: true)
        store.update { $0.apps = p.apps }
        sut.preferencesDidChange()
        monitor.activate("com.apple.TextEdit", pid: 11)
        sut.keySignal(.doubleShift(snapshot, gen: 2))            // Kytkin disabled for TextEdit
        sut.kytkinDidBecomeActive()
        sut.keySignal(.doubleShift(snapshot, gen: 3))            // typed in Kytkin's own window
        sut.kytkinDidResignActive(frontmostPID: 11)
        sut.setPaused(true)
        sut.keySignal(.doubleShift(snapshot, gen: 4))            // paused (a late signal)
        XCTAssertEqual(watcher.finishes, [1, 2, 3, 4])
        XCTAssertEqual(convert?.requests, [])
    }

    // MARK: - Pause and menu

    func testPauseStopsTheTapAndResumeStartsIt() {
        make()
        sut.setPaused(true)
        XCTAssertEqual(watcher.stops, 1)
        XCTAssertTrue(sut.menuState.paused)
        XCTAssertFalse(sut.availability.appSwitching)
        sut.setPaused(false)
        XCTAssertEqual(watcher.starts, [.active, .active])
        XCTAssertFalse(sut.menuState.paused)
    }

    func testMenuWillOpenRefreshesSilently() {
        make()
        sut.menuWillOpen()
        XCTAssertEqual(conflicts.refreshCount, 1)
        XCTAssertEqual(permissions.refreshCount, 1)
    }

    func testMenuPinAndForget() {
        make()
        monitor.activate(notes, pid: 10)
        switcher.current = IDs.hebrew
        sut.pinCurrent()
        XCTAssertEqual(sut.menuState.currentRule?.resolution.matched?.origin, .pinned)
        XCTAssertEqual(sut.menuState.currentRule?.resolution.target, IDs.hebrew)
        sut.forgetCurrent()
        XCTAssertNil(sut.menuState.currentRule?.resolution.matched)
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    /// P6-0c (visual review N5): the checked "Always Use …" chosen again makes the pin learned.
    func testMenuUnpinMakesThePinLearned() {
        make()
        monitor.activate(notes, pid: 10)
        switcher.current = IDs.hebrew
        sut.pinCurrent()
        sut.unpinCurrent()
        XCTAssertEqual(sut.menuState.currentRule?.resolution.matched?.origin, .learned)
        XCTAssertEqual(store.prefs.rules.count, 1, "the rule stays, only its pin goes")
    }

    /// P6-0c (flows S3; owner: double-Shift only): "Don't Convert in {App}" writes the per-app convert switch.
    func testMenuDontConvertInTheCurrentApp() {
        make()
        monitor.activate(notes, pid: 10)
        XCTAssertFalse(sut.menuState.convertOffInCurrentApp)
        sut.setConvertInCurrentApp(false)
        XCTAssertEqual(store.prefs.apps[notes]?.convertEnabled, false)
        XCTAssertNil(store.prefs.apps[notes]?.disabled, "Kytkin itself stays on in the app")
        XCTAssertTrue(sut.menuState.convertOffInCurrentApp)
        sut.setConvertInCurrentApp(true)
        XCTAssertNil(store.prefs.apps[notes]?.convertEnabled)
        XCTAssertFalse(sut.menuState.convertOffInCurrentApp)
    }

    /// P6-0c (visual review N2): "Turn Kytkin On" from the menu.
    func testMenuTurnOn() {
        make()
        store.update { $0.general.enabled = false }
        XCTAssertFalse(sut.menuState.enabled)
        sut.turnOn()
        XCTAssertTrue(store.prefs.general.enabled)
        XCTAssertTrue(sut.menuState.enabled)
    }

    func testMenuSelectIsOurs() {
        make()
        XCTAssertTrue(sut.selectFromMenu(IDs.hebrew))
        XCTAssertEqual(conflicts.ourSwitches, 1)
    }

    // MARK: - P2-20 QA

    /// P3-37 (b): a terminal in front (seeded, or the user's Settings → Apps choice) is named by its pid, so the tap
    /// parks its buffer on the way out and restores it on the way back.
    func testATerminalContextIsNamedToTheTapByItsPID() {
        make()
        watcher.clear()
        monitor.activate("com.apple.Terminal", pid: 77)
        XCTAssertEqual(watcher.calls.first, .perform(.contextChanged(terminalPID: 77)))
        watcher.clear()
        monitor.activate("com.cmuxterm.app", pid: 78)
        XCTAssertEqual(watcher.calls.first, .perform(.contextChanged(terminalPID: 78)))
        watcher.clear()
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.calls.first, .perform(.contextChanged(terminalPID: nil)))
    }

    func testAnAppTheUserSetToTerminalCountsToo() {
        var p = Preferences()
        p.apps["com.example.MyShell"] = .init(replacementMethod: .terminal)
        make(p)
        watcher.clear()
        monitor.activate("com.example.MyShell", pid: 90)
        XCTAssertEqual(watcher.calls.first, .perform(.contextChanged(terminalPID: 90)))
    }

    /// P3-37 (b): the first key of a terminal buffer asks the convert controller to note the focused element.
    /// (P3-40: it no longer also drops an undo record.)
    func testATerminalBufferStartIsAnchored() {
        make(withConvert: true)
        monitor.activate("com.apple.Terminal", pid: 77)
        sut.keySignal(.terminalBufferStarted(epoch: 3))
        XCTAssertEqual(convert?.anchors, [3])
    }

    func testTheClipboardSettingReachesTheRequest() {
        var p = Preferences()
        p.convert.useClipboardInUnreadableApps = false
        make(p, withConvert: true)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests.first?.useClipboard, false)
    }

    /// P3-37 QA: an installed web app (a Docs / Sheets shim) never uses the clipboard: ⌘A there is the whole document.
    func testAWebAppShimNeverUsesTheClipboard() {
        make(withConvert: true)
        monitor.activate("com.google.Chrome.app.abcdefghijklmnop", pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests.first?.useClipboard, false)
        XCTAssertEqual(convert?.requests.first?.allowsChromiumAX, false, "P3-42: nor the AX piece convert")
    }

    /// P3-42: the Chromium AX convert doesn't depend on the clipboard switch.
    func testTheChromiumAXPathIgnoresTheClipboardSetting() {
        var p = Preferences()
        p.convert.useClipboardInUnreadableApps = false
        make(p, withConvert: true)
        monitor.activate("com.tinyspeck.slackmacgap", pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests.first?.allowsChromiumAX, true)
    }

    /// P3-37 QA: whole-document web apps (Google Docs / Sheets, Office, web IDEs) never use the clipboard.
    func testWholeDocumentSitesBlockTheClipboard() {
        for host in ["docs.google.com", "DOCS.google.com", "colab.research.google.com", "foo.sharepoint.com",
                     "vscode.dev", "x.github.dev"] {
            XCTAssertTrue(ReplacementCapabilities.blocksClipboard(bundleID: "com.google.Chrome", host: host), host)
        }
        for host in ["app.slack.com", "mail.google.com", "github.com", "notdocs.google.com.evil.io", nil] as [String?] {
            XCTAssertFalse(ReplacementCapabilities.blocksClipboard(bundleID: "com.google.Chrome", host: host),
                           host ?? "nil")
        }
    }

    /// Kytkin's own window is not a Context, so the root must reset the word buffer itself: otherwise a word typed in
    /// Settings would still be in the buffer after ⌘Tab back to the same app (no new Context) and a double-Shift there
    /// would replace the wrong text once P2-21 converts.
    func testOwnWindowActivationAndResignResetTheWordBuffer() {
        make()
        monitor.activate(notes, pid: 10)
        watcher.clear()
        sut.kytkinDidBecomeActive()
        XCTAssertEqual(watcher.calls, [.perform(.reset(.contextChange))])
        watcher.clear()
        sut.kytkinDidResignActive(frontmostPID: 10)
        XCTAssertEqual(watcher.calls, [.perform(.reset(.contextChange)), .checkSecureInput])
        XCTAssertTrue(watcher.starts.isEmpty, "never a tap restart")
    }

    /// `start` blocks main up to 1–2 s: a burst of app changes, status reports, menu opens, preference writes and
    /// permission callbacks that don't change what is wanted must never call it again.
    func testNoTapStartOrStopInABurstOfEvents() {
        make()
        var status = KeyWatcherStatus()
        status.health.mode = .active
        for i in 0..<200 {
            monitor.activate(i.isMultiple(of: 2) ? notes : "com.apple.Terminal", pid: Int32(10 + i % 2))
            sut.keyWatcherStatusDidChange(status)
            sut.menuWillOpen()
            sut.preferencesDidChange()
            permissions.grant(accessibility: .granted)   // same grants (the real manager wouldn't even call back)
            sut.keySignal(.wordBoundary)
            sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
            clock.advance(byMilliseconds: 10)
        }
        XCTAssertEqual(watcher.starts, [.active])
        XCTAssertEqual(watcher.stops, 0)
    }

    /// One start per real change of the desired mode (Accessibility revoked with Input Monitoring kept, and back).
    func testEachDesiredModeChangeStartsOnce() {
        make(accessibility: .granted, inputMonitoring: .granted)
        permissions.grant(accessibility: .denied, inputMonitoring: .granted)
        permissions.grant(accessibility: .denied, inputMonitoring: .granted)
        permissions.grant(accessibility: .granted, inputMonitoring: .granted)
        XCTAssertEqual(watcher.starts, [.active, .listenOnly, .active])
        XCTAssertEqual(watcher.stops, 0)
    }

    /// Auto-fix is P4: even with `autoFix.enabled` on in the file it is off end to end (no Space hold-back), and a
    /// `.wordEnded` / `.undoCandidate` that still arrived is finished at once, never handed on.
    func testAutoFixStaysOffEndToEnd() {
        var p = Preferences()
        p.autoFix.enabled = true
        make(p, withConvert: true)
        XCTAssertFalse(AppController.initialProcessorConfig(store).autoFixEnabled)
        XCTAssertFalse(watcher.configs.isEmpty)
        XCTAssertTrue(watcher.configs.allSatisfy { !$0.autoFixEnabled })
        XCTAssertFalse(sut.availability.autoFix)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.wordEnded(snapshot, gen: 3))
        sut.keySignal(.undoCandidate(gen: 4))
        XCTAssertEqual(watcher.finishes, [3, 4])
        XCTAssertEqual(convert?.requests, [])
    }

    /// Pause, per-document input and Kytkin's own window are session state: nothing reaches the preferences.
    func testSessionOnlyStateIsNeverWritten() {
        var p = Preferences()
        p.rules = [.app(notes, IDs.hebrew)]
        make(p)
        let before = store.prefs
        sut.setPaused(true)
        conflicts.setPerDocument(true)
        sut.kytkinDidBecomeActive()
        sut.kytkinDidResignActive(frontmostPID: nil)
        sut.setPaused(false)
        conflicts.setPerDocument(false)
        XCTAssertEqual(store.prefs, before)
    }

    /// A signal that was already queued on main when the app stopped is still finished, and nothing restarts.
    func testSignalAfterStopIsStillFinished() {
        make()
        monitor.activate(notes, pid: 10)
        sut.stop()
        sut.keySignal(.doubleShift(snapshot, gen: 5))
        XCTAssertEqual(watcher.finishes, [5])
        XCTAssertEqual(watcher.starts, [.active])
    }

    /// P2-27 (001 §7 B1): the DEBUG menu's slow-callback count is the tap's own counter, passed through as reported.
    func testSlowCallbackCountFollowsTheTapStatus() {
        make()
        XCTAssertEqual(sut.menuState.slowCallbackCount, 0)
        var status = KeyWatcherStatus()
        status.health.mode = .active
        status.health.overBudgetCallbacks = 3
        sut.keyWatcherStatusDidChange(status)
        XCTAssertEqual(sut.menuState.slowCallbackCount, 3)
    }

    // MARK: - P2-21: convert requests, the after-convert switch, the buffer-keeping distinction (P2-52 item 7)

    func testStartTellsTheTapTheCurrentLayout() {
        make()
        XCTAssertTrue(watcher.calls.contains(.perform(.inputSourceChanged(to: IDs.abc, isOurs: false))))
    }

    func testRequestCarriesThePairTheCurrentSourceAndTheSwitchSetting() {
        var p = Preferences()
        p.languagePair = LanguagePair(a: IDs.abc, b: IDs.russian)
        p.convert.switchLanguageAfterConvert = false
        make(p, withConvert: true)
        switcher.current = IDs.russian
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests, [ConvertRequest(snapshot: snapshot, gen: 1, bundleID: notes, mode: .convert,
                                                          pair: p.languagePair, currentSource: IDs.russian,
                                                          switchAfterConvert: false, useClipboard: true,
                                                          processID: 10, allowsChromiumAX: true)])
    }

    func testConvertOffForTheAppLeavesDoubleShiftAsAToggle() {
        var p = Preferences()
        p.apps[notes] = .init(convertEnabled: false)
        make(p, withConvert: true)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests.map(\.mode), [.toggleOnly])
        XCTAssertTrue(watcher.finishes.isEmpty, "the convert controller finishes it")
    }

    func testSecureInputMakesDoubleShiftAToggle() {
        make(withConvert: true)
        var status = KeyWatcherStatus()
        status.health.mode = .active
        status.secureInputOn = true
        sut.keyWatcherStatusDidChange(status)
        monitor.activate(notes, pid: 10)
        sut.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert?.requests.map(\.mode), [.toggleOnly])
    }

    func testOnlyTheBufferKeepingAfterConvertSwitchKeepsTheBuffer() {
        make()
        watcher.clear()
        XCTAssertTrue(sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: true))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        XCTAssertEqual(switcher.selects.first?.1, .afterConvert)
        XCTAssertEqual(conflicts.ourSwitches, 1)
        sut.inputSourceDidChange(.ours(IDs.hebrew))          // its notification: keep
        sut.inputSourceDidChange(.ours(IDs.hebrew))          // anything after it: reset
        XCTAssertEqual(watcher.calls, [.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: true)),
                                       .perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false))])
    }

    func testAToggleOrSelectionSwitchResetsTheBuffer() {
        make()
        watcher.clear()
        XCTAssertTrue(sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: false))
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        XCTAssertEqual(watcher.calls, [.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false))])
    }

    func testTheKeepExpiresAndNeverAppliesToAnotherSource() {
        make()
        watcher.clear()
        sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: true)
        clock.advance(byMilliseconds: 600)
        sut.inputSourceDidChange(.ours(IDs.hebrew))         // too late
        sut.switchAfterConvert(to: IDs.abc, keepsBuffer: true)
        sut.inputSourceDidChange(.ours(IDs.russian))        // some other ours (a rule) in between
        sut.inputSourceDidChange(.ours(IDs.abc))
        XCTAssertEqual(watcher.calls.compactMap {
            if case .perform(.inputSourceChanged(_, let ours)) = $0 { ours } else { nil }
        }, [false, false, false])
    }

    func testAnExternalChangeCancelsTheKeep() {
        make()
        sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: true)
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        watcher.clear()
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        XCTAssertEqual(watcher.calls, [.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false))])
    }

    func testAfterConvertSwitchWhenAlreadyCurrentFailedOrPaused() {
        make()
        XCTAssertTrue(sut.switchAfterConvert(to: IDs.abc, keepsBuffer: true), "already current: nothing to do")
        XCTAssertTrue(switcher.selects.isEmpty)

        switcher.selectSucceeds = false
        XCTAssertFalse(sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: true))
        watcher.clear()
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        XCTAssertEqual(watcher.calls, [.perform(.inputSourceChanged(to: IDs.hebrew, isOurs: false))])

        switcher.selectSucceeds = true
        sut.setPaused(true)
        let before = switcher.selects.count
        XCTAssertFalse(sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: false), "paused: no switch")
        XCTAssertEqual(switcher.selects.count, before)

        sut.setPaused(false)
        sut.stop()
        XCTAssertFalse(sut.switchAfterConvert(to: IDs.hebrew, keepsBuffer: false), "stopped: no switch")
    }

    // MARK: - P2-22: menu state, restart, display refreshes

    func testMenuStateCarriesGrantsEnabledAndConflicts() {
        make(accessibility: .denied, inputMonitoring: .granted)
        conflicts.conflicts = Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: false)
        var state = sut.menuState
        XCTAssertEqual(state.accessibility, .denied)
        XCTAssertEqual(state.inputMonitoring, .granted)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.conflicts.runningSwitchers, ["FlicKey"])
        XCTAssertEqual(state.store, MenuState.StoreFlags())
        store.update { $0.general.enabled = false }
        sut.preferencesDidChange()
        state = sut.menuState
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(MenuWarning.list(for: state).first, .kytkinOff)
    }

    func testMenuStateCarriesTheStoreFlags() {
        let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
        let fs = InMemoryPreferencesFileSystem()
        fs[url] = Data("{}".utf8)
        fs.failReads = true
        let clock = FakeClock(nowNanos: 1)
        make(store: PreferencesStore(fileURL: url, clock: clock, fileSystem: fs))
        XCTAssertEqual(sut.menuState.store.loadIssue, .unreadable)
        XCTAssertTrue(sut.menuState.store.isReadOnly)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.settingsReadOnly(newerVersion: false)])
    }

    func testRestartKeyboardAfterAWatchdogDowngrade() {
        make()
        XCTAssertFalse(sut.menuState.canRestartKeyboard)
        sut.restartKeyboard()
        XCTAssertEqual(watcher.starts, [.active], "not degraded: nothing to restart")

        var status = KeyWatcherStatus()
        status.health.mode = .listenOnly
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        XCTAssertTrue(sut.menuState.canRestartKeyboard)
        sut.restartKeyboard()
        XCTAssertEqual(watcher.starts, [.active, .active])
        XCTAssertEqual(sut.policy.achieved, .active)
        XCTAssertTrue(sut.availability.doubleShiftConvert)

        // The real KeyWatcher clears the flag on a user-initiated start and reports it.
        var cleared = KeyWatcherStatus()
        cleared.health.mode = .active
        sut.keyWatcherStatusDidChange(cleared)
        XCTAssertFalse(sut.menuState.canRestartKeyboard)
        sut.preferencesDidChange()
        permissions.grant(accessibility: .granted)
        XCTAssertEqual(watcher.starts, [.active, .active], "the restart isn't repeated by later events")
    }

    func testRestartKeyboardDoesNothingWhilePausedOrStopped() {
        make()
        var status = KeyWatcherStatus()
        status.health.mode = .off
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        sut.setPaused(true)
        XCTAssertFalse(sut.menuState.canRestartKeyboard, "paused: nothing wants the keyboard")
        sut.restartKeyboard()
        XCTAssertEqual(watcher.starts, [.active])
        sut.setPaused(false)          // resume starts it anyway
        XCTAssertEqual(watcher.starts, [.active, .active])
        sut.keyWatcherStatusDidChange(status)
        sut.stop()
        watcher.clear()
        sut.restartKeyboard()
        XCTAssertTrue(watcher.starts.isEmpty, "stopped: never")
    }

    func testRestartKeyboardWhenListenOnlyWasLowered() {
        make(accessibility: .denied, inputMonitoring: .granted)
        var status = KeyWatcherStatus()
        status.health.mode = .off
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        sut.restartKeyboard()
        XCTAssertEqual(watcher.starts, [.listenOnly, .listenOnly])
    }

    // MARK: - P2-52 item 2 / P2-57 item 1: the keyboard features are never off silently

    /// Launches with the first `start` timing out (the fake answers `.off`).
    private func makeWithLaunchTimeout(_ prefs: Preferences = Preferences()) {
        make(prefs, start: false)
        watcher.startAnswer = .off
        sut.start()
        XCTAssertEqual(watcher.starts, [.active])
        XCTAssertEqual(sut.policy.achieved, .off)
    }

    func testLaunchTimeoutWarnsAndRetriesOnceOnTheNextActivation() {
        makeWithLaunchTimeout()
        XCTAssertTrue(sut.menuState.keyboardBelowDesired)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardFeaturesOff(canRestart: true)])

        monitor.activate(notes, pid: 10)                     // the one retry; it times out again
        XCTAssertEqual(watcher.starts, [.active, .active])
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardFeaturesOff(canRestart: true)],
                       "still off: the warning stays")

        // No bursts: 200 more events of every kind start nothing.
        for i in 0..<200 {
            switch i % 5 {
            case 0: monitor.activate(i % 2 == 0 ? notes : "com.apple.Safari", pid: Int32(10 + i % 2))
            case 1: sut.keyWatcherStatusDidChange(KeyWatcherStatus())
            case 2: sut.preferencesDidChange()
            case 3: sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
            default: sut.kytkinDidBecomeActive()
            }
        }
        XCTAssertEqual(watcher.starts, [.active, .active], "never more than one automatic retry")
        XCTAssertTrue(sut.menuState.keyboardBelowDesired)
    }

    /// QA: the real monitor reports the frontmost app from inside `start()`, right after the first start timed out.
    /// That report must not fire the retry (two blocking starts back to back at launch); the next real one does.
    func testTheLaunchContextReportDoesNotFireTheRetry() {
        make(start: false)
        monitor.emitOnStart = Context(bundleID: notes, pid: 10, generation: 1)
        watcher.startAnswer = .off
        sut.start()
        XCTAssertEqual(watcher.starts, [.active], "one start at launch, not two back to back")
        XCTAssertTrue(sut.menuState.keyboardBelowDesired)
        monitor.activate("com.apple.Safari", pid: 11)
        XCTAssertEqual(watcher.starts, [.active, .active], "the retry waits for the next real activation")
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.active, .active])
    }

    /// QA: a watchdog downgrade (B4) before the next activation is never fought by the automatic retry.
    func testTheRetryNeverFightsAWatchdogDowngrade() {
        make(start: false)
        watcher.startAnswer = .listenOnly                    // the first start came back below `.active`
        sut.start()
        XCTAssertTrue(sut.policy.launchRetryArmed)
        var status = KeyWatcherStatus()
        status.health.mode = .off
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.active], "no automatic start after a watchdog downgrade")
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardSlowedDown(canRestart: true)])
    }

    /// QA: while only a relaunch can help ("Quit & Reopen"), the retry would block main for nothing.
    func testNoRetryWhileOnlyARelaunchCanHelp() {
        make(accessibility: .denied, inputMonitoring: .granted, start: false)
        watcher.startAnswer = .off
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .denied,
                                                                             inputMonitoring: .granted),
                                                     inputMonitoringNeedsRelaunch: true)
        sut.start()
        XCTAssertTrue(sut.menuState.showsQuitAndReopen)
        XCTAssertTrue(sut.policy.launchRetryArmed)
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.listenOnly], "no retry: Quit & Reopen is the fix")
        XCTAssertEqual(MenuWarning.list(for: sut.menuState).filter {
            if case .keyboardFeaturesOff = $0 { return true } else { return false }
        }, [], "Quit & Reopen takes precedence")
    }

    func testASuccessfulRetryClearsTheWarning() {
        makeWithLaunchTimeout()
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: sut.menuState).look, .attention)
        watcher.startAnswer = nil                            // the system calmed down
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.active, .active])
        XCTAssertEqual(sut.policy.achieved, .active)
        XCTAssertTrue(sut.availability.doubleShiftConvert)
        XCTAssertFalse(sut.menuState.keyboardBelowDesired)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [])
        monitor.activate("com.apple.Safari", pid: 11)
        XCTAssertEqual(watcher.starts, [.active, .active])
    }

    func testAFailedManualRestartKeepsTheWarning() {
        makeWithLaunchTimeout()
        monitor.activate(notes, pid: 10)                     // the automatic retry fails too
        sut.restartKeyboard()                                // a user click; fails again
        XCTAssertEqual(watcher.starts, [.active, .active, .active])
        // The real KeyWatcher clears the watchdog flag on a user-initiated start; the warning must not go with it.
        sut.keyWatcherStatusDidChange(KeyWatcherStatus())
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardFeaturesOff(canRestart: true)])
        watcher.startAnswer = nil
        sut.restartKeyboard()                                // works this time
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [])
        sut.restartKeyboard()
        XCTAssertEqual(watcher.starts.count, 4, "nothing to restart once it runs")
    }

    func testAFailedRestartAfterAWatchdogDowngradeStillWarns() {
        make()
        var status = KeyWatcherStatus()
        status.health.mode = .listenOnly
        status.degradedByWatchdog = true
        sut.keyWatcherStatusDidChange(status)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardSlowedDown(canRestart: true)],
                       "the watchdog keeps its own wording")
        watcher.startAnswer = .off
        sut.restartKeyboard()
        var cleared = KeyWatcherStatus()
        cleared.health.mode = .off                           // the user start cleared the watchdog flag
        sut.keyWatcherStatusDidChange(cleared)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.keyboardFeaturesOff(canRestart: true)])
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.active, .active], "a watchdog downgrade arms no automatic retry")
    }

    func testNoWarningOrRetryWhilePausedOrTurnedOff() {
        makeWithLaunchTimeout()
        sut.setPaused(true)
        XCTAssertFalse(sut.menuState.keyboardBelowDesired)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [])
        let starts = watcher.starts.count
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts.count, starts, "paused: no retry")

        makeWithLaunchTimeout()
        store.update { $0.general.enabled = false }
        sut.preferencesDidChange()
        XCTAssertFalse(sut.menuState.keyboardBelowDesired)
        XCTAssertEqual(MenuWarning.list(for: sut.menuState), [.kytkinOff])
        monitor.activate(notes, pid: 10)
        XCTAssertEqual(watcher.starts, [.active], "turned off: no retry")
    }

    /// P2-52 item 4: key signals never refresh the label (the menu reads everything when it opens).
    func testKeySignalsDoNotRefreshTheDisplay() {
        make()
        monitor.activate(notes, pid: 10)
        displayChanges = 0
        for gen in UInt64(1)...50 {
            sut.keySignal(.wordBoundary)
            sut.keySignal(.bufferInvalidated)
            sut.keySignal(.doubleShift(snapshot, gen: gen))
        }
        XCTAssertEqual(displayChanges, 0)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        XCTAssertEqual(displayChanges, 1, "a language change does")
    }

    func testMenuActionsRefreshTheDisplay() {
        make()
        monitor.activate(notes, pid: 10)
        displayChanges = 0
        sut.pinCurrent()
        XCTAssertGreaterThan(displayChanges, 0)
        displayChanges = 0
        sut.setPaused(true)
        XCTAssertGreaterThan(displayChanges, 0)
    }

    /// P2-22 QA: a debounced save failing (or recovering) changes the menu's warnings and the label's dot, so it
    /// refreshes the display without waiting for the next app switch.
    func testASaveFailureRefreshesTheDisplay() async {
        let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
        let fs = InMemoryPreferencesFileSystem()
        let clock = FakeClock(nowNanos: 1)
        make(store: PreferencesStore(fileURL: url, clock: clock, fileSystem: fs))
        fs.failWrites = true
        store.update { $0.convert.doubleShiftWindowMs = 450 }
        for _ in 0..<50 where watcher.configs.isEmpty { await Task.yield() }
        XCTAssertFalse(watcher.configs.isEmpty, "the preference change was observed")
        for _ in 0..<50 { await Task.yield() }
        displayChanges = 0
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(displayChanges, 0, "settled")
        store.flush()
        XCTAssertTrue(store.lastSaveFailed)
        for _ in 0..<50 where displayChanges == 0 { await Task.yield() }
        XCTAssertGreaterThan(displayChanges, 0, "the failed save refreshed the label")
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: sut.menuState).look, .attention)
    }

    // MARK: - P2-55: learning from manual switches in the live app (status-bar menu activations)

    private var textEdit: String { "com.apple.TextEdit" }

    /// The owner's repro: TextEdit in front, open the Kytkin menu (AppKit posts didBecomeActive, but TextEdit stays
    /// frontmost and no resign follows), close it, ⌃Space, wait, type two words. Before P2-55 the own-window gate stayed
    /// on, so the switch and both words were dropped and nothing was learned.
    func testMenuOpenThatIsNotARealActivationDoesNotBlockLearning() {
        make()
        monitor.activate(textEdit, pid: 20)
        clock.advance(byMilliseconds: 5_000)
        sut.kytkinDidBecomeActive(isFrontmost: false)       // status-bar menu opened; no resign comes
        clock.advance(byMilliseconds: 2_000)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))   // ⌃Space
        clock.advance(byMilliseconds: 1_000)
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: textEdit)])
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew)
        XCTAssertEqual(store.prefs.rules.first?.origin, .learned)
        XCTAssertEqual(sut.menuState.learnerDebug,
                       "Learner: idle (words); last: learned \(textEdit)→\(IDs.hebrew.rawValue)")
    }

    /// QA lead: opening and closing the menu between the switch and the words must not erase the candidate.
    func testMenuOpenAndCloseBetweenTheSwitchAndTheWordsKeepsTheCandidate() {
        make()
        monitor.activate(textEdit, pid: 20)
        clock.advance(byMilliseconds: 1_000)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        watcher.clear()
        sut.kytkinDidBecomeActive(isFrontmost: false)
        sut.kytkinDidResignActive(frontmostPID: 20)        // unpaired: the "activation" above didn't count
        XCTAssertTrue(watcher.calls.isEmpty, "a menu is not Kytkin's window: no buffer reset")
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: textEdit)])
    }

    /// A real activation whose resign never arrives can't block learning for good: the next Context clears it.
    func testANewContextClearsAStuckOwnWindowFlag() {
        make()
        monitor.activate(notes, pid: 10)
        sut.kytkinDidBecomeActive()                        // really frontmost; resign lost
        XCTAssertTrue(sut.switching.isOwnAppActive)
        monitor.activate(textEdit, pid: 20)
        XCTAssertFalse(sut.switching.isOwnAppActive)
        clock.advance(byMilliseconds: 1_000)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: textEdit)])
    }

    /// The real Settings window still cancels and ignores (P2-39), and the DEBUG line says why.
    func testRealOwnWindowStillBlocksLearningAndTheDebugLineSaysSo() {
        make()
        monitor.activate(textEdit, pid: 20)
        clock.advance(byMilliseconds: 1_000)
        sut.kytkinDidBecomeActive(isFrontmost: true)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertTrue(store.prefs.rules.isEmpty)
        XCTAssertEqual(sut.menuState.learnerDebug, "Learner: off while Kytkin is active; "
                       + "last: switch to \(IDs.hebrew.rawValue) ignored (Kytkin active)")
    }

    func testLearnerDebugLineShowsTheCandidateAndWhyLearningIsOff() {
        make()
        monitor.activate(textEdit, pid: 20)
        XCTAssertEqual(sut.menuState.learnerDebug, "Learner: idle (words)")
        clock.advance(byMilliseconds: 1_000)
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        sut.keySignal(.wordBoundary)
        XCTAssertEqual(sut.menuState.learnerDebug, "Learner: candidate \(textEdit)→\(IDs.hebrew.rawValue), 1/2 words")
        conflicts.setPerDocument(true)
        XCTAssertEqual(sut.menuState.learnerDebug, "Learner: off (per-document input)")
        conflicts.setPerDocument(false)
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))       // straight back
        XCTAssertEqual(sut.menuState.learnerDebug, "Learner: idle (words); last: discarded (switchedBack)")
    }
}

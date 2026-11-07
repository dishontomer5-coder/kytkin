// P2-26: Settings → Permissions logic: the rows (status, what each enables, the buttons for notDetermined and denied
// (P2-46), "not needed", "needs a restart"), the request APIs reached only from the click methods, "Quit & Reopen"
// only while TapModePolicy shows it, the 1 s poll while visible (shared with the welcome window), the keyboard mode
// and Secure Input in plain words, and the P2-46 retry reflected in the tab. Fakes only: no TCC, no System Settings.

import XCTest

@MainActor
final class PermissionsSettingsModelTests: XCTestCase {
    private var permissions: RecordingPermissions!
    private var polling: PermissionPollingDemand!
    private var store: PreferencesStore!
    private var state = MenuState()
    private var relaunches = 0
    private var sut: PermissionsSettingsModel!

    override func setUp() async throws {
        permissions = RecordingPermissions()
        polling = PermissionPollingDemand(permissions: permissions)
        store = makeStore(clock: FakeClock())
        state = MenuState()
        relaunches = 0
        sut = PermissionsSettingsModel(permissions: permissions, store: store, polling: polling, appName: "Kytkin Dev",
                                       state: { [unowned self] in self.state },
                                       relaunch: { [unowned self] in self.relaunches += 1 })
    }

    private func set(_ change: (inout MenuState) -> Void) {
        change(&state)
        sut.reload()
    }

    private func row(_ pane: PermissionPane) -> PermissionRow {
        sut.rows.first { $0.pane == pane }!
    }

    // MARK: - Rows

    func testTwoRowsAndNoAutomationYet() {
        XCTAssertEqual(sut.rows.map(\.pane), [.accessibility, .inputMonitoring])
        XCTAssertEqual(sut.rows.map(\.title), ["Accessibility", "Input Monitoring"])
    }

    func testBeforeTheFirstReadRowsSayCheckingWithNoButtons() {
        for r in sut.rows {
            XCTAssertEqual(r.status, .checking)
            XCTAssertEqual(r.statusText, "Checking…")
            XCTAssertFalse(r.showsGrant || r.showsOpenSettings || r.showsQuitAndReopen)
        }
    }

    func testNotAskedYetOffersAllowAndTheSystemSettingsLink() {
        set { $0.accessibility = .notDetermined; $0.inputMonitoring = .notDetermined }
        for r in sut.rows {
            XCTAssertEqual(r.status, .notGranted)
            XCTAssertEqual(r.statusText, "Not allowed")
            XCTAssertTrue(r.showsGrant)
            XCTAssertTrue(r.showsOpenSettings, "P2-46: the link shows for notDetermined too")
            XCTAssertFalse(r.showsQuitAndReopen)
            XCTAssertNotNil(r.withoutIt)
            XCTAssertNil(r.hint)
        }
        XCTAssertEqual(row(.accessibility).grantTitle, "Allow Accessibility…")
        XCTAssertEqual(row(.inputMonitoring).grantTitle, "Allow Input Monitoring…")
    }

    func testDeniedKeepsBothButtonsAndExplainsWhereToTurnItOn() {
        set { $0.accessibility = .denied; $0.inputMonitoring = .denied }
        let ax = row(.accessibility)
        XCTAssertTrue(ax.showsGrant && ax.showsOpenSettings, "P2-46: the link shows for denied")
        XCTAssertTrue(try XCTUnwrap(ax.hint).contains("Privacy & Security → Accessibility, turn on “Kytkin Dev”"))
        XCTAssertTrue(try XCTUnwrap(row(.inputMonitoring).hint).contains("→ Input Monitoring"))
    }

    func testEachRowSaysWhatItEnablesAndWhatIsLost() {
        set { $0.accessibility = .notDetermined; $0.inputMonitoring = .notDetermined }
        XCTAssertTrue(row(.accessibility).enables.contains("fix text"))
        XCTAssertTrue(try XCTUnwrap(row(.accessibility).withoutIt).contains("can't fix text"))
        XCTAssertTrue(try XCTUnwrap(row(.accessibility).withoutIt).contains("with Input Monitoring"),
                      "QA: with neither permission Shift twice does nothing, so the toggle is conditional")
        XCTAssertTrue(row(.inputMonitoring).enables.contains("never saved"))
        XCTAssertTrue(try XCTUnwrap(row(.inputMonitoring).withoutIt).contains("does nothing"))
    }

    func testAccessibilityGrantedMakesInputMonitoringNotNeeded() {
        set { $0.accessibility = .granted; $0.inputMonitoring = .notDetermined; $0.tapMode = .active }
        let ax = row(.accessibility)
        XCTAssertEqual(ax.status, .granted)
        XCTAssertEqual(ax.statusText, "Allowed")
        XCTAssertNil(ax.withoutIt)
        XCTAssertFalse(ax.showsGrant || ax.showsOpenSettings)
        let im = row(.inputMonitoring)
        XCTAssertEqual(im.status, .notNeeded)
        XCTAssertFalse(im.showsGrant || im.showsOpenSettings || im.showsQuitAndReopen,
                       "no second permission asked for nothing")
    }

    /// P2-64 (replaces P2-26 QA's "only once the tap runs"): P1-17 is answered, Accessibility alone gives listen
    /// access on macOS 26, so Input Monitoring is never offered while Accessibility is allowed, whatever the tap does.
    func testInputMonitoringIsNotNeededWhileAccessibilityIsAllowedWhateverTheTapDoes() {
        for mode in [TapMode.off, .listenOnly, .active] {
            set { $0.accessibility = .granted; $0.inputMonitoring = .notDetermined; $0.tapMode = mode }
            let im = row(.inputMonitoring)
            XCTAssertEqual(im.status, .notNeeded, "\(mode)")
            XCTAssertEqual(im.statusText, "Not needed (Accessibility covers it)")
            XCTAssertFalse(im.showsGrant || im.showsOpenSettings || im.showsQuitAndReopen, "\(mode)")
        }
    }

    /// P2-64 (owner, macOS 26): with only Accessibility granted, `CGPreflightListenEventAccess()` reads true although
    /// Kytkin isn't in the Input Monitoring list. The row must not say "Allowed" (or ask for a restart).
    func testAPreflightThatReadsTrueBecauseOfAccessibilityStillSaysNotNeeded() {
        set { $0.accessibility = .granted; $0.inputMonitoring = .granted; $0.tapMode = .active }
        XCTAssertEqual(row(.inputMonitoring).status, .notNeeded)
        XCTAssertEqual(row(.inputMonitoring).statusText, "Not needed (Accessibility covers it)")

        set { $0.showsQuitAndReopen = true }   // even a stale hint can't bring the button back
        XCTAssertEqual(row(.inputMonitoring).status, .notNeeded)
        XCTAssertFalse(row(.inputMonitoring).showsQuitAndReopen)

        set { $0.accessibility = .denied; $0.showsQuitAndReopen = false }
        XCTAssertEqual(row(.inputMonitoring).status, .granted, "without Accessibility the real value shows again")
    }

    func testInputMonitoringNotNeededWhenNoTypingFeatureWantsATap() {
        set { $0.accessibility = .granted; $0.inputMonitoring = .notDetermined; $0.tapMode = .off; $0.enabled = false }
        store.update { $0.general.enabled = false }
        XCTAssertEqual(sut.desiredTapMode, .off)
        XCTAssertEqual(row(.inputMonitoring).status, .notNeeded)
    }

    func testAWatchdogSlowDownDoesNotBringTheInputMonitoringRowBack() {
        set { $0.accessibility = .granted; $0.inputMonitoring = .notDetermined; $0.tapMode = .listenOnly
              $0.degradedByWatchdog = true }
        XCTAssertEqual(row(.inputMonitoring).status, .notNeeded)
    }

    func testInputMonitoringNeedsARestartOnlyWhileThePolicySaysSo() {
        set { $0.accessibility = .denied; $0.inputMonitoring = .granted; $0.showsQuitAndReopen = true }
        let im = row(.inputMonitoring)
        XCTAssertEqual(im.status, .needsRelaunch)
        XCTAssertTrue(im.showsQuitAndReopen)
        XCTAssertFalse(im.showsGrant || im.showsOpenSettings)
        XCTAssertEqual(im.statusText, "Allowed, needs a restart of Kytkin")
        XCTAssertFalse(row(.accessibility).showsQuitAndReopen)

        set { $0.showsQuitAndReopen = false }
        XCTAssertEqual(row(.inputMonitoring).status, .granted)
        XCTAssertFalse(row(.inputMonitoring).showsQuitAndReopen)
    }

    // MARK: - The request APIs only from a click

    func testReadingAndShowingNeverPrompt() {
        set { $0.accessibility = .notDetermined; $0.inputMonitoring = .denied }
        sut.setVisible(true)
        sut.reload()
        _ = sut.rows
        _ = sut.keyboardModeText
        _ = sut.secureInputText
        sut.checkAgain()
        sut.setVisible(false)
        XCTAssertEqual(permissions.promptingCalls, [])
        XCTAssertEqual(relaunches, 0)
    }

    func testEachButtonCallsExactlyItsAPI() {
        sut.grant(.accessibility)
        XCTAssertEqual(permissions.promptingCalls, [.requestAccessibility])
        sut.grant(.inputMonitoring)
        XCTAssertEqual(permissions.promptingCalls, [.requestAccessibility, .requestInputMonitoring])
        sut.openSystemSettings(.accessibility)
        sut.openSystemSettings(.inputMonitoring)
        XCTAssertEqual(permissions.promptingCalls, [.requestAccessibility, .requestInputMonitoring,
                                                    .openSystemSettings(.accessibility),
                                                    .openSystemSettings(.inputMonitoring)])
        XCTAssertEqual(relaunches, 0)
    }

    func testCheckAgainIsASilentRead() {
        sut.checkAgain()
        XCTAssertEqual(permissions.calls, [.refresh])
    }

    func testQuitAndReopenOnlyWhileTheHintShows() {
        sut.quitAndReopen()
        XCTAssertEqual(relaunches, 0, "a stale click can't quit the app")
        state.showsQuitAndReopen = true   // not reloaded yet: quitAndReopen reads fresh
        sut.quitAndReopen()
        XCTAssertEqual(relaunches, 1)
    }

    // MARK: - 1 s poll while visible

    func testVisibleTurnsTheFastPollOnAndOffOnce() {
        sut.setVisible(true)
        sut.setVisible(true)
        sut.setVisible(false)
        sut.setVisible(false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false])
    }

    func testTheTabAndTheWelcomeWindowShareThePoll() {
        polling.set(.onboarding, visible: true)
        sut.setVisible(true)
        sut.setVisible(false)
        XCTAssertEqual(permissions.interactiveCalls, [true], "still fast while the welcome window shows")
        polling.set(.onboarding, visible: false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false])
        XCTAssertFalse(polling.isInteractive)
    }

    // MARK: - Keyboard mode and Secure Input

    func testKeyboardModeInPlainWords() {
        func text(_ change: (inout MenuState) -> Void, desired: TapMode) -> String {
            var s = MenuState()
            change(&s)
            return PermissionsSettingsModel.keyboardModeText(state: s, desired: desired)
        }
        XCTAssertTrue(text({ $0.enabled = false }, desired: .off).hasPrefix("Kytkin is turned off"))
        XCTAssertTrue(text({ $0.paused = true }, desired: .off).hasPrefix("Kytkin is paused"))
        XCTAssertEqual(text({ $0.tapMode = .active }, desired: .active),
                       "Full: pressing Shift twice fixes text and switches the language.")
        XCTAssertEqual(text({ $0.tapMode = .listenOnly }, desired: .listenOnly),
                       "Limited: pressing Shift twice switches the language but can't fix text.")
        XCTAssertTrue(text({ $0.accessibility = .notDetermined }, desired: .off).hasPrefix("Off: allow Accessibility"))
        XCTAssertTrue(text({ $0.accessibility = .granted }, desired: .off).hasPrefix("Not in use"))
        XCTAssertTrue(text({ $0.accessibility = .granted }, desired: .active)
            .hasPrefix("Off: Kytkin couldn't start watching the keyboard yet."))
        XCTAssertTrue(text({ $0.tapMode = .listenOnly; $0.showsQuitAndReopen = true }, desired: .active)
            .hasSuffix("Quit & Reopen Kytkin to use everything you allowed."))
        XCTAssertTrue(text({ $0.tapMode = .listenOnly; $0.degradedByWatchdog = true }, desired: .active)
            .contains("Restart Keyboard Features"))
        XCTAssertTrue(text({ $0.tapMode = .listenOnly }, desired: .active).contains("try the full mode again"))
    }

    func testDesiredModeFollowsTheSettings() {
        set { $0.accessibility = .granted }
        XCTAssertEqual(sut.desiredTapMode, .active)
        store.update {
            $0.convert.doubleShiftEnabled = false
            $0.general.learnFromManualSwitches = false
        }
        XCTAssertEqual(sut.desiredTapMode, .off)
        XCTAssertTrue(sut.keyboardModeText.hasPrefix("Not in use"))
    }

    func testSecureInputIsDisplayOnlyFromKeyWatcher() {
        set { $0.tapMode = .active; $0.secureInputOn = true }
        XCTAssertTrue(sut.secureInputText.hasPrefix("On: another app is protecting your typing"))
        set { $0.secureInputOn = false }
        XCTAssertTrue(sut.secureInputText.hasPrefix("Off: no app"))
        set { $0.tapMode = .off }
        XCTAssertEqual(sut.secureInputText, "Kytkin checks this only while it watches the keyboard.")
        XCTAssertEqual(permissions.promptingCalls, [])
    }

    func testConflictLines() {
        XCTAssertEqual(sut.conflictLines, [])
        set { $0.conflicts = Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: true) }
        XCTAssertEqual(sut.conflictLines.count, 2)
        XCTAssertTrue(sut.conflictLines[0].hasPrefix("FlicKey also switches keyboard languages"))
        XCTAssertTrue(sut.conflictLines[1].contains("Automatically switch to a document's input source"))
    }

    // MARK: - P2-46: the retry after a grant shows in the tab

    func testAGrantRetriesTheTapAndTheTabFollows() {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        let fake = FakePermissions()   // preconditionFailure on any prompt
        fake.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .notDetermined,
                                                                      inputMonitoring: .notDetermined))
        let watcher = FakeKeyWatcher()
        let appStore = makeStore(clock: clock)
        let controller = AppController(switcher: FakeSwitcher(), context: FakeContextMonitor(), store: appStore,
                                       permissions: fake, conflicts: FakeConflicts(), keyWatcher: watcher,
                                       ticker: FakeTicker(), clock: clock)
        let tab = PermissionsSettingsModel(permissions: fake, store: appStore,
                                           polling: PermissionPollingDemand(permissions: fake), appName: "Kytkin",
                                           state: { controller.menuState }, relaunch: { XCTFail("no relaunch") })
        controller.onDisplayChange = { tab.reload() }   // the root's fan-out
        fake.onChange = { controller.permissionsDidChange($0) }
        controller.start()
        XCTAssertEqual(watcher.starts, [])
        XCTAssertEqual(tab.rows.first?.status, .notGranted)
        XCTAssertTrue(tab.keyboardModeText.hasPrefix("Off: allow Accessibility"))

        fake.grant(accessibility: .granted)
        XCTAssertEqual(watcher.starts, [.active], "the retry happens in AppController (TapModePolicy)")
        XCTAssertEqual(tab.rows.first?.status, .granted)
        XCTAssertEqual(tab.rows.last?.status, .notNeeded)
        XCTAssertEqual(tab.keyboardModeText, "Full: pressing Shift twice fixes text and switches the language.")
    }

    func testAnInputMonitoringGrantThatNeedsARelaunchShowsQuitAndReopen() {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        let fake = FakePermissions()
        fake.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .denied,
                                                                      inputMonitoring: .granted),
                                              inputMonitoringNeedsRelaunch: true)
        let watcher = FakeKeyWatcher()
        watcher.startAnswer = .off   // the listen-only tap fails until a relaunch
        let appStore = makeStore(clock: clock)
        let controller = AppController(switcher: FakeSwitcher(), context: FakeContextMonitor(), store: appStore,
                                       permissions: fake, conflicts: FakeConflicts(), keyWatcher: watcher,
                                       ticker: FakeTicker(), clock: clock)
        var relaunched = 0
        let tab = PermissionsSettingsModel(permissions: fake, store: appStore,
                                           polling: PermissionPollingDemand(permissions: fake), appName: "Kytkin",
                                           state: { controller.menuState }, relaunch: { relaunched += 1 })
        controller.onDisplayChange = { tab.reload() }
        fake.onChange = { controller.permissionsDidChange($0) }
        controller.start()
        XCTAssertEqual(watcher.starts, [.listenOnly])
        let im = tab.rows[1]
        XCTAssertEqual(im.status, .needsRelaunch)
        XCTAssertTrue(im.showsQuitAndReopen)
        XCTAssertTrue(tab.keyboardModeText.hasSuffix("Quit & Reopen Kytkin to use everything you allowed."))
        tab.quitAndReopen()
        XCTAssertEqual(relaunched, 1)
    }
}

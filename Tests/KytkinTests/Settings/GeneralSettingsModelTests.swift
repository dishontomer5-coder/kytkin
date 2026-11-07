// P2-23: Settings → General logic: the three preferences controls write the store, read-only mode blocks them,
// the "no rule" picker's options, the notices, and launch at login (register/unregister only on the toggle, status
// read fresh, approval hint, errors).

import XCTest

@MainActor
final class GeneralSettingsModelTests: XCTestCase {
    private var clock: FakeClock!
    private var store: PreferencesStore!
    private var login: FakeLoginItems!
    private var sources: [InputSourceInfo] = []
    private var sourceReads = 0
    private var sut: GeneralSettingsModel!

    private func info(_ id: InputSourceID, _ name: String, enabled: Bool = true) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: "", isEnabled: enabled, isConvertible: true,
                        isInputMethod: false)
    }

    private func make(_ prefs: Preferences = Preferences(), store custom: PreferencesStore? = nil) {
        clock = FakeClock()
        store = custom ?? makeStore(prefs, clock: clock)
        login = FakeLoginItems()
        sources = [info(IDs.abc, "ABC"), info(IDs.hebrew, "Hebrew")]
        sut = GeneralSettingsModel(store: store, loginItems: login, sources: { [unowned self] in
            self.sourceReads += 1
            return self.sources
        })
    }

    private func readOnlyStore() throws -> PreferencesStore {
        let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
        let fs = InMemoryPreferencesFileSystem(files: [url: try Fixtures.data("preferences/v1-future-version.json")])
        return PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: fs)
    }

    // MARK: - Nothing happens at creation

    func testCreatingTheModelCallsNothing() {
        make()
        XCTAssertTrue(login.calls.isEmpty, "no status read, never a register at startup")
        XCTAssertEqual(sourceReads, 0)
        XCTAssertNil(sut.loginItemStatus)
        XCTAssertFalse(sut.launchAtLogin)
    }

    func testRefreshReadsStatusAndSourcesButNeverRegisters() {
        make()
        login.current = .enabled
        sut.refresh()
        XCTAssertEqual(login.calls, [.status])
        XCTAssertEqual(sourceReads, 1)
        XCTAssertTrue(sut.launchAtLogin)
        login.current = .notRegistered          // the user turned it off in System Settings
        sut.refresh()
        XCTAssertFalse(sut.launchAtLogin, "never cached across opens")
        XCTAssertTrue(login.actions.isEmpty)
    }

    // MARK: - Preferences controls

    func testEnabledWritesTheStore() {
        make()
        XCTAssertTrue(sut.enabled)
        sut.enabled = false
        XCTAssertFalse(store.prefs.general.enabled)
        XCTAssertFalse(sut.enabled)
        sut.enabled = true
        XCTAssertTrue(store.prefs.general.enabled)
    }

    func testLearnFromManualSwitchesWritesTheStore() {
        make()
        XCTAssertTrue(sut.learnFromManualSwitches)
        sut.learnFromManualSwitches = false
        XCTAssertFalse(store.prefs.general.learnFromManualSwitches)
    }

    func testDefaultBehaviorPickerRoundTrips() {
        make()
        sut.refresh()
        XCTAssertEqual(sut.defaultBehaviorID, DefaultBehaviorOption.keepCurrentID)
        XCTAssertEqual(sut.defaultBehaviorOptions.map(\.title),
                       ["Leave the language as it is", "Switch to ABC", "Switch to Hebrew"])
        sut.defaultBehaviorID = "switchTo:" + IDs.hebrew.rawValue
        XCTAssertEqual(store.prefs.general.defaultBehavior, .switchTo(IDs.hebrew))
        XCTAssertEqual(sut.defaultBehaviorID, "switchTo:" + IDs.hebrew.rawValue)
        sut.defaultBehaviorID = DefaultBehaviorOption.keepCurrentID
        XCTAssertEqual(store.prefs.general.defaultBehavior, .keepCurrent)
    }

    func testUnknownPickerIDIsIgnored() {
        make()
        sut.refresh()
        sut.defaultBehaviorID = "switchTo:com.example.Nope"
        XCTAssertEqual(store.prefs.general.defaultBehavior, .keepCurrent)
        XCTAssertEqual(store.prefs, Preferences())
    }

    func testReadOnlyBlocksEveryPreferenceButNotLaunchAtLogin() throws {
        make(store: try readOnlyStore())
        sut.refresh()
        let before = store.prefs
        XCTAssertFalse(sut.isEditable)
        sut.enabled.toggle()
        sut.learnFromManualSwitches.toggle()
        sut.defaultBehaviorID = "switchTo:" + IDs.abc.rawValue
        XCTAssertEqual(store.prefs, before, "nothing changes, not even in memory")
        XCTAssertEqual(sut.notices.first?.kind, .readOnly)
        XCTAssertTrue(sut.notices[0].message.contains("newer version"))
        sut.setLaunchAtLogin(true)
        XCTAssertEqual(login.actions, [.register], "not stored in the preferences file")
    }

    func testCleanStoreHasNoNotices() {
        make()
        XCTAssertTrue(sut.notices.isEmpty)
        XCTAssertTrue(sut.isEditable)
    }

    // MARK: - Launch at login

    func testToggleOnRegistersOnceAndOffUnregistersOnce() {
        make()
        sut.refresh()
        sut.setLaunchAtLogin(true)
        XCTAssertEqual(login.actions, [.register])
        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertEqual(sut.loginItemStatus, .enabled)
        XCTAssertNil(sut.loginItemHint)
        sut.setLaunchAtLogin(false)
        XCTAssertEqual(login.actions, [.register, .unregister])
        XCTAssertFalse(sut.launchAtLogin)
        XCTAssertNil(sut.loginItemError)
    }

    func testToggleToTheStateItIsAlreadyInDoesNothing() {
        make()
        login.current = .enabled
        sut.setLaunchAtLogin(true)
        XCTAssertTrue(login.actions.isEmpty)
        XCTAssertTrue(sut.launchAtLogin, "the status was re-read")
        login.current = .notFound
        sut.setLaunchAtLogin(false)
        XCTAssertTrue(login.actions.isEmpty, "notFound counts as off: no unregister")
    }

    func testRequiresApprovalShowsTheHintAndTheButton() {
        make()
        login.statusAfterRegister = .requiresApproval
        sut.setLaunchAtLogin(true)
        XCTAssertTrue(sut.launchAtLogin, "on while waiting for approval")
        XCTAssertEqual(sut.loginItemStatus, .requiresApproval)
        XCTAssertNotNil(sut.loginItemHint)
        XCTAssertTrue(sut.loginItemHint?.contains("System Settings → General → Login Items") ?? false)
        XCTAssertTrue(sut.showsOpenLoginItems)
        XCTAssertNil(sut.loginItemError)
        XCTAssertEqual(login.actions, [.register], "System Settings opens only on the button")
        sut.openLoginItems()
        XCTAssertEqual(login.actions, [.register, .openSystemSettings])
    }

    func testRegisterThrowingWhileApprovalIsPendingIsNotAnError() {
        make()
        login.statusAfterRegister = .requiresApproval
        login.registerError = FakeLoginItems.Failure()
        sut.setLaunchAtLogin(true)
        XCTAssertNil(sut.loginItemError)
        XCTAssertNotNil(sut.loginItemHint)
    }

    func testRegisterFailureIsShownAndTheSwitchStaysOff() {
        make()
        login.registerError = FakeLoginItems.Failure()
        sut.setLaunchAtLogin(true)
        XCTAssertFalse(sut.launchAtLogin)
        XCTAssertEqual(sut.loginItemError, "Couldn't turn on Open at Login.")
        sut.refresh()
        XCTAssertNil(sut.loginItemError, "cleared when Settings opens again")
    }

    func testUnregisterFailureIsShownAndTheSwitchStaysOn() {
        make()
        login.current = .enabled
        login.unregisterError = FakeLoginItems.Failure()
        sut.setLaunchAtLogin(false)
        XCTAssertTrue(sut.launchAtLogin)
        XCTAssertEqual(sut.loginItemError, "Couldn't turn off Open at Login.")
    }

    func testNoHintWhenEnabledOrOff() {
        make()
        for status in [LoginItemStatus.enabled, .notRegistered, .notFound] {
            login.current = status
            sut.refresh()
            XCTAssertNil(sut.loginItemHint)
            XCTAssertFalse(sut.showsOpenLoginItems)
        }
    }
}

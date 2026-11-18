// P4-3: "Keep Kytkin up to date" over a fake updater (no Sparkle, no network in tests): off until the user ticks it,
// the opt-in → updater configuration mapping, the v1.0.0 setting migration, the menu line, setup screen 3.

import XCTest

@MainActor final class FakeUpdater: SoftwareUpdating {
    var isAvailable = true
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onNotice: (@MainActor (String?) -> Void)?
    private(set) var applied: [UpdaterConfiguration] = []
    private(set) var checks = 0

    func apply(_ configuration: UpdaterConfiguration) { applied.append(configuration) }
    func checkForUpdates() { checks += 1 }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private var store: PreferencesStore!
    private var updater: FakeUpdater!
    private var sut: UpdateController!

    override func setUp() async throws {
        store = makeStore(clock: FakeClock())
        updater = FakeUpdater()
        sut = UpdateController(store: store, updater: updater, appVersion: "1.1.0")
    }

    // MARK: - Opt-in → configuration (pure)

    func testOffMapsToNoCheckAndNothingAutomatic() {
        let off = UpdaterConfiguration.forUser(keepUpToDate: false, appVersion: "1.1.0")
        XCTAssertFalse(off.automaticallyChecks)
        XCTAssertFalse(off.automaticallyDownloads)
        XCTAssertFalse(off.sendsSystemProfile)
    }

    func testOnMapsToADailyCheckButNeverAnAutomaticDownload() {
        let on = UpdaterConfiguration.forUser(keepUpToDate: true, appVersion: "1.1.0")
        XCTAssertTrue(on.automaticallyChecks)
        XCTAssertFalse(on.automaticallyDownloads, "install only on the user's click")
        XCTAssertFalse(on.sendsSystemProfile, "nothing about the user is sent")
        XCTAssertEqual(on.checkInterval, 86_400)
        XCTAssertEqual(on.userAgent, "Kytkin/1.1.0")
        XCTAssertEqual(on.httpHeaders, ["Accept-Language": "en"], "not the Mac's preferred languages")
    }

    // MARK: - The switch

    func testOffUntilTheUserTicksIt() {
        XCTAssertFalse(Preferences().general.keepUpToDate)
        sut.start()
        XCTAssertEqual(updater.applied, [.forUser(keepUpToDate: false, appVersion: "1.1.0")])
        sut.checkNow()
        sut.showUpdate()
        XCTAssertEqual(updater.checks, 0, "no check of any kind while off")
        XCTAssertFalse(sut.canCheckNow)
    }

    func testTurningOnSavesAndAppliesTheDailyCheck() {
        sut.start()
        sut.setOn(true)
        XCTAssertTrue(store.prefs.general.keepUpToDate)
        XCTAssertEqual(updater.applied.last, .forUser(keepUpToDate: true, appVersion: "1.1.0"))
        sut.checkNow()
        XCTAssertEqual(updater.checks, 1)
        sut.setOn(false)
        XCTAssertFalse(store.prefs.general.keepUpToDate)
        XCTAssertEqual(updater.applied.last?.automaticallyChecks, false)
    }

    func testLaunchAppliesTheSavedChoice() {
        store.update { $0.general.keepUpToDate = true }
        sut.start()
        XCTAssertEqual(updater.applied, [.forUser(keepUpToDate: true, appVersion: "1.1.0")])
    }

    func testReadOnlyPreferencesKeepTheSwitchAsItIs() {
        let readOnly = makeReadOnlyStore(Preferences())
        XCTAssertTrue(readOnly.isReadOnly)
        let controller = UpdateController(store: readOnly, updater: updater, appVersion: "1.1.0")
        controller.setOn(true)
        XCTAssertFalse(controller.isOn)
        XCTAssertTrue(updater.applied.isEmpty)
    }

    // MARK: - The menu line

    func testAQuietCheckBecomesOneMenuLineThatOpensTheUpdaterWindow() {
        store.update { $0.general.keepUpToDate = true }
        var changes = 0
        sut.onChange = { changes += 1 }
        updater.onNotice?("1.2.0")
        XCTAssertEqual(sut.notice, UpdateNotice(version: "1.2.0"))
        XCTAssertEqual(changes, 1)

        var state = MenuState()
        state.updateNotice = sut.notice
        XCTAssertTrue(MenuModel.items(state: state, currentSource: nil, settingsAvailable: true, includeDebug: false,
                                       sourceName: { $0.rawValue }, appName: { $0 })
            .contains(.action("Update available: Kytkin 1.2.0…", .showUpdate)))

        sut.showUpdate()
        XCTAssertEqual(updater.checks, 1, "the click opens the updater's window")
        updater.onNotice?(nil)
        XCTAssertNil(sut.notice)
        XCTAssertEqual(changes, 2)
    }

    func testTurningOffHidesTheLine() {
        store.update { $0.general.keepUpToDate = true }
        updater.onNotice?("1.2.0")
        var changes = 0
        sut.onChange = { changes += 1 }
        sut.setOn(false)
        XCTAssertNil(sut.notice)
        XCTAssertEqual(changes, 1, "the menu refreshes and drops the line")
        sut.showUpdate()
        XCTAssertEqual(updater.checks, 0, "no window, no network while off")
        XCTAssertNotEqual(sut.statusText, "Kytkin 1.2.0 is available.")
    }

    // P4-4 (QA's P4-3 item): Sparkle's gentle-reminder session stays open while the switch is off, so it never reports
    // the version again; the line must come back from the controller itself, without a new check.
    func testTurningOffAndOnAgainBringsTheLineBack() {
        store.update { $0.general.keepUpToDate = true }
        updater.onNotice?("1.2.0")
        var changes = 0
        sut.onChange = { changes += 1 }
        sut.setOn(false)
        sut.setOn(true)
        XCTAssertEqual(sut.notice, UpdateNotice(version: "1.2.0"))
        XCTAssertEqual(changes, 2, "the menu refreshes on both flips")
        XCTAssertEqual(updater.checks, 0, "no new check: the found update is shown again")
        XCTAssertEqual(sut.statusText, "Kytkin 1.2.0 is available.")
        sut.showUpdate()
        XCTAssertEqual(updater.checks, 1, "the click opens the updater's window for it")
    }

    func testASessionEndedWhileOffIsNotShownAgain() {
        store.update { $0.general.keepUpToDate = true }
        updater.onNotice?("1.2.0")
        sut.setOn(false)
        updater.onNotice?(nil)
        sut.setOn(true)
        XCTAssertNil(sut.notice, "Sparkle dropped it, so the line stays away")
    }

    func testFlippingWithNothingFoundDoesNotRefreshTheMenu() {
        var changes = 0
        sut.onChange = { changes += 1 }
        sut.setOn(true)
        sut.setOn(false)
        XCTAssertEqual(changes, 0)
    }

    // MARK: - Builds that can't update

    func testUnavailableUpdaterKeepsTheChoiceButNeverChecks() {
        let controller = UpdateController(store: store, updater: UnavailableUpdater(), appVersion: "1.1.0")
        controller.setOn(true)
        XCTAssertTrue(controller.isOn, "the choice is kept for the released app")
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckNow)
        XCTAssertEqual(controller.statusText, "Updates work only in the Kytkin you download from GitHub.")
    }

    func testStatusText() {
        store.update { $0.general.keepUpToDate = true }
        XCTAssertEqual(sut.statusText, "Not checked yet.")
        updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(sut.statusText.hasPrefix("Last checked "))
        updater.onNotice?("1.2.0")
        XCTAssertEqual(sut.statusText, "Kytkin 1.2.0 is available.")
    }

    // MARK: - Migration of v1.0.0's setting

    private func general(_ json: String) throws -> Preferences.General {
        try PreferencesCodec.decodeDetailed(Data(json.utf8)).prefs.general
    }

    func testV1OptInCarriesOver() throws {
        XCTAssertTrue(try general(#"{"schemaVersion":2,"general":{"updateCheckOptedIn":true}}"#).keepUpToDate)
        XCTAssertFalse(try general(#"{"schemaVersion":2,"general":{"updateCheckOptedIn":false}}"#).keepUpToDate)
        XCTAssertFalse(try general(#"{"schemaVersion":2,"general":{}}"#).keepUpToDate)
    }

    func testTheNewKeyWinsOverTheOldOne() throws {
        let json = #"{"schemaVersion":2,"general":{"updateCheckOptedIn":true,"keepUpToDate":false}}"#
        XCTAssertFalse(try general(json).keepUpToDate)
    }

    func testOnlyTheNewKeyIsWritten() throws {
        var p = try PreferencesCodec.decodeDetailed(
            Data(#"{"schemaVersion":2,"general":{"updateCheckOptedIn":true,"lastUpdateCheck":0}}"#.utf8)).prefs
        XCTAssertTrue(p.general.keepUpToDate)
        p.general.enabled = true
        let data = try PreferencesCodec.encode(p, schemaVersion: Preferences.currentSchemaVersion)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let general = try XCTUnwrap(obj["general"] as? [String: Any])
        XCTAssertEqual(general["keepUpToDate"] as? Bool, true)
        XCTAssertNil(general["updateCheckOptedIn"])
        XCTAssertNil(general["lastUpdateCheck"])
    }

    // MARK: - Setup screen 3

    func testTheSetupBoxIsUncheckedAndAppliedOnDone() {
        let general = GeneralSettingsModel(store: store, loginItems: FakeLoginItems(), sources: { [] }, updates: sut)
        let permissions = RecordingPermissions()
        let fs = InMemoryLayoutFileSystem()
        let imported = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                           fileSystem: fs)
        let languages = LanguagesSettingsModel(store: store, imported: imported,
                                               catalog: LayoutMapCatalog(system: FakeSystemLayouts.standard(),
                                                                         imported: imported),
                                               fileSystem: fs, inputMethods: { [] })
        let setup = OnboardingModel(store: store, permissions: permissions,
                                    polling: PermissionPollingDemand(permissions: permissions), general: general,
                                    languages: languages, appName: "Kytkin Dev", updates: sut)
        setup.begin(firstLaunch: true)
        XCTAssertFalse(setup.keepUpToDate, "never ticked for the user")
        setup.done()
        XCTAssertFalse(store.prefs.general.keepUpToDate)
        setup.keepUpToDate = true
        setup.done()
        XCTAssertTrue(store.prefs.general.keepUpToDate)
        XCTAssertEqual(updater.applied.last?.automaticallyChecks, true)
    }

    func testTheWordingMatchesTheOwnersCopy() {
        XCTAssertEqual(GeneralSettingsModel.keepUpToDateTitle, "Keep Kytkin up to date")
        XCTAssertEqual(GeneralSettingsModel.keepUpToDateHelp,
                       "Once a day, checks GitHub for a new version. You choose when to install. Nothing about you is sent.")
    }
}

// P2-26: The welcome window's logic: when it shows (first launch only, never with read-only preferences), the "seen"
// flag (set as soon as it shows), the steps, the Accessibility request reached only from the button's click (then
// waiting, then success), the default language pair from the layouts actually turned on (P2-62), launch at login off
// until the user turns it on, and the shared 1 s poll. Fakes only: no TCC, no TIS, no SMAppService, no real files.

import XCTest

// MARK: - Default pair (P2-62)

final class DefaultLanguagePairTests: XCTestCase {
    private let us = InputSourceID("com.apple.keylayout.US")
    private let british = InputSourceID("com.apple.keylayout.British")
    private let hebrewPC = InputSourceID("com.apple.keylayout.Hebrew-PC")
    private let german = InputSourceID("com.apple.keylayout.German")
    private let russian = InputSourceID("com.apple.keylayout.Russian")
    private let pinyin = InputSourceID("com.apple.inputmethod.SCIM.ITABC")

    private func info(_ id: InputSourceID, _ lang: String, enabled: Bool = true, convertible: Bool = true,
                      inputMethod: Bool = false) -> InputSourceInfo {
        InputSourceInfo(id: id, name: id.rawValue, languageCode: lang, isEnabled: enabled,
                        isConvertible: convertible, isInputMethod: inputMethod)
    }

    func testHebrewAndABCWhenBothAreOn() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(german, "de"), info(IDs.hebrew, "he"),
                                                         info(IDs.abc, "en")])
        XCTAssertEqual(pair, LanguagePair(a: IDs.abc, b: IDs.hebrew))
    }

    func testUSWhenABCIsOff() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(us, "en"), info(IDs.abc, "en", enabled: false),
                                                         info(hebrewPC, "he")])
        XCTAssertEqual(pair, LanguagePair(a: us, b: hebrewPC), "any turned-on Hebrew layout, not only “Hebrew”")
    }

    func testABCIsPreferredOverUS() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(us, "en"), info(IDs.abc, "en"), info(IDs.hebrew, "he")])
        XCTAssertEqual(pair, LanguagePair(a: IDs.abc, b: IDs.hebrew))
    }

    func testHebrewWithAnotherEnglishLayout() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(german, "de"), info(british, "en"),
                                                         info(IDs.hebrew, "he")])
        XCTAssertEqual(pair, LanguagePair(a: british, b: IDs.hebrew))
    }

    func testHebrewIsFoundByIDWhenTheLanguageCodeIsMissing() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(IDs.abc, ""), info(IDs.hebrew, "")])
        XCTAssertEqual(pair, LanguagePair(a: IDs.abc, b: IDs.hebrew))
    }

    func testElseTheFirstTwoTurnedOnConvertibleLayouts() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(pinyin, "zh", convertible: false, inputMethod: true),
                                                         info(IDs.abc, "en", enabled: false),
                                                         info(german, "de"), info(russian, "ru"), info(us, "en")])
        XCTAssertEqual(pair, LanguagePair(a: german, b: russian))
    }

    func testHebrewOnlyWithNoEnglishFallsBackToTheFirstTwo() {
        let pair = DefaultLanguagePair.suggest(enabled: [info(russian, "ru"), info(IDs.hebrew, "he")])
        XCTAssertEqual(pair, LanguagePair(a: russian, b: IDs.hebrew))
    }

    func testFewerThanTwoGivesNothing() {
        XCTAssertNil(DefaultLanguagePair.suggest(enabled: []))
        XCTAssertNil(DefaultLanguagePair.suggest(enabled: [info(IDs.hebrew, "he"), info(IDs.abc, "en", enabled: false)]))
        XCTAssertNil(DefaultLanguagePair.suggest(enabled: [info(IDs.abc, "en"), info(IDs.abc, "en")]),
                     "duplicates count once")
    }
}

// MARK: - Onboarding

@MainActor
final class OnboardingModelTests: XCTestCase {
    private var permissions: RecordingPermissions!
    private var polling: PermissionPollingDemand!
    private var store: PreferencesStore!
    private var loginItems: FakeLoginItems!
    private var system: FakeSystemLayouts!
    private var languages: LanguagesSettingsModel!
    private var sut: OnboardingModel!

    private func make(_ prefs: Preferences = Preferences(), store custom: PreferencesStore? = nil,
                      layouts: FakeSystemLayouts = .standard()) {
        permissions = RecordingPermissions()
        polling = PermissionPollingDemand(permissions: permissions)
        store = custom ?? makeStore(prefs, clock: FakeClock())
        loginItems = FakeLoginItems()
        system = layouts
        let fs = InMemoryLayoutFileSystem()
        let imported = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                           fileSystem: fs)
        languages = LanguagesSettingsModel(store: store, imported: imported,
                                           catalog: LayoutMapCatalog(system: system, imported: imported),
                                           fileSystem: fs, inputMethods: { [] })
        let general = GeneralSettingsModel(store: store, loginItems: loginItems, sources: { [] })
        sut = OnboardingModel(store: store, permissions: permissions, polling: polling, general: general,
                              languages: languages, appName: "Kytkin Dev")
    }

    private func seen(_ value: Bool) -> Preferences {
        var p = Preferences()
        p.general.onboardingSeen = value
        return p
    }

    // MARK: When to show, and the seen flag

    func testShownAtLaunchOnlyUntilSeen() {
        make()
        XCTAssertFalse(store.prefs.general.onboardingSeen, "absent → not seen")
        XCTAssertTrue(OnboardingModel.shouldShowAtLaunch(store))
        make(seen(true))
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(store))
    }

    func testNeverShownAtLaunchWithReadOnlyPreferences() {
        make(store: makeReadOnlyStore(seen(false)))
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(store), "the flag couldn't be saved: it would nag every launch")
        sut.begin(firstLaunch: true)   // reopened by hand: works, writes nothing
        XCTAssertFalse(store.prefs.general.onboardingSeen)
    }

    func testShowingMarksItSeenAtOnceSoItNeverComesBack() {
        make()
        sut.begin(firstLaunch: true)
        XCTAssertTrue(store.prefs.general.onboardingSeen, "set as it shows, so quitting half-way doesn't re-show it")
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(store))
    }

    func testFinishKeepsItSeen() {
        make()
        sut.begin(firstLaunch: false)
        sut.finish()
        XCTAssertTrue(store.prefs.general.onboardingSeen)
    }

    func testTheFlagIsSavedInTheFile() throws {
        var p = Preferences()
        p.general.onboardingSeen = true
        let decoded = try PreferencesCodec.decode(PreferencesCodec.encode(p)).0
        XCTAssertTrue(decoded.general.onboardingSeen)
        XCTAssertFalse(try PreferencesCodec.decode(Data(#"{"schemaVersion":1,"general":{}}"#.utf8)).0
            .general.onboardingSeen)
    }

    // MARK: Steps

    func testStepsForwardAndBack() {
        make()
        sut.begin(firstLaunch: true)
        XCTAssertEqual(sut.step, .welcome)
        XCTAssertTrue(sut.isFirstStep)
        XCTAssertEqual(sut.primaryTitle, "Continue")
        sut.back()
        XCTAssertEqual(sut.step, .welcome)
        sut.next(); XCTAssertEqual(sut.step, .languages)
        sut.next(); XCTAssertEqual(sut.step, .accessibility)
        sut.next(); XCTAssertEqual(sut.step, .finish)
        XCTAssertTrue(sut.isLastStep)
        XCTAssertEqual(sut.primaryTitle, "Done")
        sut.next(); XCTAssertEqual(sut.step, .finish)
        sut.back(); XCTAssertEqual(sut.step, .accessibility)
    }

    func testReopeningStartsAtTheWelcomeStep() {
        make()
        sut.begin(firstLaunch: true)
        sut.next(); sut.next()
        sut.finish()
        sut.begin(firstLaunch: false)
        XCTAssertEqual(sut.step, .welcome)
    }

    // MARK: Accessibility: only on the click

    func testNothingButTheButtonReachesTheRequestAPI() {
        make()
        permissions.set(accessibility: .notDetermined)
        sut.begin(firstLaunch: true)
        sut.setVisible(true)
        for _ in OnboardingModel.Step.allCases { sut.next(); sut.reload() }
        sut.back(); sut.back()
        sut.finish()
        XCTAssertEqual(permissions.promptingCalls, [], "showing, stepping, polling and closing never prompt")
    }

    func testAllowWaitsThenShowsSuccess() {
        make()
        permissions.set(accessibility: .unknown)
        sut.begin(firstLaunch: true)
        XCTAssertEqual(sut.accessibilityPhase, .checking)
        permissions.set(accessibility: .notDetermined)
        sut.reload()
        XCTAssertEqual(sut.accessibilityPhase, .notAsked)

        sut.grantAccessibility()
        XCTAssertEqual(permissions.promptingCalls, [.requestAccessibility])
        permissions.set(accessibility: .denied)   // read right after the request: not on yet
        sut.reload()
        XCTAssertEqual(sut.accessibilityPhase, .waiting)

        sut.openAccessibilitySettings()
        XCTAssertEqual(permissions.promptingCalls, [.requestAccessibility, .openSystemSettings(.accessibility)])

        permissions.set(accessibility: .granted)  // the 1 s poll saw the switch
        sut.reload()
        XCTAssertEqual(sut.accessibilityPhase, .granted)
    }

    func testAlreadyGrantedShowsSuccessWithoutAsking() {
        make()
        permissions.set(accessibility: .granted)
        sut.begin(firstLaunch: true)
        XCTAssertEqual(sut.accessibilityPhase, .granted)
        XCTAssertEqual(permissions.promptingCalls, [])
    }

    func testDeniedInAnEarlierRunIsNotWaitingUntilClicked() {
        make()
        permissions.set(accessibility: .denied)
        sut.begin(firstLaunch: true)
        XCTAssertEqual(sut.accessibilityPhase, .notAsked, "the button and the System Settings link both show")
    }

    // MARK: 1 s poll

    func testThePollIsFastOnlyWhileTheWindowShows() {
        make()
        sut.begin(firstLaunch: true)
        sut.setVisible(true)
        XCTAssertTrue(polling.isInteractive)
        sut.finish()
        XCTAssertFalse(polling.isInteractive)
        XCTAssertEqual(permissions.interactiveCalls, [true, false])
    }

    // MARK: Language pair (P2-62)

    func testFirstLaunchReplacesAPairThatIsNotTurnedOn() {
        let layouts = FakeSystemLayouts.standard()
        layouts.infos = [FakeSystemLayouts.info(IDs.abc, "ABC"),
                         FakeSystemLayouts.info(IDs.hebrew, "Hebrew", enabled: false),
                         FakeSystemLayouts.info(IDs.hebrewQWERTY, "Hebrew-QWERTY")]
        make(layouts: layouts)
        XCTAssertEqual(store.prefs.languagePair, .default)
        sut.begin(firstLaunch: true)
        XCTAssertEqual(store.prefs.languagePair, LanguagePair(a: IDs.abc, b: IDs.hebrewQWERTY),
                       "the turned-on Hebrew layout")
    }

    func testFirstLaunchKeepsAWorkingPair() {
        make()   // ABC and Hebrew turned on
        sut.begin(firstLaunch: true)
        XCTAssertEqual(store.prefs.languagePair, .default)
    }

    func testReopeningNeverChangesThePairByItself() {
        let layouts = FakeSystemLayouts.standard()
        layouts.infos = [FakeSystemLayouts.info(IDs.abc, "ABC"),
                         FakeSystemLayouts.info(IDs.hebrew, "Hebrew", enabled: false),
                         FakeSystemLayouts.info(IDs.hebrewQWERTY, "Hebrew-QWERTY")]
        make(layouts: layouts)
        sut.begin(firstLaunch: false)
        XCTAssertEqual(store.prefs.languagePair, .default)
    }

    func testTheUserCanChangeThePairOnTheStep() {
        make()
        sut.begin(firstLaunch: true)
        sut.languages.pairB = IDs.hebrewQWERTY.rawValue
        XCTAssertEqual(store.prefs.languagePair.b, IDs.hebrewQWERTY)
        sut.languages.pairA = IDs.hebrewQWERTY.rawValue
        XCTAssertEqual(sut.languages.pairProblem, .sameLanguage, "same checks as Settings → Languages")
    }

    // MARK: Launch at login

    func testLaunchAtLoginIsOffAndOnlyTheSwitchRegisters() {
        make()
        sut.begin(firstLaunch: true)
        for _ in OnboardingModel.Step.allCases { sut.next() }
        sut.finish()
        XCTAssertFalse(sut.general.launchAtLogin, "off by default")
        XCTAssertEqual(loginItems.actions, [], "nothing registered without the user's click")
        sut.general.setLaunchAtLogin(true)
        XCTAssertEqual(loginItems.actions, [.register])
        XCTAssertTrue(sut.general.launchAtLogin)
    }
}

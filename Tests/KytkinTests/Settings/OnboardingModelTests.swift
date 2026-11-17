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

    /// P6-0c: the wall clock the "waiting long" hint reads.
    private final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
    private let clock = TestClock()

    private func make(_ prefs: Preferences = Preferences(), store custom: PreferencesStore? = nil,
                      layouts: FakeSystemLayouts = .standard(),
                      bundlePath: String = "/Applications/Kytkin.app") {
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
        let clock = self.clock
        sut = OnboardingModel(store: store, permissions: permissions, polling: polling, general: general,
                              languages: languages, appName: "Kytkin Dev", bundlePath: bundlePath,
                              now: { clock.now }, layouts: { ConvertFixtures.layouts },
                              sourceName: { $0 == IDs.hebrew ? "Hebrew" : "English" })
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
        // P6-0c (owner 2026-11-17): three screens.
        sut.next(); XCTAssertEqual(sut.step, .permissions)
        sut.next(); XCTAssertEqual(sut.step, .practice)
        XCTAssertTrue(sut.isLastStep)
        XCTAssertEqual(sut.primaryTitle, "Done")
        XCTAssertEqual(sut.stepDescription, "Step 3 of 3")
        sut.next(); XCTAssertEqual(sut.step, .practice)
        sut.back(); XCTAssertEqual(sut.step, .permissions)
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

    /// QA (P2-26): existing installs see the welcome once too (firstLaunch = true); a pair the user chose, even one
    /// with a warning (a convert-only layout P2-24 allows), is never replaced.
    func testFirstLaunchNeverReplacesAPairTheUserChose() {
        let layouts = FakeSystemLayouts.standard()
        layouts.infos = [FakeSystemLayouts.info(IDs.abc, "ABC"),
                         FakeSystemLayouts.info(IDs.hebrew, "Hebrew"),
                         FakeSystemLayouts.info(IDs.hebrewQWERTY, "Hebrew-QWERTY", enabled: false)]
        let chosen = LanguagePair(a: IDs.abc, b: IDs.hebrewQWERTY)
        var prefs = Preferences()
        prefs.languagePair = chosen
        make(prefs, layouts: layouts)
        XCTAssertFalse(languages.pairWarnings.isEmpty, "the chosen pair has a warning (convert only)")
        sut.begin(firstLaunch: true)
        XCTAssertEqual(store.prefs.languagePair, chosen)
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

    // MARK: - P6-0c: move to Applications, waiting long, Open at Login, the practice box

    func testFromTheDiskImageOnlyTheMoveScreenAndNothingIsAskedOrSaved() {
        make(bundlePath: "/Volumes/Kytkin/Kytkin.app")
        XCTAssertTrue(OnboardingModel.shouldShowAtLaunch(store, bundlePath: "/Volumes/Kytkin/Kytkin.app"))
        XCTAssertTrue(OnboardingModel.shouldShowAtLaunch(
            store, bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Kytkin.app"))
        sut.begin(firstLaunch: true)
        XCTAssertTrue(sut.mustMoveToApplications)
        sut.grantAccessibility()
        sut.openAccessibilitySettings()
        sut.finish()
        XCTAssertEqual(permissions.promptingCalls, [], "flows M2: no permission from the disk image")
        XCTAssertFalse(store.prefs.general.onboardingSeen, "the setup shows again once it runs from Applications")
    }

    func testFromApplicationsNoMoveScreen() {
        make()
        XCTAssertFalse(sut.mustMoveToApplications)
        XCTAssertFalse(InstallLocation.needsMove(bundlePath: "/Users/me/Applications/Kytkin.app"))
    }

    func testWaitingLongShowsTheStaleEntryHint() {
        make()
        permissions.set(accessibility: .notDetermined)
        sut.begin(firstLaunch: true)
        sut.grantAccessibility()
        permissions.set(accessibility: .denied)
        sut.reload()
        XCTAssertEqual(sut.accessibilityPhase, .waiting)
        clock.now += OnboardingModel.waitingLongSeconds
        XCTAssertEqual(sut.accessibilityPhase, .waitingLong)
    }

    func testOpenAtLoginIsCheckedOnFirstLaunchAndAppliedOnlyOnDone() {
        make()
        sut.begin(firstLaunch: true)
        XCTAssertTrue(sut.openAtLogin, "owner 2026-11-17: on by default")
        sut.finish()   // Skip / close: nothing registered without Done
        XCTAssertFalse(sut.general.launchAtLogin)
        sut.begin(firstLaunch: true)
        sut.done()
        XCTAssertTrue(sut.general.launchAtLogin)
        sut.begin(firstLaunch: false)
        XCTAssertTrue(sut.openAtLogin, "reopened: shows the current state")
        sut.openAtLogin = false
        sut.done()
        XCTAssertFalse(sut.general.launchAtLogin)
    }

    func testThePracticeBoxConvertsInProcessAndBack() {
        make()
        sut.begin(firstLaunch: true)
        sut.next(); sut.next()
        XCTAssertEqual(sut.step, .practice)
        sut.practiceText = "akuo"
        XCTAssertNil(sut.practiceDoubleShift(), "only while the box has the keyboard")
        sut.practiceFocused = true
        XCTAssertEqual(sut.practiceDoubleShift(), IDs.hebrew)
        XCTAssertEqual(sut.practiceText, "שלום")
        XCTAssertEqual(sut.practiceResult, .converted("Hebrew"))
        sut.practiceTextChanged()   // the box reports its own new text: not an edit
        XCTAssertEqual(sut.practiceResult, .converted("Hebrew"))
        XCTAssertEqual(sut.practiceDoubleShift(), IDs.abc)
        XCTAssertEqual(sut.practiceText, "akuo")
        XCTAssertEqual(sut.practiceResult, .convertedBack)
        XCTAssertEqual(permissions.promptingCalls, [], "no AX, no clipboard, nothing asked")
    }

    func testThePracticeTextIsClearedWhenLeavingTheScreen() {
        make()
        sut.begin(firstLaunch: true)
        sut.next(); sut.next()
        sut.practiceText = "akuo"
        sut.practiceFocused = true
        sut.back()
        XCTAssertEqual(sut.practiceText, "", "typed text is never kept")
        XCTAssertNil(sut.practiceDoubleShift(), "not on the practice screen")
    }

    func testNothingToConvertSaysSo() {
        make()
        sut.begin(firstLaunch: true)
        sut.next(); sut.next()
        sut.practiceFocused = true
        XCTAssertNil(sut.practiceDoubleShift())
        XCTAssertEqual(sut.practiceResult, .nothingToConvert)
    }

    func testTheHintUsesTheUsersPair() {
        make()
        XCTAssertEqual(sut.practiceHint,
                       "With the English keyboard on, type akuo and press Shift twice. It becomes \u{2068}שלום\u{2069}.")
        XCTAssertEqual(PracticeConvert.hint(layouts: nil, name: { $0.rawValue }), PracticeConvert.genericHint)
    }
}

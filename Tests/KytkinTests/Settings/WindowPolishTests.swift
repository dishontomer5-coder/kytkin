// P3-12 (P2-63): window polish logic, with fakes only (no windows, no window server, no real files):
// - the 1 s permission poll pauses while a shown screen's window is hidden or fully covered, and resumes;
// - the 0.3 s focus fallback insists only if the user didn't switch apps meanwhile;
// - Esc clears, then leaves a text field, and closes the window only when nothing is being edited;
// - the welcome shows at launch only on a true first launch (no preferences file yet).

import XCTest

// MARK: - Poll only while on screen

@MainActor
final class PermissionPollingDemandTests: XCTestCase {
    private var permissions: RecordingPermissions!
    private var sut: PermissionPollingDemand!

    override func setUp() async throws {
        permissions = RecordingPermissions()
        sut = PermissionPollingDemand(permissions: permissions)
    }

    func testCoveringAShownScreenPausesThePollAndUncoveringResumesIt() {
        sut.set(.permissionsTab, visible: true)
        sut.set(.permissionsTab, covered: true)
        XCTAssertFalse(sut.isInteractive)
        sut.set(.permissionsTab, covered: false)
        XCTAssertTrue(sut.isInteractive)
        XCTAssertEqual(permissions.interactiveCalls, [true, false, true], "each resume is a fresh read")
    }

    func testRepeatedOcclusionReportsCallOnce() {
        sut.set(.onboarding, visible: true)
        sut.set(.onboarding, covered: true)
        sut.set(.onboarding, covered: true)
        sut.set(.onboarding, covered: false)
        sut.set(.onboarding, covered: false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false, true])
    }

    func testOcclusionOfAScreenThatIsNotShownDoesNothing() {
        sut.set(.permissionsTab, covered: false)
        sut.set(.permissionsTab, covered: true)
        sut.set(.permissionsTab, covered: false)
        XCTAssertEqual(permissions.interactiveCalls, [])
        XCTAssertFalse(sut.isInteractive)
    }

    func testShowingACoveredScreenDoesNotPollUntilItIsUncovered() {
        sut.set(.onboarding, covered: true)
        sut.set(.onboarding, visible: true)
        XCTAssertEqual(permissions.interactiveCalls, [])
        sut.set(.onboarding, covered: false)
        XCTAssertEqual(permissions.interactiveCalls, [true])
    }

    func testOneUncoveredScreenKeepsThePollWhileTheOtherIsCovered() {
        sut.set(.permissionsTab, visible: true)
        sut.set(.onboarding, visible: true)
        sut.set(.permissionsTab, covered: true)
        XCTAssertTrue(sut.isInteractive, "the welcome window still shows")
        sut.set(.onboarding, covered: true)
        XCTAssertFalse(sut.isInteractive, "Kytkin hidden: both covered")
        sut.set(.onboarding, covered: false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false, true])
    }

    func testClosingWhileCoveredStaysOff() {
        sut.set(.permissionsTab, visible: true)
        sut.set(.permissionsTab, covered: true)
        sut.set(.permissionsTab, visible: false)
        sut.set(.permissionsTab, covered: false)   // the next show marks it on top before showing it
        XCTAssertEqual(permissions.interactiveCalls, [true, false])
        XCTAssertFalse(sut.isInteractive)
    }

    func testThePermissionsTabForwardsOcclusion() {
        let tab = PermissionsSettingsModel(permissions: permissions, store: makeStore(clock: FakeClock()), polling: sut,
                                           appName: "Kytkin", state: { MenuState() }, relaunch: {})
        tab.setVisible(true)
        tab.setCovered(true)
        tab.setCovered(false)
        tab.setVisible(false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false, true, false])
        XCTAssertEqual(permissions.promptingCalls, [], "pausing and resuming never prompt")
    }
}

// MARK: - Focus fallback only if the user didn't switch apps

final class FocusFallbackPolicyTests: XCTestCase {
    private let own: Int32 = 100
    private let textEdit: Int32 = 200
    private let safari: Int32 = 300

    private func insist(visible: Bool = true, keyboard: Bool = false, atShow: Int32?, now: Int32?) -> Bool {
        FocusFallbackPolicy.shouldInsist(windowVisible: visible, windowHasKeyboard: keyboard, ownPID: own,
                                         frontmostAtShow: atShow, frontmostNow: now)
    }

    func testActivationRefusedAndTheSameAppInFrontInsistsOnce() {
        XCTAssertTrue(insist(atShow: textEdit, now: textEdit))
    }

    func testUserSwitchedToAnotherAppMeanwhileIsLeftAlone() {
        XCTAssertFalse(insist(atShow: textEdit, now: safari))
    }

    func testUserSwitchedAwayFromKytkinIsLeftAlone() {
        XCTAssertFalse(insist(atShow: own, now: safari), "Kytkin was in front, now another app is: the user moved on")
    }

    func testKytkinInFrontButWindowNotKeyInsists() {
        XCTAssertTrue(insist(atShow: textEdit, now: own))
    }

    func testNothingToDoWhenTheWindowHasTheKeyboardOrIsGone() {
        XCTAssertFalse(insist(keyboard: true, atShow: textEdit, now: textEdit))
        XCTAssertFalse(insist(visible: false, atShow: textEdit, now: textEdit))
    }

    func testUnknownFrontmostApps() {
        XCTAssertTrue(insist(atShow: nil, now: nil), "no app in front then or now: nothing switched")
        XCTAssertFalse(insist(atShow: nil, now: safari), "an app came forward meanwhile")
        XCTAssertFalse(insist(atShow: textEdit, now: nil))
    }
}

// MARK: - Esc

final class EscapeKeyActionTests: XCTestCase {
    func testNothingEditedClosesTheWindow() {
        XCTAssertEqual(EscapeKeyAction.decide(sheetAttached: false, focus: .nothingEdited), .closeWindow)
    }

    func testAFieldWithTextIsClearedFirst() {
        XCTAssertEqual(EscapeKeyAction.decide(sheetAttached: false, focus: .textField(isEmpty: false)), .clearField)
    }

    func testAnEmptyFieldIsLeftNotTheWindowClosed() {
        XCTAssertEqual(EscapeKeyAction.decide(sheetAttached: false, focus: .textField(isEmpty: true)), .stopEditing)
    }

    func testATextAreaIsNeverCleared() {
        XCTAssertEqual(EscapeKeyAction.decide(sheetAttached: false, focus: .textArea), .stopEditing)
    }

    func testASheetKeepsEscWhateverHasFocus() {
        let all: [EscapeKeyAction.Focus] = [.nothingEdited, .textField(isEmpty: true), .textField(isEmpty: false),
                                            .textArea]
        for focus in all {
            XCTAssertEqual(EscapeKeyAction.decide(sheetAttached: true, focus: focus), .ignore)
        }
    }

    func testThreeEscsFromASearchFieldWithText() {
        // clear → (field now empty) leave → (nothing edited) close
        var focus = EscapeKeyAction.Focus.textField(isEmpty: false)
        var actions: [EscapeKeyAction] = []
        for _ in 0..<3 {
            let action = EscapeKeyAction.decide(sheetAttached: false, focus: focus)
            actions.append(action)
            switch action {
            case .clearField: focus = .textField(isEmpty: true)
            case .stopEditing: focus = .nothingEdited
            default: break
            }
        }
        XCTAssertEqual(actions, [.clearField, .stopEditing, .closeWindow])
    }
}

// MARK: - Welcome only on a true first launch

@MainActor
final class WelcomeAtLaunchTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")

    private func store(_ fs: InMemoryPreferencesFileSystem) -> PreferencesStore {
        PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: fs)
    }

    func testTrueFirstLaunchShowsIt() {
        let s = store(InMemoryPreferencesFileSystem())
        XCTAssertFalse(s.foundFileAtLoad)
        XCTAssertTrue(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testAFileFromBeforeTheWelcomeDoesNotShowItAtLogin() {
        // An install from before P2-26: no `onboardingSeen` key, so the flag reads false.
        let old = Data(#"{"schemaVersion":1,"general":{"enabled":true},"rules":[]}"#.utf8)
        let s = store(InMemoryPreferencesFileSystem(files: [url: old]))
        XCTAssertTrue(s.foundFileAtLoad)
        XCTAssertFalse(s.prefs.general.onboardingSeen)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testAnEmptyObjectFileCountsAsAnExistingInstall() {
        let s = store(InMemoryPreferencesFileSystem(files: [url: Data("{}".utf8)]))
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testACorruptFileThatWasQuarantinedCountsAsAnExistingInstall() {
        let s = store(InMemoryPreferencesFileSystem(files: [url: Data("{".utf8)]))
        XCTAssertNotNil(s.loadIssue)
        XCTAssertFalse(s.isReadOnly)
        XCTAssertTrue(s.foundFileAtLoad)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testAnUnreadableFileCountsAsAnExistingInstall() {
        let fs = InMemoryPreferencesFileSystem()
        fs.failReads = true
        let s = store(fs)
        XCTAssertTrue(s.foundFileAtLoad)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testTheFirstLaunchWritesTheFileSoTheNextLaunchIsNotFirst() {
        let fs = InMemoryPreferencesFileSystem()
        let first = store(fs)
        first.update { $0.general.onboardingSeen = true }   // what `begin` does as the welcome shows
        first.flush()
        let next = store(fs)
        XCTAssertTrue(next.foundFileAtLoad)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(next))
    }

    func testAnExistingInstallCanStillReopenItFromSettings() {
        // "Show Welcome Again…" doesn't ask shouldShowAtLaunch: it shows, marks the flag, and pauses its poll
        // while covered like a first-launch welcome.
        let s = store(InMemoryPreferencesFileSystem(files: [url: Data(#"{"schemaVersion":1}"#.utf8)]))
        let permissions = RecordingPermissions()
        let fs = InMemoryLayoutFileSystem()
        let imported = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                           fileSystem: fs)
        let languages = LanguagesSettingsModel(store: s, imported: imported,
                                               catalog: LayoutMapCatalog(system: FakeSystemLayouts.standard(),
                                                                         imported: imported),
                                               fileSystem: fs, inputMethods: { [] })
        let model = OnboardingModel(store: s, permissions: permissions,
                                    polling: PermissionPollingDemand(permissions: permissions),
                                    general: GeneralSettingsModel(store: s, loginItems: FakeLoginItems(),
                                                                  sources: { [] }),
                                    languages: languages, appName: "Kytkin Dev")
        model.begin(firstLaunch: false)
        XCTAssertTrue(s.prefs.general.onboardingSeen)
        model.setVisible(true)
        model.setCovered(true)
        model.setCovered(false)
        XCTAssertEqual(permissions.interactiveCalls, [true, false, true])
        XCTAssertEqual(permissions.promptingCalls, [])
    }
}

// MARK: - QA (P3-12): more launch states

@MainActor
final class WelcomeAtLaunchQATests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")

    private func store(_ fs: InMemoryPreferencesFileSystem) -> PreferencesStore {
        PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: fs)
    }

    func testANewerSchemaFileCountsAsAnExistingInstall() {
        let newer = Data(#"{"schemaVersion":99,"general":{"onboardingSeen":false}}"#.utf8)
        let s = store(InMemoryPreferencesFileSystem(files: [url: newer]))
        XCTAssertEqual(s.loadIssue, .newerSchemaReadOnly)
        XCTAssertTrue(s.foundFileAtLoad)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testALossyFileCountsAsAnExistingInstall() {
        // Mistyped fields are defaulted (a lossy load); the file was still there.
        let lossy = Data(#"{"schemaVersion":1,"general":{"enabled":"yes","onboardingSeen":"no"}}"#.utf8)
        let s = store(InMemoryPreferencesFileSystem(files: [url: lossy]))
        XCTAssertTrue(s.loadWasLossy)
        XCTAssertTrue(s.foundFileAtLoad)
        XCTAssertFalse(s.isReadOnly)
        XCTAssertFalse(s.prefs.general.onboardingSeen)
        XCTAssertFalse(OnboardingModel.shouldShowAtLaunch(s))
    }

    func testFoundFileAtLoadNeverChangesDuringTheRun() {
        // True first launch: the file written later in the same run doesn't flip it.
        let fs = InMemoryPreferencesFileSystem()
        let s = store(fs)
        s.update { $0.general.onboardingSeen = true }
        s.flush()
        XCTAssertNotNil(fs[url])
        XCTAssertFalse(s.foundFileAtLoad)
    }

    func testADeletedFileIsAFreshStartAndShowsItAgain() {
        // Documented choice (OnboardingModel header): deleting preferences.json means starting over.
        let fs = InMemoryPreferencesFileSystem()
        let first = store(fs)
        first.update { $0.general.onboardingSeen = true }
        first.flush()
        fs[url] = nil
        XCTAssertTrue(OnboardingModel.shouldShowAtLaunch(store(fs)))
    }
}

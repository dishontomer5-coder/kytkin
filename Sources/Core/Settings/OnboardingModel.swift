// P2-26: The setup window's logic (001 §6.1), so the SwiftUI view stays a thin layout. A small state machine.
// P6-0c (owner 2026-11-17: a 3-screen guided setup; flows §5.2–§5.4, copy review §4.1):
//
//   welcome (what Kytkin does + your two languages) → permissions (Accessibility, with why) → practice (double-Shift)
//   ("Skip Setup" on the first screen; "Back" one step back; "Done" on the last)
//
// - P6-0c (flows M2): running from the disk image or a quarantined copy (`InstallLocation.needsMove`), the window shows
//   only a "Move Kytkin to Applications first" screen: no permission request there, and the "seen" flag is not set.
// - P6-0c: the practice box converts its own text in process (`PracticeConvert`; AppController hands it the
//   double-Shift while the box has the keyboard). "Open Kytkin when I log in" is checked by default (owner) and is
//   applied on Done only (the user's click).
//
// - Shown at launch only while `general.onboardingSeen` is false, and never with read-only preferences (the flag
//   couldn't be saved, so it would come back on every launch). `begin` marks it seen as soon as it shows, so quitting
//   half-way doesn't bring it back: it never steals focus twice. Settings → General → "Show Welcome Again" reopens it.
// - P3-12 (P2-63): and only on a true first launch, i.e. no preferences file existed when Kytkin started. An install
//   from before P2-26 has a file without the flag (absent → false), so the flag alone would greet it at its next
//   login. "File was there" is the robust test: Kytkin writes the file on the first change and the welcome itself
//   writes it (`markSeen`), so any earlier run that did anything left one; it needs no version stamp or second flag;
//   and it holds whatever state the file is in (migrated, lossy, corrupt). A file the user deleted counts as a fresh
//   start, which is what deleting it means.
// - Language pair (P2-62): on the first launch, if the saved pair is still the shipped default and has a problem (a
//   layout not turned on, missing…), it is replaced by `DefaultLanguagePair.suggest` from the layouts actually turned on. The user can change it on
//   that step (the same pickers and checks as Settings → Languages). Reopened later, it never changes the pair itself.
// - Accessibility: `grantAccessibility()` is the ONLY place the request API is called, from the button's click.
//   Then the step waits (the poll runs every 1 s while the window is visible) and turns to "done" once granted.
// - Launch at login: GeneralSettingsModel registers it, only from Done with the box checked (P6-0c: checked by default).

import Foundation
import Observation

@MainActor @Observable final class OnboardingModel {
    enum Step: Int, CaseIterable, Sendable {
        case welcome, permissions, practice
    }

    /// What the Accessibility step shows.
    enum AccessibilityPhase: Equatable, Sendable {
        /// Not read yet.
        case checking
        /// Not allowed; the button hasn't been clicked in this window.
        case notAsked
        /// The user clicked "Allow…" and hasn't switched it on yet.
        case waiting
        /// P6-0c (flows M4): still waiting after 20 s: maybe a stale entry in the list.
        case waitingLong
        case granted
    }

    /// P6-0c: what the practice box says after a double-Shift.
    enum PracticeResult: Equatable, Sendable {
        case none
        /// Converted, and the keyboard is now this language (its name).
        case converted(String)
        /// Converted again: back to how it was.
        case convertedBack
        /// Nothing to convert (empty, or already right).
        case nothingToConvert
    }

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let polling: PermissionPollingDemand
    @ObservationIgnored let general: GeneralSettingsModel
    @ObservationIgnored let languages: LanguagesSettingsModel
    @ObservationIgnored let appName: String
    @ObservationIgnored private let bundlePath: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let layouts: @MainActor () -> LayoutSnapshot?
    @ObservationIgnored private let sourceName: @MainActor (InputSourceID) -> String

    private(set) var step: Step = .welcome
    private(set) var accessibility: PermissionState = .unknown
    /// The "Allow…" button was clicked since the window opened.
    private(set) var requestedAccessibility = false
    @ObservationIgnored private var requestedAt: Date?
    /// The practice box's text (typed text: in memory only, cleared when the user leaves the screen).
    var practiceText = ""
    /// The practice box has the keyboard (set by the view).
    var practiceFocused = false
    private(set) var practiceResult: PracticeResult = .none
    /// The text the last double-Shift wrote, so that write isn't taken for the user's own edit.
    @ObservationIgnored private var lastPracticeWrite: String?
    /// "Open Kytkin when I log in" (owner 2026-11-17: on by default); applied on Done.
    var openAtLogin = true

    init(store: PreferencesStore, permissions: any PermissionsProviding, polling: PermissionPollingDemand,
         general: GeneralSettingsModel, languages: LanguagesSettingsModel, appName: String,
         bundlePath: String = "/Applications/Kytkin.app", now: @escaping () -> Date = Date.init,
         layouts: @escaping @MainActor () -> LayoutSnapshot? = { nil },
         sourceName: @escaping @MainActor (InputSourceID) -> String = { $0.rawValue }) {
        self.store = store
        self.permissions = permissions
        self.polling = polling
        self.general = general
        self.languages = languages
        self.appName = appName
        self.bundlePath = bundlePath
        self.now = now
        self.layouts = layouts
        self.sourceName = sourceName
    }

    // MARK: - When to show

    /// At launch: only on a true first launch (no preferences file yet, P3-12), and only if the "seen" flag can
    /// be saved. P6-0c: always while Kytkin runs from the disk image (the move screen).
    static func shouldShowAtLaunch(_ store: PreferencesStore, bundlePath: String = Bundle.main.bundlePath) -> Bool {
        if InstallLocation.needsMove(bundlePath: bundlePath) { return true }
        return !store.foundFileAtLoad && !store.isReadOnly && !store.prefs.general.onboardingSeen
    }

    /// P6-0c (flows M2): the move screen instead of the setup.
    var mustMoveToApplications: Bool { InstallLocation.needsMove(bundlePath: bundlePath) }

    /// The window is about to show. `firstLaunch`: shown by itself at launch (not reopened from Settings).
    /// `startAt`: P6-0c, e.g. the practice screen.
    func begin(firstLaunch: Bool, startAt: Step = .welcome) {
        step = startAt
        requestedAccessibility = false
        requestedAt = nil
        clearPractice()
        if mustMoveToApplications { return }   // nothing is asked or saved from the disk image
        markSeen()
        general.refresh()
        languages.refresh()
        openAtLogin = firstLaunch ? true : general.launchAtLogin
        if firstLaunch { pickDefaultPairIfNeeded() }
        reload()
    }
    /// The window became visible or closed: the 1 s permission poll runs while it is visible.
    func setVisible(_ visible: Bool) {
        polling.set(.onboarding, visible: visible)
        if visible { reload() }
    }

    /// P3-12: the window is hidden or fully covered (true), or back on screen (false). No poll while covered.
    func setCovered(_ covered: Bool) {
        polling.set(.onboarding, covered: covered)
        if !covered { reload() }
    }

    /// Silent: takes the last permission reading.
    func reload() {
        let next = permissions.status.grants.accessibility
        if next != accessibility { accessibility = next }
    }

    // MARK: - Steps

    var isFirstStep: Bool { step == .welcome }
    var isLastStep: Bool { step == .practice }
    var primaryTitle: String { isLastStep ? "Done" : "Continue" }
    /// VoiceOver for the dots (copy review §4.1).
    var stepDescription: String { "Step \(step.rawValue + 1) of \(Step.allCases.count)" }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        if step == .practice { clearPractice() }
        step = following
        reload()
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        if step == .practice { clearPractice() }   // typed text is never kept
        step = previous
    }

    /// "Done": applies "Open Kytkin when I log in" (the user's click), then closes like Skip.
    func done() {
        if openAtLogin != general.launchAtLogin { general.setLaunchAtLogin(openAtLogin) }
    }

    /// "Done", "Skip Setup" or the close button: the window is closing. The view closes it.
    func finish() {
        clearPractice()
        if !mustMoveToApplications { markSeen() }
        setVisible(false)
    }

    // MARK: - Practice (P6-0c, flows §5.4)

    /// The hint under the box, built from the user's pair.
    var practiceHint: String { PracticeConvert.hint(layouts: layouts(), name: sourceName) }

    /// A double-Shift while Kytkin's own window is in front (AppController). Converts the practice box in process.
    /// Returns the language to switch to (the after-convert switch), nil = not for the practice box or nothing
    /// converted.
    func practiceDoubleShift() -> InputSourceID? {
        guard step == .practice, practiceFocused else { return nil }
        guard let layouts = layouts(), let result = PracticeConvert.convert(practiceText, layouts: layouts) else {
            practiceResult = .nothingToConvert
            return nil
        }
        practiceText = result.text
        lastPracticeWrite = result.text
        if case .converted = practiceResult {
            practiceResult = .convertedBack
        } else {
            practiceResult = .converted(sourceName(result.target))
        }
        return result.target
    }

    /// The text is edited by hand: the next double-Shift is a fresh convert.
    func practiceTextChanged() {
        guard practiceText != lastPracticeWrite else { return }
        lastPracticeWrite = nil
        if practiceResult != .none { practiceResult = .none }
    }

    private func clearPractice() {
        practiceText = ""
        lastPracticeWrite = nil
        practiceResult = .none
        practiceFocused = false
    }

    // MARK: - Accessibility (user click only)

    var accessibilityPhase: AccessibilityPhase {
        switch accessibility {
        case .unknown: return .checking
        case .granted: return .granted
        case .denied, .notDetermined:
            guard requestedAccessibility else { return .notAsked }
            if let at = requestedAt, now().timeIntervalSince(at) >= Self.waitingLongSeconds { return .waitingLong }
            return .waiting
        }
    }

    /// P6-0c (flows M4): after this long waiting, the stale-entry hint shows.
    static let waitingLongSeconds: TimeInterval = 20

    /// The "Allow Accessibility…" button. The only caller of the request API in the setup window. Never from the
    /// disk image (flows M2).
    func grantAccessibility() {
        guard !mustMoveToApplications else { return }
        requestedAccessibility = true
        requestedAt = now()
        permissions.requestAccessibility()
        reload()
    }

    /// The "Open System Settings" link (shown before and after the request: macOS asks only once ever, P2-46).
    func openAccessibilitySettings() {
        guard !mustMoveToApplications else { return }
        permissions.openSystemSettings(.accessibility)
    }

    // MARK: - Private

    private func markSeen() {
        guard !store.isReadOnly, !store.prefs.general.onboardingSeen else { return }
        store.update { $0.general.onboardingSeen = true }
    }

    /// P2-62: replace a saved pair that has a problem with one built from the turned-on layouts.
    /// QA (P2-26): only while the saved pair is still the shipped default. Existing installs also see the welcome
    /// once, and a pair the user chose (e.g. an "Other installed (convert only)" layout, which P2-24 allows and
    /// warns about) must never be replaced behind their back.
    private func pickDefaultPairIfNeeded() {
        guard languages.isEditable, languages.pair == .default, !languages.pairWarnings.isEmpty,
              let suggestion = DefaultLanguagePair.suggest(enabled: languages.systemLayouts),
              suggestion != languages.pair else { return }
        languages.choose(suggestion)
    }
}

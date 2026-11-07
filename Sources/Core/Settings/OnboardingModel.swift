// P2-26: The welcome window's logic (001 §6.1), so the SwiftUI view stays a thin layout. A small state machine:
//
//   welcome → languages → accessibility → finish        ("Skip" ends it from any step; "Back" goes one step back)
//
// - Shown at launch only while `general.onboardingSeen` is false, and never with read-only preferences (the flag
//   couldn't be saved, so it would come back on every launch). `begin` marks it seen as soon as it shows, so quitting
//   half-way doesn't bring it back: it never steals focus twice. Settings → General → "Show Welcome Again" reopens it.
// - Language pair (P2-62): on the first launch, if the saved pair has a problem (a layout not turned on, missing…),
//   it is replaced by `DefaultLanguagePair.suggest` from the layouts actually turned on. The user can change it on
//   that step (the same pickers and checks as Settings → Languages). Reopened later, it never changes the pair itself.
// - Accessibility: `grantAccessibility()` is the ONLY place the request API is called, from the button's click.
//   Then the step waits (the poll runs every 1 s while the window is visible) and turns to "done" once granted.
// - Launch at login: the switch is GeneralSettingsModel's (off until the user turns it on; register only on click).

import Foundation
import Observation

@MainActor @Observable final class OnboardingModel {
    enum Step: Int, CaseIterable, Sendable {
        case welcome, languages, accessibility, finish
    }

    /// What the Accessibility step shows.
    enum AccessibilityPhase: Equatable, Sendable {
        /// Not read yet.
        case checking
        /// Not allowed; the button hasn't been clicked in this window.
        case notAsked
        /// The user clicked "Allow…" and hasn't switched it on yet.
        case waiting
        case granted
    }

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let polling: PermissionPollingDemand
    @ObservationIgnored let general: GeneralSettingsModel
    @ObservationIgnored let languages: LanguagesSettingsModel
    @ObservationIgnored let appName: String

    private(set) var step: Step = .welcome
    private(set) var accessibility: PermissionState = .unknown
    /// The "Allow…" button was clicked since the window opened.
    private(set) var requestedAccessibility = false

    init(store: PreferencesStore, permissions: any PermissionsProviding, polling: PermissionPollingDemand,
         general: GeneralSettingsModel, languages: LanguagesSettingsModel, appName: String) {
        self.store = store
        self.permissions = permissions
        self.polling = polling
        self.general = general
        self.languages = languages
        self.appName = appName
    }

    // MARK: - When to show

    /// At launch: only the first time, and only if the "seen" flag can be saved.
    static func shouldShowAtLaunch(_ store: PreferencesStore) -> Bool {
        !store.isReadOnly && !store.prefs.general.onboardingSeen
    }

    /// The window is about to show. `firstLaunch`: shown by itself at launch (not reopened from Settings).
    func begin(firstLaunch: Bool) {
        step = .welcome
        requestedAccessibility = false
        markSeen()
        general.refresh()
        languages.refresh()
        if firstLaunch { pickDefaultPairIfNeeded() }
        reload()
    }

    /// The window became visible or closed: the 1 s permission poll runs while it is visible.
    func setVisible(_ visible: Bool) {
        polling.set(.onboarding, visible: visible)
        if visible { reload() }
    }

    /// Silent: takes the last permission reading.
    func reload() {
        let next = permissions.status.grants.accessibility
        if next != accessibility { accessibility = next }
    }

    // MARK: - Steps

    var isFirstStep: Bool { step == .welcome }
    var isLastStep: Bool { step == .finish }
    var primaryTitle: String { isLastStep ? "Done" : "Continue" }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
        reload()
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// "Done" or "Skip": the window is closing. The view closes it.
    func finish() {
        markSeen()
        setVisible(false)
    }

    // MARK: - Accessibility (user click only)

    var accessibilityPhase: AccessibilityPhase {
        switch accessibility {
        case .unknown: .checking
        case .granted: .granted
        case .denied, .notDetermined: requestedAccessibility ? .waiting : .notAsked
        }
    }

    /// The "Allow Accessibility…" button. The only caller of the request API in the welcome window.
    func grantAccessibility() {
        requestedAccessibility = true
        permissions.requestAccessibility()
        reload()
    }

    /// The "Open System Settings" link (shown before and after the request: macOS asks only once ever, P2-46).
    func openAccessibilitySettings() {
        permissions.openSystemSettings(.accessibility)
    }

    // MARK: - Private

    private func markSeen() {
        guard !store.isReadOnly, !store.prefs.general.onboardingSeen else { return }
        store.update { $0.general.onboardingSeen = true }
    }

    /// P2-62: replace a saved pair that has a problem with one built from the turned-on layouts.
    private func pickDefaultPairIfNeeded() {
        guard languages.isEditable, !languages.pairWarnings.isEmpty,
              let suggestion = DefaultLanguagePair.suggest(enabled: languages.systemLayouts),
              suggestion != languages.pair else { return }
        languages.choose(suggestion)
    }
}

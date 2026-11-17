// P2-26: The logic behind Settings → Permissions (001 §5.2, §6), so the SwiftUI view stays a thin layout.
//
// - Rows for Accessibility and Input Monitoring (`PermissionRow`). Automation per browser is Phase 3 (P3-7): none.
// - What it reads: `MenuState` from AppController (grants, the tap mode actually running, Secure Input from
//   KeyWatcher (P2-45), the "Quit & Reopen" hint from `TapModePolicy` (P2-46), conflicts) plus the preferences for
//   the mode Kytkin wants. `reload()` takes a fresh copy; the root calls it whenever the menu's display changes
//   (a grant, a tap restart, Secure Input), so the tab follows the P2-46 retry with no timer of its own.
// - While the tab is visible the permission poll runs every 1 s (`PermissionPollingDemand`, 001 §2.2).
// - The request APIs, System Settings and the relaunch are reached ONLY from the user-click methods below
//   (`grant`, `openSystemSettings`, `quitAndReopen`). Nothing else here calls them (design.md: never prompt
//   without a click). Reads (`reload`, `checkAgain`) are silent.

import Foundation
import Observation

@MainActor @Observable final class PermissionsSettingsModel {
    @ObservationIgnored private let permissions: any PermissionsProviding
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let readState: @MainActor () -> MenuState
    @ObservationIgnored private let relaunch: @MainActor () -> Void
    @ObservationIgnored private let polling: PermissionPollingDemand
    @ObservationIgnored let appName: String

    /// The last copy of what the app is doing. Refreshed by `reload()`.
    private(set) var state: MenuState

    init(permissions: any PermissionsProviding, store: PreferencesStore, polling: PermissionPollingDemand,
         appName: String, state: @escaping @MainActor () -> MenuState, relaunch: @escaping @MainActor () -> Void) {
        self.permissions = permissions
        self.store = store
        self.polling = polling
        self.appName = appName
        self.readState = state
        self.relaunch = relaunch
        self.state = state()
    }

    /// Takes a fresh copy (silent; no OS call).
    func reload() {
        let next = readState()
        if next != state { state = next }
    }

    /// The tab became visible (true) or hidden / its window closed (false): 1 s poll while visible.
    func setVisible(_ visible: Bool) {
        polling.set(.permissionsTab, visible: visible)
        if visible { reload() }
    }

    /// P3-12: the Settings window is hidden or fully covered (true), or back on screen (false). No poll while covered.
    func setCovered(_ covered: Bool) {
        polling.set(.permissionsTab, covered: covered)
        if !covered { reload() }
    }

    // MARK: - Rows

    var rows: [PermissionRow] {
        let covers = Self.accessibilityCoversInputMonitoring(state: state)
        return [
            PermissionRow.make(.accessibility, state: state.accessibility, accessibilityCoversIt: covers,
                               showsQuitAndReopen: false, appName: appName),
            PermissionRow.make(.inputMonitoring, state: state.inputMonitoring, accessibilityCoversIt: covers,
                               showsQuitAndReopen: state.showsQuitAndReopen, appName: appName),
        ]
    }

    /// P2-64 (P1-17 answered, keyboard-event-tap.md addendum): on macOS 26 Accessibility alone gives listen access,
    /// and `CGPreflightListenEventAccess()` then reads true even though Kytkin is not in the Input Monitoring list.
    /// An Input Monitoring grant adds nothing while Accessibility is allowed, so the row reads "Not needed" whatever
    /// the preflight value and the tap mode are (this replaces P2-26 QA's "only once the tap runs" rule: offering a
    /// second permission can't help a tap that Accessibility didn't start; the Mode line and the menu say so).
    static func accessibilityCoversInputMonitoring(state: MenuState) -> Bool {
        state.accessibility == .granted
    }

    // MARK: - User clicks only

    /// The row's "Allow…" button. The only caller of the request APIs in Settings.
    func grant(_ pane: PermissionPane) {
        switch pane {
        case .accessibility: permissions.requestAccessibility()
        case .inputMonitoring: permissions.requestInputMonitoring()
        }
        reload()
    }

    /// The row's "Open System Settings" link.
    func openSystemSettings(_ pane: PermissionPane) {
        permissions.openSystemSettings(pane)
    }

    /// "Check Again": a silent re-read.
    func checkAgain() {
        permissions.refresh()
        reload()
    }

    /// "Quit & Reopen" (P2-46). Does nothing unless the hint is showing (a stale click can't quit the app).
    func quitAndReopen() {
        reload()
        guard state.showsQuitAndReopen else { return }
        relaunch()
    }

    // MARK: - Keyboard mode and Secure Input (display only)

    /// The mode Kytkin wants from the grants and settings (001 §6.2).
    var desiredTapMode: TapMode {
        FeatureAvailability.desiredTapMode(
            grants: PermissionGrants(accessibility: state.accessibility, inputMonitoring: state.inputMonitoring),
            settings: PreferencesMapping.featureSettings(store.prefs, paused: state.paused))
    }

    var keyboardModeText: String {
        Self.keyboardModeText(state: state, desired: desiredTapMode)
    }

    var secureInputText: String {
        Self.secureInputText(state: state)
    }

    /// Other switchers and per-document input (001 §5.2 "Conflicts"). Empty = nothing in the way.
    var conflictLines: [String] {
        Self.conflictLines(state.conflicts)
    }

    /// The current keyboard mode in plain words (pure, tested). P6-0c (copy review P-9/P-10): named after what the
    /// user sees (double-Shift), each line with its next step.
    static func keyboardModeText(state: MenuState, desired: TapMode) -> String {
        if !state.enabled { return "Off: Kytkin is turned off." }
        if state.paused { return "Off: Kytkin is paused." }
        let achieved = state.tapMode
        var text: String
        switch achieved {
        case .active:
            text = "Works: converts text and switches the language."
        case .listenOnly:
            text = "Switches only: allow Accessibility to convert text too."
        case .off:
            if desired == .off {
                let anyGrant = state.accessibility == .granted || state.inputMonitoring == .granted
                text = anyGrant ? "Off in Double-Shift settings." : "Off: allow Accessibility to use it."
            } else {
                text = "Stopped: Kytkin couldn't start it. Quit & Reopen Kytkin."
            }
        }
        if TapModePolicy.rank(achieved) < TapModePolicy.rank(desired) {
            if state.showsQuitAndReopen {
                text += " Quit & Reopen Kytkin to use everything you allowed."
            } else if state.degradedByWatchdog {
                text += " It stopped after a slowdown. Use Start Double-Shift Again in the Kytkin menu."
            } else {
                // P2-57 item 1 / P2-52 item 2: the same words as the menu's warning, never silent.
                text += " Part of it is off. Use Start Double-Shift Again in the Kytkin menu."
            }
        }
        return text
    }

    static func secureInputText(state: MenuState) -> String {
        guard state.enabled, !state.paused, state.tapMode != .off else {
            return "Kytkin checks this only while it watches the keyboard."
        }
        return state.secureInputOn
            ? "On: another app is protecting your typing (like a password box). Double-Shift waits until it ends."
            : "Off: no app is protecting your typing right now."
    }

    static func conflictLines(_ conflicts: Conflicts) -> [String] {
        var lines: [String] = []
        if !conflicts.runningSwitchers.isEmpty {
            let names = conflicts.runningSwitchers.joined(separator: ", ")
            // P6-0c (copy review P-13). Owner 2026-11-17: a warning only, no Quit button.
            lines.append("\(names) also switches languages, so the two may undo each other. Quit \(names) to avoid "
                + "this.")
        }
        if conflicts.perDocumentInputEnabled {
            lines.append("macOS is switching languages per document, so Kytkin isn't learning. "
                + "To turn that off: System Settings → Keyboard → Text Input → Edit…, then turn off "
                + "“Automatically switch to a document's input source”.")
        }
        return lines
    }
}

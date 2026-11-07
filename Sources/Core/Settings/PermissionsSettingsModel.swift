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

    // MARK: - Rows

    var rows: [PermissionRow] {
        let covers = Self.accessibilityCoversInputMonitoring(state: state, desired: desiredTapMode)
        return [
            PermissionRow.make(.accessibility, state: state.accessibility, accessibilityCoversIt: covers,
                               showsQuitAndReopen: false, appName: appName),
            PermissionRow.make(.inputMonitoring, state: state.inputMonitoring, accessibilityCoversIt: covers,
                               showsQuitAndReopen: state.showsQuitAndReopen, appName: appName),
        ]
    }

    /// QA (P2-26): Input Monitoring is "not needed" only while Accessibility is allowed and the tap is not below
    /// the mode Kytkin wants. Whether Accessibility alone allows the active tap on every Mac is still open (P1-17),
    /// so a tap stuck below it keeps Input Monitoring offered as the fallback (001 §6.1 step 4). A watchdog
    /// slow-down is not a permission problem, so it doesn't bring the row back.
    static func accessibilityCoversInputMonitoring(state: MenuState, desired: TapMode) -> Bool {
        guard state.accessibility == .granted else { return false }
        return TapModePolicy.rank(state.tapMode) >= TapModePolicy.rank(desired) || state.degradedByWatchdog
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

    /// The current keyboard mode in plain words (pure, tested).
    static func keyboardModeText(state: MenuState, desired: TapMode) -> String {
        if !state.enabled { return "Kytkin is turned off, so it isn't watching the keyboard." }
        if state.paused { return "Kytkin is paused, so it isn't watching the keyboard." }
        let achieved = state.tapMode
        var text: String
        switch achieved {
        case .active:
            text = "Full: pressing Shift twice fixes text and switches the language."
        case .listenOnly:
            text = "Limited: pressing Shift twice switches the language but can't fix text."
        case .off:
            if desired == .off {
                let anyGrant = state.accessibility == .granted || state.inputMonitoring == .granted
                text = anyGrant
                    ? "Not in use: double-Shift and learning from your typing are turned off."
                    : "Off: allow Accessibility so pressing Shift twice can work. Switching the language for each "
                        + "app works without it."
            } else {
                text = "Off: Kytkin couldn't start watching the keyboard yet."
            }
        }
        if TapModePolicy.rank(achieved) < TapModePolicy.rank(desired) {
            if state.showsQuitAndReopen {
                text += " Quit & Reopen Kytkin to use everything you allowed."
            } else if state.degradedByWatchdog {
                text += " Kytkin turned some keyboard features off because the keyboard was slow to answer. "
                    + "Use “Restart Keyboard Features” in the Kytkin menu."
            } else if achieved != .off {
                text += " Kytkin will try the full mode again when a permission changes."
            }
        }
        return text
    }

    static func secureInputText(state: MenuState) -> String {
        guard state.enabled, !state.paused, state.tapMode != .off else {
            return "Kytkin checks this only while it watches the keyboard."
        }
        return state.secureInputOn
            ? "On: another app is protecting your typing right now (for example a password box). Kytkin won't "
                + "fix text until it ends."
            : "Off: no app is protecting your typing right now."
    }

    static func conflictLines(_ conflicts: Conflicts) -> [String] {
        var lines: [String] = []
        if !conflicts.runningSwitchers.isEmpty {
            let names = conflicts.runningSwitchers.joined(separator: ", ")
            lines.append("\(names) also switches keyboard languages. Please quit it while you use Kytkin.")
        }
        if conflicts.perDocumentInputEnabled {
            lines.append("macOS switches the language for each document by itself, so Kytkin doesn't learn. "
                + "To turn that off: System Settings → Keyboard → Text Input → Edit…, then turn off "
                + "“Automatically switch to a document's input source”.")
        }
        return lines
    }
}

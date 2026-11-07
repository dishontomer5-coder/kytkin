// P2-22: The warnings the menu shows, only when they apply (001 §5.1, §6.2, §12.1 S1), most important first.
// Decided here from MenuState; MenuModel turns each into lines (texts) and an optional action.

import Foundation

enum MenuWarning: Equatable {
    /// Settings → General → "Enable Kytkin" is off.
    case kytkinOff
    /// Input Monitoring was granted while running and the tap stays below it (P2-46): needs a relaunch.
    case quitAndReopen
    /// Accessibility is denied or not asked yet. `toggleStillWorks`: Input Monitoring is granted, so double-Shift
    /// still switches the language (§6.2 listen-only row).
    case accessibilityNeeded(toggleStillWorks: Bool)
    /// Other input switchers running now (display names, e.g. "FlicKey").
    case otherSwitchers([String])
    /// macOS per-document input is on: learning is paused (owner decision P2-38).
    case perDocumentInput
    /// The watchdog lowered the keyboard tap (001 §7 B4). `canRestart`: "Restart Keyboard Features" is offered.
    case keyboardSlowedDown(canRestart: Bool)
    /// Secure Input is on (a password field somewhere). Temporary, so it never marks the label.
    case secureInput
    /// preferences.json is never written this session: from a newer Kytkin, or it couldn't be read.
    case settingsReadOnly(newerVersion: Bool)
    /// The last save failed (cleared by the next successful one).
    case saveFailed
    /// Some settings in the file couldn't be read and were reset; the original is kept at `original` (once saved).
    case settingsPartlyReset(original: URL?)
    /// The file couldn't be decoded; it was moved to `movedTo` and Kytkin started from the defaults.
    case settingsReset(movedTo: URL)

    /// The warnings for `state`, most important first.
    static func list(for state: MenuState) -> [MenuWarning] {
        var out: [MenuWarning] = []
        if !state.enabled { out.append(.kytkinOff) }
        if state.showsQuitAndReopen { out.append(.quitAndReopen) }
        // P2-46: the Settings link for both notDetermined and denied; unknown = not read yet, say nothing.
        if state.accessibility == .denied || state.accessibility == .notDetermined {
            out.append(.accessibilityNeeded(toggleStillWorks: state.inputMonitoring == .granted))
        }
        if !state.conflicts.runningSwitchers.isEmpty { out.append(.otherSwitchers(state.conflicts.runningSwitchers)) }
        if state.conflicts.perDocumentInputEnabled { out.append(.perDocumentInput) }
        if state.degradedByWatchdog { out.append(.keyboardSlowedDown(canRestart: state.canRestartKeyboard)) }
        if state.secureInputOn { out.append(.secureInput) }

        let store = state.store
        if store.isReadOnly {
            out.append(.settingsReadOnly(newerVersion: store.loadIssue == .newerSchemaReadOnly))
        } else if store.lastSaveFailed {
            out.append(.saveFailed)
        }
        if case .corruptQuarantined(let url) = store.loadIssue {
            out.append(.settingsReset(movedTo: url))
        } else if store.loadWasLossy {
            out.append(.settingsPartlyReset(original: store.originalBackupURL))
        }
        return out
    }

    /// The label's dot (001 §5.1): every warning except Secure Input, which comes and goes with each password
    /// field and would make the label flicker.
    var marksLabel: Bool {
        self != .secureInput
    }
}

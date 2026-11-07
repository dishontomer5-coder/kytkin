// P2-20: The values the menu-bar label and menu are built from (001 §5.1). AppController fills it on demand.
// P2-22: + Kytkin on/off, the grants, "Restart Keyboard Features", and the preferences file flags (001 §12.1 S1).
// MenuModel turns it into the label and the menu items.

import Foundation

struct MenuState: Equatable {
    /// The app Kytkin is acting for (never Kytkin itself), its resolution and the scope a Pin writes.
    var currentRule: SwitchController.CurrentRule?
    var paused = false
    /// `general.enabled` (Settings → General → Enable Kytkin).
    var enabled = true
    var tapMode: TapMode = .off
    var secureInputOn = false
    var degradedByWatchdog = false
    /// P2-22: the watchdog lowered the tap and a user-clicked restart could bring it back.
    var canRestartKeyboard = false
    var tapReEnableCount = 0
    /// DEBUG counter for checklist §P2-17 (counts only, never keys).
    var doubleShiftCount = 0
    var conflicts = Conflicts.none
    /// P2-55: DEBUG line about learning (gate, candidate, last decision). IDs and reasons only, never typed text,
    /// site domains or chat keys. MenuModel shows it in Debug builds.
    var learnerDebug: String?
    /// "Quit & Reopen" hint (P2-46).
    var showsQuitAndReopen = false
    /// P2-22: the grants as last read (silently). `.unknown` = not read yet: no warning.
    var accessibility: PermissionState = .unknown
    var inputMonitoring: PermissionState = .unknown
    /// P2-22 (001 §12.1 S1): what happened to preferences.json.
    var store = StoreFlags()

    /// PreferencesStore's flags, copied (001 §2.2 PreferencesStore).
    struct StoreFlags: Equatable {
        var loadIssue: PreferencesLoadIssue?
        var isReadOnly = false
        var lastSaveFailed = false
        var loadWasLossy = false
        var originalBackupURL: URL?
    }
}

// P2-20: The values the menu-bar label and menu are built from (001 §5.1). AppController fills it on demand.
// P2-22: + Kytkin on/off, the grants, "Restart Keyboard Features", and the preferences file flags (001 §12.1 S1).
// MenuModel turns it into the label and the menu items.

import Foundation

struct MenuState: Equatable {
    /// The app Kytkin is acting for (never Kytkin itself), its resolution and the scope a Pin writes.
    var currentRule: SwitchController.CurrentRule?
    /// P6-0c (flows S3): double-Shift is turned off for the app in front (`apps[id].convertEnabled == false`).
    var convertOffInCurrentApp = false
    /// P6-0c: Settings → General → "Show in menu bar".
    var menuBarDisplay: Preferences.General.MenuBarLabel = .iconAndLanguage
    /// P6-0e: the pair as the input sources Kytkin switches to (an imported map's base), so the menu-bar logo fills
    /// the half of the language that is on. nil = unknown.
    var pairInputSources: LanguagePair?
    /// P6-3: a newer release is out (only while the update check is on).
    var updateNotice: UpdateNotice?
    var paused = false
    /// `general.enabled` (Settings → General → Enable Kytkin).
    var enabled = true
    var tapMode: TapMode = .off
    var secureInputOn = false
    var degradedByWatchdog = false
    /// P2-22: a user-clicked restart could bring the tap back up to the desired mode (after a watchdog downgrade, or
    /// P2-57 item 1 any time it runs below).
    var canRestartKeyboard = false
    /// P2-57 item 1 / P2-52 item 2: the tap runs below what the grants and settings want while Kytkin is on and not
    /// paused (`TapModePolicy.runsBelow`): a timed-out start, a failed retry or restart. Never silent.
    var keyboardBelowDesired = false
    var tapReEnableCount = 0
    /// P2-27 (001 §7 B1): DEBUG counter of tap callbacks slower than 1 ms (`TapHealth.overBudgetCallbacks`, counted
    /// only in Debug builds). Counts only, never keys.
    var slowCallbackCount = 0
    /// DEBUG counter for checklist §P2-17 (counts only, never keys).
    var doubleShiftCount = 0
    var conflicts = Conflicts.none
    /// P2-55: DEBUG line about learning (gate, candidate, last decision). IDs and reasons only, never typed text,
    /// site domains or chat keys. MenuModel shows it in Debug builds.
    var learnerDebug: String?
    /// P3-14: DEBUG line about the browser watch (engine, attach, update count, last page state and source). Never a
    /// host, a URL or a title.
    var siteDebug: String?
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

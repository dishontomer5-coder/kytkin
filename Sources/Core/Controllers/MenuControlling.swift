// P2-20: What the menu-bar menu reads and does (001 §5.1). AppController implements it; StatusItemController (UI)
// depends only on this and on `InputSourceSwitching`. P2-22 builds the full menu on these hooks.

import Foundation

struct MenuState: Equatable {
    /// The app Kytkin is acting for (never Kytkin itself), its resolution and the scope a Pin writes.
    var currentRule: SwitchController.CurrentRule?
    var paused = false
    var tapMode: TapMode = .off
    var secureInputOn = false
    var degradedByWatchdog = false
    var tapReEnableCount = 0
    /// DEBUG counter for checklist §P2-17 (counts only, never keys).
    var doubleShiftCount = 0
    var conflicts = Conflicts.none
    /// P2-55: DEBUG line about learning (gate, candidate, last decision). IDs and reasons only, never typed text.
    /// StatusItemController (P2-22) renders it in Debug builds.
    var learnerDebug: String?
    /// "Quit & Reopen" hint (P2-46).
    var showsQuitAndReopen = false
}

@MainActor protocol MenuControlling: AnyObject {
    var menuState: MenuState { get }
    /// From `menuNeedsUpdate` (P2-48): silent, cheap refreshes so warnings are fresh when the menu opens.
    func menuWillOpen()
    func pinCurrent()
    func forgetCurrent()
    func setPaused(_ on: Bool)
    @discardableResult func selectFromMenu(_ id: InputSourceID) -> Bool
}

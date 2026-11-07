// P2-20: What the menu-bar menu reads and does (001 §5.1). AppController implements it; StatusItemController (UI)
// depends only on this and on `InputSourceSwitching`.
// P2-22: the full menu. What it shows is decided by `MenuModel` (Core) from `menuState`; the UI only renders.

import Foundation

@MainActor protocol MenuControlling: AnyObject {
    var menuState: MenuState { get }
    /// From `menuNeedsUpdate` (P2-48): silent, cheap refreshes so warnings are fresh when the menu opens.
    func menuWillOpen()
    func pinCurrent()
    func forgetCurrent()
    func setPaused(_ on: Bool)
    @discardableResult func selectFromMenu(_ id: InputSourceID) -> Bool
    /// P2-22: "Restart Keyboard Features" after a watchdog downgrade (a user click only). Blocks main ≤ 1 s.
    func restartKeyboard()
}

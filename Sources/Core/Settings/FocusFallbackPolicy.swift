// P3-12 (P2-63): When `WindowPresenter`'s one 0.3 s focus fallback may insist with `activate(ignoringOtherApps:)`.
//
// The fallback exists for one case: cooperative activation was refused, so the window Kytkin just showed is on top
// but typing still goes to the app behind. It must not fire when the user has moved on in those 0.3 s (clicked
// another app, ⌘-Tabbed away): taking the keyboard back then is exactly the focus-stealing Kytkin never does.
//
// Facts in, decision out (pids only, read by the UI):
// - the window is gone or already has the keyboard → nothing to do;
// - Kytkin itself is frontmost (activation landed, the window just isn't key yet) → insist, it's ours;
// - the frontmost app is the same one as when the window was shown → the refusal case: insist once;
// - any other frontmost app (or one appeared/vanished) → the user switched: leave it.

import Foundation

enum FocusFallbackPolicy {
    static func shouldInsist(windowVisible: Bool, windowHasKeyboard: Bool, ownPID: Int32,
                             frontmostAtShow: Int32?, frontmostNow: Int32?) -> Bool {
        guard windowVisible, !windowHasKeyboard else { return false }
        if frontmostNow == ownPID { return true }
        return frontmostNow == frontmostAtShow
    }
}

// P4-5 (owner-reproduced 2026-11-18, first real users: double-Shift did nothing in Slack): Electron apps build their
// accessibility tree only after an assistive client sets the application attribute `AXManualAccessibility` to true
// (Electron's documented switch, electronjs.org/docs/latest/tutorial/accessibility, MIT). Until then AX names no
// focused text box in them. Kytkin used to rely on other helper apps (Paste, DockDoor…) having set it.
//
// The seam for that one write. The live adapter (`System/Text/AXManualAccessibilitySetter`) sets
// `AXManualAccessibility = kCFBooleanTrue` on the application element of a pid, with a short messaging timeout; it
// never sets `AXEnhancedUserInterface` (window-manager side effects, R5) and is only ever used for the chat apps
// (`ReplacementCapabilities.chatAppBundleIDs`), never browsers (R3b rule 1). It reads and sends no text.

import Foundation

/// What the one write answered (an enum name for the DEBUG trace; no data from the app).
enum ManualAccessibilityAnswer: String, Sendable, Equatable {
    /// The app accepted the value.
    case set
    /// The app said the attribute is unsupported or failed. Electron versions are known to answer an error and still
    /// turn the tree on, so this counts as done too (it is not asked again for this process).
    case refused
    /// The app didn't answer in time (still launching, busy): asked again next time.
    case noAnswer
    /// Kytkin has no Accessibility grant: nothing was sent.
    case notTrusted
}

protocol ManualAccessibilitySetting: AnyObject, Sendable {
    /// P4-5: sets `AXManualAccessibility = true` on the application element of `pid` (bounded by `timeout` seconds).
    func setManualAccessibility(pid: Int32, timeout: Double) -> ManualAccessibilityAnswer
}

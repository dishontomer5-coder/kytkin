// P2-17: What KeyWatcher tells main about itself (counts and states only, never keys): the tap mode actually
// running and its health counters (001 §7 B1/B4), and whether Secure Input is on (§6.2 "Typing protected by
// another app" hint). Sent on every change.
// P2-20: moved from System/Keyboard to Core so Core controllers (AppController) can take it; unchanged.

import Foundation

struct KeyWatcherStatus: Sendable, Equatable {
    var health = TapHealth()
    var secureInputOn = false
    /// The watchdog lowered the mode (B4): the menu shows a warning.
    var degradedByWatchdog = false

    init() {}
}

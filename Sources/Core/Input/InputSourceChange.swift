// P2-10: What SwitchAttributor reports for one observed input-source change (001 §2.2).
// `ours` = the change Kytkin asked for (expected-switch token matched). `external` = anything else
// (the user, the OS restoring a per-document source, or another switcher). Only `external` changes
// may reach RuleLearner, which rules out feedback loops by construction (R1 §3).
// Lives in Core (not next to InputSourceSwitching in System/Input) because the pure attributor returns it.

import Foundation

enum InputSourceChange: Sendable, Equatable {
    case ours(InputSourceID)
    case external(InputSourceID, atNanos: UInt64)
}

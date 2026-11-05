// P2-8: `convert.doubleShiftSides` in preferences.json uses SidePolicy's raw values (001 §4.2).
// The conformance lives here so Core/Keyboard stays untouched.

import Foundation

extension DoubleShiftConfig.SidePolicy: Codable {}

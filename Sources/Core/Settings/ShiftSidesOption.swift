// P2-25: The choices of Settings → Convert "Which Shift keys" (001 §4.2 `convert.doubleShiftSides`). The tab offers
// same side (the default) and either side. Left only / right only exist in the file format; a file that has one
// still shows it, so the picker never goes blank or changes the setting by itself.

import Foundation

struct ShiftSidesOption: Identifiable, Equatable, Sendable {
    let sides: DoubleShiftConfig.SidePolicy
    let title: String

    var id: String { sides.rawValue }

    static func options(current: DoubleShiftConfig.SidePolicy) -> [ShiftSidesOption] {
        var result = [ShiftSidesOption(sides: .sameSide, title: title(of: .sameSide)),
                      ShiftSidesOption(sides: .either, title: title(of: .either))]
        if current == .leftOnly || current == .rightOnly {
            result.append(ShiftSidesOption(sides: current, title: title(of: current)))
        }
        return result
    }

    static func title(of sides: DoubleShiftConfig.SidePolicy) -> String {
        switch sides {
        case .sameSide: "Same Shift Twice"   // P6-0c (copy review C-2); P6-0g: title case (mock-up)
        case .either: "Either Shift"
        case .leftOnly: "Left Shift Only"
        case .rightOnly: "Right Shift Only"
        }
    }
}

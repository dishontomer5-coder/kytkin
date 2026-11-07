// P2-23: The choices of General → "When an app has no rule" (001 §5.2): leave the language alone (the default,
// 001 §11 Q3), or switch to one of the enabled layouts. A saved layout that isn't enabled any more is still listed,
// so the picker never shows a blank or silently changes the setting.

import Foundation

struct DefaultBehaviorOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let behavior: DefaultBehavior

    static let keepCurrentID = "keepCurrent"

    static func id(for behavior: DefaultBehavior) -> String {
        switch behavior {
        case .keepCurrent: keepCurrentID
        case .switchTo(let source): "switchTo:" + source.rawValue
        }
    }

    /// Keep current first, then each enabled source (in the given order, duplicates dropped), then the saved one if
    /// it isn't among them.
    static func options(current: DefaultBehavior, sources: [InputSourceInfo]) -> [DefaultBehaviorOption] {
        var result = [DefaultBehaviorOption(id: keepCurrentID, title: "Leave the language as it is",
                                            behavior: .keepCurrent)]
        var seen = Set<InputSourceID>()
        for s in sources where s.isEnabled && !s.id.rawValue.isEmpty && seen.insert(s.id).inserted {
            let name = s.name.isEmpty ? fallbackName(s.id) : s.name
            result.append(DefaultBehaviorOption(id: id(for: .switchTo(s.id)), title: "Switch to \(name)",
                                                behavior: .switchTo(s.id)))
        }
        if case .switchTo(let saved) = current, !seen.contains(saved) {
            result.append(DefaultBehaviorOption(id: id(for: current),
                                                title: "Switch to \(fallbackName(saved)) (not turned on)",
                                                behavior: current))
        }
        return result
    }

    /// "com.apple.keylayout.Hebrew-QWERTY" → "Hebrew-QWERTY".
    static func fallbackName(_ id: InputSourceID) -> String {
        id.rawValue.split(separator: ".").last.map(String.init) ?? id.rawValue
    }
}

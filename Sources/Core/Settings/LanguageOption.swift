// P2-25: One choice in a language picker (Settings → Rules "Language"): an input source and its name.

import Foundation

struct LanguageOption: Identifiable, Equatable, Sendable {
    let id: InputSourceID
    let name: String

    /// The pair first, then the other enabled layouts (in the given order), then `current` if it is none of them,
    /// so a rule's saved language is always listed. Duplicates and empty ids are dropped.
    static func options(pair: LanguagePair, sources: [InputSourceInfo], current: InputSourceID? = nil)
        -> [LanguageOption] {
        var result: [LanguageOption] = []
        var seen = Set<InputSourceID>()
        var ids: [(InputSourceID, String)] = []
        func add(_ id: InputSourceID, suffix: String = "") {
            guard !id.rawValue.isEmpty, seen.insert(id).inserted else { return }
            ids.append((id, suffix))
        }
        add(pair.a)
        add(pair.b)
        for s in sources where s.isEnabled { add(s.id) }
        if let current { add(current, suffix: " (not turned on)") }
        // P6-0g: "English", "Hebrew"; two layouts of one language are told apart by the layout ("English (ABC)").
        let names = ids.map { name(of: $0.0, in: sources) }
        for (i, (id, suffix)) in ids.enumerated() {
            let clash = names.filter { $0 == names[i] }.count > 1
            result.append(LanguageOption(id: id, name: (clash ? pickerTitle(of: id, in: sources) : names[i]) + suffix))
        }
        return result
    }

    /// P6-0g: the language's name ("English", "Hebrew") from `sources` (enabled or not), else the last part of its id.
    static func name(of id: InputSourceID, in sources: [InputSourceInfo]) -> String {
        if let s = sources.first(where: { $0.id == id }) { return LanguageNames.friendly(s) }
        return DefaultBehaviorOption.fallbackName(id)
    }

    /// P6-0g: "English (ABC)".
    static func pickerTitle(of id: InputSourceID, in sources: [InputSourceInfo]) -> String {
        if let s = sources.first(where: { $0.id == id }) { return LanguageNames.pickerTitle(s) }
        return DefaultBehaviorOption.fallbackName(id)
    }
}

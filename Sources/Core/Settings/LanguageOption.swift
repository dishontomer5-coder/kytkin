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
        func add(_ id: InputSourceID, suffix: String = "") {
            guard !id.rawValue.isEmpty, seen.insert(id).inserted else { return }
            result.append(LanguageOption(id: id, name: name(of: id, in: sources) + suffix))
        }
        add(pair.a)
        add(pair.b)
        for s in sources where s.isEnabled { add(s.id) }
        if let current { add(current, suffix: " (not turned on)") }
        return result
    }

    /// The source's name from `sources` (enabled or not), else the last part of its id.
    static func name(of id: InputSourceID, in sources: [InputSourceInfo]) -> String {
        if let s = sources.first(where: { $0.id == id }), !s.name.isEmpty { return s.name }
        return DefaultBehaviorOption.fallbackName(id)
    }
}

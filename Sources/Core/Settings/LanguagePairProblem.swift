// P2-24: Why a language pair can't be saved (001 §5.2): both sides the same, a side that can't convert, or two
// choices that type with the same keyboard (an imported map over Hebrew paired with Hebrew). Plain-English messages.

import Foundation

enum LanguagePairProblem: Equatable, Sendable {
    case sameLanguage
    /// Not in the list, an input method, missing, or an imported map whose keyboard isn't installed.
    case notConvertible(String)
    /// Both choices switch to the same input source.
    case sameKeyboard(String)

    var message: String {
        switch self {
        case .sameLanguage: "Choose two different languages."
        // P6-0c (copy review L-5, L-6): no "keyboard layout" / "input method" jargon.
        case .notConvertible(let name):
            "\(name) can’t be converted, because it’s not a plain keyboard (like Pinyin). Choose another language."
        case .sameKeyboard(let name):
            "Both use the \(name) keyboard, so there’s nothing to convert. Choose two different languages."
        }
    }

    /// nil = the pair is valid. `options` is the picker's list (`LanguagePairOption.options`).
    static func check(_ pair: LanguagePair, options: [LanguagePairOption],
                      name: (InputSourceID) -> String) -> LanguagePairProblem? {
        guard pair.a != pair.b else { return .sameLanguage }
        var sources: [InputSourceID] = []
        for id in [pair.a, pair.b] {
            guard let option = options.first(where: { $0.id == id }), option.isSelectable,
                  let source = option.inputSource else {
                return .notConvertible(options.first { $0.id == id }?.name ?? DefaultBehaviorOption.fallbackName(id))
            }
            sources.append(source)
        }
        if sources[0] == sources[1] { return .sameKeyboard(name(sources[0])) }
        return nil
    }
}

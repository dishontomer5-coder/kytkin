// P3-29 (plan.md decision 2026-11-08, owner): which input source the browser's address bar gets when the browser
// has no app rule: "English", meaning the Latin-script member of the active language pair. URLs and searches typed
// in the address bar are mostly Latin text.
//
//   - A member counts as Latin when its language code's likely script is Latn (Foundation's
//     `Locale.Language(identifier:).script`: "en" → Latn, "he" → Hebr, "ru" → Cyrl). ABC and U.S. count as Latin
//     even when their info isn't listed.
//   - Both Latin (e.g. French ⇄ German): the English one if there is one, else member A.
//   - Neither Latin (e.g. Hebrew ⇄ Russian): nil. The address bar then keeps the normal default (`DefaultBehavior`).
//   - An imported map in the pair switches to its installed base, like convert does (`inputSource`).
// Pure; the caller passes what it knows about the layouts.

import Foundation

enum AddressBarLanguage {
    static func latinSource(pair: LanguagePair, layouts: [InputSourceInfo],
                            inputSource: (InputSourceID) -> InputSourceID? = { $0 }) -> InputSourceID? {
        let members = [pair.a, pair.b]
        let language = { (id: InputSourceID) -> String? in layouts.first(where: { $0.id == id })?.languageCode }
        let latin = members.filter { id in
            if let code = language(id), !code.isEmpty { return isLatinScript(languageCode: code) }
            return id == DefaultLanguagePair.abc || id == DefaultLanguagePair.us
        }
        let english = latin.first { id in
            (language(id) ?? "").lowercased().hasPrefix("en") || id == DefaultLanguagePair.abc
                || id == DefaultLanguagePair.us
        }
        guard let pick = english ?? latin.first else { return nil }
        return inputSource(pick)
    }

    /// The language's likely script is Latin ("en", "fr", "tr", "en-US"; not "he", "ru", "ja", "sr").
    static func isLatinScript(languageCode: String) -> Bool {
        let code = languageCode.replacingOccurrences(of: "_", with: "-")
        guard !code.isEmpty else { return false }
        return Locale.Language(identifier: code).script?.identifier == "Latn"
    }
}

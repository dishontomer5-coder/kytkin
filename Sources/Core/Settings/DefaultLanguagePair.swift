// P2-26 / P2-62: the language pair the welcome window starts with, chosen from the keyboard layouts that are
// actually turned on (001 §6.1 step 2). The shipped default (ABC ⇄ Hebrew) may name a layout this Mac doesn't use.
//
//   1. A turned-on Hebrew layout ⇄ ABC (else U.S.), when both are turned on: (ABC/US, Hebrew), like the default.
//   2. Otherwise a turned-on Hebrew layout ⇄ the first other turned-on English layout (British, Australian…), so a
//      Hebrew user with a different English keyboard still gets Hebrew ⇄ English.
//   3. Otherwise the first two turned-on convertible layouts, in the system's order.
//   4. Fewer than two: nil (keep what is saved; Settings → Languages explains what's missing).
// Pure; the caller passes the turned-on convertible layouts (input methods can't convert and are skipped here too).

import Foundation

enum DefaultLanguagePair {
    static let abc = InputSourceID("com.apple.keylayout.ABC")
    static let us = InputSourceID("com.apple.keylayout.US")

    static func suggest(enabled layouts: [InputSourceInfo]) -> LanguagePair? {
        var seen = Set<InputSourceID>()
        let usable = layouts.filter { $0.isEnabled && $0.isConvertible && !$0.isInputMethod
            && !$0.id.rawValue.isEmpty && seen.insert($0.id).inserted }
        if let hebrew = usable.first(where: isHebrew) {
            let ids = Set(usable.map(\.id))
            if let latin = [abc, us].first(where: ids.contains) {
                return LanguagePair(a: latin, b: hebrew.id)
            }
            if let english = usable.first(where: { $0.id != hebrew.id && isEnglish($0) }) {
                return LanguagePair(a: english.id, b: hebrew.id)
            }
        }
        guard usable.count >= 2 else { return nil }
        return LanguagePair(a: usable[0].id, b: usable[1].id)
    }

    static func isHebrew(_ info: InputSourceInfo) -> Bool {
        info.languageCode.lowercased() == "he" || info.id.rawValue.hasPrefix("com.apple.keylayout.Hebrew")
    }

    static func isEnglish(_ info: InputSourceInfo) -> Bool {
        info.languageCode.lowercased().hasPrefix("en")
    }
}

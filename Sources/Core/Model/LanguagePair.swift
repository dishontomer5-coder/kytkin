// P2-8: The two layouts Kytkin converts between, A ⇄ B (001 §2.2, Core/Model), persisted as
// preferences.json `languagePair` (001 §4.2). Created here because Preferences needs it.
// The stored default is ABC ⇄ Hebrew. Onboarding (P2-24/P2-26) picks the actually enabled layouts.

import Foundation

struct LanguagePair: Codable, Sendable, Equatable {
    var a: InputSourceID
    var b: InputSourceID

    init(a: InputSourceID, b: InputSourceID) {
        self.a = a
        self.b = b
    }

    static let `default` = LanguagePair(a: InputSourceID("com.apple.keylayout.ABC"),
                                        b: InputSourceID("com.apple.keylayout.Hebrew"))

    /// The other half of the pair, or nil if `id` isn't in it.
    func other(than id: InputSourceID) -> InputSourceID? {
        if id == a { return b }
        if id == b { return a }
        return nil
    }
}

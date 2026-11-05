// P0-5: Pure mapping from an input source's language list to the short menu-bar label.
// No system calls here, so it is unit-tested in KytkinTests.

import Foundation // trimmingCharacters(in:); don't rely on other files' imports

enum InputSourceLabel {
    /// Shown when the input source reports no usable language.
    static let unknown = "?"

    /// Returns the first language's base code, uppercased.
    /// `["en"]` → "EN", `["he"]` → "HE", `["en-US"]` → "EN", `[]` → "?".
    static func label(forLanguages languages: [String]) -> String {
        guard let first = languages.first else { return unknown }
        let base = first
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? unknown : base.uppercased()
    }
}

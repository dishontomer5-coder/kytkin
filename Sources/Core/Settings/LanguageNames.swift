// P6-0g (design v2 review, "Across the app" P1): one name per language everywhere: "English" and "Hebrew", from the
// input source's language, never the layout's name ("ABC"). The layout name shows only inside the language pickers,
// as "English (ABC)". An imported layout keeps the name its file gives it (the user chose it), and a source with no
// usable language keeps its own name.

import Foundation

enum LanguageNames {
    /// English names for every language code (the app's UI is English).
    private static let english = Locale(identifier: "en_US")

    /// "English" for ABC / U.S. ("en"), "Hebrew" for Hebrew and Hebrew-QWERTY ("he"); an imported layout's own name.
    static func friendly(id: InputSourceID, name: String, languageCode: String) -> String {
        let fallback = name.isEmpty ? DefaultBehaviorOption.fallbackName(id) : name
        if isImported(id) { return fallback }
        return languageName(languageCode) ?? fallback
    }

    static func friendly(_ info: InputSourceInfo) -> String {
        friendly(id: info.id, name: info.name, languageCode: info.languageCode)
    }

    /// The pickers' title: "English (ABC)"; just the name when it already says the language ("Hebrew").
    static func pickerTitle(id: InputSourceID, name: String, languageCode: String) -> String {
        let layout = name.isEmpty ? DefaultBehaviorOption.fallbackName(id) : name
        let language = friendly(id: id, name: name, languageCode: languageCode)
        return language == layout ? layout : "\(language) (\(layout))"
    }

    static func pickerTitle(_ info: InputSourceInfo) -> String {
        pickerTitle(id: info.id, name: info.name, languageCode: info.languageCode)
    }

    /// "en" / "en-US" / "he_IL" → "English" / "Hebrew"; nil for an empty or unknown code.
    static func languageName(_ code: String) -> String? {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !base.isEmpty, let name = english.localizedString(forLanguageCode: base), !name.isEmpty,
              name.lowercased() != base.lowercased() else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Imported layout ids start with "user." (ImportedLayoutStore).
    static func isImported(_ id: InputSourceID) -> Bool {
        id.rawValue.hasPrefix("user.")
    }
}

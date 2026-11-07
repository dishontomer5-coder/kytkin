// P2-25: The choices of Settings → Apps "How Kytkin replaces text" (001 §4.2 `apps.*.replacementMethod`, §12 T1/T3).
// "Default" stores nothing, so Kytkin's built-in choice for the app applies (for example Terminal for terminals);
// any other choice is stored and wins over the built-in one (001 §12 T5 → MethodHint).

import Foundation

struct AppMethodOption: Identifiable, Equatable, Sendable {
    /// `defaultID`, or a `ReplacementMethod` raw value.
    let id: String
    let title: String
    /// nil = no override.
    let method: Preferences.AppOverride.ReplacementMethod?

    static let defaultID = "default"

    static func id(for method: Preferences.AppOverride.ReplacementMethod?) -> String {
        method?.rawValue ?? defaultID
    }

    /// "Default (…)" first, then every method in a fixed order.
    /// P2-25 QA (001 §12 T1): a built-in terminal offers only "Default (Terminal)": any other method would type a
    /// "converted" selection at the shell prompt, and `ReplacementCapabilities` keeps terminals on `.terminal`
    /// anyway. A method a hand-edited file stored is still listed (marked as not used), so the picker never goes
    /// blank and never changes the file by itself.
    static func options(for bundleID: String,
                        current: Preferences.AppOverride.ReplacementMethod? = nil) -> [AppMethodOption] {
        let builtIn = ReplacementCapabilities().seedMethod(for: bundleID)
        var result = [AppMethodOption(id: defaultID, title: "Default (\(title(of: builtIn)))", method: nil)]
        if builtIn == .terminal {
            if let current {
                let suffix = current == .terminal ? "" : " (not used in terminals)"
                result.append(AppMethodOption(id: current.rawValue, title: title(of: current) + suffix,
                                              method: current))
            }
            return result
        }
        let order: [Preferences.AppOverride.ReplacementMethod] = [.auto, .keysOnly, .noUnicode, .preferPaste, .terminal]
        for m in order {
            result.append(AppMethodOption(id: m.rawValue, title: title(of: m), method: m))
        }
        return result
    }

    static func title(of method: Preferences.AppOverride.ReplacementMethod) -> String {
        switch method {
        case .auto: "Auto"
        case .keysOnly: "Keys only"
        case .noUnicode: "No Unicode"
        // Paste is Phase 3 (P3-8); until then it works like Auto (MethodHint.preferPaste).
        case .preferPaste: "Prefer paste (coming later, works like Auto for now)"
        case .terminal: "Terminal"
        }
    }

    static func title(of hint: MethodHint) -> String {
        switch hint {
        case .auto: "Auto"
        case .keysOnly: "Keys only"
        case .noUnicode: "No Unicode"
        case .preferPaste: "Prefer paste"
        case .terminal: "Terminal"
        case .disabled: "Off"
        }
    }

    /// One line under the picker explaining the current choice.
    static func explanation(of hint: MethodHint) -> String {
        switch hint {
        case .auto: "Auto: replaces text directly when the app allows it, otherwise types the new text."
        case .keysOnly: "Keys only: always types the new text (for browsers, Electron apps and code editors)."
        case .noUnicode: "No Unicode: for remote desktops and virtual machines that ignore typed characters."
        case .preferPaste: "Prefer paste: coming in a later version. Works like Auto for now."
        case .terminal: "Terminal: types the new text, and never converts a selection (it would type at the prompt)."
        case .disabled: "Converting is off in this app."
        }
    }
}

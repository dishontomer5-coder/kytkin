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
    /// P6-0c (copy review A-4, B4): plain names; "Prefer paste" (does nothing yet) is listed only when the file
    /// already holds it. Kytkin's own built-in choice reads "Automatic" (Slack's built-in Keys only still uses the
    /// clipboard, so "Keys only" there was wrong).
    static func options(for bundleID: String,
                        current: Preferences.AppOverride.ReplacementMethod? = nil) -> [AppMethodOption] {
        let builtIn = ReplacementCapabilities().seedMethod(for: bundleID)
        var result = [AppMethodOption(id: defaultID, title: "Default (\(builtInTitle(of: builtIn)))", method: nil)]
        if builtIn == .terminal {
            if let current {
                let suffix = current == .terminal ? "" : " (not used in terminals)"
                result.append(AppMethodOption(id: current.rawValue, title: title(of: current) + suffix,
                                              method: current))
            }
            return result
        }
        var order: [Preferences.AppOverride.ReplacementMethod] = [.auto, .keysOnly, .noUnicode, .terminal]
        if current == .preferPaste { order.insert(.preferPaste, at: 3) }
        for m in order {
            result.append(AppMethodOption(id: m.rawValue, title: title(of: m), method: m))
        }
        return result
    }

    static func title(of method: Preferences.AppOverride.ReplacementMethod) -> String {
        switch method {
        case .auto: "Automatic"
        case .keysOnly: "Type the new text"
        case .noUnicode: "Type key by key"
        // Paste is not built yet; it works like Automatic (MethodHint.preferPaste).
        case .preferPaste: "Prefer paste (works like Automatic for now)"
        case .terminal: "Terminal"
        }
    }

    /// P6-0c (B4): Kytkin's own choice for an app, as the "Default (…)" option names it.
    static func builtInTitle(of hint: MethodHint) -> String {
        switch hint {
        case .auto, .keysOnly, .preferPaste: "Automatic"
        case .noUnicode: "Type key by key"
        case .terminal: "Terminal"
        case .disabled: "Off"
        }
    }

    static func title(of hint: MethodHint) -> String {
        switch hint {
        case .auto: "Automatic"
        case .keysOnly: "Type the new text"
        case .noUnicode: "Type key by key"
        case .preferPaste: "Prefer paste"
        case .terminal: "Terminal"
        case .disabled: "Off"
        }
    }

    /// One line under the picker explaining the current choice. `userChosen`: the user picked it (not "Default").
    /// P6-0c (copy review A-5…A-8, B4): Kytkin's built-in choice (other than Terminal) is "Automatic", which may use
    /// the clipboard; only a user's own "Type the new text" promises never to.
    static func explanation(of hint: MethodHint, userChosen: Bool = true) -> String {
        if !userChosen, hint == .keysOnly || hint == .auto || hint == .preferPaste { return automaticText }
        switch hint {
        case .auto: return automaticText
        case .keysOnly: return "Type the new text: Kytkin deletes the old text and types the new. It never uses the "
            + "clipboard in this app."
        case .noUnicode: return "Type key by key: for remote desktops and virtual machines."
        case .preferPaste: return "Prefer paste: not available yet. Works like Automatic for now."
        case .terminal: return "Terminal: types the new text on the current line. It never presses Return."
        case .disabled: return "Converting is off in this app."
        }
    }

    static let automaticText = "Automatic: Kytkin picks the best way for this app."
}

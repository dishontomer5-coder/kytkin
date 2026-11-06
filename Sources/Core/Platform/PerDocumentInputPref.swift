// P2-19: Maps macOS's per-document input preference to on/off (research input-source-switching.md §4).
// The System adapter reads the raw value READ-ONLY with CFPreferencesCopyAppValue and hands it here;
// Kytkin never writes this preference (design.md: never change system settings).
//
// Where it lives: System Settings → Keyboard → Input Sources → Edit… → "Automatically switch to a
// document's input source" is stored under the key `TextInputGlobalPropertyPerContextInput` (the string is
// in KeyboardSettings.appex) inside the `AppleGlobalTextInputProperties` dictionary of `com.apple.HIToolbox`.
// Observed on the owner's Mac (2026-11-06, setting off = macOS default): the dictionary doesn't exist at
// all, in `com.apple.HIToolbox` or in the global domain. The "on" value hasn't been seen on disk yet
// (research open question 1); the expected form is `{ TextInputGlobalPropertyPerContextInput = 1; }`.
// So the mapping is lenient: any true-ish value means on; absent or anything unrecognized means off
// (the default, and it never pauses learning by mistake). The adapter also reads the global domain in case
// a macOS version keeps it there; either one being on counts.

import Foundation

enum PerDocumentInputPref {
    static let domain = "com.apple.HIToolbox"
    static let dictionaryKey = "AppleGlobalTextInputProperties"
    static let flagKey = "TextInputGlobalPropertyPerContextInput"

    /// `dictionary` is the raw `AppleGlobalTextInputProperties` value (nil when the key doesn't exist).
    static func isEnabled(_ dictionary: Any?) -> Bool {
        guard let dict = dictionary as? [String: Any] else { return false }
        return isTrue(dict[flagKey])
    }

    /// The HIToolbox domain's value and the global domain's value; on if either is on.
    static func isEnabled(hiToolbox: Any?, global: Any?) -> Bool {
        isEnabled(hiToolbox) || isEnabled(global)
    }

    /// Bool/NSNumber true or non-zero, or the strings "1"/"true"/"yes" (any case). Everything else is false.
    static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let i as Int: return i != 0
        case let s as String:
            return ["1", "true", "yes"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        default: return false
        }
    }
}

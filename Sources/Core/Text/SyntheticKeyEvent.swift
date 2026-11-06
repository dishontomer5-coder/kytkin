// P2-18: One key event Kytkin posts as replacement text (001 §2.2, R5 §B). Only two shapes exist: a Backspace,
// or a Unicode string on a neutral key code. Both always carry the `ours` marker and no modifier flags (the user
// may still hold Shift right after a double-Shift). There is no way to build a Return, Tab or other control key.

import Foundation

struct SyntheticKeyEvent: Sendable, Equatable {
    /// R5: the key code a Unicode event rides on. Apps that ignore the Unicode string see `a`, so those apps
    /// (`MethodHint.noUnicode`) never get typing steps.
    static let unicodeKeyCode: UInt16 = 0
    /// 001 §10 P2-18: at most 16 UTF-16 units per event (the API takes ~20; longer text is chunked).
    static let maxUnicodeUnits = 16

    let keyCode: UInt16
    let isKeyDown: Bool
    /// UTF-16 units to type. Empty for a Backspace.
    let unicode: [UInt16]
    /// `eventSourceUserData`. Always `EventOrigin.oursMarker`, so our own tap ignores the event (design.md).
    let marker: Int64
    /// Modifier flags to post with. Always 0: flags are cleared on every event.
    let modifierFlags: UInt64

    private init(keyCode: UInt16, isKeyDown: Bool, unicode: [UInt16]) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.unicode = unicode
        marker = EventOrigin.oursMarker
        modifierFlags = 0
    }

    static func backspace(keyDown: Bool) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: KeyCode.delete, isKeyDown: keyDown, unicode: [])
    }

    /// nil if the units are empty, too long, or hold a control/line-break character (design.md invariant).
    static func text(_ units: [UInt16], keyDown: Bool) -> SyntheticKeyEvent? {
        let e = SyntheticKeyEvent(keyCode: unicodeKeyCode, isKeyDown: keyDown, unicode: units)
        return e.isSafeToPost ? e : nil
    }

    /// The last check before posting, repeated by the live poster: a marked Backspace, or a marked Unicode
    /// event whose text is 1…16 units with no Cc/Zl/Zp character. Nothing else may be posted.
    var isSafeToPost: Bool {
        guard marker == EventOrigin.oursMarker, modifierFlags == 0 else { return false }
        switch keyCode {
        case KeyCode.delete:
            return unicode.isEmpty
        case Self.unicodeKeyCode:
            guard (1...Self.maxUnicodeUnits).contains(unicode.count) else { return false }
            let text = String(decoding: unicode, as: UTF16.self)
            // A lone surrogate decodes to U+FFFD; refuse it rather than type a replacement character.
            guard Array(text.utf16) == unicode else { return false }
            return !ReplacementPlanner.containsUnsafeCharacter(text)
        default:
            return false
        }
    }
}

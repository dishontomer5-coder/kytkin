// P2-18: One key event Kytkin posts as replacement text (001 §2.2, R5 §B). Only two shapes exist: a Backspace,
// or a Unicode string on a neutral key code. Both always carry the `ours` marker and no modifier flags (the user
// may still hold Shift right after a double-Shift). There is no way to build a Return, Tab or other control key.
// P3-37 / P3-62: three more shapes, for the clipboard convert in unreadable non-terminal apps only: ⌘C / ⌘V (Command
// and nothing else, on the two ANSI keys, no text), ⇧⌘↑ (Up arrow, Shift + Command, no text: selects from the cursor
// to the box's start) and a plain Right arrow (drops the selection, caret at its end).
// Still never a Return, Tab, Escape, ⌃C or any other key.

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

    /// P3-37: CGEventFlags.maskCommand (bit 20).
    static let commandFlag: UInt64 = 0x0010_0000
    /// P3-62: CGEventFlags.maskShift (bit 17), only ever with Command on the Up arrow (`selectToStart`).
    static let shiftFlag: UInt64 = 0x0002_0000

    private init(keyCode: UInt16, isKeyDown: Bool, unicode: [UInt16], modifierFlags: UInt64 = 0) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.unicode = unicode
        marker = EventOrigin.oursMarker
        self.modifierFlags = modifierFlags
    }

    /// P3-37: ⌘C / ⌘V for the clipboard convert (P3-62: ⌘A removed). Command only, no text.
    static func shortcut(_ s: ClipboardShortcut, keyDown: Bool) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: s.keyCode, isKeyDown: keyDown, unicode: [], modifierFlags: commandFlag)
    }

    /// P3-62 (owner 2026-11-17: no selection → the text from the start of the box up to the cursor): ⇧⌘↑, "select to
    /// the beginning of the document" in Cocoa text views, Chromium and Gecko text boxes. The anchor stays at the cursor.
    static func selectToStart(keyDown: Bool) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: KeyCode.upArrow, isKeyDown: keyDown, unicode: [],
                          modifierFlags: commandFlag | shiftFlag)
    }

    /// P3-37: a plain Right arrow, to drop the copy selection when nothing is pasted (P3-62: the caret goes back to the
    /// selection's end, where the cursor was).
    static func rightArrow(keyDown: Bool) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: KeyCode.rightArrow, isKeyDown: keyDown, unicode: [])
    }

    static func backspace(keyDown: Bool) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: KeyCode.delete, isKeyDown: keyDown, unicode: [])
    }

    /// nil if the units are empty, too long, or hold a control/line-break character (design.md invariant).
    static func text(_ units: [UInt16], keyDown: Bool) -> SyntheticKeyEvent? {
        let e = SyntheticKeyEvent(keyCode: unicodeKeyCode, isKeyDown: keyDown, unicode: units)
        return e.isSafeToPost ? e : nil
    }

    /// P3-55: U+FFFC, U+FFFD, or an emoji grapheme: one with an emoji-presentation scalar, VS16, a keycap, or a ZWJ
    /// joining emoji. P3-55 QA: *not* text symbols a layout types (`™` ⌥2, `☺`, arrows: emoji-capable but text-presented
    /// by default), nor a lone ZWJ / ZWNJ / bidi mark an imported layout may produce.
    static func holdsObject(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { $0.value == 0xFFFC || $0.value == 0xFFFD }) { return true }
        return text.contains { c in
            let s = c.unicodeScalars
            if s.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }) {
                return true
            }
            return s.contains { $0.value == 0x200D } && s.contains { $0.value >= 0x2100 && $0.properties.isEmoji }
        }
    }

    /// The last check before posting, repeated by the live poster: a marked Backspace, or a marked Unicode
    /// event whose text is 1…16 units with no Cc/Zl/Zp character. Nothing else may be posted.
    var isSafeToPost: Bool {
        guard marker == EventOrigin.oursMarker else { return false }
        // P3-37: Command goes only with ⌘C / ⌘V and no text. P3-62: Shift + Command only with the Up arrow (⇧⌘↑).
        if modifierFlags == Self.commandFlag {
            return unicode.isEmpty && ClipboardShortcut.allCases.contains { $0.keyCode == keyCode }
        }
        if modifierFlags == Self.commandFlag | Self.shiftFlag {
            return unicode.isEmpty && keyCode == KeyCode.upArrow
        }
        guard modifierFlags == 0 else { return false }
        switch keyCode {
        case KeyCode.rightArrow:
            return unicode.isEmpty   // P3-37
        case KeyCode.delete:
            return unicode.isEmpty
        case Self.unicodeKeyCode:
            guard (1...Self.maxUnicodeUnits).contains(unicode.count) else { return false }
            let text = String(decoding: unicode, as: UTF16.self)
            // A lone surrogate decodes to U+FFFD; refuse it rather than type a replacement character.
            guard Array(text.utf16) == unicode else { return false }
            // P3-55 (owner, Slack: a typed copy of the box held a literal U+FFFC): never type an object (U+FFFC, U+FFFD,
            // an emoji or a picture symbol): a conversion never produces one, so one here means the text came from a
            // read of the box, not from the user's keys.
            guard !Self.holdsObject(text) else { return false }
            return !ReplacementPlanner.containsUnsafeCharacter(text)
        default:
            return false
        }
    }
}

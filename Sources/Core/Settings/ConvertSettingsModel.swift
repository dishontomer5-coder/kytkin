// P2-25: The logic behind Settings → Convert (001 §5.2 "Convert & Fix", P2 part), so the SwiftUI view stays thin.
//
// - Double-Shift on/off, which Shift keys, the window (a slider clamped to 200–500 ms, P2-31) and "Switch language
//   after converting" (001 §11 Q1) read and write `prefs.convert`. AppController observes the store and sends the
//   new tap config with `KeyWatcherOperation.updateConfig` (P2-50), so a change works at once, without a restart.
// - The explanation says what double-Shift does: the selection, or the text before the cursor (P3-62), again =
//   convert back (P3-40). P6-0c: rewritten per the copy review (C-1), four short lines.
// - Auto-fix is Phase 4: the tab shows only a "coming later" line, never a control.
// - Read-only preferences (§12 S1): every setter does nothing and the notice says why.

import Foundation
import Observation

@MainActor @Observable final class ConvertSettingsModel {
    @ObservationIgnored private let store: PreferencesStore

    static let windowRangeMs = Preferences.Convert.windowRangeMs
    static let windowStepMs = 10
    static let sliderRange = Double(windowRangeMs.lowerBound)...Double(windowRangeMs.upperBound)

    /// P6-0c (copy review C-1, P1): what double-Shift does since P3-62 (up to the cursor) and P3-40 (again = back).
    /// Hebrew samples are wrapped in FSI/PDI so bidi never flips the punctuation (copy review B7).
    static let explanation = [
        "Typed in the wrong language? Press Shift twice. For example, akuo becomes \u{2068}שלום\u{2069}.",
        "With text selected, Kytkin converts only the selection. With nothing selected, it converts what's before "
            + "the cursor, back to the start of the box. Text already in the right language stays.",
        "Press Shift twice again to convert it back. You can also undo with ⌘Z.",
        "In terminals, Kytkin converts what you typed since you last pressed Return. Where it can't convert, "
            + "double-Shift just switches the language.",
    ]

    /// P6-0c: the one-line summary shown under the main switch (the rest sits behind "How it works").
    static let summary = "Typed in the wrong language? Press Shift twice to convert it."

    /// P3-37; P6-0c (copy review C-3).
    static let clipboardTitle = "Convert through the clipboard when needed"

    /// P3-37: the caption under the clipboard toggle. P6-0c (copy review C-4, P3-18 audit M1 disclosure, P1).
    static let clipboardNote = "In apps Kytkin can't read directly (like Slack, VS Code and Chrome), it copies the "
        + "text, pastes it back converted, then puts back what you had copied. In Slack, Discord and Teams, bold or "
        + "italic in that message may become plain text. Clipboard history apps (like Maccy, Raycast or Alfred) may "
        + "briefly see the copied text and save it. If you use one, you may want to turn this off. It's never used in "
        + "terminals, in password boxes, or while you have a password copied."

    /// P6-0c (copy review C-5).
    static let autoFixNote = "Coming later: converting wrong-language words by itself as you type."

    init(store: PreferencesStore) {
        self.store = store
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    var doubleShiftEnabled: Bool {
        get { store.prefs.convert.doubleShiftEnabled }
        set { write { $0.convert.doubleShiftEnabled = newValue } }
    }

    var sidesOptions: [ShiftSidesOption] {
        ShiftSidesOption.options(current: store.prefs.convert.doubleShiftSides)
    }

    /// A `ShiftSidesOption.id`. Unknown ids are ignored.
    var sidesID: String {
        get { store.prefs.convert.doubleShiftSides.rawValue }
        set {
            guard let option = sidesOptions.first(where: { $0.id == newValue }) else { return }
            write { $0.convert.doubleShiftSides = option.sides }
        }
    }

    /// The slider's value in milliseconds. Rounded to a whole millisecond and clamped to 200–500 on write.
    var windowMs: Double {
        get { Double(store.prefs.convert.doubleShiftWindowMs) }
        set {
            guard newValue.isFinite else { return }
            let ms = Preferences.Convert.clampedWindow(Int(min(max(newValue.rounded(), -1e9), 1e9)))
            write { $0.convert.doubleShiftWindowMs = ms }
        }
    }

    var windowText: String { "\(store.prefs.convert.doubleShiftWindowMs) ms" }

    var switchLanguageAfterConvert: Bool {
        get { store.prefs.convert.switchLanguageAfterConvert }
        set { write { $0.convert.switchLanguageAfterConvert = newValue } }
    }

    /// P3-37: Settings → Convert "Use the clipboard in apps Kytkin can't read".
    var useClipboardInUnreadableApps: Bool {
        get { store.prefs.convert.useClipboardInUnreadableApps }
        set { write { $0.convert.useClipboardInUnreadableApps = newValue } }
    }

    private func write(_ change: (inout Preferences) -> Void) {
        guard isEditable else { return }
        store.update(change)
    }
}

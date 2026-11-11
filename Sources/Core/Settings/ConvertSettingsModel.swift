// P2-25: The logic behind Settings → Convert (001 §5.2 "Convert & Fix", P2 part), so the SwiftUI view stays thin.
//
// - Double-Shift on/off, which Shift keys, the window (a slider clamped to 200–500 ms, P2-31) and "Switch language
//   after converting" (001 §11 Q1) read and write `prefs.convert`. AppController observes the store and sends the
//   new tap config with `KeyWatcherOperation.updateConfig` (P2-50), so a change works at once, without a restart.
// - The explanation says what double-Shift does since P2-59 (plan.md decisions P2-59, P2-54(a)); P3-35: the whole
//   text box, or the selection.
// - Auto-fix is Phase 4: the tab shows only a "coming later" line, never a control.
// - Read-only preferences (§12 S1): every setter does nothing and the notice says why.

import Foundation
import Observation

@MainActor @Observable final class ConvertSettingsModel {
    @ObservationIgnored private let store: PreferencesStore

    static let windowRangeMs = Preferences.Convert.windowRangeMs
    static let windowStepMs = 10
    static let sliderRange = Double(windowRangeMs.lowerBound)...Double(windowRangeMs.upperBound)

    static let explanation = [
        "Typed something in the wrong layout? Press Shift twice.",
        // P3-35 (owner 2026-11-11): the whole text box (was the wrong-layout text before the cursor, P3-33).
        "With nothing selected, Kytkin converts the whole text box: every letter in the language next to the "
            + "cursor changes to the other language, on every line. Text already in the other language stays.",
        "With text selected, it converts only the selection, so select just the part you want to change.",
        "Press Shift twice again right away to undo.",
        "Where Kytkin can't read the text, it converts what it remembers you typing, "
            + "or only switches the language.",
    ]

    static let autoFixNote = "Fixing words automatically as you type is coming in a later version."

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

    private func write(_ change: (inout Preferences) -> Void) {
        guard isEditable else { return }
        store.update(change)
    }
}

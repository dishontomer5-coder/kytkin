// P3-37: the shortcuts the clipboard convert posts (⌘C, ⌘V), as `SyntheticKeyEvent.shortcut`. P3-62: ⌘A is gone (the
// box convert selects from the cursor to the start with ⇧⌘↑, `SyntheticKeyEvent.selectToStart`).

import Foundation

/// P3-37: the clipboard shortcuts Kytkin posts (always `ours`-marked, Command only, never in a terminal).
enum ClipboardShortcut: Sendable, Equatable, CaseIterable {
    case copy, paste

    /// ANSI key codes (kVK_ANSI_A / C / V). Only used when the pair's Latin layout types a, c, v on exactly these keys
    /// (`LayoutSnapshot.clipboardShortcutsAreSafe`), so ⌘ + this key is ⌘C / ⌘V and never, say, ⌘Q on AZERTY.
    var keyCode: UInt16 {
        switch self {
        case .copy: 8
        case .paste: 9
        }
    }

    var letter: String {
        switch self {
        case .copy: "c"
        case .paste: "v"
        }
    }
}

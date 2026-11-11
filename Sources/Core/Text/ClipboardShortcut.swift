// P3-37: the three shortcuts the clipboard convert posts (⌘A, ⌘C, ⌘V), as `SyntheticKeyEvent.shortcut`.

import Foundation

/// P3-37: the clipboard shortcuts Kytkin posts (always `ours`-marked, Command only, never in a terminal).
enum ClipboardShortcut: Sendable, Equatable, CaseIterable {
    case selectAll, copy, paste

    /// ANSI key codes (kVK_ANSI_A / C / V). Only used when the pair's Latin layout types a, c, v on exactly these keys
    /// (`LayoutSnapshot.clipboardShortcutsAreSafe`), so ⌘ + this key is ⌘A / ⌘C / ⌘V and never, say, ⌘Q on AZERTY.
    var keyCode: UInt16 {
        switch self {
        case .selectAll: 0
        case .copy: 8
        case .paste: 9
        }
    }

    var letter: String {
        switch self {
        case .selectAll: "a"
        case .copy: "c"
        case .paste: "v"
        }
    }
}

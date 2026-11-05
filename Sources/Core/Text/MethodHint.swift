// P2-13: How Kytkin may replace text in one app (001 §2.2). Comes from the shipped seed list or the user's
// per-app override (Settings → Apps). P2-8's `Preferences` stores the override; the composition root maps
// it into a MethodHint, so Core/Text never depends on Preferences.

import Foundation

enum MethodHint: String, Sendable, Equatable, CaseIterable {
    /// Use the full chain: AX with read-back first, then keys.
    case auto
    /// Never use AX writes here (terminals, code editors, Chromium/Electron start here): keys only.
    case keysOnly
    /// The app ignores the Unicode string in key events (remote desktops, VMs): no typing steps.
    case noUnicode
    /// Paste first when the pasteboard step is allowed (P3). Behaves like `auto` until then.
    case preferPaste
    /// The user turned text replacement off for this app.
    case disabled
}

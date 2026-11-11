// P3-42 (001 §12.3 X15): a per-family capability hint beside `MethodHint`. `MethodHint` is what the user can choose in
// Settings → Apps; this says how a seeded family's text boxes can be read and written, so a seeded keys-only app can
// still convert its whole box without AX writes. Shipped seeds only, never persisted.

import Foundation

enum FieldFamily: String, Sendable, Equatable {
    /// Chromium / Electron web content (Chrome, Edge, Brave, Arc, Vivaldi, Opera, Chromium, Slack, Discord, Teams):
    /// `AXValue` and the caret read fine without any AX flag (P3-37 probe, owner's Mac 2026-11-11), `AXSelectedTextRange`
    /// writes move the real selection, but an `AXSelectedText` write is a silent no-op and an `AXValue` write breaks the
    /// page's editor (research p3-37 §2). So: read through AX, select each changed piece, check it by reading it back,
    /// type over it with Unicode key events (`ChromiumAXConvert`).
    case chromiumAX
}

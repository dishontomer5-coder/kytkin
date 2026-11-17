// P6-0c: the menu-bar glyphs, shared by the status item and (P6-0d) Settings → General's live preview, so the
// preview is drawn exactly like the real item. AppKit only; nothing here reads or changes any state.

import AppKit

/// P6-0c: the menu-bar glyph for each look. The real artwork goes in Resources/MenuBar/ (README there); until it lands,
/// an SF Symbol stands in. Always a template image: macOS tints it for every menu bar.
@MainActor enum MenuBarGlyph {
    private static var cache: [MenuModel.Label.Look: NSImage] = [:]

    static func image(for look: MenuModel.Label.Look) -> NSImage? {
        if let cached = cache[look] { return cached }
        let name = MenuModel.glyphName(look)
        let image: NSImage? = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "MenuBar")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: placeholderSymbol(look), accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        if let image { cache[look] = image }
        return image
    }

    static func placeholderSymbol(_ look: MenuModel.Label.Look) -> String {
        switch look {
        case .active, .off: "keyboard"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.circle"
        }
    }

    /// Letters-only mode: a small template dot after the letters while a warning applies.
    static func attentionDot() -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        image?.size = NSSize(width: 5, height: 5)
        image?.isTemplate = true
        return image
    }
}

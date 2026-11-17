// P6-0c: the menu-bar glyphs, shared by the status item and (P6-0d) Settings → General's live preview, so the
// preview is drawn exactly like the real item. AppKit only; nothing here reads or changes any state.
// P6-0e (docs/design/artwork/Colors.md): Claude Design's artwork. Eight template PDFs, 18 × 18 pt:
// `kytkin-menubar-{active,paused,attention,off}-{a,b}.pdf`, the filled half = the language that is on (`-a` the
// pair's first language, `-b` the second). The whole item is one template image: the glyph, 4 pt, then the letters
// (SF Pro Text 13 pt medium) in a fixed 20 pt frame, so the item's width never changes; when Kytkin is off the
// letters fade to 35 % like the glyph. macOS tints it for every menu bar.

import AppKit

@MainActor enum MenuBarGlyph {
    static let glyphSize = NSSize(width: 18, height: 18)
    static let gap: CGFloat = 4
    static let lettersWidth: CGFloat = 20
    static var lettersFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }

    /// The headless renderer's repo folder (Resources/MenuBar); nil = the app bundle's.
    static var resourceDirectory: URL?
    private static var glyphCache: [String: NSImage] = [:]
    private static var itemCache: [MenuModel.Label: NSImage] = [:]

    /// The glyph alone for a look and side (a bundled PDF; an SF Symbol if the PDF is missing).
    /// P6-0e: the designer's attention PDFs lost their mask in the export (only the badge dot is left), so the
    /// attention look is drawn here from the active PDF, exactly as `kytkin-menubar-attention-*.svg` does it: the key
    /// with a circle (r 3.3 at 15.4, 3.4) cut out, then the badge (r 2.2).
    static func image(for look: MenuModel.Label.Look, side: PairSide = .a) -> NSImage? {
        let name = MenuModel.glyphName(look, side: side)
        if let cached = glyphCache[name] { return cached }
        if look == .attention, let active = image(for: .active, side: side), isArtwork(active) {
            let badged = NSImage(size: glyphSize, flipped: true) { rect in
                active.draw(in: rect)
                guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: 15.4 - 3.3, y: 3.4 - 3.3, width: 6.6, height: 6.6))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: 15.4 - 2.2, y: 3.4 - 2.2, width: 4.4, height: 4.4))
                return true
            }
            badged.isTemplate = true
            glyphCache[name] = badged
            return badged
        }
        let url = resourceDirectory.map { $0.appendingPathComponent(name + ".pdf") }
            ?? Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "MenuBar")
            ?? Bundle.main.url(forResource: name, withExtension: "pdf")   // XcodeGen copies them to Resources/
        let image: NSImage? = url.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: placeholderSymbol(look), accessibilityDescription: nil)
        image?.size = glyphSize
        image?.isTemplate = true
        if let image { glyphCache[name] = image }
        return image
    }

    /// The bundled artwork (not the SF Symbol stand-in).
    private static func isArtwork(_ image: NSImage) -> Bool {
        image.representations.contains { $0 is NSPDFImageRep }
    }

    /// The whole status item for `label`: glyph and/or letters, as one template image. nil = nothing to draw.
    static func itemImage(for label: MenuModel.Label) -> NSImage? {
        if let cached = itemCache[label] { return cached }
        let glyph = label.showsIcon ? image(for: label.look, side: label.side) : nil
        let letters = label.letters
        let dot = !label.showsIcon && label.look == .attention
        var width: CGFloat = 0
        if glyph != nil { width += glyphSize.width }
        if letters != nil { width += (glyph != nil ? gap : 0) + lettersWidth }
        if dot { width += 3 + 5 }
        guard width > 0 else { return nil }
        let size = NSSize(width: width, height: glyphSize.height)
        let font = lettersFont
        let opacity = label.lettersOpacity
        let item = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            if let glyph {
                glyph.draw(in: NSRect(origin: .zero, size: glyphSize))
                x += glyphSize.width + gap
            }
            if let letters {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.black.withAlphaComponent(opacity),
                ]
                let text = letters as NSString
                let textSize = text.size(withAttributes: attrs)
                let y = (size.height - textSize.height) / 2
                text.draw(at: NSPoint(x: x + max(0, (lettersWidth - textSize.width) / 2), y: y), withAttributes: attrs)
                x += lettersWidth
            }
            if dot {   // letters-only mode: a small dot marks "needs attention" (visual review §3.2)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 3, y: (size.height - 5) / 2, width: 5, height: 5)).fill()
            }
            return true
        }
        item.isTemplate = true
        item.accessibilityDescription = label.accessibilityLabel
        itemCache[label] = item
        return item
    }

    static func placeholderSymbol(_ look: MenuModel.Label.Look) -> String {
        switch look {
        case .active, .off: "keyboard"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.circle"
        }
    }
}

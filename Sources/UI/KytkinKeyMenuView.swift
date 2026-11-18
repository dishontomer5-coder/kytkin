// P6-0g (design v2, lg-menu): the menu's "Always use" line: the title on the left and the Kytkin key (92 × 26 pt) on the
// right, as an NSMenuItem's custom view. The key's halves come from `KytkinKeyShape` (the same drawing as Rules'
// SwiftUI key); the filled half is the language this app or website is pinned to. A click on a half calls `choose`
// and closes the menu; what that does (pin, or unpin for the filled half) is `MenuItemModel.LanguageKey`'s.
// AppKit only (a plain NSView tracks clicks reliably inside a menu); nothing here reads or changes any state.

import AppKit

@MainActor final class KytkinKeyMenuView: NSView {
    private let title: String
    private let key: MenuItemModel.LanguageKey
    private let choose: (PairSide) -> Void
    private var pressed: PairSide?

    static let keySize = NSSize(width: 92, height: 26)
    /// The menu's own text inset (the titles of the other items start here).
    static let leading: CGFloat = 22
    static let trailing: CGFloat = 14

    init(title: String, key: MenuItemModel.LanguageKey, enabled: Bool, choose: @escaping (PairSide) -> Void) {
        self.title = title
        self.key = key
        self.choose = choose
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(Self.leading + titleWidth + 24 + Self.keySize.width + Self.trailing),
                                 height: Self.keySize.height + 8))
        autoresizingMask = [.width]
        isEnabled = enabled
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        // P6-0g QA: VoiceOver hears which language is pinned without visiting the halves.
        setAccessibilityValue(key.chosen.map { key.half($0).name } ?? "None")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private var isEnabled = true

    override var isFlipped: Bool { true }

    // P6-0n: the menu (glass on macOS 26) sits on a vibrant material; a vibrant view's colours are blended with what
    // is behind the menu, which let faint glyphs show through the filled half. This view draws plain, opaque pixels.
    override var allowsVibrancy: Bool { false }

    private var keyRect: NSRect {
        NSRect(x: bounds.maxX - Self.trailing - Self.keySize.width, y: (bounds.height - Self.keySize.height) / 2,
               width: Self.keySize.width, height: Self.keySize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // P6-0g QA: a view item draws its own highlight (the menu redraws it when the highlight moves), so a keyboard
        // user sees this line selected before pressing Return (the item's keyboard action, StatusItemController).
        let highlighted = isEnabled && enclosingMenuItem?.isHighlighted == true
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let font = NSFont.menuFont(ofSize: 0)
        let titleColor: NSColor = highlighted ? .selectedMenuItemTextColor
            : isEnabled ? .labelColor : .disabledControlTextColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: titleColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: Self.leading, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = keyRect.insetBy(dx: 0.5, dy: 0.5)
        let halves = KytkinKeyShape.halves(in: rect)
        for side in [PairSide.a, .b] {
            let path = side == .a ? halves.left : halves.right
            let filled = key.chosen == side
            ctx.saveGState()
            ctx.addPath(path)
            if filled {
                // P6-0n: a solid sRGB fill resolved for this view's appearance (not a dynamic colour at 45 % alpha,
                // not a material colour), drawn as plain source-over pixels: opaque in either half, light and dark.
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ctx.setBlendMode(.normal)
                ctx.setAlpha(1)
                ctx.setFillColor(NSColor.kytkinKeyFill(dark: dark, enabled: isEnabled).cgColor)
                ctx.fillPath()
            } else {
                let stroke: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
                ctx.setStrokeColor(stroke.withAlphaComponent(pressed == side ? 0.9 : 0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            ctx.restoreGState()
            let letters = key.half(side).letters as NSString
            let letterAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: filled ? NSColor.white
                    : highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor,
            ]
            let ls = letters.size(withAttributes: letterAttrs)
            let centerX = rect.midX + (side == .a ? -1 : 1) * rect.width * 0.24
            letters.draw(at: NSPoint(x: centerX - ls.width / 2, y: rect.midY - ls.height / 2), withAttributes: letterAttrs)
        }
    }

    private func side(at point: NSPoint) -> PairSide? {
        let rect = keyRect.insetBy(dx: 0.5, dy: 0.5)
        guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let halves = KytkinKeyShape.halves(in: rect)
        if halves.left.contains(point) { return .a }
        if halves.right.contains(point) { return .b }
        return point.x < rect.midX ? .a : .b
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = side(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let side = side(at: convert(event.locationInWindow, from: nil))
        pressed = nil
        needsDisplay = true
        guard let side else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        choose(side)
    }

    // VoiceOver: each half is a button.
    override func accessibilityChildren() -> [Any]? {
        [PairSide.a, .b].map { side in
            let element = HalfElement { [weak self] in
                guard let self, self.isEnabled else { return }
                self.enclosingMenuItem?.menu?.cancelTracking()
                self.choose(side)
            }
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(key.half(side).name)
            element.setAccessibilityValue(key.chosen == side ? "Selected" : "")
            element.setAccessibilityParent(self)
            let halves = KytkinKeyShape.halves(in: keyRect)
            let box = (side == .a ? halves.left : halves.right).boundingBoxOfPath
            element.setAccessibilityFrameInParentSpace(box)
            return element
        }
    }
}

/// A half of the key for VoiceOver ("press" = a click).
@MainActor private final class HalfElement: NSAccessibilityElement {
    private let press: @MainActor () -> Void

    init(press: @escaping @MainActor () -> Void) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

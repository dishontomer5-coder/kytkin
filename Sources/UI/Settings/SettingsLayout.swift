// P6-0g (design v2, "Across the app"): the one layout every Settings tab uses.
// - `SettingsPage`: 20 pt top, 40 pt sides (P2); the content reports its natural height, so the window can size itself
//   to the tab (P1: min 380, max 640 pt, then it scrolls with a 20 pt bottom inset).
// - `SettingsSection`: a title-case header (P3) over one card of rows, a hairline between rows. Standard controls only
//   (Liquid Glass: no glass on the cards, the content layer).
// - `SettingsRow`: one row style everywhere (P2): a 13 pt regular title, an 11 pt secondary line, the control on the
//   right.
// - The Kytkin key (`KytkinKey`): two halves, the filled one is the chosen language; used only to choose between the
//   pair's two languages (Rules' Language column; the menu draws the same shape in AppKit, `KytkinKeyShape`).

import AppKit
import SwiftUI

// MARK: - Sizes and colours

enum SettingsMetrics {
    static let width: CGFloat = 720
    static let minHeight: CGFloat = 380
    static let maxHeight: CGFloat = 640
    static let top: CGFloat = 20
    static let sides: CGFloat = 40
    static let bottom: CGFloat = 20
    static let titleSize: CGFloat = 13
    static let secondarySize: CGFloat = 11

    /// The window's content height for a tab whose content is `natural` points tall.
    static func height(for natural: CGFloat) -> CGFloat {
        min(max(ceil(natural), minHeight), maxHeight)
    }
}

extension Color {
    /// The setting cards (Colors.md: Form section, light #FFFFFF, dark #2E2E31).
    static let kytkinCard = Color(nsColor: NSColor(name: "KytkinCard") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2E / 255, green: 0x2E / 255, blue: 0x31 / 255, alpha: 1)
            : NSColor.white
    })

    /// P6-0g (review P2): the green for controls and the chosen half: light #0E7A66, dark #2FA88B.
    static let kytkinAccent = Color(nsColor: .kytkinAccent)
}

extension NSColor {
    static let kytkinAccent = NSColor(name: "KytkinAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2F / 255, green: 0xA8 / 255, blue: 0x8B / 255, alpha: 1)
            : NSColor(srgbRed: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255, alpha: 1)
    }
}

// MARK: - Page

/// Reports the content's natural height (the window sizes itself to it).
struct SettingsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One tab's content: margins, scrolling past 640 pt, and its natural height reported up.
struct SettingsPage<Content: View>: View {
    var sides: CGFloat = SettingsMetrics.sides
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SettingsMetrics.top)
                .padding(.horizontal, sides)
                .padding(.bottom, SettingsMetrics.bottom)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsContentHeightKey.self, value: proxy.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Section and rows

/// A header (title case) over one card of rows with a hairline between them.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            _VariadicView.Tree(DividedCard()) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.kytkinCard))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// The card's rows with a hairline between each two.
private struct DividedCard: _VariadicView_MultiViewRoot {
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }
}

/// The one row style: title (13 pt) and an optional secondary line (11 pt) on the left, the control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel(title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A switch row.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Free content inside a card, with the row padding.
struct SettingsCardContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }
}

/// The privacy line (General, About): the review's exact wording.
struct PrivacyLine: View {
    static let text = "Kytkin works only on your Mac. Nothing you type is saved or sent."
    var centered = false

    var body: some View {
        Label {
            Text(Self.text)
        } icon: {
            Image(systemName: "lock")
        }
        .font(.system(size: centered ? SettingsMetrics.titleSize : SettingsMetrics.secondarySize))
        .foregroundStyle(centered ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.leading, centered ? 0 : 2)
    }
}

// MARK: - The Kytkin key

/// The two halves of the Kytkin key (y down): the left half up to an S-shaped seam, the right half after it.
enum KytkinKeyShape {
    static func halves(in rect: CGRect, gap: CGFloat = 2, radius: CGFloat? = nil,
                       slant slantRatio: CGFloat = 0.32) -> (left: CGPath, right: CGPath) {
        let h = rect.height, w = rect.width
        let r = radius ?? min(h * 0.32, 8)
        let slant = h * slantRatio
        let mid = rect.minX + w / 2
        let top = rect.minY, bottom = rect.maxY
        // The seam runs from (mid + slant, top) down to (mid - slant, bottom), an S like the logo's.
        func seam(_ path: CGMutablePath, offset: CGFloat, downward: Bool) {
            let t = CGPoint(x: mid + slant + offset, y: top)
            let b = CGPoint(x: mid - slant + offset, y: bottom)
            if downward {
                path.addCurve(to: b, control1: CGPoint(x: t.x, y: top + h * 0.5),
                              control2: CGPoint(x: b.x, y: top + h * 0.5))
            } else {
                path.addCurve(to: t, control1: CGPoint(x: b.x, y: top + h * 0.5),
                              control2: CGPoint(x: t.x, y: top + h * 0.5))
            }
        }
        let left = CGMutablePath()
        left.move(to: CGPoint(x: mid + slant - gap / 2, y: top))
        seam(left, offset: -gap / 2, downward: true)
        left.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        left.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: top), radius: r)
        left.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: mid, y: top), radius: r)
        left.closeSubpath()

        let right = CGMutablePath()
        right.move(to: CGPoint(x: mid - slant + gap / 2, y: bottom))
        seam(right, offset: gap / 2, downward: false)
        right.addLine(to: CGPoint(x: rect.maxX - r, y: top))
        right.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: r)
        right.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: mid, y: bottom), radius: r)
        right.closeSubpath()
        return (left, right)
    }
}

struct KeyHalf: Shape {
    let side: PairSide
    var gap: CGFloat = 2
    var radius: CGFloat? = nil
    var slant: CGFloat = 0.32

    func path(in rect: CGRect) -> Path {
        let halves = KytkinKeyShape.halves(in: rect.insetBy(dx: 0.5, dy: 0.5), gap: gap, radius: radius, slant: slant)
        return Path(side == .a ? halves.left : halves.right)
    }
}

/// P6-0g: the Kytkin key. `chosen` = the filled half (nil = neither, "leave alone"). Clicking a half calls `choose`;
/// what a click on the filled half does is the caller's (Rules: leave the app alone; the menu: follow my last switch).
struct KytkinKey: View {
    let left: String
    let right: String
    let chosen: PairSide?
    var size = CGSize(width: 84, height: 24)
    var leftName: String = ""
    var rightName: String = ""
    let choose: (PairSide) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            half(.a, letters: left)
            half(.b, letters: right)
        }
        .frame(width: size.width, height: size.height)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
    }

    private func half(_ side: PairSide, letters: String) -> some View {
        let filled = chosen == side
        let name = side == .a ? leftName : rightName
        return Button { choose(side) } label: {
            ZStack {
                KeyHalf(side: side).fill(filled ? Color.kytkinAccent : Color.clear)
                KeyHalf(side: side).stroke(filled ? Color.clear : Color.secondary.opacity(0.55), lineWidth: 1)
                Text(letters)
                    .font(.system(size: size.height * 0.5, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : Color.secondary)
                    .offset(x: (side == .a ? -1 : 1) * size.width * 0.24)
            }
            .contentShape(KeyHalf(side: side))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.isEmpty ? letters : name)
        .accessibilityAddTraits(filled ? .isSelected : [])
        .help(name)
    }
}

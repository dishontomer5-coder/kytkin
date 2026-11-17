// P6-0c (visual review X1–X3): shared pieces of the Settings tabs.
// - RowLabel: a control's explanation sits inside its row (title + grey subtitle), not as a separate divided row.
// - StatusLabel: colour only on the symbol; the text stays primary or secondary (WCAG AA on the light grouped rows,
//   where orange / green text measured about 2:1).
// - NoticeSection: the preferences-file notices are the form's first section, on the form's own left edge.

import AppKit
import SwiftUI

struct RowLabel: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        // P6-0g (review P2): one row style, a 13 pt regular title and an 11 pt secondary line.
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A status line: a tinted symbol, untinted text.
struct StatusLabel: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary
    var secondaryText = false

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(secondaryText ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A problem line: ⚠ in orange, the text primary.
struct WarningLabel: View {
    let text: String

    var body: some View {
        StatusLabel(text: text, symbol: "exclamationmark.triangle.fill", tint: .orange)
    }
}

/// P6-0d (owner): the status item as it will look, from the same label model and glyphs (`MenuBarGlyph`), template-
/// tinted for the current appearance, on a small menu-bar-like capsule.
struct MenuBarPreview: View {
    let label: MenuModel.Label

    var body: some View {
        // P6-0e: the very image the status item shows.
        HStack {
            if let image = MenuBarGlyph.itemImage(for: label) {
                Image(nsImage: image).renderingMode(.template)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(label.accessibilityLabel)")
    }
}

/// The preferences-file notices as the form's first section (nothing when there are none).
struct NoticeSection: View {
    let notices: [SettingsNotice]
    var extra: [String] = []

    var body: some View {
        if !notices.isEmpty || !extra.isEmpty {
            Section {
                ForEach(notices) { WarningLabel(text: $0.message) }
                ForEach(extra, id: \.self) { WarningLabel(text: $0) }
            }
        }
    }
}

/// P6-0e QA (Colors.md: Link, light #0E7A66): Kytkin's link colour, for every link and link-style button (the system
/// `.link` style draws the system blue). A dynamic colour, so it follows the appearance. P6-0g (review P2): dark #5FD3B5.
extension Color {
    static let kytkinLink = Color(nsColor: NSColor(name: "KytkinLink") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0x5F / 255, green: 0xD3 / 255, blue: 0xB5 / 255, alpha: 1)
            : NSColor(srgbRed: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255, alpha: 1)
    })
}

/// P6-0e QA: a text button drawn as a link in Kytkin's link colour.
struct KytkinLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.kytkinLink)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == KytkinLinkButtonStyle {
    static var kytkinLink: KytkinLinkButtonStyle { KytkinLinkButtonStyle() }
}

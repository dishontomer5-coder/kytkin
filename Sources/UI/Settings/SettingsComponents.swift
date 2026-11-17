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
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
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

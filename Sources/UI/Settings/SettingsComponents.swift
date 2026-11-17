// P6-0c (visual review X1–X3): shared pieces of the Settings tabs.
// - RowLabel: a control's explanation sits inside its row (title + grey subtitle), not as a separate divided row.
// - StatusLabel: colour only on the symbol; the text stays primary or secondary (WCAG AA on the light grouped rows,
//   where orange / green text measured about 2:1).
// - NoticeSection: the preferences-file notices are the form's first section, on the form's own left edge.

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

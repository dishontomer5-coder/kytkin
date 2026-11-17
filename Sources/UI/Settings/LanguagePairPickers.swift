// P2-24 / P2-26: The two language pickers with their caption, the refusal line and the pair warnings. Shared by
// Settings and the setup window, so both pick from the same list with the same checks (`LanguagesSettingsModel`,
// Core). Layout only.
// P6-0d (owner): Settings → General shows them as one row (`LanguagePairRow`): two compact pickers with their
// menu-bar letters and a ⇄ swap button between them; the setup window keeps the two labelled pickers.

import AppKit
import SwiftUI

struct LanguagePairPickers: View {
    @Bindable var model: LanguagesSettingsModel

    var body: some View {
        LanguagePairMenu(model: model, title: "First language", selection: $model.pairA)   // P6-0c (L-1)
        LanguagePairMenu(model: model, title: "Second language", selection: $model.pairB)
        Text(LanguagePairRow.hint)   // P6-0c (L-2)
            .font(.caption).foregroundStyle(.secondary)
        LanguagePairProblems(model: model)
    }
}

/// P6-0d: `[ABC ▾] EN  ⇄  [Hebrew ▾] HE`, the hint as the row's subtitle, problems below it.
struct LanguagePairRow: View {
    @Bindable var model: LanguagesSettingsModel

    static let hint = "Press Shift twice to convert text between these two languages."

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                LanguagePairMenu(model: model, title: "First language", selection: $model.pairA)
                    .labelsHidden().fixedSize()
                CodeBadge(code: model.code(for: model.pair.a))
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("Swap the two languages")
                    .accessibilityLabel("Swap the two languages")
                    .padding(.horizontal, 4)
                LanguagePairMenu(model: model, title: "Second language", selection: $model.pairB)
                    .labelsHidden().fixedSize()
                CodeBadge(code: model.code(for: model.pair.b))
            }
        } label: {
            RowLabel("Your two languages", subtitle: Self.hint)
        }
        LanguagePairProblems(model: model)
    }
}

/// One pair member's pop-up, grouped like the system's lists.
struct LanguagePairMenu: View {
    let model: LanguagesSettingsModel
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(model.optionGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Text(option.title).tag(option.tag)
                            .selectionDisabled(!option.isSelectable)
                    }
                }
            }
        }
    }
}

/// The refusal line and the pair warnings (P6-0c: colour only on the symbol).
struct LanguagePairProblems: View {
    let model: LanguagesSettingsModel

    var body: some View {
        if let problem = model.pairProblem {
            StatusLabel(text: problem.message, symbol: "xmark.circle.fill", tint: .red).font(.caption)
        }
        ForEach(model.pairWarnings, id: \.self) { warning in
            WarningLabel(text: warning).font(.caption)
        }
    }
}

/// P6-0g (design v2, lg-general "Language pair"): one wide key with two halves. Each half is a standard language picker
/// ("First language", "Second language") beside the half-filled key icon it is in the menu bar (review P3: the one
/// place that teaches the icon); a round button on the seam swaps them.
struct LanguagePairKey: View {
    @Bindable var model: LanguagesSettingsModel
    static let height: CGFloat = 64

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                half(.a)
                half(.b)
            }
            .background {
                ZStack {
                    KeyHalf(side: .a, gap: 6, radius: 16, slant: 0.12).fill(Color.primary.opacity(0.07))
                    KeyHalf(side: .b, gap: 6, radius: 16, slant: 0.12).fill(Color.kytkinMint)
                }
            }
            Button { model.swap() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.kytkinCard).shadow(color: .black.opacity(0.18), radius: 3, y: 1))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Swap the two languages")
            .accessibilityLabel("Swap the two languages")
        }
        .frame(height: Self.height)
    }

    private func half(_ side: PairSide) -> some View {
        let id = side == .a ? model.pair.a : model.pair.b
        let title = side == .a ? "First language" : "Second language"
        return HStack(spacing: 10) {
            if let glyph = MenuBarGlyph.image(for: .active, side: side) {
                Image(nsImage: glyph).renderingMode(.template).foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                LanguagePairMenu(model: model, title: title, selection: side == .a ? $model.pairA : $model.pairB)
                    .labelsHidden()
                    .frame(maxWidth: 210, alignment: .leading)
                    .accessibilityLabel("\(title): \(model.name(of: id))")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, side == .a ? 14 : 34)
        .padding(.trailing, side == .a ? 34 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    /// The second language's half (lg-general): mint, light #D8F5EC, dark #1E3F37.
    static let kytkinMint = Color(nsColor: NSColor(name: "KytkinMint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1E / 255, green: 0x3F / 255, blue: 0x37 / 255, alpha: 1)
            : NSColor(srgbRed: 0xD8 / 255, green: 0xF5 / 255, blue: 0xEC / 255, alpha: 1)
    })
}

/// P6-0d: the letters the menu bar shows for a language ("EN", "HE").
private struct CodeBadge: View {
    let code: String?

    var body: some View {
        if let code {
            Text(code)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                .accessibilityLabel("Menu bar letters \(code)")
        }
    }
}

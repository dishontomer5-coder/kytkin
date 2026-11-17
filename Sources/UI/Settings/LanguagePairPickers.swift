// P2-24 / P2-26: The two language pickers with their caption, the refusal line and the pair warnings. Shared by
// Settings and the setup window, so both pick from the same list with the same checks (`LanguagesSettingsModel`,
// Core). Layout only.
// P6-0d (owner): Settings → General shows them as one row (`LanguagePairRow`): two compact pickers with their
// menu-bar letters and a ⇄ swap button between them; the setup window keeps the two labelled pickers.

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
private struct LanguagePairMenu: View {
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
private struct LanguagePairProblems: View {
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

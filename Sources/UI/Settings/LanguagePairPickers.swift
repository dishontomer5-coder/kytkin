// P2-24 / P2-26: The two language pickers with their caption, the refusal line and the pair warnings. Shared by
// Settings → Languages and the welcome window, so both pick from the same list with the same checks
// (`LanguagesSettingsModel`, Core). Layout only.

import SwiftUI

struct LanguagePairPickers: View {
    @Bindable var model: LanguagesSettingsModel

    var body: some View {
        pairPicker("First language", selection: $model.pairA)   // P6-0c (L-1)
        pairPicker("Second language", selection: $model.pairB)
        Text("Press Shift twice to convert text between these two languages.")   // P6-0c (L-2)
            .font(.caption).foregroundStyle(.secondary)
        // P6-0c (visual review L1, X2): colour only on the symbol.
        if let problem = model.pairProblem {
            StatusLabel(text: problem.message, symbol: "xmark.circle.fill", tint: .red).font(.caption)
        }
        ForEach(model.pairWarnings, id: \.self) { warning in
            WarningLabel(text: warning).font(.caption)
        }
    }

    private func pairPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
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

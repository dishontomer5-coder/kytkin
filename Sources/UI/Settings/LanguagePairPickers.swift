// P2-24 / P2-26: The two language pickers with their caption, the refusal line and the pair warnings. Shared by
// Settings → Languages and the welcome window, so both pick from the same list with the same checks
// (`LanguagesSettingsModel`, Core). Layout only.

import SwiftUI

struct LanguagePairPickers: View {
    @Bindable var model: LanguagesSettingsModel

    var body: some View {
        pairPicker("Language A", selection: $model.pairA)
        pairPicker("Language B", selection: $model.pairB)
        Text("Double-Shift converts text typed in one of these languages into the other.")
            .font(.caption).foregroundStyle(.secondary)
        if let problem = model.pairProblem {
            Text(problem.message).font(.caption).foregroundStyle(.red)
        }
        ForEach(model.pairWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
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

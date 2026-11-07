// P2-25: Settings → Rules (001 §5.2). Layout only; `RulesSettingsModel` (Core) sorts, filters and writes every
// change through RuleWriter, and is tested. Read-only preferences disable every edit (the notice says why).
// P3-15: a kind filter, "Add Website…" / "Add Subdomain Rule…" (a sheet), and the search box is a real search field
// (Esc clears only search fields).

import SwiftUI

struct RulesSettingsView: View {
    @Bindable var model: RulesSettingsModel
    @State private var selection: UUID?
    @State private var confirmingForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsNoticeList(notices: model.notices)
            HStack {
                SearchField(prompt: "Search", text: $model.searchText)
                Picker("Kind", selection: $model.kindFilter) {
                    ForEach(RuleKindFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Show", selection: $model.originFilter) {
                    ForEach(RuleOriginFilter.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(RuleSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }

            let rows = model.rows
            if rows.isEmpty {
                Text(model.emptyText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("For") { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text([row.kindTitle, row.detail].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Language") { row in
                        Picker("Language", selection: Binding(
                            get: { row.inputSource },
                            set: { model.setLanguage($0, for: row.id) })) {
                            ForEach(model.languageOptions(for: row)) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .disabled(!model.isEditable)
                    }
                    TableColumn("Status") { row in
                        Text(row.originTitle).foregroundStyle(row.isPinned ? .primary : .secondary)
                    }
                    .width(70)
                    TableColumn("Last updated") { row in
                        Text(row.updatedAt, format: .dateTime.day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                let selected = rows.first { $0.id == selection }
                Button(selected?.isPinned == true ? "Unpin" : "Pin") {
                    guard let selected else { return }
                    if selected.isPinned { model.unpin(selected.id) } else { model.pin(selected.id) }
                }
                .disabled(selected == nil || !model.isEditable)
                Button("Delete") {
                    if let selected { model.delete(selected.id) }
                }
                .disabled(selected == nil || !model.isEditable)
                if let selected, model.offersSubdomainRule(selected), case .site(let domain) = selected.scope {
                    Button("Add Subdomain Rule…") { model.beginAddWebsite(subdomainOf: domain) }
                }
                Spacer()
                Button("Add Website…") { model.beginAddWebsite() }
                    .disabled(!model.canAddWebsite)
                    .help(model.canAddWebsite ? "" : RulesSettingsModel.websiteDataMissingText)
                Button("Forget All Learned Rules…") { confirmingForgetAll = true }
                    .disabled(model.learnedCount == 0 || !model.isEditable)
            }
            Text("Choosing a language for a rule pins it: Kytkin won't change a pinned rule by learning.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $model.addWebsite) { form in
            AddWebsiteSheet(form: form, save: { model.saveAddWebsite() }, cancel: { model.cancelAddWebsite() })
        }
        .confirmationDialog(model.forgetAllLearnedQuestion, isPresented: $confirmingForgetAll) {
            Button("Forget Learned Rules", role: .destructive) { model.forgetAllLearned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RulesSettingsModel.forgetAllLearnedMessage)
        }
    }
}

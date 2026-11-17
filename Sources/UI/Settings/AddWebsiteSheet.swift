// P3-15: the "Add Website…" / "Add Subdomain Rule…" sheet (001 §14.8). Layout only; `AddWebsiteForm` parses the
// address and `RulesSettingsModel` saves it through RuleWriter. A sheet, so the Settings window's Esc handling never
// clears its field (P3-12 note). Esc never throws away a typed address: it closes the sheet only while the field is
// empty (`AddWebsiteForm.escapeCloses`); Cancel is a click.

import SwiftUI

struct AddWebsiteSheet: View {
    @Bindable var form: AddWebsiteForm
    let save: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(form.title).font(.headline)
            TextField("Website address", text: $form.text, prompt: Text("ynet.co.il or a copied link"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { if form.canSave { save() } }
            if let hint = form.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if form.showsChoice {
                Picker("Use this language for", selection: $form.extent) {
                    ForEach(WebsiteInput.Extent.allCases) { extent in
                        Text(form.input.title(for: extent) ?? "").tag(extent)
                    }
                }
                .pickerStyle(.radioGroup)
            } else if let message = form.input.message {
                // P6-0c (visual review S2, X2): secondary text, the orange only on the symbol.
                StatusLabel(text: message, symbol: form.scope == nil ? "exclamationmark.triangle.fill" : "info.circle",
                            tint: form.scope == nil ? .orange : .secondary, secondaryText: true)
                    .font(.callout)
            }
            Picker("Language", selection: $form.language) {
                ForEach(form.languageOptions) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
            if let replaces = form.replacesText {
                Text(replaces).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onExitCommand { if form.escapeCloses { cancel() } }
    }
}

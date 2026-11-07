// P2-24: Settings → Languages (001 §5.2). Layout only; `LanguagesSettingsModel` (Core) holds the logic and is tested.
// The open and save panels open only from the user's click on Import… / Export…, and hand the picked URL to the model.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LanguagesSettingsView: View {
    @Environment(LanguagesSettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.notices) { notice in
                Label(notice.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Section {
                    LanguagePairPickers(model: model)   // P2-26: shared with the welcome window
                }
                .disabled(!model.isEditable)

                Section("Imported layouts") {
                    if model.importedRows.isEmpty {
                        Text("None yet. Import a Kytkin layout file (.json) to add a language.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.importedRows) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.name)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { model.remove(row.id) }
                                .disabled(!model.isEditable || row.isInPair)
                                .help(row.isInPair ? "It's one of your two languages. Choose another one first." : "")
                        }
                    }
                    if let notice = model.skippedFilesNotice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Import Layout…") { chooseFileToImport() }
                        .disabled(!model.isEditable)
                }

                Section("Export") {
                    HStack {
                        Picker("Layout", selection: $model.exportSelection) {
                            ForEach(model.exportOptions) { option in
                                Text(option.title).tag(option.tag)
                            }
                        }
                        Button("Export…") { chooseFileToExport() }
                            .disabled(!model.canExport)
                    }
                    Text("Saves the layout as a Kytkin layout file you can edit and import again.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let status = model.status {
                    Text(status.text)
                        .foregroundStyle(status.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { model.refresh() }
    }

    // MARK: - Panels (user click only)

    private func chooseFileToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import a Kytkin Layout"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importFile(at: url)
    }

    private func chooseFileToExport() {
        let panel = NSSavePanel()
        panel.title = "Export a Kytkin Layout"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = model.suggestedExportFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }
}

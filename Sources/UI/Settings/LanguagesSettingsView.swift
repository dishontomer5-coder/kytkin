// P2-24: Settings → Advanced → Keyboard Layouts (001 §5.2; was the Languages tab). Layout only;
// `LanguagesSettingsModel` (Core) holds the logic and is tested. P6-0c: the language pair moved to General; this is
// the import/export of layout files (visual review L3: a power-user feature).
// P6-0g (design v2, proposed-advanced): one section of Advanced, in the shared row style.
// The open and save panels open only from the user's click on Import… / Export…, and hand the picked URL to the model.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyboardLayoutsSection: View {
    @Environment(LanguagesSettingsModel.self) private var model

    static let noneYetText = "None yet. Any language in your Mac’s Keyboard settings already works."

    var body: some View {
        @Bindable var model = model
        NoticeLines(notices: model.notices)
        SettingsSection("Keyboard Layouts") {
            SettingsRow("Imported layouts", subtitle: model.importedRows.isEmpty ? Self.noneYetText : nil) {
                Button("Import Layout…") { chooseFileToImport() }
                    .disabled(!model.isEditable)
            }
            ForEach(model.importedRows) { row in
                SettingsRow(row.name, subtitle: row.detail) {
                    Button("Remove") { model.remove(row.id) }
                        .disabled(!model.isEditable || row.isInPair)
                        .help(row.isInPair ? "You’re using this language. Choose another one in General first." : "")
                }
            }
            if let notice = model.skippedFilesNotice {
                SettingsCardContent { WarningLabel(text: notice) }
            }
            SettingsRow("Export a layout", subtitle: "Saves a Kytkin layout file you can edit and import again.") {
                HStack(spacing: 8) {
                    Picker("Layout", selection: $model.exportSelection) {
                        ForEach(model.exportOptions) { option in
                            Text(option.title).tag(option.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Button("Export…") { chooseFileToExport() }
                        .disabled(!model.canExport)
                        .fixedSize()
                }
            }
            if let status = model.status {
                SettingsCardContent {
                    StatusLabel(text: status.text, symbol: status.isError ? "xmark.circle.fill" : "checkmark.circle",
                                tint: status.isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
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

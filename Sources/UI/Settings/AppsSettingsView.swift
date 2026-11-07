// P2-25: Settings → Apps (001 §5.2). Layout only; `AppsSettingsModel` (Core) holds the logic and is tested.
// Adding an app: from the running apps (a menu), or "Choose App…", which opens a file panel on /Applications only
// when the user clicks it; only the chosen app's bundle ID is kept. Read-only preferences disable every edit.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsSettingsView: View {
    @Bindable var model: AppsSettingsModel
    @State private var chooseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsNoticeList(notices: model.notices)
            let rows = model.rows
            if rows.isEmpty {
                Text(model.emptyText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(rows) { row in
                        Section {
                            Toggle("Kytkin works in this app", isOn: Binding(
                                get: { row.kytkinOn }, set: { model.setKytkinOn($0, for: row.bundleID) }))
                            Text(AppsSettingsModel.kytkinOffText).font(.caption).foregroundStyle(.secondary)
                            Toggle("Convert with double-Shift", isOn: Binding(
                                get: { row.convertOn }, set: { model.setConvertOn($0, for: row.bundleID) }))
                                .disabled(!row.kytkinOn)
                            Text(AppsSettingsModel.convertOffText).font(.caption).foregroundStyle(.secondary)
                            Picker("How Kytkin replaces text", selection: Binding(
                                get: { row.methodID }, set: { model.setMethod($0, for: row.bundleID) })) {
                                ForEach(model.methodOptions(for: row)) { Text($0.title).tag($0.id) }
                            }
                            .disabled(!row.kytkinOn || !row.convertOn)
                            Text(AppMethodOption.explanation(of: row.effectiveMethod))
                                .font(.caption).foregroundStyle(.secondary)
                        } header: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(row.name).font(.headline)
                                    if let detail = row.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Remove") { model.remove(row.bundleID) }
                                    .help("Use Kytkin's defaults for this app again")
                                    .disabled(!model.isEditable)
                            }
                        }
                        .disabled(!model.isEditable)
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Menu("Add Running App") {
                    if model.candidates.isEmpty {
                        Text("No other apps are running")
                    }
                    ForEach(model.candidates) { app in
                        Button(app.name) { model.addApp(bundleID: app.bundleID) }
                    }
                }
                .fixedSize()
                Button("Choose App…") { chooseApp() }
                if let chooseError {
                    Text(chooseError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .disabled(!model.isEditable)
        }
        .onAppear { model.refresh() }
    }

    /// User click only: an open panel on /Applications; the chosen app's bundle ID is added.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an app to change Kytkin's settings for it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let id = Bundle(url: url)?.bundleIdentifier, model.addApp(bundleID: id) {
            chooseError = nil
        } else {
            chooseError = "That app can't be added."
        }
    }
}

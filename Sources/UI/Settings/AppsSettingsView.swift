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
            ForEach(model.notices) { WarningLabel(text: $0.message) }
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
                            // P6-0c (visual review A1, A2): explanations in their rows; the rows that depend on
                            // "Kytkin works in this app" show only while it is on.
                            Toggle(isOn: Binding(get: { row.kytkinOn },
                                                 set: { model.setKytkinOn($0, for: row.bundleID) })) {
                                RowLabel("Kytkin works in this app", subtitle: AppsSettingsModel.kytkinOffText)
                            }
                            if row.kytkinOn {
                                Toggle(isOn: Binding(get: { row.convertOn },
                                                     set: { model.setConvertOn($0, for: row.bundleID) })) {
                                    RowLabel("Convert with double-Shift", subtitle: AppsSettingsModel.convertOffText)
                                }
                                if row.convertOn {
                                    Picker(selection: Binding(get: { row.methodID },
                                                              set: { model.setMethod($0, for: row.bundleID) })) {
                                        ForEach(model.methodOptions(for: row)) { Text($0.title).tag($0.id) }
                                    } label: {
                                        RowLabel("How double-Shift changes text", subtitle: AppMethodOption.explanation(
                                            of: row.effectiveMethod, userChosen: row.methodID != AppMethodOption.defaultID))
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                // P6-0c (copy review A-1): the app's name; its bundle ID only as a tooltip.
                                Text(row.name).font(.headline).help(row.detail ?? "")
                                Spacer()
                                Button { model.remove(row.bundleID) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Use the usual settings for this app again")
                                    .accessibilityLabel("Remove \(row.name)")
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
                    StatusLabel(text: chooseError, symbol: "xmark.circle.fill", tint: .red)
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
            chooseError = "That app can't be added. Choose an app from the Applications folder."
        }
    }
}

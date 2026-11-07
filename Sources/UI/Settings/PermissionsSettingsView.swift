// P2-26: Settings → Permissions (001 §5.2, §6). Layout only; `PermissionsSettingsModel` and `PermissionRow` (Core)
// hold every rule and wording and are tested. Every button here is a user click: "Allow…" is the only way to the
// macOS permission dialog, "Open System Settings" the only way to System Settings, "Quit & Reopen" the only relaunch.
// The window controller turns the 1 s permission poll on while this tab is showing.

import SwiftUI

struct PermissionsSettingsView: View {
    let model: PermissionsSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    PermissionRowView(row: row,
                                      grant: { model.grant(row.pane) },
                                      openSettings: { model.openSystemSettings(row.pane) },
                                      quitAndReopen: { model.quitAndReopen() })
                }
            } footer: {
                HStack {
                    Text("Kytkin checks about once a second while this tab is open.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Again") { model.checkAgain() }
                        .controlSize(.small)
                }
            }

            Section("Keyboard") {
                LabeledContent("Mode") {
                    Text(model.keyboardModeText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Typing protection") {
                    Text(model.secureInputText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let conflicts = model.conflictLines
            if !conflicts.isEmpty {
                Section("Things that get in the way") {
                    ForEach(conflicts, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One permission: name and status, what it does, and its buttons.
private struct PermissionRowView: View {
    let row: PermissionRow
    let grant: () -> Void
    let openSettings: () -> Void
    let quitAndReopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title).font(.headline)
                Spacer()
                Label(row.statusText, systemImage: symbol)
                    .foregroundStyle(color)
            }
            Text(row.enables).fixedSize(horizontal: false, vertical: true)
            if let without = row.withoutIt {
                Text(without).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = row.hint {
                Text(hint).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.showsGrant || row.showsOpenSettings || row.showsQuitAndReopen {
                HStack(spacing: 12) {
                    if row.showsGrant { Button(row.grantTitle, action: grant) }
                    if row.showsOpenSettings { Button("Open System Settings", action: openSettings).buttonStyle(.link) }
                    if row.showsQuitAndReopen { Button("Quit & Reopen", action: quitAndReopen) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch row.status {
        case .granted: "checkmark.circle.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .notNeeded: "minus.circle"
        case .notGranted: "xmark.circle"
        case .checking: "clock"
        }
    }

    private var color: Color {
        switch row.status {
        case .granted: .green
        case .needsRelaunch: .orange
        case .notNeeded, .checking: .secondary
        case .notGranted: .red
        }
    }
}

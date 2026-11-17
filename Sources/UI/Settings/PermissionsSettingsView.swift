// P2-26: The permission rows (001 §5.2, §6). Layout only; `PermissionsSettingsModel` and `PermissionRow` (Core)
// hold every rule and wording and are tested. Every button here is a user click: "Allow…" is the only way to the
// macOS permission dialog, "Open System Settings" the only way to System Settings, "Quit & Reopen" the only relaunch.
// P6-0c (visual review §2.2): no Permissions tab any more. `SetupSection` is the top of General (one line when all is
// fine; the window controller polls permissions once a second while General shows), and `DiagnosticsView` (keyboard
// status, typing protection) is Advanced → Diagnostics.

import SwiftUI

struct SetupSection: View {
    let model: PermissionsSettingsModel

    var body: some View {
        Section {
            if model.setupIsComplete {
                StatusLabel(text: PermissionsSettingsModel.setupCompleteText, symbol: "checkmark.circle.fill",
                            tint: .green)
            } else {
                ForEach(model.setupRows) { row in
                    PermissionRowView(row: row,
                                      grant: { model.grant(row.pane) },
                                      openSettings: { model.openSystemSettings(row.pane) },
                                      quitAndReopen: { model.quitAndReopen() })
                }
                if let problem = model.keyboardProblemText {
                    WarningLabel(text: "Double-Shift: " + problem)
                }
                ForEach(model.conflictLines, id: \.self) { WarningLabel(text: $0) }
            }
        } header: {
            HStack {
                Text("Setup")
                Spacer()
                Button { model.checkAgain() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Check again")
                    .accessibilityLabel("Check again")
            }
        }
    }
}

/// P6-0c: Advanced → Diagnostics. Plain status lines; nothing here changes a setting.
struct DiagnosticsView: View {
    let model: PermissionsSettingsModel
    let openSettingsFolder: @MainActor () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Double-Shift") { Text(model.keyboardModeText).foregroundStyle(.secondary) }
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Typing protection") { Text(model.secureInputText).foregroundStyle(.secondary) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(model.rows) { row in
                    PermissionRowView(row: row,
                                      grant: { model.grant(row.pane) },
                                      openSettings: { model.openSystemSettings(row.pane) },
                                      quitAndReopen: { model.quitAndReopen() })
                }
            }
            Section {
                LabeledContent {
                    Button("Open Settings Folder") { openSettingsFolder() }   // P6-0c (visual Ab3): moved from About
                } label: {
                    RowLabel("Settings folder", subtitle: "Where Kytkin keeps your rules and settings.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One permission: name and status on one line, why, and its buttons (visual review P3: fewer text levels).
struct PermissionRowView: View {
    let row: PermissionRow
    let grant: () -> Void
    let openSettings: () -> Void
    let quitAndReopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).bold()
                Spacer()
                StatusLabel(text: row.statusText, symbol: symbol, tint: tint, secondaryText: true)
            }
            Text(row.enables).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let without = row.withoutIt {
                Text(without).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = row.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
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
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch row.status {
        case .granted: "checkmark.circle.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .notNeeded: "minus.circle"
        case .notGranted: row.pane == .inputMonitoring ? "circle.dashed" : "xmark.circle.fill"
        case .checking: "clock"
        }
    }

    /// P6-0c (visual X2): colour on the symbol only. Input Monitoring is optional, so never red.
    private var tint: Color {
        switch row.status {
        case .granted: .green
        case .needsRelaunch: .orange
        case .notNeeded, .checking: .secondary
        case .notGranted: row.pane == .inputMonitoring ? .secondary : .red
        }
    }
}

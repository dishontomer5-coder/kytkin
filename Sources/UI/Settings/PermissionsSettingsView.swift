// P2-26: The permission rows (001 §5.2, §6). Layout only; `PermissionsSettingsModel` and `PermissionRow` (Core)
// hold every rule and wording and are tested. Every button here is a user click: "Allow…" is the only way to the
// macOS permission dialog, "Open System Settings" the only way to System Settings, "Quit & Reopen" the only relaunch.
// P6-0c (visual review §2.2): no Permissions tab any more. `SetupSection` is the top of General (one line when all is
// fine; the window controller polls permissions once a second while General shows).
// P6-0g (design v2): `TroubleshootingSection` is Advanced's second part (was Diagnostics): the same row style as every
// tab, a status word on the right; "Secure typing"; Input Monitoring only when it could help; "Copy Diagnostics".

import SwiftUI

struct SetupSection: View {
    let model: PermissionsSettingsModel
    /// General → "Show Setup Again…" (a click).
    var showWelcome: (@MainActor () -> Void)? = nil

    var body: some View {
        // P6-0d (owner): no "check again" button: the 1 s poll re-reads while General shows.
        SettingsSection("Setup") {
            if model.setupIsComplete {
                HStack {
                    StatusLabel(text: PermissionsSettingsModel.setupCompleteText, symbol: "checkmark.circle.fill",
                                tint: .green)
                    Spacer()
                    if let showWelcome {
                        Button("Show Setup Again…") { showWelcome() }.buttonStyle(.kytkinLink)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
            } else {
                ForEach(model.setupRows) { row in
                    SettingsCardContent {
                        PermissionRowView(row: row,
                                          grant: { model.grant(row.pane) },
                                          openSettings: { model.openSystemSettings(row.pane) },
                                          quitAndReopen: { model.quitAndReopen() })
                    }
                }
                if let problem = model.keyboardProblemText {
                    SettingsCardContent { WarningLabel(text: "Double-Shift: " + problem) }
                }
                ForEach(model.conflictLines, id: \.self) { line in
                    SettingsCardContent { WarningLabel(text: line) }
                }
                if let showWelcome {
                    SettingsRow("Setup", subtitle: "The 3-step setup: what Kytkin does, permissions and a practice box.") {
                        Button("Show Setup Again…") { showWelcome() }
                    }
                }
            }
        }
    }
}

/// P6-0g: Advanced → Troubleshooting. Plain status lines; nothing here changes a setting.
struct TroubleshootingSection: View {
    let model: PermissionsSettingsModel
    let openSettingsFolder: @MainActor () -> Void
    let copyDiagnostics: @MainActor () -> Void

    var body: some View {
        SettingsSection("Troubleshooting") {
            let doubleShift = model.doubleShiftStatus
            SettingsRow("Double-Shift", subtitle: doubleShift.detail) {
                StatusLabel(text: doubleShift.status, symbol: doubleShift.ok ? "checkmark.circle.fill" : "info.circle",
                            tint: doubleShift.ok ? .green : .secondary)
            }
            ForEach(model.troubleshootingRows) { row in
                if row.showsGrant || row.showsOpenSettings || row.showsQuitAndReopen {
                    SettingsCardContent {
                        PermissionRowView(row: row,
                                          grant: { model.grant(row.pane) },
                                          openSettings: { model.openSystemSettings(row.pane) },
                                          quitAndReopen: { model.quitAndReopen() })
                    }
                } else {
                    SettingsRow(row.title, subtitle: row.enables) {
                        StatusLabel(text: row.statusText, symbol: PermissionRowView.symbol(row),
                                    tint: PermissionRowView.tint(row))
                    }
                }
            }
            let secure = model.secureTyping
            SettingsRow(PermissionsSettingsModel.secureTypingTitle, subtitle: secure.detail) {
                Text(secure.status).foregroundStyle(.secondary)
            }
            SettingsRow("Settings folder", subtitle: "Where Kytkin keeps your rules and settings.") {
                HStack(spacing: 8) {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .help("Copies Kytkin’s version, settings switches, permissions and counts for a bug report. "
                              + "Never what you type, your websites or your rules.")
                    Button("Open Settings Folder") { openSettingsFolder() }   // P6-0c (visual Ab3): moved from About
                }
                .fixedSize()
            }
        }
    }
}

/// One permission: name and status on one line, why, and its buttons (visual review P3: fewer text levels).
struct PermissionRowView: View {
    let row: PermissionRow
    let grant: () -> Void
    let openSettings: () -> Void
    let quitAndReopen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.system(size: SettingsMetrics.titleSize))   // P6-0g: no bold titles
                Spacer()
                StatusLabel(text: row.statusText, symbol: Self.symbol(row), tint: Self.tint(row), secondaryText: true)
            }
            Text(row.enables).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let without = row.withoutIt {
                Text(without).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = row.hint {
                Text(hint).font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.showsGrant || row.showsOpenSettings || row.showsQuitAndReopen {
                HStack(spacing: 12) {
                    if row.showsGrant { Button(row.grantTitle, action: grant) }
                    if row.showsOpenSettings { Button("Open System Settings", action: openSettings).buttonStyle(.kytkinLink) }
                    if row.showsQuitAndReopen { Button("Quit & Reopen", action: quitAndReopen) }
                }
                .padding(.top, 2)
            }
        }
    }

    static func symbol(_ row: PermissionRow) -> String {
        switch row.status {
        case .granted: "checkmark.circle.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .notNeeded: "minus.circle"
        case .notGranted: row.pane == .inputMonitoring ? "circle.dashed" : "xmark.circle.fill"
        case .checking: "clock"
        }
    }

    /// P6-0c (visual X2): colour on the symbol only. Input Monitoring is optional, so never red.
    static func tint(_ row: PermissionRow) -> Color {
        switch row.status {
        case .granted: .green
        case .needsRelaunch: .orange
        case .notNeeded, .checking: .secondary
        case .notGranted: row.pane == .inputMonitoring ? .secondary : .red
        }
    }
}

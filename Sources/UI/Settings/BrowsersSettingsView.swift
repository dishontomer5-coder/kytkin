// P3-15: Settings → Browsers & Sites (001 §14.8). Layout only; `BrowsersSettingsModel` (Core) builds every row and
// text and writes the switches, and is tested. Read-only preferences disable the switches (the notice says why).
// The Automation control is P3-7's: `automationSlot` is where it goes.

import SwiftUI

struct BrowsersSettingsView: View {
    let model: BrowsersSettingsModel
    /// "Open Permissions" on a row that needs Accessibility.
    let openPermissions: @MainActor () -> Void
    /// "Show in Rules": Rules, filtered to websites (D7).
    let showWebsiteRules: @MainActor () -> Void

    var body: some View {
        Form {
            if !model.notices.isEmpty || model.dataMissingNotice != nil {
                Section {
                    SettingsNoticeList(notices: model.notices)
                    if let missing = model.dataMissingNotice {
                        Label(missing, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                let rows = model.rows
                if rows.isEmpty {
                    Text(BrowsersSettingsModel.noBrowsersText).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in browserRow(row) }
            } header: {
                Text("Browsers")
            } footer: {
                Text(BrowsersSettingsModel.introText).font(.caption).foregroundStyle(.secondary)
            }

            Section("Private windows") {
                Toggle(BrowsersSettingsModel.privateToggleTitle, isOn: Binding(
                    get: { model.ignorePrivateWindows },
                    set: { model.ignorePrivateWindows = $0 }))
                    .disabled(!model.isEditable)
                caption(BrowsersSettingsModel.privateExplanation)
                caption(BrowsersSettingsModel.privateDetectionText)
                caption(BrowsersSettingsModel.safariPrivateNote)
            }

            Section("Website rules") {
                HStack {
                    Text(model.websiteRuleCountText)
                    Spacer()
                    Button("Show in Rules") { showWebsiteRules() }
                }
                caption(BrowsersSettingsModel.groupingText)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func browserRow(_ row: BrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text(row.engineText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(BrowsersSettingsModel.siteRulesToggleTitle, isOn: Binding(
                    get: { row.siteRulesOn },
                    set: { model.setSiteRulesEnabled($0, for: row.bundleID) }))
                    .disabled(!model.isEditable)
            }
            HStack(alignment: .firstTextBaseline) {
                Label(row.statusText, systemImage: row.isWorking ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(row.isWorking ? .green : .secondary)
                if row.statusAction == .openPermissions {
                    Button("Open Permissions") { openPermissions() }.controlSize(.small)
                }
            }
            if let hint = row.statusHint { caption(hint) }
            automationSlot(row)
        }
        .padding(.vertical, 2)
    }

    /// P3-7 hook: the "Use Automation" opt-in (and its Allowed / Denied / Ask state) goes here for `.available` rows.
    /// Until P3-7 lands, those rows show nothing; rows without an AppleScript dictionary say why there is none.
    @ViewBuilder private func automationSlot(_ row: BrowserRow) -> some View {
        switch row.automation {
        case .available:
            EmptyView()   // P3-7
        case .notAvailable(let text):
            caption(text)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

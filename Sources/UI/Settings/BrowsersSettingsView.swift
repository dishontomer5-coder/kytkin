// P3-15: Settings → Browsers & Sites (001 §14.8). Layout only; `BrowsersSettingsModel` (Core) builds every row and
// text and writes the switches, and is tested. Read-only preferences disable the switches (the notice says why).
// P3-26 (plan.md Phase 3 decision 2026-11-08): no list of every browser. "All browsers" holds the global switches
// (website rules, Automation, private windows) and one note; a "Browser" dropdown below shows one browser's status,
// engine and Automation permission (Ask / Open System Settings). The macOS Automation question comes only from a
// click: the switch turned on, or Ask.

import SwiftUI

struct BrowsersSettingsView: View {
    let model: BrowsersSettingsModel
    /// "Open Permissions" on a browser that needs Accessibility.
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
                Toggle(BrowsersSettingsModel.siteRulesToggleTitle, isOn: Binding(
                    get: { model.siteRulesOn },
                    set: { model.siteRulesOn = $0 }))
                    .disabled(!model.isEditable)
                VStack(alignment: .leading, spacing: 2) {
                    // P3-26: a click only; turning it on asks macOS for the open browsers, one at a time.
                    Toggle(BrowsersSettingsModel.automationToggleTitle, isOn: Binding(
                        get: { model.useAutomation },
                        set: { model.setUseAutomation($0) }))
                        .disabled(!model.isEditable)
                    caption(BrowsersSettingsModel.automationExplanation)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // P3-29: the address bar uses the browser's language (on by default).
                    Toggle(BrowsersSettingsModel.addressBarToggleTitle, isOn: Binding(
                        get: { model.browserLanguageInAddressBar },
                        set: { model.browserLanguageInAddressBar = $0 }))
                        .disabled(!model.isEditable)
                    caption(BrowsersSettingsModel.addressBarExplanation)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(BrowsersSettingsModel.privateToggleTitle, isOn: Binding(
                        get: { model.ignorePrivateWindows },
                        set: { model.ignorePrivateWindows = $0 }))
                        .disabled(!model.isEditable)
                    caption(BrowsersSettingsModel.privateExplanation)
                    caption(BrowsersSettingsModel.privateDetectionText)
                    caption(BrowsersSettingsModel.safariPrivateNote)
                }
            } header: {
                Text(BrowsersSettingsModel.allBrowsersTitle)
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    caption(BrowsersSettingsModel.introText)
                    caption(BrowsersSettingsModel.skipNote)
                }
            }

            Section(BrowsersSettingsModel.browserPickerTitle) {
                let rows = model.rows
                if let selected = model.selectedRow {
                    Picker(BrowsersSettingsModel.browserPickerTitle, selection: Binding(
                        get: { selected.bundleID },
                        set: { model.selectedBrowserID = $0 })) {
                        ForEach(rows) { row in Text(row.name).tag(row.bundleID) }
                    }
                    browserDetails(selected)
                } else {
                    Text(BrowsersSettingsModel.noBrowsersText).foregroundStyle(.secondary)
                }
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

    /// P3-26: the chosen browser: engine, status (+ hint, + Open Permissions) and its Automation permission.
    @ViewBuilder private func browserDetails(_ row: BrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.engineText).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Label(row.statusText, systemImage: row.isWorking ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(row.isWorking ? .green : .secondary)
                Spacer()
                if row.statusAction == .openPermissions {
                    Button("Open Permissions") { openPermissions() }.controlSize(.small)
                }
            }
            if let hint = row.statusHint { caption(hint) }
        }
        .padding(.vertical, 2)
        automationSlot(row)
    }

    /// P3-7 / P3-26: the chosen browser's Automation permission (Off / Allowed / Denied / Not asked / Checking) and
    /// its button (Ask / Open System Settings), each a user click passed to the model. Browsers without an AppleScript
    /// dictionary (Zen, Firefox, Orion, other browsers) say it isn't available.
    @ViewBuilder private func automationSlot(_ row: BrowserRow) -> some View {
        switch row.automation {
        case .available(let state):
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Automation")
                    if let text = row.automationStatusText { caption(text) }
                }
                Spacer()
                if let title = state.actionTitle() {
                    Button(title) {
                        switch state.action {
                        case .ask: model.askAutomation(for: row.bundleID)
                        case .openSystemSettings: model.openAutomationSettings()
                        case nil: break
                        }
                    }
                    .controlSize(.small)
                    .disabled(!state.actionEnabled)
                }
            }
        case .notAvailable(let text):
            caption(text)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

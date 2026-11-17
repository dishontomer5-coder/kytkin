// P3-15: Settings → Browsers & Sites (001 §14.8). Layout only; `BrowsersSettingsModel` (Core) builds every row and
// text and writes the switches, and is tested. Read-only preferences disable the switches (the notice says why).
// P3-26 (plan.md Phase 3 decision 2026-11-08): no list of every browser. "All browsers" holds the global switches
// (website rules, Automation, private windows) and one note; a "Browser" dropdown below shows one browser's status,
// engine and Automation permission (Ask / Open System Settings). The macOS Automation question comes only from a
// click: the switch turned on, or Ask.

import SwiftUI

struct BrowsersSettingsView: View {
    let model: BrowsersSettingsModel
    /// "Open Setup" on a browser that needs Accessibility (P6-0c: General's setup section).
    let openPermissions: @MainActor () -> Void
    /// "Show in Rules": Rules, filtered to websites (D7).
    let showWebsiteRules: @MainActor () -> Void

    var body: some View {
        Form {
            NoticeSection(notices: model.notices, extra: model.dataMissingNotice.map { [$0] } ?? [])

            Section {
                // P6-0c (visual review B4): the tab's intro is the main switch's subtitle.
                Toggle(isOn: Binding(get: { model.siteRulesOn }, set: { model.siteRulesOn = $0 })) {
                    RowLabel(BrowsersSettingsModel.siteRulesToggleTitle, subtitle: BrowsersSettingsModel.introText)
                }
                .disabled(!model.isEditable)
                // P3-26: a click only; turning it on asks macOS for the open browsers, one at a time.
                Toggle(isOn: Binding(get: { model.useAutomation }, set: { model.setUseAutomation($0) })) {
                    RowLabel(BrowsersSettingsModel.automationToggleTitle,
                             subtitle: BrowsersSettingsModel.automationExplanation)
                }
                .disabled(!model.isEditable)
                // P3-29: the address bar uses the browser's language (on by default).
                Toggle(isOn: Binding(get: { model.browserLanguageInAddressBar },
                                     set: { model.browserLanguageInAddressBar = $0 })) {
                    RowLabel(BrowsersSettingsModel.addressBarToggleTitle,
                             subtitle: BrowsersSettingsModel.addressBarExplanation)
                }
                .disabled(!model.isEditable)
                // P6-0c (visual review B2, copy B-5): one line; the per-browser detection is in the browser's status.
                Toggle(isOn: Binding(get: { model.ignorePrivateWindows }, set: { model.ignorePrivateWindows = $0 })) {
                    RowLabel(BrowsersSettingsModel.privateToggleTitle, subtitle: BrowsersSettingsModel.privateExplanation)
                }
                .disabled(!model.isEditable)
            }

            Section("Your browsers") {
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

            Section {
                LabeledContent {
                    Button("Show in Rules") { showWebsiteRules() }
                } label: {
                    RowLabel(model.websiteRuleCountText, subtitle: BrowsersSettingsModel.groupingText)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// P3-26: the chosen browser: engine, status (+ hint, + Open Setup) and its Automation permission.
    /// P6-0c (visual X2): colour only on the status symbol.
    @ViewBuilder private func browserDetails(_ row: BrowserRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                StatusLabel(text: row.statusText, symbol: row.isWorking ? "checkmark.circle.fill" : "info.circle",
                            tint: row.isWorking ? .green : .secondary)
                Spacer()
                if row.statusAction == .openPermissions {
                    Button("Open Setup") { openPermissions() }.controlSize(.small)
                }
            }
            if let hint = row.statusHint { caption(hint) }
            caption(row.engineText)
            if let note = row.privateNote { caption(note) }
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

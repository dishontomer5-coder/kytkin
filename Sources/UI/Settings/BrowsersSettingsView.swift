// P3-15: Settings → Websites (001 §14.8). Layout only; `BrowsersSettingsModel` (Core) builds every row and text and
// writes the switches, and is tested. Read-only preferences disable the switches (the notice says why).
// The macOS Automation question comes only from a click: the switch turned on, or a browser's "Allow…".
// P6-0g (design v2, proposed-websites): with "Use website rules" off, everything under it is dimmed and disabled;
// "Work in more browsers" and "Ignore private windows"; "Your Browsers" lists only real browsers, each with one status
// line and the one button that fixes it; one footer line with "Show in Rules".

import SwiftUI

struct BrowsersSettingsView: View {
    let model: BrowsersSettingsModel
    /// "Open Setup" on a browser that needs Accessibility (P6-0c: General's setup section).
    let openPermissions: @MainActor () -> Void
    /// "Show in Rules": Rules, filtered to websites (D7).
    let showWebsiteRules: @MainActor () -> Void

    var body: some View {
        let on = model.siteRulesOn
        SettingsPage {
            NoticeLines(notices: model.notices, extra: model.dataMissingNotice.map { [$0] } ?? [])

            SettingsSection {
                // P6-0c (visual review B4): the tab's intro is the main switch's subtitle.
                SettingsToggleRow(BrowsersSettingsModel.siteRulesToggleTitle, subtitle: BrowsersSettingsModel.introText,
                                  isOn: Binding(get: { model.siteRulesOn }, set: { model.siteRulesOn = $0 }))
                    .disabled(!model.isEditable)
            }

            Group {
                SettingsSection {
                    // P3-26: a click only; turning it on asks macOS for the open browsers, one at a time.
                    SettingsToggleRow(BrowsersSettingsModel.automationToggleTitle,
                                      subtitle: BrowsersSettingsModel.automationExplanation,
                                      isOn: Binding(get: { model.useAutomation }, set: { model.setUseAutomation($0) }))
                    // P3-29: the address bar uses the browser's language (on by default).
                    SettingsToggleRow(BrowsersSettingsModel.addressBarToggleTitle,
                                      subtitle: BrowsersSettingsModel.addressBarExplanation,
                                      isOn: Binding(get: { model.browserLanguageInAddressBar },
                                                    set: { model.browserLanguageInAddressBar = $0 }))
                    SettingsToggleRow(BrowsersSettingsModel.privateToggleTitle,
                                      subtitle: BrowsersSettingsModel.privateExplanation,
                                      isOn: Binding(get: { model.ignorePrivateWindows },
                                                    set: { model.ignorePrivateWindows = $0 }))
                }
                .disabled(!model.isEditable)

                SettingsSection("Your Browsers") {
                    let rows = model.rows
                    if rows.isEmpty {
                        SettingsRow(BrowsersSettingsModel.noBrowsersText)
                    }
                    ForEach(rows) { row in
                        let line = model.statusLine(for: row)
                        SettingsRow(row.name, subtitle: line.text) {
                            if let title = line.actionTitle {
                                Button(title) { perform(line.action, row) }
                            }
                        }
                        .help([line.help, row.privateNote].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.5)

            HStack(alignment: .center, spacing: 16) {
                Text(model.footerText)
                    .font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Show in Rules") { showWebsiteRules() }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Each one a user click passed to the model (the Automation question only from here or the switch).
    private func perform(_ action: BrowsersSettingsModel.StatusLine.Action?, _ row: BrowserRow) {
        switch action {
        case .openSetup: openPermissions()
        case .askAutomation: model.askAutomation(for: row.bundleID)
        case .openAutomationSettings: model.openAutomationSettings()
        case nil: break
        }
    }
}

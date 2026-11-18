// P2-23: Settings → General (001 §5.2). Layout only; `GeneralSettingsModel` (Core) holds the logic and is tested.
// Read-only preferences disable the preferences controls (the model's notice says why); Open at Login stays usable
// because it isn't stored in the preferences file.
// P6-0c (visual review §2.3): the setup status (was the Permissions tab) sits on top, one line when all is fine; the
// language pair moved here from Languages; explanations sit inside their rows.
// P6-0g (design v2, proposed-general / lg-general): the switch is "Kytkin"; the pair is one wide two-half key with the
// two standard pickers and a round swap button on the seam; "Show in menu bar" is a radio group of three tiles, each
// with the real menu-bar item; the privacy line at the bottom.

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
    let permissions: PermissionsSettingsModel
    @Environment(LanguagesSettingsModel.self) private var languages
    /// P2-26: reopens the setup window (user click only).
    let showWelcome: @MainActor () -> Void

    var body: some View {
        SettingsPage {
            NoticeLines(notices: model.notices)
            SetupSection(model: permissions, showWelcome: showWelcome)

            SettingsSection("Kytkin") {   // P6-0e (mock-up settings-general): headed sections
                SettingsToggleRow(GeneralSettingsModel.enabledTitle, subtitle: GeneralSettingsModel.enabledHelp,
                                  isOn: $model.enabled)
                    .disabled(!model.isEditable)
                SettingsToggleRow(GeneralSettingsModel.learnTitle, subtitle: GeneralSettingsModel.learnHelp,
                                  isOn: $model.learnFromManualSwitches)
                    .disabled(!model.isEditable)
                SettingsRow("When an app has no rule") {
                    Picker("When an app has no rule", selection: $model.defaultBehaviorID) {
                        ForEach(model.defaultBehaviorOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
                .disabled(!model.isEditable)
                SettingsToggleRow("Open at Login", subtitle: model.loginItemHint ?? "Starts Kytkin when you log in.",
                                  isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.showsOpenLoginItems {
                    SettingsCardContent { Button("Open Login Items…") { model.openLoginItems() } }
                }
                if let error = model.loginItemError {
                    SettingsCardContent { StatusLabel(text: error, symbol: "xmark.circle.fill", tint: .red) }
                }
            }

            SettingsSection("Languages") {
                SettingsCardContent {
                    RowLabel(GeneralSettingsModel.languagesTitle, subtitle: GeneralSettingsModel.languagesHelp)
                    LanguagePairKey(model: languages)   // P6-0g (lg-general)
                        .padding(.top, 4)
                    LanguagePairProblems(model: languages)
                }
                .disabled(!languages.isEditable)
            }

            SettingsSection("Menu Bar") {
                SettingsCardContent {
                    RowLabel("Show in menu bar", subtitle: GeneralSettingsModel.menuBarDisplayHelp)
                    MenuBarDisplayTiles(model: model).padding(.top, 4)
                        .disabled(!model.isEditable)
                }
            }

            if let updates = model.updates {
                UpdatesSection(updates: updates, model: model)   // P6-3
            }

            PrivacyLine()   // P6-0g (review P1)
        }
    }
}

/// The preferences-file notices, above everything (nothing when there are none).
struct NoticeLines: View {
    let notices: [SettingsNotice]
    var extra: [String] = []

    var body: some View {
        if !notices.isEmpty || !extra.isEmpty {
            SettingsSection {
                ForEach(notices) { notice in SettingsCardContent { WarningLabel(text: notice.message) } }
                ForEach(extra, id: \.self) { line in SettingsCardContent { WarningLabel(text: line) } }
            }
        }
    }
}

/// P6-0g (lg-general "Show in menu bar"): three tiles, each the real status-item image in that mode, a radio button
/// and its name. Replaces the pop-up and the separate preview.
struct MenuBarDisplayTiles: View {
    @Bindable var model: GeneralSettingsModel
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Preferences.General.MenuBarLabel.allCases, id: \.self) { display in
                tile(display)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show in menu bar")
    }

    private func tile(_ display: Preferences.General.MenuBarLabel) -> some View {
        let selected = model.menuBarDisplay == display
        return Button { model.menuBarDisplay = display } label: {
            VStack(spacing: 8) {
                MenuBarPreview(label: model.menuBarPreview(for: display))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.kytkinAccent : Color.secondary)
                    Text(GeneralSettingsModel.title(of: display)).font(.system(size: SettingsMetrics.titleSize))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.kytkinAccent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(GeneralSettingsModel.title(of: display))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// P6-3, P4-3: "Keep Kytkin up to date". Off until the user turns it on; "Check Now…" (Sparkle's window) only while on.
private struct UpdatesSection: View {
    let updates: UpdateController
    let model: GeneralSettingsModel

    var body: some View {
        SettingsSection("Updates") {
            SettingsToggleRow(GeneralSettingsModel.keepUpToDateTitle, subtitle: GeneralSettingsModel.keepUpToDateHelp,
                              isOn: Binding(get: { updates.isOn }, set: { updates.setOn($0) }))
                .disabled(!model.isEditable)
            if updates.isOn {
                SettingsRow("Kytkin \(updates.appVersion)", subtitle: updates.statusText) {
                    Button("Check Now…") { updates.checkNow() }
                        .disabled(!updates.canCheckNow)
                }
            }
        }
    }
}

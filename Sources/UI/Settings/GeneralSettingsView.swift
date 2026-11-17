// P2-23: Settings → General (001 §5.2). Layout only; `GeneralSettingsModel` (Core) holds the logic and is tested.
// Read-only preferences disable the preferences controls (the model's notice says why); Open at Login stays usable
// because it isn't stored in the preferences file.
// P6-0c (visual review §2.3): the setup status (was the Permissions tab) sits on top, one line when all is fine; the
// language pair moved here from Languages; explanations sit inside their rows.

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel
    let permissions: PermissionsSettingsModel
    @Environment(LanguagesSettingsModel.self) private var languages
    /// P2-26: reopens the setup window (user click only).
    let showWelcome: @MainActor () -> Void

    var body: some View {
        Form {
            NoticeSection(notices: model.notices)
            SetupSection(model: permissions)

            Section {
                Toggle(isOn: $model.enabled) {
                    // P6-0c (copy review S-4): off vs paused.
                    RowLabel("Kytkin is on", subtitle: "When off, Kytkin does nothing until you turn it back on. "
                             + "To stop it for a while, use Pause in the menu.")
                }
                Toggle(isOn: $model.learnFromManualSwitches) {
                    // P6-0c (copy review S-5): websites learn too.
                    RowLabel("Learn from my switches", subtitle: "When you switch the language yourself, Kytkin "
                             + "remembers it for that app or website.")
                }
                Picker("When an app has no rule", selection: $model.defaultBehaviorID) {
                    ForEach(model.defaultBehaviorOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }
            .disabled(!model.isEditable)

            Section("Your two languages") {
                LanguagePairPickers(model: languages)
            }
            .disabled(!languages.isEditable)

            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    RowLabel("Open at Login", subtitle: model.loginItemHint)
                }
                if model.showsOpenLoginItems {
                    Button("Open Login Items…") { model.openLoginItems() }
                }
                if let error = model.loginItemError {
                    StatusLabel(text: error, symbol: "xmark.circle.fill", tint: .red)
                }
            }

            Section {
                LabeledContent {
                    Button("Show Setup Again…") { showWelcome() }
                } label: {
                    // P6-0c (copy review S-9).
                    RowLabel("Setup", subtitle: "The 3-step setup: what Kytkin does, permissions and a practice box.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

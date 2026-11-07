// P2-23: Settings → General (001 §5.2). Layout only; `GeneralSettingsModel` (Core) holds the logic and is tested.
// Read-only preferences disable the preferences controls (the model's notice says why); Open at Login stays usable
// because it isn't stored in the preferences file.

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.notices) { notice in
                Label(notice.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                Section {
                    Toggle("Kytkin is on", isOn: $model.enabled)
                    Text("When off, Kytkin doesn't switch languages, learn, or convert.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Learn from my manual switches", isOn: $model.learnFromManualSwitches)
                    Text("When you switch the language yourself in an app, Kytkin remembers it for that app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("When an app has no rule", selection: $model.defaultBehaviorID) {
                        ForEach(model.defaultBehaviorOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                }
                .disabled(!model.isEditable)

                Section {
                    Toggle("Open at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }))
                    if let hint = model.loginItemHint {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.showsOpenLoginItems {
                        Button("Open Login Items…") { model.openLoginItems() }
                    }
                    if let error = model.loginItemError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

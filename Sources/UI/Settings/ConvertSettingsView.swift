// P2-25: Settings → Convert (001 §5.2). Layout only; `ConvertSettingsModel` (Core) holds the logic and is tested.
// Read-only preferences disable every control (the notice says why). Auto-fix (Phase 4) is only a note.

import SwiftUI

struct ConvertSettingsView: View {
    @Bindable var model: ConvertSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsNoticeList(notices: model.notices)
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ConvertSettingsModel.explanation, id: \.self) { line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Convert with double-Shift", isOn: $model.doubleShiftEnabled)
                    Picker("Press", selection: $model.sidesID) {
                        ForEach(model.sidesOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .disabled(!model.doubleShiftEnabled)
                    LabeledContent("Time between presses") {
                        HStack {
                            Slider(value: $model.windowMs, in: ConvertSettingsModel.sliderRange,
                                   step: Double(ConvertSettingsModel.windowStepMs))
                            Text(model.windowText).monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                    .disabled(!model.doubleShiftEnabled)
                    Text("A shorter time avoids converting by accident; a longer one is easier to press.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Switch language after converting", isOn: $model.switchLanguageAfterConvert)
                        .disabled(!model.doubleShiftEnabled)
                    Text("Afterwards, the keyboard is in the language you meant to type.")
                        .font(.caption).foregroundStyle(.secondary)
                    // P3-37
                    Toggle("Use the clipboard in apps Kytkin can't read", isOn: $model.useClipboardInUnreadableApps)
                        .disabled(!model.doubleShiftEnabled)
                    Text(ConvertSettingsModel.clipboardNote)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!model.isEditable)

                Section {
                    Text(ConvertSettingsModel.autoFixNote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

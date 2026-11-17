// P2-25: Settings → Double-Shift (001 §5.2; was "Convert"). Layout only; `ConvertSettingsModel` (Core) holds the
// logic and is tested. Read-only preferences disable every control (the notice says why).
// P6-0c (visual review C1, C2, C3, C4): the switch comes first with a one-line summary; every explanation sits in its
// row; the longer "how it works" lines are behind a disclosure; the auto-fix teaser left Settings.

import SwiftUI

struct ConvertSettingsView: View {
    @Bindable var model: ConvertSettingsModel
    @State private var showsHowItWorks = false

    var body: some View {
        Form {
            NoticeSection(notices: model.notices)

            Section {
                Toggle(isOn: $model.doubleShiftEnabled) {
                    RowLabel("Convert with double-Shift", subtitle: ConvertSettingsModel.summary)
                }
                Picker("Keys", selection: $model.sidesID) {
                    ForEach(model.sidesOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .disabled(!model.doubleShiftEnabled)
                LabeledContent {
                    Slider(value: $model.windowMs, in: ConvertSettingsModel.sliderRange) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Shorter").font(.caption)
                    } maximumValueLabel: {
                        Text("Longer").font(.caption)
                    }
                    .help(model.windowText)
                } label: {
                    RowLabel("Time between presses",
                             subtitle: "Shorter avoids converting by accident. Longer is easier to press.")
                }
                .disabled(!model.doubleShiftEnabled)
                Toggle(isOn: $model.switchLanguageAfterConvert) {
                    RowLabel("Switch language after converting",
                             subtitle: "Afterwards, the keyboard is in the language you meant to type.")
                }
                .disabled(!model.doubleShiftEnabled)
                // P3-37; P6-0c (copy review C-3, C-4: the P3-18 M1 clipboard disclosure).
                Toggle(isOn: $model.useClipboardInUnreadableApps) {
                    RowLabel(ConvertSettingsModel.clipboardTitle, subtitle: ConvertSettingsModel.clipboardNote)
                }
                .disabled(!model.doubleShiftEnabled)
            }
            .disabled(!model.isEditable)

            Section {
                DisclosureGroup("How it works", isExpanded: $showsHowItWorks) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ConvertSettingsModel.explanation, id: \.self) { line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
    }
}

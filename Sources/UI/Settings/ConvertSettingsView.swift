// P2-25: Settings → Double-Shift (001 §5.2; was "Convert"). Layout only; `ConvertSettingsModel` (Core) holds the
// logic and is tested. Read-only preferences disable every control (the notice says why).
// P6-0c (visual review C1, C2, C3, C4): the switch comes first with a one-line summary; every explanation sits in its
// row; the auto-fix teaser left Settings.
// P6-0g (design v2, proposed-double-shift): the clipboard switch is "Work in more apps (uses the clipboard)" with the
// short text and "Learn more…" (a popover with the details and what turning it off does); "How It Works" moved behind
// a link and a help button (a popover), so the tab fits the window.

import AppKit
import SwiftUI

struct ConvertSettingsView: View {
    @Bindable var model: ConvertSettingsModel
    @State private var showsClipboardDetails = false
    @State private var showsHowItWorks = false

    var body: some View {
        SettingsPage {
            NoticeLines(notices: model.notices)

            SettingsSection {
                SettingsToggleRow(ConvertSettingsModel.toggleTitle, subtitle: ConvertSettingsModel.summary,
                                  isOn: $model.doubleShiftEnabled)
                SettingsRow("Keys") {
                    Picker("Keys", selection: $model.sidesID) {
                        ForEach(model.sidesOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(!model.doubleShiftEnabled)
                SettingsRow("Time between presses",
                            subtitle: "Shorter avoids converting by accident. Longer is easier to press.") {
                    Slider(value: $model.windowMs, in: ConvertSettingsModel.sliderRange) {
                        Text("Time between presses")
                    } minimumValueLabel: {
                        Text("Shorter").font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Longer").font(.system(size: SettingsMetrics.secondarySize)).foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    .help(model.windowText)
                }
                .disabled(!model.doubleShiftEnabled)
                SettingsToggleRow("Switch language after converting",
                                  subtitle: "Afterwards, the keyboard is in the language you meant to type.",
                                  isOn: $model.switchLanguageAfterConvert)
                    .disabled(!model.doubleShiftEnabled)
            }
            .disabled(!model.isEditable)

            // P3-37; P6-0c (copy review C-3, C-4: the P3-18 M1 clipboard disclosure); P6-0g: short, details behind
            // "Learn more…".
            SettingsSection {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConvertSettingsModel.clipboardTitle).font(.system(size: SettingsMetrics.titleSize))
                        (Text(ConvertSettingsModel.clipboardNote + " ").foregroundStyle(.secondary))
                            .font(.system(size: SettingsMetrics.secondarySize))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Learn more…") { showsClipboardDetails = true }
                            .buttonStyle(.kytkinLink)
                            .font(.system(size: SettingsMetrics.secondarySize))
                            .popover(isPresented: $showsClipboardDetails, arrowEdge: .bottom) {
                                DetailsPopover(title: ConvertSettingsModel.clipboardTitle,
                                               lines: ConvertSettingsModel.clipboardDetails)
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(ConvertSettingsModel.clipboardTitle, isOn: $model.useClipboardInUnreadableApps)
                        .labelsHidden().toggleStyle(.switch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .disabled(!model.doubleShiftEnabled)
            }
            .disabled(!model.isEditable)

            // P6-0g (review P1): "How It Works" behind a link and a help button.
            HStack {
                Button(ConvertSettingsModel.howItWorksLink) { showsHowItWorks = true }
                    .buttonStyle(.kytkinLink)
                    .popover(isPresented: $showsHowItWorks, arrowEdge: .bottom) {
                        DetailsPopover(title: ConvertSettingsModel.howItWorksTitle, lines: ConvertSettingsModel.explanation)
                    }
                Spacer()
                HelpButton { showsHowItWorks = true }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// P6-0g: the details behind a "Learn more…" / "How It Works" link.
struct DetailsPopover: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: SettingsMetrics.titleSize, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}

/// The round "?" help button (AppKit's own bezel).
struct HelpButton: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: NSViewRepresentableContext<HelpButton>) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.click))
        button.bezelStyle = .helpButton
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: NSViewRepresentableContext<HelpButton>) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func click() { action() }
    }
}

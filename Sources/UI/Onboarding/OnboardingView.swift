// P2-26: The welcome window's content (001 §6.1). Layout and wording only; `OnboardingModel` (Core) holds the steps,
// the "seen" flag, the default language pair and the Accessibility state, and is tested. The only way to the macOS
// permission dialog is the "Allow Accessibility…" button.

import SwiftUI

struct OnboardingView: View {
    let model: OnboardingModel
    /// Closes the window (Done or Skip). The window controller calls `model.finish()` when it closes.
    let close: @MainActor () -> Void

    static let size = CGSize(width: 520, height: 440)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if !model.isLastStep {
                    Button("Skip") { close() }
                        .help("You can open this again from Settings → General.")
                }
                Spacer()
                StepDots(current: model.step)
                Spacer()
                if !model.isFirstStep {
                    Button("Back") { model.back() }
                }
                Button(model.primaryTitle) {
                    if model.isLastStep { close() } else { model.next() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .languages: languages
        case .accessibility: accessibility
        case .finish: finish
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to Kytkin").font(.largeTitle).bold()
            Text("Kytkin switches your keyboard language for you. It remembers which language you use in each app "
                 + "and switches when you go back to it.")
            Text("Typed something in the wrong language? Press Shift twice and Kytkin fixes it.")
            Spacer().frame(height: 4)
            Label("Kytkin never saves or sends what you type.", systemImage: "lock")
            Label("It doesn't use the internet, except to check for updates.", systemImage: "network.slash")
            Label("No account and no tracking.", systemImage: "person.crop.circle.badge.xmark")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your two languages").font(.title).bold()
            Text("Kytkin picked these from the keyboards turned on in your Mac. Change them if they're not right.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                LanguagePairPickers(model: model.languages)
            }
            .formStyle(.grouped)
            .disabled(!model.languages.isEditable)
            Text("You can change them later in Settings → Languages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow Accessibility").font(.title).bold()
            Text("To fix text when you press Shift twice, Kytkin needs the Accessibility permission. macOS asks "
                 + "you once.")
                .fixedSize(horizontal: false, vertical: true)
            // QA (P2-26): with no Input Monitoring either, Shift twice does nothing (001 §6.2), so don't promise it.
            Text("Without it, Kytkin still switches the language for each app, but pressing Shift twice can't fix "
                 + "text.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            accessibilityStatus
            Spacer()
            Text("You can do this later in Settings → Permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessibilityStatus: some View {
        switch model.accessibilityPhase {
        case .checking:
            ProgressView().controlSize(.small)
        case .notAsked:
            HStack(spacing: 12) {
                Button("Allow Accessibility…") { model.grantAccessibility() }
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.link)
            }
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you…")
                }
                Text("In System Settings → Privacy & Security → Accessibility, turn on “\(model.appName)”. "
                     + "If it isn't in the list, click + under the list and choose \(model.appName).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.link)
            }
        case .granted:
            Label("Done! Kytkin can now fix text when you press Shift twice.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're all set").font(.title).bold()
            Text("Kytkin lives in the menu bar at the top of your screen: look for the language label (EN or HE). "
                 + "Click it for options and Settings.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Toggle("Open Kytkin when I log in", isOn: Binding(
                    get: { model.general.launchAtLogin },
                    set: { model.general.setLaunchAtLogin($0) }))
                if let hint = model.general.loginItemHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.general.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Which step you're on, as small dots.
private struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }
}

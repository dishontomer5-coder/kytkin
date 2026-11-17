// P2-26: The setup window's content (001 §6.1). Layout and wording only; `OnboardingModel` (Core) holds the steps,
// the "seen" flag, the default language pair, the Accessibility state and the practice box, and is tested. The only
// way to the macOS permission dialog is the "Allow Accessibility…" button.
// P6-0c (owner 2026-11-17; copy review §4.1, flows §5.2–§5.4, visual review O1–O6): three screens (what Kytkin does
// and your two languages → Accessibility with why → try double-Shift), one title style, a fixed three-column footer
// so the dots never move, and a "Move Kytkin to Applications first" screen when it runs from the disk image.

import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Closes the window (Done or Skip). The window controller calls `model.finish()` when it closes.
    let close: @MainActor () -> Void
    /// "Show in Finder" on the move screen.
    var showInFinder: @MainActor () -> Void = {}
    /// "Quit" on the move screen.
    var quit: @MainActor () -> Void = {}

    static let size = CGSize(width: 540, height: 480)

    var body: some View {
        Group {
            if model.mustMoveToApplications {
                MoveToApplicationsView(showInFinder: showInFinder, quit: quit)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    footer
                }
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .practice: PracticeStep(model: model)
        }
    }

    /// Visual review O4: three equal columns, so the dots stay put on every screen.
    private var footer: some View {
        HStack {
            HStack {
                if model.isFirstStep {
                    Button("Skip Setup") { close() }
                        .help("You can open this again in Settings → General.")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            StepDots(current: model.step, description: model.stepDescription)
            HStack {
                Spacer()
                if !model.isFirstStep { Button("Back") { model.back() } }
                Button(model.primaryTitle) {
                    if model.isLastStep {
                        model.done()
                        close()
                    } else {
                        model.next()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Screen 1: what Kytkin does

private struct WelcomeStep: View {
    let model: OnboardingModel
    @State private var showsPickers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                Text("Kytkin keeps your keyboard in the right language").font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("It remembers the language you use in each app and website, and switches for you.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Typed in the wrong language? Press Shift twice and Kytkin converts it:")
                .fixedSize(horizontal: false, vertical: true)
            // Copy review B7: the Hebrew sample on its own line, isolated, so bidi never flips it.
            Text("akuo  →  \u{2068}שלום\u{2069}").font(.title3).padding(.leading, 12)

            HStack {
                Text("Your two languages:").foregroundStyle(.secondary)
                Text(pairText).bold()
                Button(showsPickers ? "Done" : "Change…") { showsPickers.toggle() }.buttonStyle(.link)
            }
            if showsPickers {
                Form { LanguagePairPickers(model: model.languages) }
                    .formStyle(.grouped)
                    .frame(height: 150)
                    .disabled(!model.languages.isEditable)
                Text("You can change these later in Settings → General.").font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            // Visual review O3: fixed-width icons, so the three lines start at one edge. Flows M8: no update claim.
            VStack(alignment: .leading, spacing: 6) {
                privacy("lock", "What you type stays on your Mac. Kytkin never saves or sends it.")
                privacy("network.slash", "No internet, no account, no tracking.")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { showsPickers = !model.languages.pairWarnings.isEmpty || model.languages.pairProblem != nil }
    }

    private var pairText: String {
        let options = model.languages.options
        let name = { (id: InputSourceID) in options.first { $0.id == id }?.name ?? id.rawValue }
        let pair = model.languages.pair
        return "\(name(pair.a))  ⇄  \(name(pair.b))"
    }

    private func privacy(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Screen 2: Accessibility, with why

private struct PermissionsStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One permission: Accessibility").font(.title2.bold())
            Text("Kytkin needs Accessibility to read and replace the text you convert, and to see which website "
                 + "you're on. macOS asks you once.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Kytkin only reads text when you press Shift twice, and never saves it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Without it, Kytkin still switches the language for each app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status
            Spacer()
            Text("Later: Kytkin menu → Settings → General.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.accessibilityPhase {
        case .checking:
            ProgressView().controlSize(.small)
        case .notAsked:
            HStack(spacing: 12) {
                Button("Allow Accessibility…") { model.grantAccessibility() }.buttonStyle(.borderedProminent)
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.link)
            }
        case .waiting, .waitingLong:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting… In System Settings → Privacy & Security → Accessibility, turn on "
                         + "\(model.appName). Not in the list? Click + and choose \(model.appName).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.accessibilityPhase == .waitingLong {
                    // Flows M4: a stale entry from an older copy.
                    Text("Already on? Select \(model.appName), click –, then click Allow Accessibility… again.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Allow Accessibility…") { model.grantAccessibility() }
                }
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.link)
            }
        case .granted:
            StatusLabel(text: "Accessibility is on.", symbol: "checkmark.circle.fill", tint: .green)
        }
    }
}

// MARK: - Screen 3: try double-Shift

private struct PracticeStep: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try double-Shift").font(.title2.bold())
            Text("Type in the box below with the wrong keyboard, then press Shift twice.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type here…", text: $model.practiceText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .accessibilityLabel("Practice box")
            Text(model.practiceHint).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            result
            Spacer()
            // P6-0c QA: Text concatenation, not an Image interpolated into a String (that rendered "Image(provider: …)").
            (Text("Kytkin lives in the menu bar, at the top right of your screen. Look for ")
                + Text(Image(systemName: "keyboard"))
                + Text(" and the language letters, like HE or EN."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open Kytkin when I log in", isOn: $model.openAtLogin)
            if let error = model.general.loginItemError {
                StatusLabel(text: error, symbol: "xmark.circle.fill", tint: .red).font(.caption)
            }
        }
        .onAppear { focused = true }
        .onChange(of: focused) { model.practiceFocused = focused }
        .onChange(of: model.practiceText) { model.practiceTextChanged() }
    }

    @ViewBuilder private var result: some View {
        switch model.practiceResult {
        case .none:
            EmptyView()
        case .converted(let language):
            StatusLabel(text: "That's it. Kytkin converted it and switched to \(language).",
                        symbol: "checkmark.circle.fill", tint: .green)
        case .convertedBack:
            StatusLabel(text: "Pressing Shift twice again converts it back.", symbol: "arrow.uturn.backward.circle",
                        tint: .secondary)
        case .nothingToConvert:
            StatusLabel(text: "Nothing to convert yet. Type a word on the other keyboard first.", symbol: "info.circle",
                        tint: .secondary)
        }
    }
}

// MARK: - Before setup: running from the disk image

/// Flows §1.1 step 6 (M2): permissions given to a copy on the disk image are lost; nothing is asked here.
private struct MoveToApplicationsView: View {
    let showInFinder: @MainActor () -> Void
    let quit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Kytkin to Applications first").font(.title2.bold())
            Text("Kytkin is running from the disk image (or Downloads), so macOS won't keep its permissions. Drag "
                 + "Kytkin into Applications, then open it from there.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Quit") { quit() }
                Button("Show in Finder") { showInFinder() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Which step you're on, as small dots.
private struct StepDots: View {
    let current: OnboardingModel.Step
    let description: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(description)
    }
}

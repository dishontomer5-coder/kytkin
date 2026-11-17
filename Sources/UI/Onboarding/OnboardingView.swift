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

    /// P6-0e (Colors.md "First run": one fixed frame for every screen; 560 wide, a little taller than the mock-ups'
    /// 420 so the privacy lines and the inline pair pickers fit).
    static let size = CGSize(width: 560, height: 470)

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
            // P6-0e (Colors.md, mock-ups): Back always in the same place, on the left; Skip Setup there on screen 1.
            HStack {
                if model.isFirstStep {
                    // P6-3 QA (a): secondary buttons in primary text; the accent is for the main button only.
                    Button("Skip Setup") { close() }
                        .tint(.primary)
                        .help("You can open this again in Settings → General.")
                } else {
                    Button("Back") { model.back() }.tint(.primary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            StepDots(current: model.step, description: model.stepDescription)
            HStack {
                Spacer()
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

/// P6-0e (mock-ups firstrun-1…3): every screen starts the same way: a 56 pt tile, the title (22 pt bold), a subtitle.
private struct StepHeader: View {
    enum Tile { case appIcon, symbol(String) }
    let tile: Tile
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch tile {
            case .appIcon:
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
            case .symbol(let name):
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0x1A / 255, green: 0x9E / 255, blue: 0x85 / 255),
                                                  Color(red: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: name).font(.system(size: 24, weight: .medium)).foregroundStyle(.white))
                    .accessibilityHidden(true)
            }
            Text(title).font(.system(size: 22, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// P6-0e: a rounded box like the mock-ups' grouped rows.
private struct Box<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct WelcomeStep: View {
    let model: OnboardingModel
    @State private var showsPickers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(tile: .appIcon, title: "Kytkin keeps your keyboard in the right language",
                       subtitle: "A small helper that lives in the menu bar.")
            feature("keyboard", "It remembers the language you use in each app and website, and switches for you.")
            feature("shift", "Typed in the wrong language? Press Shift twice and Kytkin converts it:")
            // Copy review B7: the Hebrew sample on its own line, isolated, so bidi never flips it.
            Text("akuo  →  \u{2068}שלום\u{2069}").font(.title3).padding(.leading, 28)
            HStack(spacing: 8) {
                Text("You see it only in the menu bar:").foregroundStyle(.secondary)
                MenuBarPreview(label: model.general.menuBarPreview)
            }
            .padding(.leading, 28)

            Box {
                HStack {
                    Text("Your two languages")
                    Spacer()
                    Text(pairText)
                    Button(showsPickers ? "Done" : "Change…") { showsPickers.toggle() }.buttonStyle(.kytkinLink)
                }
                if showsPickers {
                    Form { LanguagePairRow(model: model.languages) }
                        .formStyle(.columns)
                        .disabled(!model.languages.isEditable)
                    Text("You can change these later in Settings → General.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            // Visual review O3: fixed-width icons, so the lines start at one edge. Flows M8: no update claim.
            VStack(alignment: .leading, spacing: 4) {
                privacy("lock", "What you type stays on your Mac. Kytkin never saves or sends it.")
                privacy("network.slash", "No account, no tracking. No internet, unless you turn on the update check.")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { showsPickers = !model.languages.pairWarnings.isEmpty || model.languages.pairProblem != nil }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
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
            StepHeader(tile: .symbol("accessibility"), title: "One permission: Accessibility",
                       subtitle: "Kytkin needs Accessibility to read and replace the text you convert, and to see "
                           + "which website you're on. macOS asks you once.")
            Text("Kytkin only reads text when you press Shift twice, and never saves it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Without it, Kytkin still switches the language for each app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Box { status }
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
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.kytkinLink)
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
                    Button("Allow Accessibility…") { model.grantAccessibility() }.tint(.primary)
                }
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(.kytkinLink)
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
            StepHeader(tile: .symbol("keyboard"), title: "Try double-Shift",
                       subtitle: "Type in the box below with the wrong keyboard, then press Shift twice.")
            TextField("Type here…", text: $model.practiceText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .accessibilityLabel("Practice box")
            HStack(alignment: .top) {
                Text(model.practiceHint).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                MenuBarPreview(label: model.general.menuBarPreview)   // the letters change when it converts
            }
            result
            Spacer()
            // P6-0e: the real logo is shown above (the preview next to the hint), so no stand-in symbol here.
            Text("Kytkin lives in the menu bar, at the top right of your screen: look for its icon and the language "
                 + "letters, like HE or EN.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open Kytkin when I log in", isOn: $model.openAtLogin)
            if model.updates != nil {
                // P6-3: unchecked until the user ticks it.
                Toggle(isOn: $model.checkForUpdates) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Check for updates")
                        Text("Once a day, asks GitHub whether a newer version is out. Only Kytkin's version number is sent.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
        // P6-0e (mock-up move-to-applications): centred, the app icon, the main button full width.
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 80, height: 80).accessibilityHidden(true)
            Text("Move Kytkin to Applications first").font(.system(size: 18, weight: .bold))
            Text("Kytkin is running from the disk image (or Downloads), so macOS won't keep its permissions. Drag "
                 + "Kytkin into Applications, then open it from there.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            VStack(spacing: 8) {
                Button { showInFinder() } label: { Text("Show in Finder").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button { quit() } label: { Text("Quit").frame(maxWidth: .infinity) }.controlSize(.large)
                    .tint(.primary)
            }
            .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                    .fill(step == current ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(description)
    }
}

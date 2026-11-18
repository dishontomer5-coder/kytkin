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
    /// P6-0i: a step appeared (the window clears an unasked-for focus ring).
    var stepChanged: @MainActor () -> Void = {}

    /// P6-0i, the headless renderer only: the practice word's celebration starts on appear and is drawn frozen at
    /// this many seconds (nil in the app).
    nonisolated(unsafe) static var renderCelebrationAt: Double?

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
        .onChange(of: model.step) { stepChanged() }
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
                MenuBarPreview(label: model.menuBarPreview)
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
                privacy("network.slash", "No account, no tracking. No internet, unless you turn on updates.")
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
                           + "which website you’re on. macOS asks you once.")
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

/// P6-0c; P6-0i (owner: a premium practice box): the word to type as faded "ghost" letters that fill in one by one,
/// "Oops — wrong language!" when it is typed, two Shift caps that light up, then the word turns into the real one with
/// a short burst of confetti. Without a sample for the pair, the plain box of P6-0c.
private struct PracticeStep: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focused: Bool
    @State private var shiftMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sample = model.practiceSample {
                StepHeader(tile: .symbol("keyboard"), title: "Try Double-Shift",
                           subtitle: "Type the faded word. Kytkin set your keyboard to the wrong language for it.")
                GhostWordBoard(model: model, sample: sample, focused: $focused)
            } else {
                StepHeader(tile: .symbol("keyboard"), title: "Try Double-Shift",
                           subtitle: "Type in the box below with the wrong keyboard, then press Shift twice.")
                TextField("Type here…", text: $model.practiceText)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focused)
                    .focusEffectDisabled()
                    .accessibilityLabel("Practice box")
                Text(model.practiceHint).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                plainResult
            }
            HStack(spacing: 8) {
                Text("You see it only in the menu bar:").foregroundStyle(.secondary)
                MenuBarPreview(label: model.menuBarPreview)   // the letters change when it converts
            }
            Spacer(minLength: 0)
            Toggle("Open Kytkin when I log in", isOn: $model.openAtLogin)
            if model.updates != nil {
                // P6-3, P4-3: unchecked until the user ticks it.
                Toggle(isOn: $model.keepUpToDate) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(GeneralSettingsModel.keepUpToDateTitle)
                        Text(GeneralSettingsModel.keepUpToDateHelp)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.general.loginItemError {
                StatusLabel(text: error, symbol: "xmark.circle.fill", tint: .red).font(.caption)
            }
        }
        .onAppear {
            focused = true
            // P6-0i: Shift presses in this window light the key caps (a key-down count only; nothing is read or kept).
            guard shiftMonitor == nil else { return }   // QA (P6-0i): one monitor, however often it appears
            shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [model] event in
                if event.keyCode == 56 || event.keyCode == 60, event.modifierFlags.contains(.shift) {
                    MainActor.assumeIsolated { model.noteShiftPressed() }
                }
                return event
            }
        }
        .onDisappear {
            if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
            shiftMonitor = nil
        }
        .onChange(of: focused) { model.practiceFocused = focused }
        .onChange(of: model.practiceText) { model.practiceTextChanged() }
    }

    @ViewBuilder private var plainResult: some View {
        switch model.practiceResult {
        case .none:
            EmptyView()
        case .converted(let language):
            StatusLabel(text: "That’s it. Kytkin converted it and switched to \(language).",
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

/// P6-0i: the ghost word, its progress, the "wrong language" moment, the Shift caps and the celebration.
private struct GhostWordBoard: View {
    @Bindable var model: OnboardingModel
    let sample: PracticeGhost.Sample
    var focused: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash: Character?
    @State private var shakes: CGFloat = 0
    @State private var wobbles: CGFloat = 0
    @State private var celebrating: Date?




    private var phase: PracticeGhost.Phase { model.practicePhase ?? .typing(filled: 0) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // The real field: it takes the typing (the window gives it the keyboard on this step), drawn invisibly
                // so the board is the box (no focus ring).
                TextField("Practice box", text: $model.practiceText)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .focusEffectDisabled()
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .opacity(0.02)
                    .frame(width: 40, height: 20)
                    .accessibilityLabel("Practice box: type \(sample.letters.map(String.init).joined(separator: " "))")
                word
                    .modifier(Shake(amount: reduceMotion ? 0 : 6, shakes: shakes))
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(sin(wobbles * .pi * 4)) * 4 * Double(1 - wobbles)))
                    .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45), value: phase == .converted)
                if let start = celebrating, !reduceMotion {
                    ConfettiView(start: start, frozenAt: OnboardingView.renderCelebrationAt)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Color.kytkinLink.opacity(0.5) : Color.primary.opacity(0.08),
                              lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
            status.frame(minHeight: 44)
        }
        .onChange(of: model.practiceRejectCount) {
            flash = model.practiceRejected
            if !reduceMotion { withAnimation(.linear(duration: 0.35)) { shakes += 1 } }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                flash = nil
            }
        }
        .onChange(of: phase) { old, new in phaseChanged(from: old, to: new) }
        .onAppear {
            if phase == .converted, OnboardingView.renderCelebrationAt != nil { celebrating = Date() }
            if phase == .wrongLanguage, OnboardingView.renderCelebrationAt != nil { wobbles = 0.3 }
        }
    }

    // MARK: - The word

    @ViewBuilder private var word: some View {
        if phase == .converted {
            // The real word: a quick flip-in (a fade with Reduce Motion), isolated so bidi never reorders it.
            Text("\u{2068}\(sample.target)\u{2069}")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.kytkinLink)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                                                  removal: .opacity))
                .id("converted")
        } else {
            let filled = { if case .typing(let n) = phase { return n } else { return sample.letters.count } }()
            HStack(spacing: 6) {
                ForEach(Array(sample.letters.enumerated()), id: \.offset) { index, letter in
                    letterView(index: index, letter: letter, filled: filled)
                }
            }
            .transition(.opacity)
            .id("typing")
        }
    }

    private func letterView(index: Int, letter: Character, filled: Int) -> some View {
        let isFlash = index == filled && flash != nil
        let shown = isFlash ? String(flash ?? letter) : String(letter)
        return Text(shown)
            .font(.system(size: 42, weight: .semibold, design: .monospaced))
            .foregroundStyle(isFlash ? Color.red : index < filled ? Color.primary : Color.secondary.opacity(0.28))
            .frame(minWidth: 30)
            .animation(.easeOut(duration: 0.15), value: filled)
    }

    // MARK: - The line under it

    @ViewBuilder private var status: some View {
        switch phase {
        case .typing(let n):
            Text(n == 0 ? "Start typing: the letters fill in as you go." : "Keep going…")
                .font(.callout).foregroundStyle(.secondary)
        case .wrongLanguage:
            VStack(spacing: 6) {
                Text("Oops — wrong language!").font(.headline)
                HStack(spacing: 8) {
                    Text("Now press Shift twice").font(.callout).foregroundStyle(.secondary)
                    ShiftCap(lit: model.practiceShiftPresses >= 1)
                    ShiftCap(lit: model.practiceShiftPresses >= 2)
                }
            }
        case .converted:
            Label {
                Text("That’s Kytkin. It works like this in every app.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        }
    }

    private func phaseChanged(from old: PracticeGhost.Phase, to new: PracticeGhost.Phase) {
        switch new {
        case .typing(let n):
            let text = PracticeGhost.progressAnnouncement(filled: n, sample: sample)
            if !text.isEmpty { AccessibilityNotification.Announcement(text).post() }
        case .wrongLanguage:
            AccessibilityNotification.Announcement("Wrong language — press Shift twice").post()
            guard !reduceMotion else { return }
            wobbles = 0
            withAnimation(.easeOut(duration: 0.6)) { wobbles = 1 }
        case .converted:
            AccessibilityNotification.Announcement("Converted to \(sample.target)").post()
            guard !reduceMotion else { return }
            let start = Date()
            celebrating = start
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ConfettiView.duration + 0.1))
                if celebrating == start { celebrating = nil }   // the timeline stops: no CPU when idle
            }
        }
        _ = old
    }
}

/// A keyboard Shift cap that lights up (teal) when pressed.
private struct ShiftCap: View {
    let lit: Bool

    var body: some View {
        Text("⇧ shift")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(lit ? Color.white : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(lit ? Color.kytkinAccent : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(lit ? 0 : 0.15), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: lit)
            .accessibilityHidden(true)
    }
}

/// A side-to-side shake (a wrong letter).
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 6), y: 0))
    }
}

/// P6-0i: a light burst of brand-coloured confetti, about 1.5 s. The timeline runs only while this view exists (the
/// board removes it when the burst is over), so nothing runs when idle.
private struct ConfettiView: View {
    let start: Date
    var frozenAt: Double?
    static let duration: Double = 1.5

    private struct Piece {
        let angle: Double, speed: Double, spin: Double, size: CGFloat, color: Color, delay: Double
    }

    private static let colors: [Color] = [
        Color(red: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255),
        Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0xB0 / 255),
        Color(red: 0x1A / 255, green: 0x9E / 255, blue: 0x85 / 255),
        Color(red: 0x56 / 255, green: 0xDF / 255, blue: 0xBE / 255),
    ]

    /// Fixed pieces (a simple generator), so every burst and every render looks the same.
    private static let pieces: [Piece] = {
        var seed: UInt64 = 0x6B79_746B_696E
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<70).map { i in
            Piece(angle: -Double.pi / 2 + (next() - 0.5) * Double.pi * 1.4, speed: 160 + next() * 220,
                  spin: (next() - 0.5) * 14, size: 4 + CGFloat(next()) * 5, color: colors[i % colors.count],
                  delay: next() * 0.12)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: frozenAt != nil)) { context in
            Canvas { gc, size in
                let t = frozenAt ?? context.date.timeIntervalSince(start)
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                for p in Self.pieces {
                    let age = t - p.delay
                    guard age > 0, age < Self.duration else { continue }
                    let x = origin.x + cos(p.angle) * p.speed * age
                    let y = origin.y + sin(p.angle) * p.speed * age + 0.5 * 520 * age * age
                    let fade = max(0, 1 - age / Self.duration)
                    var piece = gc
                    piece.opacity = fade
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(p.spin * age))
                    piece.fill(Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2),
                                    cornerRadius: 1), with: .color(p.color))
                }
            }
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
            Text("Kytkin is running from the disk image (or Downloads), so macOS won’t keep its permissions. Drag "
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

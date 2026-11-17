// P2-24 / P2-26: The two language pickers with their caption, the refusal line and the pair warnings. Shared by
// Settings and the setup window, so both pick from the same list with the same checks (`LanguagesSettingsModel`,
// Core). Layout only.
// P6-0d (owner): Settings → General shows them as one row (`LanguagePairRow`): two compact pickers with their
// menu-bar letters and a ⇄ swap button between them; the setup window keeps the two labelled pickers.

import AppKit
import SwiftUI

struct LanguagePairPickers: View {
    @Bindable var model: LanguagesSettingsModel

    var body: some View {
        LanguagePairMenu(model: model, title: "First language", selection: $model.pairA)   // P6-0c (L-1)
        LanguagePairMenu(model: model, title: "Second language", selection: $model.pairB)
        Text(LanguagePairRow.hint)   // P6-0c (L-2)
            .font(.caption).foregroundStyle(.secondary)
        LanguagePairProblems(model: model)
    }
}

/// P6-0d: `[ABC ▾] EN  ⇄  [Hebrew ▾] HE`, the hint as the row's subtitle, problems below it.
struct LanguagePairRow: View {
    @Bindable var model: LanguagesSettingsModel

    static let hint = "Press Shift twice to convert text between these two languages."

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                LanguagePairMenu(model: model, title: "First language", selection: $model.pairA)
                    .labelsHidden().fixedSize()
                CodeBadge(code: model.code(for: model.pair.a))
                Button { model.swap() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("Swap the two languages")
                    .accessibilityLabel("Swap the two languages")
                    .padding(.horizontal, 4)
                LanguagePairMenu(model: model, title: "Second language", selection: $model.pairB)
                    .labelsHidden().fixedSize()
                CodeBadge(code: model.code(for: model.pair.b))
            }
        } label: {
            RowLabel("Your two languages", subtitle: Self.hint)
        }
        LanguagePairProblems(model: model)
    }
}

/// One pair member's pop-up, grouped like the system's lists.
struct LanguagePairMenu: View {
    let model: LanguagesSettingsModel
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(model.optionGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.options) { option in
                        Text(option.title).tag(option.tag)
                            .selectionDisabled(!option.isSelectable)
                    }
                }
            }
        }
    }
}

/// The refusal line and the pair warnings (P6-0c: colour only on the symbol).
struct LanguagePairProblems: View {
    let model: LanguagesSettingsModel

    var body: some View {
        if let problem = model.pairProblem {
            StatusLabel(text: problem.message, symbol: "xmark.circle.fill", tint: .red).font(.caption)
        }
        ForEach(model.pairWarnings, id: \.self) { warning in
            WarningLabel(text: warning).font(.caption)
        }
    }
}

/// P6-0g / P6-0h (owner, lg-general): ONE rounded key, about 64 pt tall, split by the logo's S-shaped seam with a thin
/// gap. The left half is the first language, filled teal like the logo's left half; the right half is neutral. Each
/// half IS its picker: the half-filled key glyph, a grey "First language" / "Second language" caption, the language in
/// bold ("English (ABC)") and a small round chevron at its right edge; a click anywhere on the half opens the list (an
/// AppKit menu, so no pop-up bezel inside). The round swap button sits on the seam, over both halves.
struct LanguagePairKey: View {
    @Bindable var model: LanguagesSettingsModel
    static let height: CGFloat = 64
    /// The seam: how far its top leans right of the middle (and its bottom left), as a share of the height.
    static let slant: CGFloat = 0.38
    static let gap: CGFloat = 3
    static let radius: CGFloat = 18

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                half(.a)
                half(.b)
            }
            .background {
                ZStack {
                    KeyHalf(side: .a, gap: Self.gap, radius: Self.radius, slant: Self.slant).fill(Color.kytkinPairFirst)
                    KeyHalf(side: .b, gap: Self.gap, radius: Self.radius, slant: Self.slant)
                        .fill(Color.kytkinPairSecond)
                }
            }
            Button { model.swap() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.kytkinSwap).shadow(color: .black.opacity(0.25), radius: 4, y: 1.5))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Swap the two languages")
            .accessibilityLabel("Swap the two languages")
        }
        .frame(height: Self.height)
    }

    private func half(_ side: PairSide) -> some View {
        let id = side == .a ? model.pair.a : model.pair.b
        let title = side == .a ? "First language" : "Second language"
        let value = model.options.first { $0.id == id }?.title ?? model.name(of: id)
        let onTeal = side == .a
        return Button { LanguagePairPopUp.show(model: model, side: side) } label: {
            HStack(spacing: 12) {
                if let glyph = MenuBarGlyph.image(for: .active, side: side) {
                    Image(nsImage: glyph).renderingMode(.template)
                        .foregroundStyle(onTeal ? Color.white : Color.primary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: SettingsMetrics.secondarySize))
                        .foregroundStyle(onTeal ? Color.white.opacity(0.9) : Color.secondary)   // QA: 4.6:1 on teal (0.75: 3.7)
                    Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(onTeal ? Color.white : Color.primary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(onTeal ? Color.white : Color.primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill((onTeal ? Color.white : Color.primary).opacity(0.14)))
                    .accessibilityHidden(true)
            }
            .padding(.leading, side == .a ? 18 : 30)
            .padding(.trailing, side == .a ? 32 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(model.name(of: id))")
        .accessibilityHint("Opens the list of languages")
    }
}

/// P6-0h: the list behind a half of the pair key: the same groups, names and disabled entries as the setup window's
/// pickers (`LanguagesSettingsModel.optionGroups`), the current one checked. Opened only by a click.
@MainActor enum LanguagePairPopUp {
    static func show(model: LanguagesSettingsModel, side: PairSide) {
        let current = (side == .a ? model.pair.a : model.pair.b).rawValue
        let menu = NSMenu()
        menu.autoenablesItems = false
        var checked: NSMenuItem?
        for (index, group) in model.optionGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: group.title))
            for option in group.options {
                let item = ClosureMenuItem(title: option.title) {
                    if side == .a { model.pairA = option.tag } else { model.pairB = option.tag }
                }
                item.isEnabled = option.isSelectable
                if option.tag == current {
                    item.state = .on
                    checked = item
                }
                menu.addItem(item)
            }
        }
        // QA (P6-0h): opened from the keyboard or VoiceOver, the pointer may be anywhere (even another screen), so the
        // list then opens over the middle of the key window instead of at the pointer.
        let byMouse = NSApp.currentEvent.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } ?? false
        if !byMouse, let content = NSApp.keyWindow?.contentView {
            menu.popUp(positioning: checked, at: NSPoint(x: content.bounds.midX - 100, y: content.bounds.midY),
                       in: content)
        } else {
            menu.popUp(positioning: checked, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("not used") }

    @MainActor @objc private func fire() { run() }
}

extension Color {
    /// P6-0h: the first language's half, filled like the logo's left half: light #0E7A66 (white text 5.3:1), dark
    /// #2C5E57 (lg-general-dark).
    static let kytkinPairFirst = Color(nsColor: NSColor(name: "KytkinPairFirst") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2C / 255, green: 0x5E / 255, blue: 0x57 / 255, alpha: 1)
            : NSColor(srgbRed: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255, alpha: 1)
    })

    /// P6-0h: the second language’s half, neutral: light #E4E7E6, dark #3A3A3E.
    static let kytkinPairSecond = Color(nsColor: NSColor(name: "KytkinPairSecond") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3E / 255, alpha: 1)
            : NSColor(srgbRed: 0xE4 / 255, green: 0xE7 / 255, blue: 0xE6 / 255, alpha: 1)
    })

    /// P6-0h: the round swap button on the seam: light white, dark #4A4A50.
    static let kytkinSwap = Color(nsColor: NSColor(name: "KytkinSwap") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x4A / 255, green: 0x4A / 255, blue: 0x50 / 255, alpha: 1)
            : NSColor.white
    })
}

/// P6-0d: the letters the menu bar shows for a language ("EN", "HE").
private struct CodeBadge: View {
    let code: String?

    var body: some View {
        if let code {
            Text(code)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                .accessibilityLabel("Menu bar letters \(code)")
        }
    }
}

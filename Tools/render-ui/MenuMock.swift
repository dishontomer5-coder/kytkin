// P6-0a: SwiftUI stand-ins for the two AppKit pieces that can't be drawn offscreen: the status-bar menu (an NSMenu,
// which only draws while it is open on screen) and the menu-bar label (an NSStatusItem button). Both draw exactly the
// lines Core's `MenuModel` decides (the same call StatusItemController makes), in a look close to macOS's own.
// The look is an approximation; the words, order, enabled/checked state, indents and shortcuts are the real ones.

import AppKit
import SwiftUI

struct MenuMock: View {
    let items: [MenuItemModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                row(item)
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 240, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .padding(16)
    }

    @ViewBuilder private func row(_ item: MenuItemModel) -> some View {
        switch item.kind {
        case .separator:
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                .padding(.horizontal, 10).padding(.vertical, 5)
        case .header:
            // P6-0c: NSMenuItem.sectionHeader (small, bold, secondary).
            Text(item.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 20)
        default:
            HStack(spacing: 0) {
                Text(item.isChecked ? "✓" : "").frame(width: 22, alignment: .center)
                if let symbol = item.symbol {
                    Image(systemName: symbol).frame(width: 18, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).fixedSize()
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    }
                }
                .padding(.leading, CGFloat(item.indent) * 14)
                Spacer(minLength: 12)
                if !item.keyEquivalent.isEmpty {
                    Text("⌘" + item.keyEquivalent.uppercased()).foregroundStyle(.secondary)
                }
                if case .debugSwitchSubmenu = item.kind { Text("›").foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary.opacity(0.75))
            .padding(.horizontal, 6)
            .frame(minHeight: 22)
            .padding(.vertical, item.subtitle == nil ? 0 : 2)
        }
    }
}

/// The menu-bar label in several states, each on a strip of menu bar.
struct StatusLabelMock: View {
    struct Sample: Identifiable {
        let caption: String
        let label: MenuModel.Label
        var id: String { caption }
    }

    let samples: [Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(samples) { sample in
                HStack(spacing: 14) {
                    HStack(spacing: 14) {
                        Spacer()
                        Image(systemName: "wifi")
                        // P6-0c: the placeholder glyph (StatusItemController's MenuBarGlyph) + fixed-width letters.
                        HStack(spacing: 3) {
                            if sample.label.showsIcon {
                                Image(systemName: Self.placeholder(sample.label.look))
                                    .frame(width: 16, height: 16)
                            }
                            if let letters = sample.label.letters {
                                Text(letters).font(.system(size: 13, weight: .regular))
                                    .frame(minWidth: 24, alignment: .leading)
                            }
                            if !sample.label.showsIcon, sample.label.look == .attention {
                                Image(systemName: "circle.fill").font(.system(size: 4))
                            }
                        }
                        .opacity(sample.label.dimmed ? 0.45 : 1)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        Image(systemName: "battery.75percent")
                        Text("Tue 17 Nov 9:41")
                    }
                    .font(.system(size: 13))
                    .frame(width: 300, height: 24)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Text(sample.caption).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 640, alignment: .leading)
    }

    /// The same SF Symbols `MenuBarGlyph.placeholderSymbol` uses until the real artwork lands.
    static func placeholder(_ look: MenuModel.Label.Look) -> String {
        switch look {
        case .active, .off: "keyboard"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.circle"
        }
    }
}

/// P6-0c: the Settings window's toolbar tabs (icon over title, `NSTabViewController.tabStyle = .toolbar`) are window
/// chrome and can't be captured offscreen. This draws a stand-in with the same symbols and titles, the selected one
/// highlighted as macOS does. Everything below it is the real tab pane.
struct ToolbarTabsMock: View {
    let selected: SettingsTab
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            Text("Kytkin Settings").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName).font(.system(size: 18)).frame(height: 22)
                        Text(tab.title).font(.system(size: 11))
                    }
                    .foregroundStyle(tab == selected ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 64)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tab == selected ? Color.primary.opacity(0.08) : Color.clear))
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Divider()
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
    }
}

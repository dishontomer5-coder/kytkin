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
        default:
            HStack(spacing: 0) {
                Text(item.isChecked ? "✓" : "").frame(width: 22, alignment: .center)
                Text(item.title)
                    .fixedSize()
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
            .frame(height: 22)
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
                        Text(sample.label.title)
                            .font(.system(size: 13, weight: .regular))
                            .opacity(sample.label.dimmed ? 0.45 : 1)
                            .padding(.horizontal, 6).padding(.vertical, 1)
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
}

/// P6-0a: NSTabView's row of tab buttons can't be captured offscreen by `cacheDisplay` (it comes out as a blank
/// rounded bar across the top of the tab box). This draws over exactly that bar: the same tab titles, in order, with
/// the selected one highlighted, in a look close to macOS's segmented tabs. Everything else is the real SettingsView.
struct TabStripOverlay: View {
    let selected: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tab.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .foregroundStyle(tab == selected ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tab == selected ? Color.accentColor : Color.clear))
            }
        }
        .padding(1)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.24) : Color.white)
                .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5))
        .frame(height: 26)
    }
}

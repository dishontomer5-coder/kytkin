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
        case .languageKey(let key):
            // P6-0g: KytkinKeyMenuView (AppKit in the app): the title, the key on the right (92 × 26 pt).
            HStack(spacing: 0) {
                Text(item.title).font(.system(size: 13)).padding(.leading, 28)
                Spacer(minLength: 24)
                KytkinKey(left: key.a.letters, right: key.b.letters, chosen: key.chosen,
                          size: CGSize(width: 92, height: 26), leftName: key.a.name, rightName: key.b.name) { _ in }
            }
            .padding(.trailing, 14)
            .frame(height: 34)
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
                .padding(.leading, CGFloat(item.indent) * 10)   // P6-0f: NSMenuItem indents by 10 pt a level
                Spacer(minLength: 12)
                if !item.keyEquivalent.isEmpty {
                    Text("⌘" + item.keyEquivalent.uppercased()).foregroundStyle(.secondary)
                }
                if case .debugSwitchSubmenu = item.kind { Text("›").foregroundStyle(.secondary) }
                if case .submenu = item.kind { Text("›").foregroundStyle(.secondary) }   // P6-0f: "Debug ›"
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
                        // P6-0e: the very image the status item shows (MenuBarGlyph.itemImage).
                        Group {
                            if let image = MenuBarGlyph.itemImage(for: sample.label) {
                                Image(nsImage: image).renderingMode(.template)
                            }
                        }
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

}

/// P6-0c: the Settings window's toolbar tabs (icon over title, `NSTabViewController.tabStyle = .toolbar`) are window
/// chrome and can't be captured offscreen. This draws a stand-in with the same symbols and titles, the selected one
/// highlighted as macOS does. Everything below it is the real tab pane.
struct ToolbarTabsMock: View {
    let selected: SettingsTab
    /// P6-0k: the Statistics item's title is the total, as the window sets it.
    var statisticsTitle: String? = nil
    @Environment(\.colorScheme) private var scheme
    static let height: CGFloat = 78

    var body: some View {
        VStack(spacing: 0) {
            Text(selected.title).font(.system(size: 13, weight: .semibold)).padding(.top, 8)   // P6-0g: the tab's name
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName).font(.system(size: 18)).frame(height: 22)
                        Text(tab == .statistics ? statisticsTitle ?? tab.title : tab.title).font(.system(size: 11))
                    }
                    .foregroundStyle(tab == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
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

/// P6-0l: a stand-in for an NSPopover (it only draws while open on screen): the real content view in a rounded
/// panel with an arrow on its top edge pointing up at its anchor. The look is an approximation; the content is real.
struct PopoverMock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ArrowUp()
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(ArrowUp().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 22, height: 10)
                .offset(y: 0.5)
                .zIndex(1)
            content
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4))   // the panel's shadow, not the text's
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .fixedSize()
    }

    private struct ArrowUp: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return p
        }
    }
}

// P2-13: Shipped defaults for ReplacementCapabilities (001 §2.2 "Seeds", R5 seed list). User-overridable.
// Bundle IDs are the apps' public identifiers. Verify each against the installed app during P2-18 QA.

import Foundation

extension ReplacementCapabilities {
    static let defaultSeeds: [Seed] = {
        // P2-36 (001 §12 T1): terminals. No AX, no paste, no selection convert (the selection is display only).
        // Ghostty, Alacritty, kitty, WezTerm and Hyper IDs are from the apps' published bundles; verify them
        // against the installed apps in P2-18 QA. Alacritty shipped as `io.alacritty` before `org.alacritty`.
        let terminal = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "co.zeit.hyper",
        ]
        // Code editors: the editor owns the text, AX writes are unreliable (R5). Keys only (P3 paste allowed, T3).
        let keysOnly = [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            // Chromium and Electron start on keys, so we never toggle AXEnhancedUserInterface (R5 open question 3).
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
            // P2-36 (001 §12 T7): the other Chromium browsers.
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2",
        ]
        // Remote desktops and VMs read key codes only and ignore the Unicode string (R4/R5).
        let noUnicode = [
            "com.microsoft.rdc.macos", "com.parallels.desktop.console", "com.vmware.fusion",
            "com.utmapp.UTM", "com.citrix.receiver.icaviewer.mac", "com.apple.ScreenSharing",
        ]
        return terminal.map { Seed(match: .exact($0), hint: .terminal) }
            + keysOnly.map { Seed(match: .exact($0), hint: .keysOnly) }
            + [Seed(match: .prefix("com.jetbrains."), hint: .keysOnly)]
            + noUnicode.map { Seed(match: .exact($0), hint: .noUnicode) }
    }()
}

// P2-13: Shipped defaults for ReplacementCapabilities (001 §2.2 "Seeds", R5 seed list). User-overridable.
// Bundle IDs are the apps' public identifiers. Verify each against the installed app during P2-18 QA.

import Foundation

extension ReplacementCapabilities {
    static let defaultSeeds: [Seed] = {
        // Terminals and code editors: the shell / editor owns the text, AX writes are unreliable (R5).
        let keysOnly = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            // Chromium and Electron start on keys, so we never toggle AXEnhancedUserInterface (R5 open question 3).
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2",
        ]
        // Remote desktops and VMs read key codes only and ignore the Unicode string (R4/R5).
        let noUnicode = [
            "com.microsoft.rdc.macos", "com.parallels.desktop.console", "com.vmware.fusion",
            "com.utmapp.UTM", "com.citrix.receiver.icaviewer.mac", "com.apple.ScreenSharing",
        ]
        return keysOnly.map { Seed(match: .exact($0), hint: .keysOnly) }
            + [Seed(match: .prefix("com.jetbrains."), hint: .keysOnly)]
            + noUnicode.map { Seed(match: .exact($0), hint: .noUnicode) }
    }()
}

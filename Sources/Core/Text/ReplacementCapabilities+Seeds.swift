// P2-13: Shipped defaults for ReplacementCapabilities (001 §2.2 "Seeds", R5 seed list). User-overridable.
// Bundle IDs are the apps' public identifiers. Verify each against the installed app during P2-18 QA.

import Foundation

extension ReplacementCapabilities {
    static let defaultSeeds: [Seed] = {
        // P2-36 (001 §12 T1): terminals. No AX, no paste, no selection convert (the selection is display only).
        // Ghostty, Alacritty, kitty, WezTerm and Hyper IDs are from the apps' published bundles. P2-18 read the
        // installed Info.plists: Terminal and Ghostty confirmed; iTerm2, Warp, Alacritty, kitty, WezTerm and Hyper
        // weren't installed, so they're still unverified. Alacritty shipped as `io.alacritty` before `org.alacritty`.
        let terminal = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "co.zeit.hyper",
            // P3-37: cmux (a Ghostty-based terminal; the owner's), read from its installed Info.plist 2026-11-11. It
            // was `.auto`, so Kytkin tried AX reads and writes in a terminal.
            "com.cmuxterm.app",
            // P3-37 QA: more terminals (public bundle IDs, not installed here, unverified): Tabby, Wave, Rio, Warp
            // Preview. Unseeded, they were `.auto`, where the clipboard convert could reach an xterm.js box.
            "org.tabby", "dev.commandline.waveterm", "com.raphaelamorim.rio", "dev.warp.Warp-Preview",
        ]
        // Code editors: the editor owns the text, AX writes are unreliable (R5). Keys only (P3 paste allowed, T3).
        let keysOnly = [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            // Chromium and Electron start on keys, so we never toggle AXEnhancedUserInterface (R5 open question 3).
            "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
            // P2-36 (001 §12 T7): the other Chromium browsers.
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2",
        ] + geckoBrowserBundleIDs
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

    /// P3-47 (Coordinator 2026-11-16; Zen is the owner's main browser, plan.md §Phase 3): the Gecko browsers, seeded like
    /// Chrome for convert (`.keysOnly`: a known browser, so the P3-37 clipboard convert may paste a multi-line box, and
    /// a selection is copied with ⌘C, P3-40). Unseeded they were `.auto`, where a pasted line break was refused (the
    /// P3-37 unknown-terminal guard), so a two-line Gmail box in Zen beeped. Not `chromiumAX` (Gecko has no such path).
    /// Whole-document sites stay excluded by `blocksClipboard(bundleID:host:)` with the host Kytkin reads for Gecko
    /// (`GeckoReadStrategy`, P3-13); a focused address bar is `inAddressBar` (never copied). IDs as in
    /// `BrowserCatalog` (Zen verified from its Info.plist; Firefox / Developer Edition / Nightly, Waterfox and Floorp from
    /// their vendors' published bundles, unverified here). LibreWolf has shipped both IDs listed.
    static let geckoBrowserBundleIDs = [
        "app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "org.mozilla.librewolf", "io.gitlab.librewolf-community", "net.waterfox.waterfox", "one.ablaze.floorp",
    ]

    /// P3-37 (c): code editors and IDEs, where ⌘A selects the whole file (a whole-box convert would turn every English
    /// identifier into Hebrew) and the same window hosts a terminal (a pasted box with line breaks could run commands at
    /// its prompt). The clipboard never converts a whole box there; the remembered buffer does, as before.
    static let editorBundleIDs: Set<String> = [
        "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "dev.zed.zed", "com.sublimetext.4", "com.apple.dt.xcode",
    ]

    /// P3-37 QA: web apps where ⌘A selects a whole document, sheet or file, not one text box: a whole-box convert would
    /// paste the document back as plain text (formatting, images, formulas lost) or turn code into Hebrew
    /// (research p3-37 §7: "Google Docs / Sheets, Monaco or CodeMirror on the web: keys"). A host matches itself and its
    /// subdomains. The remembered buffer still converts by keys there.
    static let clipboardBlockedHosts: [String] = [
        "docs.google.com", "colab.research.google.com",
        "officeapps.live.com", "sharepoint.com", "onedrive.live.com", "cloud.microsoft", "office.com",
        "vscode.dev", "github.dev", "codesandbox.io", "replit.com", "stackblitz.com",
    ]

    /// P3-37 QA: Chrome / Edge installed web apps (Google Docs.app, Sheets.app…) are separate bundles with no site Kytkin
    /// can read. Their documents are the risky ones above, so they never use the clipboard.
    static let webAppShimPrefixes: [String] = ["com.google.chrome.app.", "com.microsoft.edgemac.app.",
                                               "com.brave.browser.app."]

    /// P3-37 QA: the clipboard convert may not be used for this app / page (`clipboardBlockedHosts`, web-app shims).
    static func blocksClipboard(bundleID: String, host: String?) -> Bool {
        let k = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if webAppShimPrefixes.contains(where: { k.hasPrefix($0) }) { return true }
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return clipboardBlockedHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// P3-37 (c): `bundleID` is a code editor or IDE (`editorBundleIDs`, or JetBrains).
    static func isEditor(_ bundleID: String) -> Bool {
        let k = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return editorBundleIDs.contains(k) || k.hasPrefix("com.jetbrains.")
    }
}

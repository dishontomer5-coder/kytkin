// P3-42 (001 §12.3 X15): which seeded keys-only apps get the Chromium/Electron AX convert (`FieldFamily.chromiumAX`).
// Not VS Code or other code editors (Monaco shows AX nothing, research p3-37 §3), not terminals, not the user's own
// choice of any method in Settings → Apps (their choice wins, as for the clipboard).

import Foundation

extension ReplacementCapabilities {
    /// P3-42: the Chromium browsers and Electron chat apps seeded `.keysOnly` (lowercased bundle IDs). Teams
    /// (`com.microsoft.teams2`) may be WebKit rather than Chromium (research p3-37 open question 3); the path's checks
    /// (web-content attributes, read-back of every selected piece) hold either way, and it falls back if they fail.
    static let chromiumAXBundleIDs: Set<String> = [
        "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium",
        "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.microsoft.teams2",
    ]

    /// P3-42: the family hint for an app: `.chromiumAX` for the bundles above while their shipped method is in force
    /// (seeded `.keysOnly`, no user override) and the app is not a code editor; nil otherwise.
    func family(for bundleID: String) -> FieldFamily? {
        let k = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.chromiumAXBundleIDs.contains(k), override(for: bundleID) == nil,
              method(for: bundleID) == .keysOnly, !Self.isEditor(bundleID) else { return nil }
        return .chromiumAX
    }
}

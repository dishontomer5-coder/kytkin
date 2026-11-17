// P3-42 (001 §12.3 X15): which seeded keys-only apps get the Chromium/Electron AX convert (`FieldFamily.chromiumAX`).
// Not VS Code or other code editors (Monaco shows AX nothing, research p3-37 §3), not terminals, not the user's own
// choice of any method in Settings → Apps (their choice wins, as for the clipboard).

import Foundation

extension ReplacementCapabilities {
    /// P3-42: the Chromium browsers seeded `.keysOnly` (lowercased bundle IDs). P3-60: the chat apps (Slack, Discord,
    /// Teams) are no longer here: since P3-58 they use the clipboard only (`chatAppBundleIDs`).
    static let chromiumAXBundleIDs: Set<String> = [
        "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium",
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

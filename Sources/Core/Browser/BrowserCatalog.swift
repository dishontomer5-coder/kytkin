// P3-6: Which apps are browsers, and which engine reads their address (001 §14.3.1, D1).
// A bundle-ID catalog per engine, plus any other app registered for https links as `.unknown` (best effort).
// Probing every frontmost app for an AXWebArea was rejected: Electron apps have web areas too and would turn
// into "sites" (chats are Phase 4's job).
//
// Bundle IDs: checked against the installed app's Info.plist (`CFBundleIdentifier`) on 2026-11-07 for Arc,
// Chrome, Safari and Zen only ("Info.plist ✓" below). The others are inferred from vendor documentation and
// stay unchecked until someone has the app installed.
// `verified` is a different fact: the AX read path was seen working on a real Mac (R3/R3b, later P3-3).

enum BrowserEngine: String, Sendable, Codable {
    case chromium, gecko, webkit
    /// Not in the catalog but opens web links: web-area search and focus up-walk only, no text field is read.
    case unknown
}

enum AppleScriptDialect: Sendable, Equatable {
    case chromium   // `URL of active tab of front window`, `mode of front window` (Chrome, Edge, Brave; others [I])
    case arc        // `URL of active tab of front window`, `incognito of front window`
    case safari     // `URL of current tab of front window`; no private-window property
}

struct KnownBrowser: Sendable, Equatable {
    let bundleID: String
    let engine: BrowserEngine
    let appleScript: AppleScriptDialect?
    /// Tor Browser: every window counts as private.
    let alwaysPrivate: Bool
    /// The AX path was seen working on a real Mac (R3/R3b/P3-3); Settings shows "(not yet tested)" otherwise.
    let verified: Bool

    init(_ bundleID: String, _ engine: BrowserEngine, appleScript: AppleScriptDialect? = nil,
         alwaysPrivate: Bool = false, verified: Bool = false) {
        self.bundleID = bundleID
        self.engine = engine
        self.appleScript = appleScript
        self.alwaysPrivate = alwaysPrivate
        self.verified = verified
    }
}

enum BrowserCatalog {
    static let all: [KnownBrowser] = [
        // Chromium
        KnownBrowser("com.google.Chrome", .chromium, appleScript: .chromium, verified: true), // Info.plist ✓, R3b [V] structure
        KnownBrowser("com.google.Chrome.beta", .chromium, appleScript: .chromium),
        KnownBrowser("com.google.Chrome.dev", .chromium, appleScript: .chromium),
        KnownBrowser("com.google.Chrome.canary", .chromium, appleScript: .chromium),
        KnownBrowser("org.chromium.Chromium", .chromium, appleScript: .chromium),
        KnownBrowser("company.thebrowser.Browser", .chromium, appleScript: .arc, verified: true), // Arc: Info.plist ✓, R3b [V]
        KnownBrowser("com.microsoft.edgemac", .chromium, appleScript: .chromium),
        KnownBrowser("com.microsoft.edgemac.Beta", .chromium, appleScript: .chromium),
        KnownBrowser("com.microsoft.edgemac.Dev", .chromium, appleScript: .chromium),
        KnownBrowser("com.microsoft.edgemac.Canary", .chromium, appleScript: .chromium),
        KnownBrowser("com.brave.Browser", .chromium, appleScript: .chromium),
        KnownBrowser("com.brave.Browser.beta", .chromium, appleScript: .chromium),
        KnownBrowser("com.brave.Browser.nightly", .chromium, appleScript: .chromium),
        KnownBrowser("com.vivaldi.Vivaldi", .chromium, appleScript: .chromium),
        KnownBrowser("com.operasoftware.Opera", .chromium, appleScript: .chromium),
        // Gecko: no AppleScript dictionary.
        KnownBrowser("app.zen-browser.zen", .gecko, verified: true), // Zen: Info.plist ✓, R3b [V]
        KnownBrowser("org.mozilla.firefox", .gecko),
        KnownBrowser("org.mozilla.firefoxdeveloperedition", .gecko),
        KnownBrowser("org.mozilla.nightly", .gecko),
        KnownBrowser("org.mozilla.librewolf", .gecko),
        KnownBrowser("net.waterfox.waterfox", .gecko),
        KnownBrowser("one.ablaze.floorp", .gecko),
        KnownBrowser("org.torproject.torbrowser", .gecko, alwaysPrivate: true),
        // WebKit. Safari stays unverified until P3-3 item 3 (it wasn't running in R3b).
        KnownBrowser("com.apple.Safari", .webkit, appleScript: .safari), // Info.plist ✓
        KnownBrowser("com.apple.SafariTechnologyPreview", .webkit, appleScript: .safari),
        KnownBrowser("com.kagi.kagimacOS", .webkit), // Orion: no dialect
    ]

    static let known: [String: KnownBrowser] = Dictionary(uniqueKeysWithValues: all.map { ($0.bundleID, $0) })

    /// nil = not a browser. A bundle ID outside the list is `.unknown` only if it opens web links (§14.3.1).
    static func engine(for bundleID: String, opensWebLinks: Bool) -> BrowserEngine? {
        if let browser = known[bundleID] { return browser.engine }
        return opensWebLinks ? .unknown : nil
    }
}

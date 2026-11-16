// P2-13: The in-memory capability cache: seeds, user overrides, session verdicts (R5, 001 §2.2).

import XCTest

final class ReplacementCapabilitiesTests: XCTestCase {
    func testSeeds() {
        let c = ReplacementCapabilities()
        XCTAssertEqual(c.method(for: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(c.method(for: "com.googlecode.iterm2"), .terminal)
        XCTAssertEqual(c.method(for: "com.microsoft.VSCode"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.jetbrains.intellij"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.jetbrains.pycharm.ce"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.tinyspeck.slackmacgap"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.microsoft.rdc.macos"), .noUnicode)
        XCTAssertEqual(c.method(for: "com.apple.TextEdit"), .auto)
        XCTAssertEqual(c.method(for: ""), .auto)
    }

    func testTerminalSeeds() {
        // P2-36 (001 §12 T1): every known terminal is in the terminal class, not keysOnly.
        let c = ReplacementCapabilities()
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                   "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
                   "co.zeit.hyper"] {
            XCTAssertEqual(c.method(for: id), .terminal, id)
        }
        // IDEs stay keysOnly: their embedded terminals are covered by the T2 control-character rule instead.
        XCTAssertEqual(c.method(for: "com.microsoft.VSCode"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.jetbrains.goland"), .keysOnly)
    }

    func testChromiumBrowserSeeds() {
        // P2-36 (001 §12 T7).
        let c = ReplacementCapabilities()
        for id in ["com.google.Chrome", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium"] {
            XCTAssertEqual(c.method(for: id), .keysOnly, id)
        }
    }

    func testGeckoBrowserSeeds() {
        // P3-47: Gecko browsers are known browsers for convert (keys + the clipboard with line breaks), never chromiumAX.
        let c = ReplacementCapabilities()
        for id in ["app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
                   "org.mozilla.nightly", "org.mozilla.librewolf", "io.gitlab.librewolf-community",
                   "net.waterfox.waterfox", "one.ablaze.floorp"] {
            XCTAssertEqual(c.method(for: id), .keysOnly, id)
            XCTAssertNil(c.family(for: id), "no Chromium AX path: \(id)")
            XCTAssertFalse(ReplacementCapabilities.isEditor(id), id)
        }
        // Every seeded Gecko browser is one the site reader knows (so whole-document sites are told by their host).
        for id in ReplacementCapabilities.geckoBrowserBundleIDs {
            XCTAssertEqual(BrowserCatalog.known[id]?.engine, .gecko, id)
        }
        // Whole-document sites stay excluded in Gecko too (the host Kytkin reads for the page).
        XCTAssertTrue(ReplacementCapabilities.blocksClipboard(bundleID: "app.zen-browser.zen", host: "docs.google.com"))
        XCTAssertFalse(ReplacementCapabilities.blocksClipboard(bundleID: "app.zen-browser.zen", host: "mail.google.com"))
    }

    func testBundleIDsAreCaseInsensitive() {
        let c = ReplacementCapabilities()
        XCTAssertEqual(c.method(for: "COM.APPLE.TERMINAL"), .terminal)
        XCTAssertEqual(c.method(for: " com.apple.Terminal "), .terminal)
    }

    func testOverrideBeatsSeed() {
        var c = ReplacementCapabilities(overrides: ["com.apple.Terminal": .disabled])
        XCTAssertEqual(c.method(for: "com.apple.Terminal"), .disabled)
        c.setOverride(.auto, for: "com.jetbrains.goland")
        XCTAssertEqual(c.method(for: "com.jetbrains.goland"), .auto)
        c.setOverride(nil, for: "com.apple.Terminal")
        XCTAssertEqual(c.method(for: "com.apple.Terminal"), .terminal)
    }

    /// P2-25 QA (001 §12 T1): a seeded terminal stays a terminal; only `.disabled` overrides it.
    func testATerminalSeedKeepsTheTerminalClassUnlessDisabled() {
        for hint in [MethodHint.auto, .keysOnly, .noUnicode, .preferPaste, .terminal] {
            let c = ReplacementCapabilities(overrides: ["com.apple.Terminal": hint])
            XCTAssertEqual(c.method(for: "com.apple.Terminal"), .terminal, "\(hint)")
            XCTAssertEqual(c.method(for: "COM.apple.terminal"), .terminal, "\(hint), any case")
        }
        XCTAssertEqual(ReplacementCapabilities(overrides: ["com.apple.Terminal": .disabled])
            .method(for: "com.apple.Terminal"), .disabled)
        XCTAssertEqual(ReplacementCapabilities(overrides: ["com.apple.Terminal": .auto])
            .seedMethod(for: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(ReplacementCapabilities().seedMethod(for: ""), .auto)
    }

    func testLongestPrefixWins() {
        let c = ReplacementCapabilities(seeds: [
            .init(match: .prefix("com.example."), hint: .keysOnly),
            .init(match: .prefix("com.example.vm."), hint: .noUnicode),
        ])
        XCTAssertEqual(c.method(for: "com.example.editor"), .keysOnly)
        XCTAssertEqual(c.method(for: "com.example.vm.player"), .noUnicode)
        XCTAssertEqual(c.method(for: "com.examples"), .auto)
    }

    func testOnlyAnUnverifiedAXWriteMarksTheAppBroken() {
        var c = ReplacementCapabilities()
        let app = "com.example.web"
        c.record(.unavailable, of: .axWriteSelection(verify: true), for: app)
        c.record(.done, of: .axWriteSelection(verify: true), for: app)
        c.record(.failedVerify, of: .typeOverSelection, for: app)
        c.record(.failedVerify, of: .axReadRunBeforeCaret(maxChars: 64), for: app)
        XCTAssertFalse(c.isAXWriteBroken(for: app))
        c.record(.failedVerify, of: .axWriteSelection(verify: true), for: app)
        XCTAssertTrue(c.isAXWriteBroken(for: app))
        XCTAssertTrue(c.isAXWriteBroken(for: "COM.EXAMPLE.WEB"))
        XCTAssertFalse(c.isAXWriteBroken(for: "com.example.other"))
        // The verdict doesn't change the hint; the planner just skips AX.
        XCTAssertEqual(c.method(for: app), .auto)
        c.forgetSessionVerdicts()
        XCTAssertFalse(c.isAXWriteBroken(for: app))
    }

    func testEmptyBundleIDIsNeverRecorded() {
        var c = ReplacementCapabilities()
        c.record(.failedVerify, of: .axWriteSelection(verify: true), for: "")
        XCTAssertFalse(c.isAXWriteBroken(for: ""))
    }

    func testSessionCacheIsBounded() {
        var c = ReplacementCapabilities()
        for i in 0..<(ReplacementCapabilities.maxSessionEntries + 10) {
            c.record(.failedVerify, of: .axWriteSelection(verify: true), for: "com.example.app\(i)")
        }
        let remembered = (0..<(ReplacementCapabilities.maxSessionEntries + 10))
            .filter { c.isAXWriteBroken(for: "com.example.app\($0)") }.count
        XCTAssertLessThanOrEqual(remembered, ReplacementCapabilities.maxSessionEntries)
        XCTAssertTrue(c.isAXWriteBroken(for: "com.example.app\(ReplacementCapabilities.maxSessionEntries + 9)"))
    }

    func testVerdictsAreNotCodable() {
        // design.md: capability verdicts are never persisted. Keep the cache out of any Codable model.
        XCTAssertFalse((ReplacementCapabilities() as Any) is any Encodable)
    }

    func testEveryPreferencesMethodMapsToAHint() {
        // P2-20 maps `apps.*.replacementMethod` with MethodHint(rawValue:). `.disabled` comes from the
        // per-app `disabled` flag instead, so it has no ReplacementMethod twin.
        for m in Preferences.AppOverride.ReplacementMethod.allCases {
            XCTAssertNotNil(MethodHint(rawValue: m.rawValue), m.rawValue)
        }
        // P2-36: and the other way round, every hint except `disabled` can be stored as an override.
        for h in MethodHint.allCases where h != .disabled {
            XCTAssertNotNil(Preferences.AppOverride.ReplacementMethod(rawValue: h.rawValue), h.rawValue)
        }
        XCTAssertEqual(MethodHint(rawValue: Preferences.AppOverride.ReplacementMethod.terminal.rawValue), .terminal)
    }
}

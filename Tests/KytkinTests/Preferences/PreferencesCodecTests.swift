// P2-8: PreferencesCodec: defaults, round-trips, lenient decoding, trimming, ISO 8601 dates,
// the P2-31 clamp, corrupt input and newer schemas. Fixtures: Fixtures/preferences/.

import XCTest

final class PreferencesCodecTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_793_872_800)   // 2026-11-05T10:00:00Z

    private func decode(_ json: String) throws -> PreferencesCodec.Decoded {
        try PreferencesCodec.decodeDetailed(Data(json.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Defaults

    func testDefaultsMatch001Schema() {
        let p = Preferences()
        XCTAssertEqual(p.languagePair, LanguagePair(a: InputSourceID("com.apple.keylayout.ABC"),
                                                    b: InputSourceID("com.apple.keylayout.Hebrew")))
        XCTAssertTrue(p.general.enabled)
        XCTAssertTrue(p.general.learnFromManualSwitches)
        XCTAssertEqual(p.general.defaultBehavior, .keepCurrent)
        XCTAssertEqual(p.general.menuBarLabel, .iconAndLanguage, "P6-0c: the old languageCode reads as the default")
        XCTAssertTrue(p.general.checkForUpdates)
        XCTAssertTrue(p.convert.doubleShiftEnabled)
        XCTAssertEqual(p.convert.doubleShiftSides, .sameSide)
        XCTAssertEqual(p.convert.doubleShiftWindowMs, 300)
        XCTAssertTrue(p.convert.switchLanguageAfterConvert)
        XCTAssertTrue(p.convert.useClipboardInUnreadableApps, "P3-37: on when the file predates it")
        XCTAssertTrue(p.autoFix.enabled)
        XCTAssertEqual(p.autoFix.mode, .confidentOnly)
        XCTAssertTrue(p.autoFix.switchLanguageAfterFix)
        XCTAssertTrue(p.autoFix.backspaceUndoes)
        XCTAssertFalse(p.browsers.ignorePrivateWindowsCompletely)
        XCTAssertFalse(p.browsers.useAutomation)
        XCTAssertTrue(p.browsers.siteRulesOn)
        XCTAssertEqual(p.rules, [])
        XCTAssertEqual(p.apps, [:])
        XCTAssertEqual(p.autoFixExceptions.algorithm, "HMAC-SHA256")
        XCTAssertEqual(p.autoFixExceptions.cap, 2_000)
        XCTAssertEqual(p.autoFixExceptions.entries, [])
    }

    func testMinimalFixtureDecodesToDefaults() throws {
        let r = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-minimal.json"))
        XCTAssertEqual(r.prefs, Preferences())
        XCTAssertNil(r.migratedFrom)
        XCTAssertNil(r.newerSchemaVersion)
    }

    func testEmptySectionsDecodeToDefaults() throws {
        let r = try decode(#"{"general":{},"convert":{},"autoFix":{},"browsers":{},"rules":[],"apps":{},"autoFixExceptions":{}}"#)
        XCTAssertEqual(r.prefs, Preferences())
    }

    func test001ContractDecodeReturnsMigratedFromNilForV1() throws {
        let (p, from) = try PreferencesCodec.decode(Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertEqual(p, Preferences())
        XCTAssertNil(from)
    }

    // MARK: - Full fixture and round-trips

    func testFullFixtureDecodesEveryField() throws {
        let p = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-full.json")).prefs
        XCTAssertEqual(p.languagePair.a, InputSourceID("com.apple.keylayout.US"))
        XCTAssertEqual(p.languagePair.b, InputSourceID("com.apple.keylayout.Hebrew-PC"))
        XCTAssertFalse(p.general.enabled)
        XCTAssertFalse(p.general.learnFromManualSwitches)
        XCTAssertEqual(p.general.defaultBehavior, .switchTo(InputSourceID("com.apple.keylayout.US")))
        XCTAssertFalse(p.general.checkForUpdates)
        XCTAssertFalse(p.convert.doubleShiftEnabled)
        XCTAssertEqual(p.convert.doubleShiftSides, .either)
        XCTAssertEqual(p.convert.doubleShiftWindowMs, 420)
        XCTAssertFalse(p.convert.switchLanguageAfterConvert)
        XCTAssertFalse(p.autoFix.enabled)
        XCTAssertEqual(p.autoFix.mode, .allWords)
        XCTAssertFalse(p.autoFix.switchLanguageAfterFix)
        XCTAssertFalse(p.autoFix.backspaceUndoes)
        XCTAssertTrue(p.browsers.ignorePrivateWindowsCompletely)
        XCTAssertTrue(p.browsers.useAutomation, "P3-26: the old per-browser opt-ins, one on → on")

        XCTAssertEqual(p.rules.map(\.scope), [
            .app(bundleID: "com.tinyspeck.slackmacgap"),
            .site(domain: "ynet.co.il"),
            .siteHost(host: "docs.google.com"),
            .chat(bundleID: "com.tinyspeck.slackmacgap", key: ChatKey(kind: .id, value: "T0123/C0456")),
        ])
        XCTAssertEqual(p.rules.map(\.origin), [.learned, .pinned, .pinned, .learned])
        XCTAssertEqual(p.rules[0].updatedAt, date)
        XCTAssertEqual(p.rules[3].label, "Slack chat 1")
        XCTAssertEqual(p.rules[0].id, UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001"))

        XCTAssertEqual(p.apps["com.apple.Terminal"],
                       .init(disabled: false, convertEnabled: true, autoFixEnabled: false, replacementMethod: .keysOnly))
        XCTAssertEqual(p.apps["com.microsoft.VSCode"], .init(disabled: true))
        XCTAssertEqual(p.autoFixExceptions.cap, 1_500)
        XCTAssertEqual(p.autoFixExceptions.entries,
                       [.init(h: "q2VhAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", lastUsed: "2026-11-05")])
    }

    func testFullFixtureRoundTrips() throws {
        let p = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-full.json")).prefs
        let again = try PreferencesCodec.decodeDetailed(PreferencesCodec.encode(p))
        XCTAssertEqual(again.prefs, p)
        XCTAssertNil(again.migratedFrom)
        XCTAssertNil(again.newerSchemaVersion)
    }

    func testDefaultsRoundTrip() throws {
        XCTAssertEqual(try PreferencesCodec.decodeDetailed(PreferencesCodec.encode(Preferences())).prefs, Preferences())
    }

    func testEncodingIsStableAndCarriesSchemaVersion() throws {
        var p = Preferences()
        p.rules = [Rule(id: UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001")!,
                        scope: .app(bundleID: "com.apple.Safari"), inputSource: InputSourceID("com.apple.keylayout.Hebrew"),
                        origin: .pinned, updatedAt: date)]
        let a = try PreferencesCodec.encode(p)
        XCTAssertEqual(a, try PreferencesCodec.encode(p), "sorted keys: same input, same bytes")
        let obj = try object(a)
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(obj["general"] as? [String: Any])
        let text = String(decoding: a, as: UTF8.self)
        XCTAssertTrue(text.contains(#""updatedAt" : "2026-11-05T10:00:00Z""#), text)
        XCTAssertFalse(text.contains(#"\/"#), "slashes aren't escaped")
    }

    func testAppOverrideOmitsUnsetFields() throws {
        var p = Preferences()
        p.apps["com.apple.Terminal"] = .init(convertEnabled: false)
        let apps = try XCTUnwrap(try object(PreferencesCodec.encode(p))["apps"] as? [String: [String: Any]])
        XCTAssertEqual(apps["com.apple.Terminal"]?.keys.sorted(), ["convertEnabled"])
    }

    func testFractionalSecondDatesDecode() throws {
        let r = try decode("""
        {"rules":[{"id":"6F1C0000-0000-4000-8000-000000000001","scope":{"kind":"app","bundleID":"a"},
          "inputSource":"x","origin":"learned","updatedAt":"2026-11-05T10:00:00.500Z"}]}
        """)
        XCTAssertEqual(r.prefs.rules.first?.updatedAt.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970 + 0.5,
                       accuracy: 0.001)
    }

    // MARK: - Lenient decoding

    func testLenientFixture() throws {
        let p = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-lenient.json")).prefs

        // Rules: only the bad entries are dropped (bad UUID, unknown scope kind, bad date, unknown origin, non-object).
        XCTAssertEqual(p.rules.map(\.id.uuidString), [
            "6F1C0000-0000-4000-8000-000000000001",
            "6F1C0000-0000-4000-8000-000000000004",
            "6F1C0000-0000-4000-8000-000000000005",
            "6F1C0000-0000-4000-8000-000000000009",
        ])
        // Hosts and domains are trimmed.
        XCTAssertEqual(p.rules[1].scope, .site(domain: "ynet.co.il"))
        XCTAssertEqual(p.rules[2].scope, .siteHost(host: "docs.google.com"))

        // A broken section or field falls back to its default; good siblings are kept.
        XCTAssertEqual(p.languagePair, .default)
        XCTAssertTrue(p.general.enabled)
        XCTAssertFalse(p.general.learnFromManualSwitches)
        XCTAssertEqual(p.general.defaultBehavior, .keepCurrent)
        XCTAssertEqual(p.convert.doubleShiftSides, .sameSide)
        XCTAssertEqual(p.convert.doubleShiftWindowMs, 500)
        XCTAssertFalse(p.convert.switchLanguageAfterConvert)
        XCTAssertEqual(p.autoFix, Preferences.AutoFix())
        XCTAssertTrue(p.browsers.useAutomation, "P3-26: the old per-browser opt-ins")
        XCTAssertEqual(p.apps, ["com.apple.Terminal": .init(convertEnabled: true)])
        XCTAssertEqual(p.autoFixExceptions.cap, 2_000)
        XCTAssertEqual(p.autoFixExceptions.entries, [.init(h: "abc=", lastUsed: "2026-11-05")])
    }

    func testRulesThatIsNotAnArrayFallsBackToEmpty() throws {
        XCTAssertEqual(try decode(#"{"rules":{"oops":1}}"#).prefs.rules, [])
    }

    func testTrimmedRulesResolveInRuleEngine() throws {
        let p = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-lenient.json")).prefs
        let engine = RuleEngine(rules: p.rules)
        let c = Context(bundleID: "com.apple.Safari", pid: 1, host: "www.ynet.co.il", siteDomain: "ynet.co.il", generation: 1)
        XCTAssertEqual(engine.resolve(c).level, .site)
    }

    func testChatAndAppRulesAreNotTrimmed() throws {
        let r = try decode("""
        {"rules":[{"id":"6F1C0000-0000-4000-8000-000000000001","scope":{"kind":"app","bundleID":" com.x "},
          "inputSource":"x","origin":"learned","updatedAt":"2026-11-05T10:00:00Z"}]}
        """)
        XCTAssertEqual(r.prefs.rules.first?.scope, .app(bundleID: " com.x "))
    }

    // MARK: - Lossy flag (gap 4)

    func testCleanFilesAreNotLossy() throws {
        XCTAssertFalse(try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-full.json")).isLossy)
        XCTAssertFalse(try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-minimal.json")).isLossy)
        XCTAssertFalse(try decode("{}").isLossy)
        XCTAssertFalse(try decode(#"{"general":{},"convert":{"doubleShiftWindowMs":350}}"#).isLossy)
        XCTAssertFalse(try decode(#"{"someFutureKey":1,"general":{"alsoUnknown":true}}"#).isLossy,
                       "unknown keys are ignored, not counted (001 §4.1)")
        XCTAssertFalse(try decode(#"{"general":{"enabled":null},"rules":null}"#).isLossy, "null holds nothing to lose")
        XCTAssertFalse(try decode("""
        {"rules":[{"id":"6F1C0000-0000-4000-8000-000000000001","scope":{"kind":"site","domain":" ynet.co.il "},
          "inputSource":"x","origin":"learned","updatedAt":"2026-11-05T10:00:00Z"}]}
        """).isLossy, "trimming is a normalization, not a loss")
    }

    func testLenientFixtureIsLossy() throws {
        XCTAssertTrue(try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-lenient.json")).isLossy)
    }

    func testEachKindOfDropIsLossy() throws {
        let cases = [
            #"{"rules":{"oops":1}}"#,                                       // non-array rules
            #"{"rules":["not a rule"]}"#,                                   // one bad entry
            #"{"general":{"enabled":"yes"}}"#,                              // mistyped field
            #"{"general":{"defaultBehavior":{"kind":"teleport"}}}"#,        // unknown enum value
            #"{"autoFix":"on"}"#,                                           // mistyped section
            #"{"languagePair":{"a":"com.apple.keylayout.ABC"}}"#,           // half a pair
            #"{"convert":{"doubleShiftWindowMs":9000}}"#,                   // clamped
            #"{"convert":{"doubleShiftWindowMs":333.6}}"#,                  // rounded
            #"{"browsers":{"appleEventsOptIn":{"com.brave.Browser":"maybe"}}}"#,
            #"{"apps":{"com.apple.Notes":5}}"#,
            #"{"apps":{"  ":{"disabled":true}}}"#,                          // blank bundle ID
            #"{"apps":{"com.x":{"disabled":true}," com.x":{"disabled":false}}}"#,   // duplicate after trimming
            #"{"apps":{"com.apple.Terminal":{"replacementMethod":"telepathy"}}}"#,
            #"{"autoFixExceptions":{"cap":-1}}"#,
            #"{"autoFixExceptions":{"entries":[{"h":12}]}}"#,
        ]
        for json in cases {
            XCTAssertTrue(try decode(json).isLossy, json)
        }
    }

    func testTerminalReplacementMethodRoundTrips() throws {
        // P2-36 (001 §12 T1, §4.2): `terminal` is a stored method; the old `keysOnly` value keeps working.
        let d = try decode(#"{"apps":{"com.mitchellh.ghostty":{"replacementMethod":"terminal"},"#
                           + #""com.google.Chrome":{"replacementMethod":"keysOnly"}}}"#)
        XCTAssertFalse(d.isLossy)
        XCTAssertEqual(d.prefs.apps["com.mitchellh.ghostty"]?.replacementMethod, .terminal)
        XCTAssertEqual(d.prefs.apps["com.google.Chrome"]?.replacementMethod, .keysOnly)
        let again = try PreferencesCodec.decodeDetailed(try PreferencesCodec.encode(d.prefs))
        XCTAssertEqual(again.prefs.apps, d.prefs.apps)
    }

    func testLossyFlagDoesNotLeakIntoTheNextDecode() throws {
        XCTAssertTrue(try decode(#"{"general":{"enabled":"yes"}}"#).isLossy)
        XCTAssertFalse(try decode("{}").isLossy)
        // Outside a codec decode, recording is a no-op (no recorder installed).
        XCTAssertNil(PreferencesDecodingLoss.current)
        _ = try JSONDecoder().decode(Preferences.self, from: Data(#"{"general":{"enabled":"yes"}}"#.utf8))
    }

    // MARK: - P2-31 clamp

    func testDoubleShiftWindowIsClampedOnDecode() throws {
        let cases: [(String, Int)] = [("5", 200), ("199", 200), ("200", 200), ("350", 350), ("500", 500),
                                      ("501", 500), ("90000", 500), ("-40", 200), ("333.6", 334), ("1e300", 500),
                                      (#""fast""#, 300), ("null", 300), ("true", 300)]
        for (raw, expected) in cases {
            let p = try decode(#"{"convert":{"doubleShiftWindowMs":\#(raw)}}"#).prefs
            XCTAssertEqual(p.convert.doubleShiftWindowMs, expected, "doubleShiftWindowMs: \(raw)")
        }
    }

    func testDoubleShiftWindowIsClampedOnAssignment() {
        var c = Preferences.Convert()
        c.doubleShiftWindowMs = 10
        XCTAssertEqual(c.doubleShiftWindowMs, 200)
        c.doubleShiftWindowMs = 10_000
        XCTAssertEqual(c.doubleShiftWindowMs, 500)
        c.doubleShiftWindowMs = 260
        XCTAssertEqual(c.doubleShiftWindowMs, 260)
    }

    func testDoubleShiftConfigFollowsSettings() {
        var c = Preferences.Convert()
        c.doubleShiftWindowMs = 450
        c.doubleShiftSides = .rightOnly
        let config = c.doubleShiftConfig
        XCTAssertEqual(config.windowNanos, 450_000_000)
        XCTAssertEqual(config.sides, .rightOnly)
        XCTAssertEqual(config.maxHoldNanos, DoubleShiftConfig().maxHoldNanos)
    }

    func testEverySidePolicyRoundTrips() throws {
        for side in [DoubleShiftConfig.SidePolicy.either, .sameSide, .leftOnly, .rightOnly] {
            var p = Preferences()
            p.convert.doubleShiftSides = side
            XCTAssertEqual(try PreferencesCodec.decodeDetailed(PreferencesCodec.encode(p)).prefs.convert.doubleShiftSides, side)
        }
    }

    // MARK: - Corrupt input

    func testCorruptInputThrows() throws {
        XCTAssertThrowsError(try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-corrupt.json"))) {
            XCTAssertEqual($0 as? PreferencesCodec.DecodeError, .notJSON)
        }
        let cases: [(String, PreferencesCodec.DecodeError)] = [
            ("", .notJSON),
            ("not json", .notJSON),
            ("[]", .notAnObject),
            ("42", .notAnObject),
            (#""text""#, .notAnObject),
            (#"{"schemaVersion":"1"}"#, .badSchemaVersion),
            (#"{"schemaVersion":1.5}"#, .badSchemaVersion),
            (#"{"schemaVersion":true}"#, .badSchemaVersion),
            (#"{"schemaVersion":0}"#, .badSchemaVersion),
            (#"{"schemaVersion":-3}"#, .badSchemaVersion),
        ]
        for (raw, expected) in cases {
            XCTAssertThrowsError(try decode(raw), raw) {
                XCTAssertEqual($0 as? PreferencesCodec.DecodeError, expected, raw)
            }
        }
    }

    // MARK: - Newer schema

    func testFutureVersionLoadsWhatV1Understands() throws {
        let r = try PreferencesCodec.decodeDetailed(Fixtures.data("preferences/v1-future-version.json"))
        XCTAssertEqual(r.newerSchemaVersion, 7)
        XCTAssertNil(r.migratedFrom)
        XCTAssertEqual(r.prefs.languagePair.b, InputSourceID("com.apple.keylayout.Russian"))
        XCTAssertFalse(r.prefs.general.learnFromManualSwitches)
        XCTAssertEqual(r.prefs.general.menuBarLabel, .iconAndLanguage, "unknown value → default")
        XCTAssertEqual(r.prefs.convert.doubleShiftSides, .leftOnly)
        XCTAssertEqual(r.prefs.convert.doubleShiftWindowMs, 350)
        XCTAssertEqual(r.prefs.rules.map(\.scope), [.app(bundleID: "com.apple.Safari")], "unknown rule kind dropped")
    }

    // MARK: - LanguagePair

    func testLanguagePairOther() {
        let pair = LanguagePair.default
        XCTAssertEqual(pair.other(than: pair.a), pair.b)
        XCTAssertEqual(pair.other(than: pair.b), pair.a)
        XCTAssertNil(pair.other(than: InputSourceID("com.apple.keylayout.Russian")))
    }
}

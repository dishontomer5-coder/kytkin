// P2-9: JSON shape and round-trips for Rule, RuleScope, ChatKey, RuleOrigin and DefaultBehavior,
// matching preferences.json schema v1 (001 §4.2), which P2-8 will persist.

import XCTest

final class RuleCodableTests: XCTestCase {
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder().encode(value)
        XCTAssertEqual(try decoder().decode(T.self, from: data), value, file: file, line: line)
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ s: String) throws -> T {
        try decoder().decode(T.self, from: Data(s.utf8))
    }

    private let date = Date(timeIntervalSince1970: 1_793_872_800)   // 2026-11-05T10:00:00Z, whole seconds for ISO 8601

    // MARK: - 001 §4.2 example rules

    func testDecodes001ExampleRules() throws {
        let s = """
        [
          { "id": "6F1C0000-0000-4000-8000-000000000001", "scope": { "kind": "app", "bundleID": "com.tinyspeck.slackmacgap" },
            "inputSource": "com.apple.keylayout.Hebrew", "origin": "learned", "updatedAt": "2026-11-05T10:00:00Z" },
          { "id": "A2D90000-0000-4000-8000-000000000002", "scope": { "kind": "site", "domain": "ynet.co.il" },
            "inputSource": "com.apple.keylayout.Hebrew", "origin": "pinned", "updatedAt": "2026-11-05T10:01:00Z" },
          { "id": "B7E00000-0000-4000-8000-000000000003", "scope": { "kind": "siteHost", "host": "docs.google.com" },
            "inputSource": "com.apple.keylayout.ABC", "origin": "pinned", "updatedAt": "2026-11-05T10:02:00Z" },
          { "id": "C3F40000-0000-4000-8000-000000000004", "scope": { "kind": "chat", "bundleID": "com.tinyspeck.slackmacgap",
            "key": { "kind": "id", "value": "T0123/C0456" } }, "label": "Slack chat 1",
            "inputSource": "com.apple.keylayout.Hebrew", "origin": "learned", "updatedAt": "2026-11-05T10:03:00Z" }
        ]
        """
        let rules = try decode([Rule].self, s)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules[0].scope, .app(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(rules[0].origin, .learned)
        XCTAssertNil(rules[0].label)
        XCTAssertEqual(rules[0].updatedAt, date)
        XCTAssertEqual(rules[0].id, UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001"))
        XCTAssertEqual(rules[1].scope, .site(domain: "ynet.co.il"))
        XCTAssertEqual(rules[1].origin, .pinned)
        XCTAssertEqual(rules[2].scope, .siteHost(host: "docs.google.com"))
        XCTAssertEqual(rules[2].inputSource, InputSourceID("com.apple.keylayout.ABC"))
        XCTAssertEqual(rules[3].scope, .chat(bundleID: "com.tinyspeck.slackmacgap", key: ChatKey(kind: .id, value: "T0123/C0456")))
        XCTAssertEqual(rules[3].label, "Slack chat 1")
        XCTAssertEqual(rules[3].updatedAt, date.addingTimeInterval(180))
    }

    // MARK: - Encoded shape

    func testScopeEncodesFlatKindTaggedObjects() throws {
        XCTAssertEqual(try json(RuleScope.app(bundleID: "a.b")), #"{"bundleID":"a.b","kind":"app"}"#)
        XCTAssertEqual(try json(RuleScope.site(domain: "ynet.co.il")), #"{"domain":"ynet.co.il","kind":"site"}"#)
        XCTAssertEqual(try json(RuleScope.siteHost(host: "docs.google.com")), #"{"host":"docs.google.com","kind":"siteHost"}"#)
        XCTAssertEqual(try json(RuleScope.chat(bundleID: "a.b", key: ChatKey(kind: .hashed, value: "q2Vh"))),
                       #"{"bundleID":"a.b","key":{"kind":"hashed","value":"q2Vh"},"kind":"chat"}"#)
    }

    func testRuleEncodesInputSourceAsBareStringAndOmitsNilLabel() throws {
        let rule = Rule(id: UUID(uuidString: "6F1C0000-0000-4000-8000-000000000001")!, scope: .app(bundleID: "a.b"),
                        inputSource: InputSourceID("com.apple.keylayout.Hebrew"), origin: .pinned, updatedAt: date)
        XCTAssertEqual(try json(rule),
                       #"{"id":"6F1C0000-0000-4000-8000-000000000001","inputSource":"com.apple.keylayout.Hebrew","#
                       + #""origin":"pinned","scope":{"bundleID":"a.b","kind":"app"},"updatedAt":"2026-11-05T10:00:00Z"}"#)
    }

    func testDefaultBehaviorShape() throws {
        XCTAssertEqual(try json(DefaultBehavior.keepCurrent), #"{"kind":"keepCurrent"}"#)
        XCTAssertEqual(try json(DefaultBehavior.switchTo(InputSourceID("com.apple.keylayout.ABC"))),
                       #"{"inputSource":"com.apple.keylayout.ABC","kind":"switchTo"}"#)
        XCTAssertEqual(try decode(DefaultBehavior.self, #"{ "kind": "keepCurrent" }"#), .keepCurrent)
    }

    // MARK: - Round-trips

    func testRoundTripsEveryScopeKindAndOrigin() throws {
        let scopes: [RuleScope] = [
            .app(bundleID: "com.apple.TextEdit"),
            .site(domain: "ynet.co.il"),
            .siteHost(host: "docs.google.com"),
            .chat(bundleID: "com.tinyspeck.slackmacgap", key: ChatKey(kind: .id, value: "T0123/C0456")),
            .chat(bundleID: "net.whatsapp.WhatsApp", key: ChatKey(kind: .hashed, value: "q2Vh+/==")),
        ]
        XCTAssertEqual(Set(scopes.map(\.kind)), Set(RuleScope.Kind.allCases))
        for scope in scopes {
            try roundTrip(scope)
            for origin in RuleOrigin.allCases {
                try roundTrip(Rule(scope: scope, inputSource: InputSourceID("com.apple.keylayout.Hebrew"),
                                   origin: origin, label: nil, updatedAt: date))
                try roundTrip(Rule(scope: scope, inputSource: InputSourceID("com.apple.keylayout.ABC"),
                                   origin: origin, label: "שיחה 1 \u{1F600}", updatedAt: date))
            }
        }
    }

    func testRoundTripsDefaultBehaviorAndChatKey() throws {
        try roundTrip(DefaultBehavior.keepCurrent)
        try roundTrip(DefaultBehavior.switchTo(InputSourceID("com.apple.keylayout.Hebrew")))
        try roundTrip(ChatKey(kind: .id, value: "T0123/C0456"))
        try roundTrip(ChatKey(kind: .hashed, value: "abc"))
    }

    func testRoundTripWithDefaultDateStrategyKeepsSubSecondPrecision() throws {
        let rule = Rule(scope: .app(bundleID: "a.b"), inputSource: InputSourceID("x"), origin: .learned,
                        updatedAt: Date(timeIntervalSince1970: 1_793_872_800.123))
        let back = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(back, rule)
    }

    func testRoundTripPreservesEngineResult() throws {
        let rules = [Rule(scope: .app(bundleID: "a.b"), inputSource: InputSourceID("en"), origin: .pinned, updatedAt: date),
                     Rule(scope: .site(domain: "ynet.co.il"), inputSource: InputSourceID("he"), origin: .learned, updatedAt: date)]
        let back = try decoder().decode([Rule].self, from: encoder().encode(rules))
        let c = Context(bundleID: "a.b", pid: 1, host: "www.ynet.co.il", siteDomain: "ynet.co.il", generation: 1)
        XCTAssertEqual(RuleEngine(rules: back).resolve(c), RuleEngine(rules: rules).resolve(c))
    }

    // MARK: - Decoding errors and leniency

    func testUnknownScopeKindThrows() {
        XCTAssertThrowsError(try decode(RuleScope.self, #"{ "kind": "window", "title": "x" }"#))
    }

    func testMissingScopeFieldThrows() {
        XCTAssertThrowsError(try decode(RuleScope.self, #"{ "kind": "app" }"#))
        XCTAssertThrowsError(try decode(RuleScope.self, #"{ "kind": "site", "host": "a.com" }"#))
        XCTAssertThrowsError(try decode(RuleScope.self, #"{ "kind": "chat", "bundleID": "a.b" }"#))
        XCTAssertThrowsError(try decode(RuleScope.self, #"{ "bundleID": "a.b" }"#))
    }

    func testUnknownOriginOrChatKindThrows() {
        XCTAssertThrowsError(try decode(RuleOrigin.self, #""automatic""#))
        XCTAssertThrowsError(try decode(ChatKey.self, #"{ "kind": "name", "value": "Mom" }"#))
    }

    func testUnknownDefaultBehaviorThrows() {
        XCTAssertThrowsError(try decode(DefaultBehavior.self, #"{ "kind": "last" }"#))
        XCTAssertThrowsError(try decode(DefaultBehavior.self, #"{ "kind": "switchTo" }"#))
    }

    func testRuleMissingRequiredFieldThrows() {
        let base = #""scope": { "kind": "app", "bundleID": "a.b" }, "inputSource": "x", "origin": "learned""#
        XCTAssertThrowsError(try decode(Rule.self, "{ \(base), \"updatedAt\": \"2026-11-05T10:00:00Z\" }"))   // no id
        XCTAssertThrowsError(try decode(Rule.self, "{ \"id\": \"6F1C0000-0000-4000-8000-000000000001\", \(base) }")) // no updatedAt
        XCTAssertThrowsError(try decode(Rule.self, "{ \"id\": \"not-a-uuid\", \(base), \"updatedAt\": \"2026-11-05T10:00:00Z\" }"))
    }

    func testUnknownKeysAreIgnoredAndNullLabelDecodesAsNil() throws {
        let s = """
        { "id": "6F1C0000-0000-4000-8000-000000000001", "scope": { "kind": "app", "bundleID": "a.b", "extra": 1 },
          "inputSource": "x", "origin": "learned", "label": null, "updatedAt": "2026-11-05T10:00:00Z", "future": true }
        """
        let rule = try decode(Rule.self, s)
        XCTAssertNil(rule.label)
        XCTAssertEqual(rule.scope, .app(bundleID: "a.b"))
    }
}

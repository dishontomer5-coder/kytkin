// P2-20: RuleWriter, the single rule write path (001 §12 S3): learn / pin / forget, each collapsing the other rules
// of the same normalized scope.

import XCTest

final class RuleWriterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let notes = "com.apple.Notes"

    func testLearnAppendsANewLearnedRule() {
        let id = UUID()
        let rules = RuleWriter.learn(.learn(.app(bundleID: notes), IDs.hebrew), into: [], now: t1, newID: id)
        XCTAssertEqual(rules, [Rule(id: id, scope: .app(bundleID: notes), inputSource: IDs.hebrew, origin: .learned,
                                    updatedAt: t1)])
    }

    func testLearnUpdatesTheLearnedRuleInPlace() {
        let existing = Rule.app(notes, IDs.abc)
        let other = Rule.app("com.apple.Terminal", IDs.abc)
        let rules = RuleWriter.learn(.learn(.app(bundleID: notes), IDs.hebrew), into: [existing, other], now: t1)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].id, existing.id)
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
        XCTAssertEqual(rules[0].updatedAt, t1)
        XCTAssertEqual(rules[1], other)
    }

    func testLearnNeverTouchesAPin() {
        let pin = Rule.app(notes, IDs.abc, .pinned)
        let dupe = Rule.app(notes, IDs.russian)
        XCTAssertEqual(RuleWriter.learn(.learn(.app(bundleID: notes), IDs.hebrew), into: [pin, dupe], now: t1),
                       [pin, dupe], "nothing written, nothing collapsed")
    }

    func testLearnCollapsesDuplicates() {
        let older = Rule.app(notes, IDs.abc, at: t0)
        let newer = Rule.app(notes, IDs.russian, at: t0.addingTimeInterval(10))
        let rules = RuleWriter.learn(.learn(.app(bundleID: notes), IDs.hebrew), into: [older, newer], now: t1)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, newer.id, "the winner keeps its id")
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
    }

    func testLearnCollapsesHostsDifferingOnlyInCaseAndDot() {
        let a = Rule(scope: .site(domain: "Ynet.co.il."), inputSource: IDs.abc, origin: .learned, updatedAt: t0)
        let b = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.abc, origin: .learned, updatedAt: t0)
        let rules = RuleWriter.learn(.learn(.site(domain: "ynet.co.il"), IDs.hebrew), into: [a, b], now: t1)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
    }

    func testDiscardOutcomeChangesNothing() {
        let rules = [Rule.app(notes, IDs.abc), Rule.app(notes, IDs.hebrew)]
        XCTAssertEqual(RuleWriter.learn(.discard(.pinned), into: rules, now: t1), rules)
    }

    func testPinAddsAPinnedRule() {
        let id = UUID()
        let rules = RuleWriter.pin(.app(bundleID: notes), to: IDs.hebrew, in: [], now: t1, newID: id)
        XCTAssertEqual(rules, [Rule(id: id, scope: .app(bundleID: notes), inputSource: IDs.hebrew, origin: .pinned,
                                    updatedAt: t1)])
    }

    func testPinTurnsTheLearnedRuleIntoAPinKeepingIdAndLabel() {
        var learned = Rule.app(notes, IDs.abc)
        learned.label = "Notes"
        let rules = RuleWriter.pin(.app(bundleID: notes), to: IDs.hebrew, in: [learned], now: t1)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, learned.id)
        XCTAssertEqual(rules[0].origin, .pinned)
        XCTAssertEqual(rules[0].label, "Notes")
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
        XCTAssertEqual(rules[0].updatedAt, t1)
    }

    func testPinCollapsesDuplicatesAndKeepsOtherScopes() {
        let other = Rule.app("com.apple.Terminal", IDs.abc)
        let rules = RuleWriter.pin(.app(bundleID: notes), to: IDs.hebrew,
                                   in: [Rule.app(notes, IDs.abc), other, Rule.app(notes, IDs.russian, .pinned)],
                                   now: t1)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.filter { $0.scope == .app(bundleID: notes) }.count, 1)
        XCTAssertTrue(rules.contains(other))
    }

    func testPinWithAnEmptyKeyWritesNothing() {
        XCTAssertEqual(RuleWriter.pin(.app(bundleID: ""), to: IDs.hebrew, in: [], now: t1), [])
    }

    func testForgetRemovesEveryRuleOfTheScope() {
        let other = Rule.app("com.apple.Terminal", IDs.abc)
        let rules = [Rule.app(notes, IDs.abc), other, Rule.app(notes, IDs.hebrew, .pinned)]
        XCTAssertEqual(RuleWriter.forget(.app(bundleID: notes), in: rules), [other])
    }

    func testForgetMatchesNormalizedHosts() {
        let r = Rule(scope: .siteHost(host: "Docs.Google.com."), inputSource: IDs.abc, origin: .pinned, updatedAt: t0)
        XCTAssertEqual(RuleWriter.forget(.siteHost(host: "docs.google.com"), in: [r]), [])
    }

    func testForgetEmptyKeyIsANoOp() {
        let rules = [Rule.app(notes, IDs.abc)]
        XCTAssertEqual(RuleWriter.forget(.app(bundleID: ""), in: rules), rules)
    }
}

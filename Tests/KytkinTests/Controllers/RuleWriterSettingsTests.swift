// P2-25: RuleWriter's Settings → Rules writes (001 §12 S3): unpin, and forget all learned rules keeping every pin.

import XCTest

final class RuleWriterSettingsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let notes = "com.apple.Notes"
    private let term = "com.apple.Terminal"

    // MARK: - Unpin

    func testUnpinMakesThePinLearnedKeepingIdSourceAndLabel() {
        var pin = Rule.app(notes, IDs.hebrew, .pinned, at: t0)
        pin.label = "Notes"
        let other = Rule.app(term, IDs.abc)
        let rules = RuleWriter.unpin(.app(bundleID: notes), in: [pin, other], now: t1)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].id, pin.id)
        XCTAssertEqual(rules[0].origin, .learned)
        XCTAssertEqual(rules[0].inputSource, IDs.hebrew)
        XCTAssertEqual(rules[0].label, "Notes")
        XCTAssertEqual(rules[0].updatedAt, t1)
        XCTAssertEqual(rules[1], other)
    }

    func testUnpinOfALearnedRuleOrNoRuleChangesNothing() {
        let learned = Rule.app(notes, IDs.hebrew)
        XCTAssertEqual(RuleWriter.unpin(.app(bundleID: notes), in: [learned], now: t1), [learned])
        XCTAssertEqual(RuleWriter.unpin(.app(bundleID: term), in: [learned], now: t1), [learned])
        XCTAssertEqual(RuleWriter.unpin(.app(bundleID: ""), in: [learned], now: t1), [learned])
    }

    func testUnpinCollapsesDuplicatesOfTheScope() {
        let pin = Rule.app(notes, IDs.hebrew, .pinned)
        let dupe = Rule.app(notes, IDs.abc)
        let rules = RuleWriter.unpin(.app(bundleID: notes), in: [dupe, pin], now: t1)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, pin.id)
        XCTAssertEqual(rules[0].origin, .learned)
    }

    func testUnpinOfASiteWorksOnTheNormalizedHost() {
        let pin = Rule(scope: .site(domain: "Ynet.co.il."), inputSource: IDs.hebrew, origin: .pinned, updatedAt: t0)
        let rules = RuleWriter.unpin(.site(domain: "ynet.co.il"), in: [pin], now: t1)
        XCTAssertEqual(rules.map(\.origin), [.learned])
    }

    // MARK: - Forget all learned

    func testForgetAllLearnedKeepsEveryPin() {
        let a = Rule.app(notes, IDs.hebrew)
        let b = Rule.app(term, IDs.abc, .pinned)
        let c = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned, updatedAt: t0)
        let d = Rule(scope: .chat(bundleID: "com.tinyspeck.slackmacgap", key: ChatKey(kind: .id, value: "T1/C2")),
                     inputSource: IDs.hebrew, origin: .pinned, updatedAt: t0)
        XCTAssertEqual(RuleWriter.forgetAllLearned(in: [a, b, c, d]), [b, d])
    }

    func testForgetAllLearnedLeavesOnlyThePinnedWinnerOfADuplicateScope() {
        let learned = Rule.app(notes, IDs.abc, at: t1)
        let olderPin = Rule.app(notes, IDs.russian, .pinned, at: t0)
        let newerPin = Rule.app(notes, IDs.hebrew, .pinned, at: t1)
        XCTAssertEqual(RuleWriter.forgetAllLearned(in: [learned, olderPin, newerPin]), [newerPin])
    }

    func testForgetAllLearnedWithEmptyKeysDropsLearnedKeepsPinned() {
        let learned = Rule.app("", IDs.abc)
        let pinned = Rule.app("", IDs.hebrew, .pinned)
        XCTAssertEqual(RuleWriter.forgetAllLearned(in: [learned, pinned]), [pinned])
    }

    func testForgetAllLearnedOnNothingIsEmpty() {
        XCTAssertEqual(RuleWriter.forgetAllLearned(in: []), [])
        XCTAssertEqual(RuleWriter.forgetAllLearned(in: [Rule.app(notes, IDs.abc)]), [])
    }
}

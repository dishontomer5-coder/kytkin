// P2-10: RuleLearner: the 500 ms settle window, confirm by words, confirm by dwell, cancel on context
// change / switch back / our switch, the pin guard, private windows, the empty bundle ID, learning off,
// and writing a .learn through RuleWriter (learn new, update learned, never touch pinned) (001 §3 (b), §10 P2-10).

import XCTest

final class RuleLearnerTests: XCTestCase {
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let russian = InputSourceID("com.apple.keylayout.Russian")
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ms: UInt64 = 1_000_000
    private let sec: UInt64 = 1_000_000_000

    private var clock: FakeClock!

    override func setUp() {
        super.setUp()
        clock = FakeClock(nowNanos: 10 * sec)
    }

    private func ctx(_ bundleID: String, host: String? = nil, domain: String? = nil,
                     isPrivate: Bool? = nil) -> Context {
        Context(bundleID: bundleID, pid: 42, host: host, siteDomain: domain, isPrivateWindow: isPrivate, generation: 1)
    }

    private func learner(_ rules: [Rule] = [], tap: Bool = true, current: InputSourceID? = nil) -> RuleLearner {
        RuleLearner(engine: RuleEngine(rules: rules), keyboardTapAvailable: tap, currentSource: current)
    }

    /// Context change now, then wait past the settle window.
    private func enter(_ c: Context, _ l: inout RuleLearner) {
        XCTAssertNil(l.handle(.contextChanged(c, atNanos: clock.nowNanos)))
        clock.advance(bySeconds: 1)
    }

    private func externalSwitch(_ id: InputSourceID, _ l: inout RuleLearner) -> LearnOutcome? {
        l.handle(.externalSwitch(id, atNanos: clock.nowNanos))
    }

    private func words(_ n: Int, _ l: inout RuleLearner) -> LearnOutcome? {
        var last: LearnOutcome?
        for _ in 0..<n {
            clock.advance(byMilliseconds: 300)
            last = l.handle(.wordBoundary(atNanos: clock.nowNanos))
        }
        return last
    }

    // MARK: - Learning

    func testLearnsAppRuleAfterTwoWords() {
        var l = learner()
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(l.pending?.source, hebrew)
        XCTAssertNil(words(1, &l), "one word isn't enough")
        XCTAssertEqual(words(1, &l), .learn(.app(bundleID: slack), hebrew))
        XCTAssertNil(l.pending)
        XCTAssertNil(words(3, &l), "committed once; later words do nothing")
    }

    func testLearnsSiteScopeFromContext() {
        var l = learner()
        enter(ctx(chrome, host: "www.ynet.co.il", domain: "ynet.co.il"), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(words(2, &l), .learn(.site(domain: "ynet.co.il"), hebrew))
    }

    func testConfirmWordsIsConfigurable() {
        var cfg = LearnerConfig()
        cfg.confirmWords = 3
        var l = RuleLearner(engine: RuleEngine(rules: []), config: cfg)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertNil(words(2, &l))
        XCTAssertEqual(words(1, &l), .learn(.app(bundleID: slack), hebrew))
    }

    func testUpdatesExistingLearnedRule() {
        let rules = [Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .learned, updatedAt: t0)]
        var l = learner(rules)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(words(2, &l), .learn(.app(bundleID: slack), hebrew))
    }

    func testSameSourceAsLearnedRuleIsDiscarded() {
        let rules = [Rule(scope: .app(bundleID: slack), inputSource: hebrew, origin: .learned, updatedAt: t0)]
        var l = learner(rules)
        enter(ctx(slack), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.alreadyLearned))
    }

    // MARK: - Settle window (debounce after a context change)

    func testSwitchInsideSettleWindowIsDiscarded() {
        var l = learner()
        XCTAssertNil(l.handle(.contextChanged(ctx(slack), atNanos: clock.nowNanos)))
        clock.advance(byMilliseconds: 120)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.tooSoonAfterContextChange))
        XCTAssertNil(l.pending)
        XCTAssertNil(words(2, &l))
    }

    func testSwitchJustBeforeSettleEdgeIsDiscarded() {
        var l = learner()
        XCTAssertNil(l.handle(.contextChanged(ctx(slack), atNanos: clock.nowNanos)))
        clock.advance(byNanos: 500 * ms - 1)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.tooSoonAfterContextChange))
    }

    func testSwitchAtSettleEdgeBecomesCandidate() {
        var l = learner()
        XCTAssertNil(l.handle(.contextChanged(ctx(slack), atNanos: clock.nowNanos)))
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(words(2, &l), .learn(.app(bundleID: slack), hebrew))
    }

    func testOutOfOrderTimestampCountsAsTooSoon() {
        var l = learner()
        XCTAssertNil(l.handle(.contextChanged(ctx(slack), atNanos: 20 * sec)))
        XCTAssertEqual(l.handle(.externalSwitch(hebrew, atNanos: 19 * sec)), .discard(.tooSoonAfterContextChange))
    }

    // MARK: - Dwell (no keyboard tap)

    func testDwellCommitsWithoutTap() {
        var l = learner(tap: false)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        clock.advance(byNanos: 4 * sec - 1)
        XCTAssertNil(l.handle(.tick(atNanos: clock.nowNanos)))
        clock.advance(byNanos: 1)
        XCTAssertEqual(l.handle(.tick(atNanos: clock.nowNanos)), .learn(.app(bundleID: slack), hebrew))
    }

    func testDwellDoesNotCommitWhenTapIsAvailable() {
        var l = learner(tap: true)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        clock.advance(bySeconds: 10)
        XCTAssertNil(l.handle(.tick(atNanos: clock.nowNanos)))
        XCTAssertEqual(l.pending?.source, hebrew, "still waiting for words")
    }

    func testWordsIgnoredWithoutTap() {
        var l = learner(tap: false)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertNil(words(5, &l))
    }

    // MARK: - Cancellation

    func testContextChangeCancelsCandidate() {
        var l = learner()
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertNil(words(1, &l))
        XCTAssertEqual(l.handle(.contextChanged(ctx(chrome), atNanos: clock.nowNanos)), .discard(.contextChanged))
        XCTAssertNil(words(2, &l), "words in the new context don't confirm the old candidate")
    }

    func testSwitchBackCancels() {
        var l = learner(current: abc)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        clock.advance(byMilliseconds: 200)
        XCTAssertEqual(externalSwitch(abc, &l), .discard(.switchedBack))
        XCTAssertNil(l.pending)
        XCTAssertNil(words(2, &l))
    }

    func testSwitchToThirdSourceReplacesCandidate() {
        var l = learner(current: abc)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertNil(words(1, &l))
        XCTAssertNil(externalSwitch(russian, &l))
        XCTAssertNil(words(1, &l), "word count restarts for the new candidate")
        XCTAssertEqual(words(1, &l), .learn(.app(bundleID: slack), russian))
    }

    func testOurSwitchCancelsCandidate() {
        var l = learner()
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(l.handle(.ourSwitch(abc)), .discard(.ourSwitch))
        XCTAssertNil(words(2, &l))
    }

    func testSwitchBackToOurChoiceCancels() {
        // P2-10 QA: Kytkin picks Hebrew; the user tries ABC, then goes back to Hebrew. That's a change of mind.
        var l = learner(current: abc)
        enter(ctx(slack), &l)
        XCTAssertNil(l.handle(.ourSwitch(hebrew)))
        XCTAssertNil(externalSwitch(abc, &l))
        clock.advance(byMilliseconds: 200)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.switchedBack))
        XCTAssertNil(words(2, &l))
    }

    func testSwitchBackAfterCommitStartsNewCandidate() {
        // Once committed, switching back is a new preference, not a cancel.
        var l = learner(current: abc)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(words(2, &l), .learn(.app(bundleID: slack), hebrew))
        XCTAssertNil(externalSwitch(abc, &l))
        XCTAssertEqual(words(2, &l), .learn(.app(bundleID: slack), abc))
    }

    func testDwellCancelledByContextChange() {
        var l = learner(tap: false)
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        clock.advance(bySeconds: 2)
        XCTAssertEqual(l.handle(.contextChanged(ctx(chrome), atNanos: clock.nowNanos)), .discard(.contextChanged))
        clock.advance(bySeconds: 5)
        XCTAssertNil(l.handle(.tick(atNanos: clock.nowNanos)))
    }

    func testCancelsWithNoCandidateReturnNil() {
        var l = learner()
        XCTAssertNil(l.handle(.ourSwitch(abc)))
        XCTAssertNil(l.handle(.contextChanged(ctx(slack), atNanos: clock.nowNanos)))
        XCTAssertNil(l.handle(.wordBoundary(atNanos: clock.nowNanos)))
        XCTAssertNil(l.handle(.tick(atNanos: clock.nowNanos)))
    }

    // MARK: - Pin guard

    func testPinnedRuleIsNeverLearnedOver() {
        let rules = [Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .pinned, updatedAt: t0)]
        var l = learner(rules)
        enter(ctx(slack), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.pinned))
        XCTAssertNil(words(2, &l))
    }

    func testPinnedSiteHostOverrideIsNeverLearnedOver() {
        let rules = [Rule(scope: .siteHost(host: "docs.google.com"), inputSource: abc, origin: .pinned, updatedAt: t0)]
        var l = learner(rules)
        enter(ctx(chrome, host: "docs.google.com", domain: "google.com"), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.pinned))
    }

    func testPinAddedWhileCandidatePendingBlocksCommit() {
        var l = learner()
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        l.engine = RuleEngine(rules: [Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .pinned, updatedAt: t0)])
        XCTAssertEqual(words(2, &l), .discard(.pinned))
    }

    func testWriterLearnNeverChangesPinnedRule() {
        let pinned = Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .pinned, updatedAt: t0)
        let out = RuleWriter.learn(.learn(.app(bundleID: slack), hebrew), into: [pinned], now: t0.addingTimeInterval(60))
        XCTAssertEqual(out, [pinned])
    }

    func testWriterLearnWithPinnedAndLearnedDuplicatesChangesNothing() {
        let pinned = Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .pinned, updatedAt: t0)
        let learned = Rule(scope: .app(bundleID: slack), inputSource: russian, origin: .learned, updatedAt: t0.addingTimeInterval(5))
        let out = RuleWriter.learn(.learn(.app(bundleID: slack), hebrew), into: [pinned, learned], now: t0.addingTimeInterval(60))
        XCTAssertEqual(out, [pinned, learned])
    }

    // MARK: - Private windows, empty bundle ID, learning off

    func testPrivateWindowLearnsNothing() {
        var l = learner()
        enter(ctx(chrome, host: "www.ynet.co.il", domain: "ynet.co.il", isPrivate: true), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.privateWindow))
        XCTAssertNil(l.pending)
        XCTAssertNil(words(2, &l))
    }

    func testPrivateWindowNoSiteStillLearnsNothing() {
        var l = learner()
        enter(ctx(chrome, isPrivate: true), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.privateWindow), "not even app-level (plan.md Decision)")
    }

    func testUnknownPrivateStatusLearns() {
        var l = learner()
        enter(ctx(chrome, host: "www.ynet.co.il", domain: "ynet.co.il", isPrivate: nil), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        XCTAssertEqual(words(2, &l), .learn(.site(domain: "ynet.co.il"), hebrew))
    }

    func testEmptyBundleIDLearnsNothing() {
        var l = learner()
        enter(ctx(""), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.emptyBundleID))
        XCTAssertNil(words(2, &l))
    }

    func testNoContextYetLearnsNothing() {
        var l = learner()
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.noContext))
    }

    func testLearningOffLearnsNothing() {
        var l = RuleLearner(engine: RuleEngine(rules: []), learningEnabled: false)
        enter(ctx(slack), &l)
        XCTAssertEqual(externalSwitch(hebrew, &l), .discard(.learningDisabled))
    }

    func testLearningTurnedOffWhilePendingBlocksCommit() {
        var l = learner()
        enter(ctx(slack), &l)
        XCTAssertNil(externalSwitch(hebrew, &l))
        l.learningEnabled = false
        XCTAssertEqual(words(2, &l), .discard(.learningDisabled))
    }

    // MARK: - Writing a .learn (P3-19: through RuleWriter, the one writer)

    func testWriterLearnAppendsNewLearnedRule() {
        let id = UUID()
        let now = t0.addingTimeInterval(60)
        let out = RuleWriter.learn(.learn(.app(bundleID: slack), hebrew), into: [], now: now, newID: id)
        XCTAssertEqual(out, [Rule(id: id, scope: .app(bundleID: slack), inputSource: hebrew, origin: .learned, updatedAt: now)])
    }

    func testWriterLearnUpdatesLearnedRuleInPlace() {
        let other = Rule(scope: .app(bundleID: chrome), inputSource: abc, origin: .learned, updatedAt: t0)
        let learned = Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .learned, label: "Slack", updatedAt: t0)
        let now = t0.addingTimeInterval(60)
        let out = RuleWriter.learn(.learn(.app(bundleID: slack), hebrew), into: [other, learned], now: now)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], other)
        XCTAssertEqual(out[1].id, learned.id, "same rule, updated")
        XCTAssertEqual(out[1].inputSource, hebrew)
        XCTAssertEqual(out[1].updatedAt, now)
        XCTAssertEqual(out[1].origin, .learned)
        XCTAssertEqual(out[1].label, "Slack")
    }

    func testWriterLearnMatchesNormalizedHost() {
        let learned = Rule(scope: .site(domain: "Ynet.co.il."), inputSource: abc, origin: .learned, updatedAt: t0)
        let out = RuleWriter.learn(.learn(.site(domain: "ynet.co.il"), hebrew), into: [learned], now: t0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].inputSource, hebrew)
    }

    func testWriterLearnIgnoresDiscard() {
        let rules = [Rule(scope: .app(bundleID: slack), inputSource: abc, origin: .learned, updatedAt: t0)]
        XCTAssertEqual(RuleWriter.learn(.discard(.pinned), into: rules, now: t0), rules)
    }

    // MARK: - End to end with the attributor

    func testOwnSwitchNeverReachesLearnerAsExternal() {
        var attributor = SwitchAttributor(clock: clock, current: abc)
        var l = learner(current: abc)
        enter(ctx(slack), &l)

        func feed(_ change: InputSourceChange?) -> LearnOutcome? {
            switch change {
            case .ours(let id)?: return l.handle(.ourSwitch(id))
            case .external(let id, let t)?: return l.handle(.externalSwitch(id, atNanos: t))
            case nil: return nil
            }
        }

        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 15)
        XCTAssertNil(feed(attributor.didObserve(current: hebrew)))
        XCTAssertNil(feed(attributor.didObserve(current: hebrew)), "duplicate")
        XCTAssertNil(words(2, &l), "our switch is never learned")

        clock.advance(bySeconds: 1)
        XCTAssertNil(feed(attributor.didObserve(current: russian)))   // the user, Ctrl-Space
        XCTAssertEqual(words(2, &l), .learn(.app(bundleID: slack), russian))
    }
}

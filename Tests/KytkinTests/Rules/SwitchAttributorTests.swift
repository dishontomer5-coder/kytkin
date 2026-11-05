// P2-10: SwitchAttributor: the expected-switch token (target + 500 ms deadline), duplicate notifications,
// expiry at and after the deadline, wrong target, and a token used twice (001 §10 P2-10, R1 §3).

import XCTest

final class SwitchAttributorTests: XCTestCase {
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let russian = InputSourceID("com.apple.keylayout.Russian")

    private var clock: FakeClock!
    private var attributor: SwitchAttributor!

    override func setUp() {
        super.setUp()
        clock = FakeClock(nowNanos: 1_000_000_000)
        attributor = SwitchAttributor(clock: clock, current: abc)
    }

    // MARK: - Inside the deadline

    func testOwnSwitchInsideDeadlineIsOurs() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 15)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .ours(hebrew))
    }

    func testJustBeforeDeadlineIsOurs() {
        attributor.willSelect(hebrew)
        clock.advance(byNanos: 499_999_999)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .ours(hebrew))
    }

    func testDuplicateNotificationIsNil() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .ours(hebrew))
        clock.advance(byMilliseconds: 10)
        XCTAssertNil(attributor.didObserve(current: hebrew))
        clock.advance(bySeconds: 2)
        XCTAssertNil(attributor.didObserve(current: hebrew), "still a duplicate long after")
    }

    func testDuplicateOfExternalIsNil() {
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
        XCTAssertNil(attributor.didObserve(current: hebrew))
    }

    func testNotificationForInitialSourceIsNil() {
        XCTAssertNil(attributor.didObserve(current: abc))
    }

    // MARK: - Deadline edge and expiry

    func testExactlyAtDeadlineIsExternal() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 500)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    func testAfterDeadlineIsExternal() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 800)
        XCTAssertFalse(attributor.hasPendingToken(atNanos: clock.nowNanos))
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    func testPendingTokenVisibleUntilDeadline() {
        attributor.willSelect(hebrew)
        XCTAssertTrue(attributor.hasPendingToken(atNanos: clock.nowNanos))
        XCTAssertTrue(attributor.hasPendingToken(atNanos: clock.nowNanos + 499_999_999))
        XCTAssertFalse(attributor.hasPendingToken(atNanos: clock.nowNanos + 500_000_000))
    }

    // MARK: - Wrong target

    func testWrongTargetIsExternalAndDropsToken() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: russian), .external(russian, atNanos: clock.nowNanos))
        // The token is gone, so a later Hebrew change inside the original window is also external.
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    func testNoTokenIsExternal() {
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    // MARK: - Token used twice

    func testTokenMatchesOnlyOnce() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .ours(hebrew))
        // The user switches away and back, still inside the original 500 ms.
        clock.advance(byMilliseconds: 50)
        XCTAssertEqual(attributor.didObserve(current: abc), .external(abc, atNanos: clock.nowNanos))
        clock.advance(byMilliseconds: 50)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    func testNewTokenReplacesOlder() {
        attributor.willSelect(hebrew)
        attributor.willSelect(russian)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
    }

    func testSecondOwnSwitchNeedsItsOwnToken() {
        attributor.willSelect(hebrew)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .ours(hebrew))
        attributor.willSelect(abc)
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(attributor.didObserve(current: abc), .ours(abc))
    }

    // MARK: - No-op select

    func testSelectingCurrentSourceStoresNoToken() {
        attributor.willSelect(abc)   // already current: TIS sends nothing
        XCTAssertFalse(attributor.hasPendingToken(atNanos: clock.nowNanos))
        clock.advance(byMilliseconds: 100)
        XCTAssertEqual(attributor.didObserve(current: hebrew), .external(hebrew, atNanos: clock.nowNanos))
        clock.advance(byMilliseconds: 100)
        XCTAssertEqual(attributor.didObserve(current: abc), .external(abc, atNanos: clock.nowNanos))
    }

    func testUnknownInitialSourceFirstChangeIsExternal() {
        var a = SwitchAttributor(clock: clock)
        XCTAssertEqual(a.didObserve(current: abc), .external(abc, atNanos: clock.nowNanos))
        XCTAssertNil(a.didObserve(current: abc))
    }

    // MARK: - Timestamped overloads (001 signatures)

    func testTimestampedOverloadsIgnoreClock() {
        var a = SwitchAttributor(clock: FakeClock(), current: abc)
        a.willSelect(hebrew, atNanos: 10_000_000_000)
        XCTAssertEqual(a.didObserve(current: hebrew, atNanos: 10_200_000_000), .ours(hebrew))
        a.willSelect(abc, atNanos: 20_000_000_000)
        XCTAssertEqual(a.didObserve(current: abc, atNanos: 20_500_000_000), .external(abc, atNanos: 20_500_000_000))
    }

    func testDeadlineSaturatesNearMax() {
        var a = SwitchAttributor(clock: FakeClock(), current: abc)
        a.willSelect(hebrew, atNanos: .max - 10)
        XCTAssertEqual(a.didObserve(current: hebrew, atNanos: .max - 5), .ours(hebrew))
    }
}

// P3-6: BrowserReadScheduler timings on a fake clock (001 §14.3.4, §14.3.5, B14, B15): read at once on attach,
// 150 ms debounce capped at 500 ms, the 2 s safety poll, readiness retries at +250/+500/+1000/+2000 ms, nothing
// while detached.

import XCTest

final class BrowserReadSchedulerTests: XCTestCase {
    private var clock: FakeClock!
    private var s: BrowserReadScheduler!

    private let ms: UInt64 = 1_000_000
    private let page = BrowserObservation(
        site: SiteAddress(host: "example.com", registrableDomain: "example.com", isWebPage: true),
        pageState: .page, isPrivate: nil, via: .axURL)

    override func setUp() {
        clock = FakeClock(nowNanos: 1_000_000_000)
        s = BrowserReadScheduler()
    }

    private var now: UInt64 { clock.nowNanos }

    /// Advances the clock to the next deadline if it is within `limit`, reads, reports `result`. Returns the read time.
    @discardableResult
    private func runNext(within limit: UInt64 = 10_000 * 1_000_000, result: BrowserObservation? = nil,
                         sawWindow: Bool = true) -> UInt64? {
        guard let d = s.nextDeadlineNanos, d <= now + limit else { return nil }
        if d > now { clock.set(nowNanos: d) }
        XCTAssertTrue(s.takeDue(now: now))
        s.readFinished(result ?? page, sawWindow: sawWindow, now: now)
        return now
    }

    func testConstants() {
        XCTAssertEqual(BrowserReadScheduler.debounceNanos, 150 * ms)
        XCTAssertEqual(BrowserReadScheduler.maxWaitNanos, 500 * ms)
        XCTAssertEqual(BrowserReadScheduler.pollNanos, 2_000 * ms)
        XCTAssertEqual(BrowserReadScheduler.readinessRetryNanos, [250 * ms, 500 * ms, 1_000 * ms, 2_000 * ms])
    }

    func testDetachedHasNoDeadlineAndIgnoresTriggers() {
        XCTAssertNil(s.nextDeadlineNanos)
        s.trigger(.titleChanged, now: now)
        XCTAssertNil(s.nextDeadlineNanos)
        XCTAssertFalse(s.takeDue(now: now + 10_000 * ms))
    }

    func testAttachReadsAtOnce() {
        s.attached(now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now)
        XCTAssertTrue(s.takeDue(now: now))
        XCTAssertFalse(s.takeDue(now: now), "consumed")
    }

    func testSuccessfulAttachReadThenPollsEveryTwoSeconds() {
        s.attached(now: now)
        let t0 = runNext()!
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 2_000 * ms, "no retries after a good read")
        clock.advance(byMilliseconds: 1_999)
        XCTAssertFalse(s.takeDue(now: now))
        XCTAssertEqual(runNext(), t0 + 2_000 * ms)
        XCTAssertEqual(runNext(), t0 + 4_000 * ms)
    }

    func testTriggerDebounces150ms() {
        s.attached(now: now)
        let t0 = runNext()!
        clock.advance(byMilliseconds: 300)
        s.trigger(.loadComplete, now: now)   // P3-29: a focus change reads at once instead (tests below)
        XCTAssertEqual(s.nextDeadlineNanos, now + 150 * ms)
        clock.advance(byMilliseconds: 100)
        s.trigger(.titleChanged, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now + 150 * ms, "the last trigger restarts the wait")
        clock.advance(byMilliseconds: 149)
        XCTAssertFalse(s.takeDue(now: now))
        XCTAssertEqual(runNext(), t0 + 300 * ms + 100 * ms + 150 * ms)
        XCTAssertEqual(s.nextDeadlineNanos, now + 2_000 * ms, "the poll restarts after the read")
    }

    // MARK: - P3-29: focus changes read at once (⌘L / a click into the address bar)

    func testAFocusChangeReadsAtOnceThenTheTrailingReadFollows() {
        s.attached(now: now)
        let t0 = runNext()!
        clock.advance(byMilliseconds: 300)
        s.trigger(.focusedElementChanged, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now, "leading edge: no 150 ms debounce")
        XCTAssertTrue(s.takeDue(now: now))
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 300 * ms + 150 * ms, "the burst's trailing read still follows")
        XCTAssertEqual(runNext(), t0 + 450 * ms)
        XCTAssertEqual(s.nextDeadlineNanos, now + 2_000 * ms, "then only the poll")
    }

    func testFocusReadsAreGappedTo50ms() {
        s.attached(now: now)
        _ = runNext()
        clock.advance(byMilliseconds: 10)
        s.trigger(.focusedElementChanged, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now + 40 * ms, "50 ms after the last read")
        XCTAssertFalse(s.takeDue(now: now))
        clock.advance(byMilliseconds: 40)
        XCTAssertTrue(s.takeDue(now: now))
        // A storm: one focus change every 5 ms for 1 s → at most one leading read per 50 ms, plus the trailing ones.
        var reads = 0
        for _ in 0..<200 {
            clock.advance(byMilliseconds: 5)
            s.trigger(.focusedElementChanged, now: now)
            if s.takeDue(now: now) { reads += 1 }
        }
        XCTAssertLessThanOrEqual(reads, 1_000 / 50 + 1 + 2)
        XCTAssertGreaterThanOrEqual(reads, 1_000 / 50 - 1)
    }

    func testAFocusStormOnASlowPageKeepsTheAXThreadAtMostHalfBusy() {
        // QA (P3-29): every read takes 120 ms (a heavy page); focus notifications queue during each read and arrive
        // right after it. Without the duty cap each one would start the next read at once (back to back).
        s.attached(now: now)
        _ = s.takeDue(now: now)
        clock.advance(byMilliseconds: 120)
        s.readFinished(page, sawWindow: true, now: now)
        let start = now
        var busy: UInt64 = 0
        var steps = 0
        while now < start + 2_000 * ms, steps < 1_000 {   // bounded
            steps += 1
            s.trigger(.focusedElementChanged, now: now)
            if s.takeDue(now: now) {
                clock.advance(byMilliseconds: 120)
                busy += 120 * ms
                s.readFinished(page, sawWindow: true, now: now)
            } else {
                clock.advance(byMilliseconds: 5)
            }
        }
        // Focus reads alone: ≤ 50 %; the burst's 500 ms max-wait read comes on top (≤ 1 per 500 ms).
        XCTAssertLessThanOrEqual(Double(busy) / Double(now - start), 0.65)
        XCTAssertGreaterThan(busy, 0)
    }

    func testAFastReadStillAllowsTheNextFocusReadAfter50ms() {
        s.attached(now: now)
        _ = s.takeDue(now: now)
        clock.advance(byMilliseconds: 5)
        s.readFinished(page, sawWindow: true, now: now)
        s.trigger(.focusedElementChanged, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now + 50 * ms, "50 ms after the read ended")
    }

    func testAFocusReadInsideABurstStillLetsTheBurstEnd() {
        s.attached(now: now)
        _ = runNext()
        clock.advance(byMilliseconds: 500)
        s.trigger(.titleChanged, now: now)
        clock.advance(byMilliseconds: 100)
        s.trigger(.focusedElementChanged, now: now)
        XCTAssertTrue(s.takeDue(now: now), "the focus read doesn't wait for the title burst")
        XCTAssertEqual(s.nextDeadlineNanos, now + 150 * ms, "the burst ends 150 ms after its last trigger")
    }

    func testEndlessBurstStillReadsWithin500ms() {
        s.attached(now: now)
        runNext()
        var burstStart = now
        s.trigger(.loadComplete, now: now)
        var reads = 0
        for _ in 0..<10 {   // a trigger every 100 ms for 1 s
            clock.advance(byMilliseconds: 100)
            if s.takeDue(now: now) {
                reads += 1
                XCTAssertEqual(now, burstStart + 500 * ms)
                s.readFinished(page, sawWindow: true, now: now)
                burstStart = now
            }
            s.trigger(.loadComplete, now: now)
        }
        XCTAssertEqual(reads, 2, "at 500 ms and at 1000 ms")
    }

    func testWakeAndReattachReadAtOnce() {
        s.attached(now: now)
        runNext()
        clock.advance(byMilliseconds: 700)
        s.trigger(.wake, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now)
        runNext()
        clock.advance(byMilliseconds: 50)
        s.trigger(.attached, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, now)
    }

    func testReadinessRetriesWhileNothingIsRead() {
        s.attached(now: now)
        let t0 = now
        var times: [UInt64] = []
        runNext(result: .unknown(), sawWindow: false)
        // QA (P3-7): bounded, so a scheduler regression fails instead of hanging the test run.
        while times.count < 20, let t = runNext(within: 1_900 * ms, result: .unknown(), sawWindow: false) {
            times.append(t - t0)
        }
        XCTAssertEqual(times, [250 * ms, 500 * ms, 1_000 * ms, 2_000 * ms])
        // Then only the poll.
        XCTAssertEqual(s.nextDeadlineNanos, now + 2_000 * ms)
    }

    func testRetriesAlsoForUnknownWithAWindow() {
        s.attached(now: now)
        let t0 = now
        runNext(result: .unknown(), sawWindow: true)
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 250 * ms)
    }

    func testRetriesStopAtTheFirstGoodRead() {
        s.attached(now: now)
        let t0 = now
        runNext(result: .unknown(), sawWindow: false)
        XCTAssertEqual(runNext(result: .unknown(), sawWindow: false), t0 + 250 * ms)
        XCTAssertEqual(runNext(), t0 + 500 * ms)
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 500 * ms + 2_000 * ms, "no more retries, just the poll")
    }

    func testATriggeredGoodReadEndsRetriesToo() {
        s.attached(now: now)
        let t0 = now
        runNext(result: .unknown(), sawWindow: false)
        clock.advance(byMilliseconds: 50)
        s.trigger(.focusedWindowChanged, now: now)
        XCTAssertEqual(runNext(), t0 + 200 * ms, "the debounced read comes before the 250 ms retry")
        XCTAssertEqual(s.nextDeadlineNanos, now + 2_000 * ms)
    }

    func testABadTriggeredReadKeepsTheRetryScheduleRelativeToAttach() {
        s.attached(now: now)
        let t0 = now
        runNext(result: .unknown(), sawWindow: false)
        clock.advance(byMilliseconds: 300)   // past the 250 ms retry without reading
        s.trigger(.titleChanged, now: now)
        // The overdue retry is due now and coalesces with the trigger.
        XCTAssertTrue(s.takeDue(now: now))
        s.readFinished(.unknown(), sawWindow: true, now: now)
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 500 * ms)
    }

    func testEditingAddressEndsRetries() {
        s.attached(now: now)
        runNext(result: BrowserObservation(site: nil, pageState: .editingAddress, isPrivate: nil, via: .kept))
        XCTAssertEqual(s.nextDeadlineNanos, now + 2_000 * ms)
    }

    func testDetachClearsEverything() {
        s.attached(now: now)
        s.trigger(.titleChanged, now: now)
        s.detached()
        XCTAssertNil(s.nextDeadlineNanos)
        XCTAssertFalse(s.isAttached)
        XCTAssertFalse(s.takeDue(now: now + 5_000 * ms))
    }

    func testDueReasonsCoalesceIntoOneRead() {
        s.attached(now: now)
        runNext()
        clock.advance(byMilliseconds: 1_950)
        s.trigger(.titleChanged, now: now)   // due at 2100 ms; the poll is due at 2000 ms
        clock.advance(byMilliseconds: 200)
        XCTAssertTrue(s.takeDue(now: now))
        XCTAssertFalse(s.takeDue(now: now), "poll and burst consumed by the same read")
    }
}

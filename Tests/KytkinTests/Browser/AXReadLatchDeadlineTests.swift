// P3-10: The read's wall-clock deadline (001 §14.3.3, B13). A slow browser that answers every call just under the
// 0.25 s messaging timeout never trips the first-timeout rule; with a clock the latch stops the read after 0.5 s.

import XCTest

/// A tree that costs `stepNanos` of fake time per call: a slow (not hung) browser.
final class SlowAXTree: AXNodeReading {
    typealias Node = Int
    let base: FakeAXTree
    let clock: FakeClock
    let stepNanos: UInt64

    init(_ base: FakeAXTree, clock: FakeClock, stepNanos: UInt64) {
        self.base = base
        self.clock = clock
        self.stepNanos = stepNanos
    }

    private func tick() { clock.advance(byNanos: stepNanos) }

    func focusedElement() throws(AXReadError) -> Int? { tick(); return try base.focusedElement() }
    func mainWindow() throws(AXReadError) -> Int? { tick(); return try base.mainWindow() }
    func focusedWindow() throws(AXReadError) -> Int? { tick(); return try base.focusedWindow() }
    func parent(of n: Int) throws(AXReadError) -> Int? { tick(); return try base.parent(of: n) }
    func children(of n: Int) throws(AXReadError) -> [Int] { tick(); return try base.children(of: n) }
    func string(_ a: AXStringAttribute, of n: Int) throws(AXReadError) -> String? { tick(); return try base.string(a, of: n) }
    func url(of n: Int) throws(AXReadError) -> String? { tick(); return try base.url(of: n) }
    func isFocused(_ n: Int) throws(AXReadError) -> Bool? { tick(); return try base.isFocused(n) }
    func area(of n: Int) throws(AXReadError) -> Double? { tick(); return try base.area(of: n) }
    func isSame(_ a: Int, _ b: Int) -> Bool { base.isSame(a, b) }
}

final class AXReadLatchDeadlineTests: XCTestCase {
    func testLatchTripsOnceTheBudgetIsSpent() throws {
        let arc = BrowserFixtures.arc()
        let clock = FakeClock(nowNanos: 10_000_000_000)
        let latch = AXReadLatch(clock: clock, startedAt: clock.nowNanos)
        let tree = LatchedAXTree(arc.tree, latch: latch)
        XCTAssertEqual(try tree.mainWindow(), arc.window)
        clock.advance(byMilliseconds: 499)
        XCTAssertEqual(try tree.mainWindow(), arc.window, "still inside the 0.5 s budget")
        XCTAssertFalse(latch.tripped)
        clock.advance(byMilliseconds: 1)
        let before = arc.tree.calls.count
        XCTAssertThrowsError(try tree.mainWindow()) { XCTAssertEqual($0 as? AXReadError, .timedOut) }
        XCTAssertTrue(latch.tripped)
        XCTAssertEqual(arc.tree.calls.count, before, "the over-budget call never reached the browser")
        XCTAssertThrowsError(try tree.focusedElement()) { XCTAssertEqual($0 as? AXReadError, .timedOut) }
    }

    func testResetStartsANewBudget() throws {
        let arc = BrowserFixtures.arc()
        let clock = FakeClock(nowNanos: 1)
        let latch = AXReadLatch(clock: clock, startedAt: 1, budgetNanos: 100)
        let tree = LatchedAXTree(arc.tree, latch: latch)
        clock.advance(byNanos: 200)
        XCTAssertThrowsError(try tree.mainWindow())
        latch.reset()
        XCTAssertEqual(try tree.mainWindow(), arc.window)
    }

    func testNoClockMeansNoDeadline() throws {
        let arc = BrowserFixtures.arc()
        let latch = AXReadLatch()
        let tree = LatchedAXTree(arc.tree, latch: latch)
        XCTAssertEqual(try tree.mainWindow(), arc.window)
        XCTAssertFalse(latch.tripped)
    }

    /// B13: a scan over a slow browser (each call 0.2 s, never a timeout) stops after ~0.5 s, not after 400 nodes.
    func testReaderStopsASlowReadAfterTheBudget() throws {
        let siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
        let chrome = BrowserFixtures.chrome()
        chrome.tree.focused = nil
        let clock = FakeClock(nowNanos: 5_000_000_000)
        let slow = SlowAXTree(chrome.tree, clock: clock, stepNanos: 200_000_000)
        let strategy = ScanAllStrategy()
        let request = BrowserWatchRequest(engine: .chromium, alwaysPrivate: false, ignorePrivateWindows: false,
                                          appleScript: nil)
        var reader = BrowserAddressReader<SlowAXTree>(
            request: request, siteReader: siteReader, strategy: strategy,
            privateProbe: { (_: LatchedAXTree<SlowAXTree>, _: Int) throws(AXReadError) -> Bool? in nil })
        reader.deadlineClock = clock
        let start = clock.nowNanos
        let (o, sawWindow) = reader.read(slow, now: start)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertLessThanOrEqual(clock.nowNanos - start, 700_000_000, "≤ budget + one call")
        XCTAssertTrue(strategy.stoppedByTimeout)

        // Without the clock the same read would walk the whole window.
        let clock2 = FakeClock(nowNanos: 5_000_000_000)
        let slow2 = SlowAXTree(BrowserFixtures.chrome().tree, clock: clock2, stepNanos: 200_000_000)
        var plain = BrowserAddressReader<SlowAXTree>(
            request: request, siteReader: siteReader, strategy: ScanAllStrategy(),
            privateProbe: { (_: LatchedAXTree<SlowAXTree>, _: Int) throws(AXReadError) -> Bool? in nil })
        _ = plain.read(slow2, now: clock2.nowNanos)
        XCTAssertGreaterThan(clock2.nowNanos - 5_000_000_000, 1_000_000_000)
    }
}

/// Walks the whole window (children of every node), then gives up: a stand-in for a full scan.
final class ScanAllStrategy: BrowserReadStrategy {
    typealias Tree = LatchedAXTree<SlowAXTree>
    var stoppedByTimeout = false

    func read(_ tree: Tree, prelude: BrowserReadPrelude<Int>, window: inout BrowserWindowState<Int>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        do {
            try AXTreeScan.breadthFirst(tree, from: prelude.window) { (_: Int) throws(AXReadError) in .descend }
        } catch {
            stoppedByTimeout = error == .timedOut
            throw error
        }
        return .unknown
    }
}

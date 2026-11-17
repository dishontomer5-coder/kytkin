// P3-6: The browser read's timeout latch (001 §14.3.3, B13): the first `.timedOut` stops every later call of the
// read without asking the browser; other errors don't trip it.

import XCTest

final class LatchedAXTreeTests: XCTestCase {
    func testFirstTimeoutTripsTheLatch() throws {
        let arc = BrowserFixtures.arc()
        let latch = AXReadLatch()
        let tree = LatchedAXTree(arc.tree, latch: latch)
        XCTAssertEqual(try tree.url(of: arc.webArea), "https://example.org/docs")
        arc.tree.errors[arc.webArea] = .timedOut
        XCTAssertThrowsError(try tree.url(of: arc.webArea)) { XCTAssertEqual($0 as? AXReadError, .timedOut) }
        XCTAssertTrue(latch.tripped)
        let before = arc.tree.calls.count
        for call in [{ _ = try tree.focusedElement() }, { _ = try tree.mainWindow() }, { _ = try tree.focusedWindow() },
                     { _ = try tree.parent(of: arc.focusedButton) }, { _ = try tree.children(of: arc.window) },
                     { _ = try tree.string(.role, of: arc.window) }, { _ = try tree.isFocused(arc.window) },
                     { _ = try tree.area(of: arc.window) }] as [() throws -> Void] {
            XCTAssertThrowsError(try call()) { XCTAssertEqual($0 as? AXReadError, .timedOut) }
        }
        XCTAssertEqual(arc.tree.calls.count, before, "nothing reached the browser after the timeout")
        XCTAssertTrue(tree.isSame(arc.window, arc.window), "isSame asks the browser nothing")
        latch.reset()
        XCTAssertEqual(try tree.string(.role, of: arc.window), "AXWindow")
    }

    func testOtherErrorsDontTripIt() throws {
        let arc = BrowserFixtures.arc()
        let latch = AXReadLatch()
        let tree = LatchedAXTree(arc.tree, latch: latch)
        for error in [AXReadError.invalidElement, .apiDisabled, .other] {
            arc.tree.errors[arc.webArea] = error
            XCTAssertThrowsError(try tree.url(of: arc.webArea)) { XCTAssertEqual($0 as? AXReadError, error) }
            XCTAssertFalse(latch.tripped)
        }
        XCTAssertEqual(try tree.mainWindow(), arc.window)
    }
}
